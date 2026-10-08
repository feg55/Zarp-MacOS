package route

import (
	"errors"
	"net"
	"net/netip"
	"reflect"
	"strings"
	"testing"
)

// tunnelWorld is a fake system: a routing table the fake `route` command reads and writes, so the
// tests assert on *state* (what routes exist) as well as on commands.
type tunnelWorld struct {
	gateways map[string]string // "inet 162.159.198.2" -> gateway, for routes added through one
	routes   map[string]string // "inet 0.0.0.0/1" -> interface
	failAdd  map[string]error  // key -> error returned when adding that route
	dnsCalls []string
	fail     func(name string, args []string) (string, error) // optional override, checked first
}

func newWorld() *tunnelWorld {
	return &tunnelWorld{routes: map[string]string{}, failAdd: map[string]error{}, gateways: map[string]string{}}
}

var (
	testEndpoint = netip.MustParseAddr("162.159.198.2")
	testPhys     = &Physical{Interface: "en0", Gateway: net.ParseIP("192.168.34.1")}
)

const exclusionKey = "inet 162.159.198.2"

func (w *tunnelWorld) run(name string, args []string) (string, error) {
	if w.fail != nil {
		if out, err := w.fail(name, args); err != nil || out != "" {
			return out, err
		}
	}
	if name != routeBin {
		return "", nil
	}
	// args: -n add|get|delete [-inet|-inet6|-host] DEST [GATEWAY | -interface IF]
	verb := args[1]
	var fam, dest, iface string
	for i := 2; i < len(args); i++ {
		switch args[i] {
		case "-inet", "-inet6":
			fam = args[i][1:]
		case "-host":
			fam = "inet"
		case "-interface":
			iface = args[i+1]
			i++
		default:
			if dest == "" {
				dest = args[i]
			} else {
				iface = "en0" // a gateway: the route leaves through the physical interface
				w.gateways[fam+" "+dest] = args[i]
			}
		}
	}
	key := fam + " " + dest
	switch verb {
	case "add":
		if err, bad := w.failAdd[key]; bad {
			return "route: writing to routing socket: " + err.Error(), errors.New("exit status 1")
		}
		if _, exists := w.routes[key]; exists {
			return "route: writing to routing socket: File exists", errors.New("exit status 1")
		}
		w.routes[key] = iface
	case "get":
		if ifc, ok := w.routes[key]; ok {
			return routeGetVia(ifc), nil
		}
		return routeGetVia("en0"), nil // best match is the default route
	case "delete":
		if _, ok := w.routes[key]; !ok {
			return "route: writing to routing socket: not in table", errors.New("exit status 1")
		}
		delete(w.routes, key)
	}
	return "", nil
}

func (w *tunnelWorld) router() (*Router, *fakeRunner) {
	f := &fakeRunner{handler: w.run}
	return New(f), f
}

func TestFullTunnelAppliesBothFamiliesAndTearsDownCompletely(t *testing.T) {
	w := newWorld()
	r, f := w.router()
	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", IPv6Addr: "2606:4700:110::1", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err != nil || len(warnings) != 0 {
		t.Fatalf("err=%v warnings=%v", err, warnings)
	}
	wantRoutes := map[string]string{
		"inet 0.0.0.0/1": "utun5", "inet 128.0.0.0/1": "utun5",
		"inet6 ::/1": "utun5", "inet6 8000::/1": "utun5",
		exclusionKey: "en0", // the WARP endpoint stays on the physical network
	}
	if !reflect.DeepEqual(w.routes, wantRoutes) {
		t.Fatalf("routes after enable: %v", w.routes)
	}
	// The default route itself is never touched.
	for _, c := range f.log() {
		if strings.Contains(c, " default") || strings.Contains(c, "-net 0.0.0.0 ") {
			t.Fatalf("the default route must not be modified: %q", c)
		}
	}
	if errs := ft.Disable(); len(errs) != 0 {
		t.Fatalf("Disable errors: %v", errs)
	}
	if len(w.routes) != 0 {
		t.Fatalf("routes left behind after Disable: %v", w.routes)
	}
	if errs := ft.Disable(); len(errs) != 0 { // idempotent
		t.Fatalf("second Disable: %v", errs)
	}
}

func TestFullTunnelIPv4Only(t *testing.T) {
	w := newWorld()
	r, f := w.router()
	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err != nil || len(warnings) != 0 {
		t.Fatalf("err=%v warnings=%v", err, warnings)
	}
	if len(w.routes) != 3 { // 0/1, 128/1 and the endpoint exclusion
		t.Fatalf("routes: %v", w.routes)
	}
	for _, c := range f.log() {
		if strings.Contains(c, "inet6") {
			t.Fatalf("no IPv6 command expected without an IPv6 address: %q", c)
		}
	}
	ft.Disable()
}

func TestFullTunnelRollsBackWhenAnIPv4RouteFails(t *testing.T) {
	w := newWorld()
	w.routes["inet 128.0.0.0/1"] = "utun28" // another VPN already owns the upper half
	r, _ := w.router()
	ft, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", IPv6Addr: "2606:4700:110::1", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err == nil || ft != nil {
		t.Fatalf("expected a failure, got ft=%v err=%v", ft, err)
	}
	if !errors.Is(err, ErrRouteExists) || !strings.Contains(err.Error(), "another VPN") {
		t.Fatalf("the error should say another VPN owns the route: %v", err)
	}
	// The first half was added and must be taken back; the other VPN's route must be untouched.
	want := map[string]string{"inet 128.0.0.0/1": "utun28"}
	if !reflect.DeepEqual(w.routes, want) {
		t.Fatalf("routing table after rollback: %v (want only the other VPN's route)", w.routes)
	}
}

