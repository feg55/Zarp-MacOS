package route

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// fakeRunner records every command and answers through handler (nil handler = succeed silently).
type fakeRunner struct {
	mu      sync.Mutex
	calls   []string
	handler func(name string, args []string) (string, error)
}

func (f *fakeRunner) Run(name string, args ...string) (string, error) {
	f.mu.Lock()
	f.calls = append(f.calls, strings.TrimSpace(name+" "+strings.Join(args, " ")))
	h := f.handler
	f.mu.Unlock()
	if h != nil {
		return h(name, args)
	}
	return "", nil
}

func (f *fakeRunner) log() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

// A real `route -n get` answer for a destination that is itself routed through utun5.
func routeGetVia(iface string) string {
	return fmt.Sprintf(`   route to: 0.0.0.0
destination: 0.0.0.0
       mask: 128.0.0.0
  interface: %s
      flags: <UP,DONE,STATIC,CLONING,GLOBAL>
 recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
       0         0         0         0         0         0      1280         0
`, iface)
}

func TestParseRouteGet(t *testing.T) {
	out := `   route to: default
destination: default
       mask: default
    gateway: 192.168.34.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
 recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
       0         0         0         0         0         0      1500         0
`
	got := parseRouteGet(out)
	if got["interface"] != "en0" || got["gateway"] != "192.168.34.1" || got["route to"] != "default" {
		t.Fatalf("parsed %v", got)
	}
	if v6 := parseRouteGet("    gateway: fe80::1%en0\n  interface: en0\n"); v6["gateway"] != "fe80::1%en0" {
		t.Fatalf("an IPv6 gateway (colons in the value) must survive: %v", v6)
	}
}

func TestCurrentDefaultUsesTheInterfaceFromRouteGet(t *testing.T) {
	r := New(&fakeRunner{handler: func(name string, args []string) (string, error) {
		return "    gateway: 10.0.0.1\n  interface: lo0\n", nil
	}})
	p, err := r.CurrentDefault()
	if err != nil {
		t.Fatal(err)
	}
	if p.Interface != "lo0" || p.Index == 0 || p.Gateway.String() != "10.0.0.1" || p.IsTunnel() {
		t.Fatalf("got %+v", p)
	}
	if !(&Physical{Interface: "utun28"}).IsTunnel() || (&Physical{Interface: "en0"}).IsTunnel() {
		t.Fatal("IsTunnel misclassifies")
	}
}

func TestCurrentDefaultErrors(t *testing.T) {
	r := New(&fakeRunner{handler: func(string, []string) (string, error) { return "route: not in table", errors.New("exit 1") }})
	if _, err := r.CurrentDefault(); err == nil {
		t.Fatal("a failing route command must be an error")
	}
	r = New(&fakeRunner{handler: func(string, []string) (string, error) { return "garbage\n", nil }})
	if _, err := r.CurrentDefault(); err == nil || !strings.Contains(err.Error(), "no interface") {
		t.Fatalf("output without an interface must be an error, got %v", err)
	}
}

func TestRouteCommandsUseAbsolutePathsAndTheRightFamily(t *testing.T) {
	f := &fakeRunner{}
	r := New(f)
	if err := r.AddHostRoute("1.1.1.1", "utun5"); err != nil {
		t.Fatal(err)
	}
	if err := r.AddNetRoute("0.0.0.0/1", "utun5"); err != nil {
		t.Fatal(err)
	}
	if err := r.AddNetRoute("8000::/1", "utun5"); err != nil {
		t.Fatal(err)
	}
	if err := r.ConfigureAddress("utun5", "172.16.0.2"); err != nil {
		t.Fatal(err)
	}
	if err := r.ConfigureAddress6("utun5", "2606:4700:110::1"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"/sbin/route -n add -host 1.1.1.1 -interface utun5",
		"/sbin/route -n add -inet 0.0.0.0/1 -interface utun5",
		"/sbin/route -n add -inet6 8000::/1 -interface utun5",
		"/sbin/ifconfig utun5 inet 172.16.0.2 172.16.0.2 up",
		"/sbin/ifconfig utun5 inet6 2606:4700:110::1 prefixlen 128 alias",
	}
	if got := f.log(); !reflect.DeepEqual(got, want) {
		t.Fatalf("commands:\n got %q\nwant %q", got, want)
	}
}