func TestFullTunnelKeepsIPv4WhenIPv6Fails(t *testing.T) {
	w := newWorld()
	w.failAdd["inet6 8000::/1"] = errors.New("Network is unreachable")
	r, _ := w.router()
	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", IPv6Addr: "2606:4700:110::1", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err != nil {
		t.Fatalf("IPv6 trouble must not fail the tunnel: %v", err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "IPv6") {
		t.Fatalf("warnings: %v", warnings)
	}
	// IPv6 is all-or-nothing: the half that was added is removed again, IPv4 stays.
	want := map[string]string{"inet 0.0.0.0/1": "utun5", "inet 128.0.0.0/1": "utun5", exclusionKey: "en0"}
	if !reflect.DeepEqual(w.routes, want) {
		t.Fatalf("routes: %v", w.routes)
	}
	ft.Disable()
	if len(w.routes) != 0 {
		t.Fatalf("left behind: %v", w.routes)
	}
}

func TestFullTunnelKeepsIPv4WhenTheIPv6AddressCannotBeSet(t *testing.T) {
	w := newWorld()
	w.fail = func(name string, args []string) (string, error) {
		if name == ifconfigBin {
			return "ifconfig: bad value", errors.New("exit status 1")
		}
		return "", nil
	}
	r, _ := w.router()
	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", IPv6Addr: "2606:4700:110::1", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err != nil || len(warnings) != 1 {
		t.Fatalf("err=%v warnings=%v", err, warnings)
	}
	for k := range w.routes {
		if strings.HasPrefix(k, "inet6") {
			t.Fatalf("no IPv6 route may be added without the address: %v", w.routes)
		}
	}
	ft.Disable()
}

func TestFullTunnelDNSOverrideIsBestEffortAndUndone(t *testing.T) {
	w := newWorld()
	dnsWorld := newDNSWorld()
	w.fail = dnsWorld.fail
	r, _ := w.router()
	dns := NewDNSOverride(&fakeRunner{handler: w.run}, t.TempDir()+"/dns.json")
	phys := &Physical{Interface: "en0"}

	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", IPv6Addr: "2606:4700:110::1", OverrideDNS: true, Physical: phys, Exclude: testEndpoint}, dns)
	if err != nil || len(warnings) != 0 {
		t.Fatalf("err=%v warnings=%v", err, warnings)
	}
	got := dnsWorld.servers["Wi-Fi"]
	if len(got) != 4 || got[0] != "1.1.1.1" || got[2] != "2606:4700:4700::1111" {
		t.Fatalf("DNS while connected (with IPv6 tunnelled): %v", got)
	}
	if errs := ft.Disable(); len(errs) != 0 {
		t.Fatalf("Disable: %v", errs)
	}
	if got := dnsWorld.servers["Wi-Fi"]; len(got) != 0 {
		t.Fatalf("DNS after Disable should be back to automatic, got %v", got)
	}
	if len(w.routes) != 0 {
		t.Fatalf("routes left behind: %v", w.routes)
	}
}

func TestFullTunnelDNSOnlyUsesIPv6ResolversWhenIPv6IsTunnelled(t *testing.T) {
	w := newWorld()
	dnsWorld := newDNSWorld()
	w.fail = dnsWorld.fail
	r, _ := w.router()
	dns := NewDNSOverride(&fakeRunner{handler: w.run}, t.TempDir()+"/dns.json")
	ft, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", OverrideDNS: true, Physical: &Physical{Interface: "en0"}, Exclude: testEndpoint}, dns)
	if err != nil {
		t.Fatal(err)
	}
	if got := dnsWorld.servers["Wi-Fi"]; !reflect.DeepEqual(got, CloudflareDNSv4) {
		t.Fatalf("IPv4-only tunnel should use only IPv4 resolvers, got %v", got)
	}
	ft.Disable()
}

func TestFullTunnelDNSFailureOnlyWarns(t *testing.T) {
	w := newWorld()
	w.fail = func(name string, args []string) (string, error) {
		if name == networksetup {
			return "networksetup: boom", errors.New("exit status 1")
		}
		return "", nil
	}
	r, _ := w.router()
	dns := NewDNSOverride(&fakeRunner{handler: w.run}, t.TempDir()+"/dns.json")
	ft, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", OverrideDNS: true, Physical: &Physical{Interface: "en0"}, Exclude: testEndpoint}, dns)
	if err != nil {
		t.Fatalf("a DNS problem must not fail the tunnel: %v", err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "DNS") {
		t.Fatalf("warnings: %v", warnings)
	}
	if len(w.routes) != 3 {
		t.Fatalf("the tunnel itself must still be up: %v", w.routes)
	}
	ft.Disable()
}

func TestFullTunnelWarnsWithoutADNSManager(t *testing.T) {
	w := newWorld()
	r, _ := w.router()
	_, warnings, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", OverrideDNS: true, Physical: &Physical{Interface: "en0"}, Exclude: testEndpoint}, nil)
	if err != nil || len(warnings) != 1 {
		t.Fatalf("err=%v warnings=%v", err, warnings)
	}
}

func TestFullTunnelNeedsAnInterface(t *testing.T) {
	r := New(&fakeRunner{})
	if _, _, err := r.EnableFullTunnel(FullTunnelConfig{Exclude: testEndpoint, Physical: testPhys}, nil); err == nil {
		t.Fatal("expected an error")
	}
}