func TestAddRouteReportsAnExistingRouteDistinctly(t *testing.T) {
	r := New(&fakeRunner{handler: func(string, []string) (string, error) {
		return "route: writing to routing socket: File exists\nadd net 0.0.0.0: gateway utun5: route already in use\n", errors.New("exit status 1")
	}})
	err := r.AddNetRoute("0.0.0.0/1", "utun5")
	if !errors.Is(err, ErrRouteExists) {
		t.Fatalf("expected ErrRouteExists, got %v", err)
	}
	if err := New(&fakeRunner{handler: func(string, []string) (string, error) { return "boom", errors.New("exit status 1") }}).AddHostRoute("1.1.1.1", "utun5"); err == nil || errors.Is(err, ErrRouteExists) {
		t.Fatalf("an ordinary failure must not look like ErrRouteExists: %v", err)
	}
}

func TestDeleteRouteIfOurs(t *testing.T) {
	t.Run("deletes our own route", func(t *testing.T) {
		f := &fakeRunner{handler: func(name string, args []string) (string, error) {
			if args[1] == "get" {
				return routeGetVia("utun5"), nil
			}
			return "", nil
		}}
		deleted, err := New(f).DeleteRouteIfOurs("0.0.0.0/1", false, "utun5")
		if err != nil || !deleted {
			t.Fatalf("deleted=%v err=%v", deleted, err)
		}
		want := []string{"/sbin/route -n get -inet 0.0.0.0/1", "/sbin/route -n delete -inet 0.0.0.0/1"}
		if !reflect.DeepEqual(f.log(), want) {
			t.Fatalf("commands %q", f.log())
		}
	})
	t.Run("leaves a route someone else owns", func(t *testing.T) {
		// 1.1.1.1 resolves to the user's own VPN (utun28), not our tunnel: must not be deleted.
		f := &fakeRunner{handler: func(name string, args []string) (string, error) { return routeGetVia("utun28"), nil }}
		deleted, err := New(f).DeleteRouteIfOurs("1.1.1.1", true, "utun5")
		if err != nil || deleted {
			t.Fatalf("deleted=%v err=%v", deleted, err)
		}
		for _, c := range f.log() {
			if strings.Contains(c, " delete ") {
				t.Fatalf("a route we don't own was deleted: %q", f.log())
			}
		}
	})
	t.Run("a route that is already gone is not an error", func(t *testing.T) {
		f := &fakeRunner{handler: func(name string, args []string) (string, error) {
			return "route: writing to routing socket: not in table", errors.New("exit status 1")
		}}
		deleted, err := New(f).DeleteRouteIfOurs("1.1.1.1", true, "utun5")
		if err != nil || deleted {
			t.Fatalf("deleted=%v err=%v", deleted, err)
		}
	})
	t.Run("a vanishing route between get and delete is fine", func(t *testing.T) {
		f := &fakeRunner{handler: func(name string, args []string) (string, error) {
			if args[1] == "get" {
				return routeGetVia("utun5"), nil
			}
			return "route: writing to routing socket: not in table", errors.New("exit status 1")
		}}
		if deleted, err := New(f).DeleteRouteIfOurs("1.1.1.1", true, "utun5"); err != nil || deleted {
			t.Fatalf("deleted=%v err=%v", deleted, err)
		}
	})
	t.Run("a real failure is reported", func(t *testing.T) {
		f := &fakeRunner{handler: func(name string, args []string) (string, error) {
			if args[1] == "get" {
				return routeGetVia("utun5"), nil
			}
			return "route: bad", errors.New("exit status 1")
		}}
		if _, err := New(f).DeleteRouteIfOurs("1.1.1.1", true, "utun5"); err == nil {
			t.Fatal("expected an error")
		}
	})
	t.Run("IPv6 uses -inet6", func(t *testing.T) {
		f := &fakeRunner{handler: func(name string, args []string) (string, error) {
			if args[1] == "get" {
				return routeGetVia("utun5"), nil
			}
			return "", nil
		}}
		if _, err := New(f).DeleteRouteIfOurs("::/1", false, "utun5"); err != nil {
			t.Fatal(err)
		}
		if got := f.log(); got[0] != "/sbin/route -n get -inet6 ::/1" || got[1] != "/sbin/route -n delete -inet6 ::/1" {
			t.Fatalf("commands %q", got)
		}
	})
}
