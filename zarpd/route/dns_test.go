package route

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Real `networksetup -listnetworkserviceorder` output (captured on a Mac with several VPN-type
// services, which list an empty Device).
const sampleServiceOrder = `An asterisk (*) denotes that a network service is disabled.
(1) AX88179A
(Hardware Port: AX88179A, Device: en5)

(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(3) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(4) iPhone USB
(Hardware Port: iPhone USB, Device: en6)

(5) feg1955
(Hardware Port: com.wireguard.macos, Device: )

(*) Old Ethernet
(Hardware Port: Ethernet, Device: en9)

(7) Happ
(Hardware Port: su.ffg.happ, Device: )
`

func TestParseServiceOrder(t *testing.T) {
	got := parseServiceOrder(sampleServiceOrder)
	want := []serviceEntry{
		{"AX88179A", "en5", false},
		{"Thunderbolt Bridge", "bridge0", false},
		{"Wi-Fi", "en0", false},
		{"iPhone USB", "en6", false},
		{"feg1955", "", false},
		{"Old Ethernet", "en9", true},
		{"Happ", "", false},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got  %+v\nwant %+v", got, want)
	}
}

func TestParseDNSServers(t *testing.T) {
	if got := parseDNSServers("There aren't any DNS Servers set on Wi-Fi.\n"); len(got) != 0 {
		t.Fatalf("the 'none set' sentence is not a server: %v", got)
	}
	if got := parseDNSServers("192.168.1.1\n8.8.8.8\n2001:4860:4860::8888\n"); !reflect.DeepEqual(got, []string{"192.168.1.1", "8.8.8.8", "2001:4860:4860::8888"}) {
		t.Fatalf("got %v", got)
	}
}

// dnsWorld fakes `networksetup`: a table of per-service manual DNS servers.
type dnsWorld struct {
	servers  map[string][]string
	failSet  bool
	setCalls int
}

func newDNSWorld() *dnsWorld { return &dnsWorld{servers: map[string][]string{}} }

func (d *dnsWorld) fail(name string, args []string) (string, error) {
	if name != networksetup {
		return "", nil
	}
	switch args[0] {
	case "-listnetworkserviceorder":
		return sampleServiceOrder, nil
	case "-getdnsservers":
		s := d.servers[args[1]]
		if len(s) == 0 {
			return "There aren't any DNS Servers set on " + args[1] + ".\n", nil
		}
		return strings.Join(s, "\n") + "\n", nil
	case "-setdnsservers":
		d.setCalls++
		if d.failSet {
			return "networksetup: failed", errors.New("exit status 1")
		}
		if len(args) == 3 && args[2] == "Empty" {
			delete(d.servers, args[1])
		} else {
			d.servers[args[1]] = append([]string(nil), args[2:]...)
		}
	}
	return "", nil
}

func newDNS(t *testing.T, w *dnsWorld) (*DNSOverride, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sub", "dns-backup.json")
	f := &fakeRunner{handler: func(name string, args []string) (string, error) {
		out, err := w.fail(name, args)
		return out, err
	}}
	return NewDNSOverride(f, path), path
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestDNSApplyAndRestoreAutomatic(t *testing.T) {
	w := newDNSWorld()
	d, backup := newDNS(t, w)
	if err := d.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, CloudflareDNSv4) {
		t.Fatalf("DNS: %v", got)
	}
	if !exists(backup) {
		t.Fatal("the original settings must be on disk while the override is applied")
	}
	if info, _ := os.Stat(backup); info.Mode().Perm() != 0o600 {
		t.Fatalf("backup mode %v", info.Mode().Perm())
	}
	if err := d.Restore(); err != nil {
		t.Fatal(err)
	}
	if len(w.servers["Wi-Fi"]) != 0 {
		t.Fatalf("the service had automatic DNS; it must be put back to Empty, got %v", w.servers["Wi-Fi"])
	}
	if exists(backup) {
		t.Fatal("the backup should be removed once restored")
	}
	if err := d.Restore(); err != nil { // idempotent
		t.Fatal(err)
	}
}

func TestDNSRestoresACustomOriginal(t *testing.T) {
	w := newDNSWorld()
	w.servers["Wi-Fi"] = []string{"9.9.9.9", "149.112.112.112"}
	d, _ := newDNS(t, w)
	if err := d.Apply("en0", true); err != nil {
		t.Fatal(err)
	}
	if len(w.servers["Wi-Fi"]) != 4 {
		t.Fatalf("DNS: %v", w.servers["Wi-Fi"])
	}
	if err := d.Restore(); err != nil {
		t.Fatal(err)
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, []string{"9.9.9.9", "149.112.112.112"}) {
		t.Fatalf("original DNS not restored: %v", got)
	}
}

func TestDNSRecoversAfterACrash(t *testing.T) {
	w := newDNSWorld()
	w.servers["Wi-Fi"] = []string{"192.168.1.1"}
	d1, backup := newDNS(t, w)
	if err := d1.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	// The daemon is killed here: d1 is gone, only the backup file and the changed system remain.
	d2 := NewDNSOverride(&fakeRunner{handler: w.fail}, backup)
	if err := d2.RecoverStale(); err != nil {
		t.Fatal(err)
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, []string{"192.168.1.1"}) {
		t.Fatalf("DNS after crash recovery: %v", got)
	}
	if exists(backup) {
		t.Fatal("backup should be gone after recovery")
	}
}

func TestDNSApplyFirstRestoresLeftovers(t *testing.T) {
	// A previous run died mid-override; a new Apply must not record Cloudflare's servers as the
	// "original" (which would make them permanent).
	w := newDNSWorld()
	w.servers["Wi-Fi"] = []string{"10.0.0.53"}
	d1, backup := newDNS(t, w)
	if err := d1.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	d2 := NewDNSOverride(&fakeRunner{handler: w.fail}, backup)
	if err := d2.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	if err := d2.Restore(); err != nil {
		t.Fatal(err)
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, []string{"10.0.0.53"}) {
		t.Fatalf("the real original was lost: %v", got)
	}
}

func TestDNSApplyFailureLeavesNothingBehind(t *testing.T) {
	w := newDNSWorld()
	w.servers["Wi-Fi"] = []string{"10.0.0.53"}
	w.failSet = true
	d, backup := newDNS(t, w)
	if err := d.Apply("en0", false); err == nil {
		t.Fatal("expected an error")
	}
	if exists(backup) {
		t.Fatal("a failed Apply must not leave a backup that a later run would 'restore'")
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, []string{"10.0.0.53"}) {
		t.Fatalf("settings changed: %v", got)
	}
}

func TestDNSRestoreFailureKeepsTheBackupForNextTime(t *testing.T) {
	w := newDNSWorld()
	w.servers["Wi-Fi"] = []string{"10.0.0.53"}
	d, backup := newDNS(t, w)
	if err := d.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	w.failSet = true
	if err := d.Restore(); err == nil {
		t.Fatal("expected the restore to fail")
	}
	if !exists(backup) {
		t.Fatal("a failed restore must keep the backup so it can be retried")
	}
	w.failSet = false
	if err := d.Restore(); err != nil {
		t.Fatal(err)
	}
	if got := w.servers["Wi-Fi"]; !reflect.DeepEqual(got, []string{"10.0.0.53"}) {
		t.Fatalf("retry did not restore: %v", got)
	}
}

func TestDNSNoServiceForInterface(t *testing.T) {
	w := newDNSWorld()
	d, backup := newDNS(t, w)
	for _, dev := range []string{"utun28", "en9" /* disabled */, "en99", ""} {
		if err := d.Apply(dev, false); err == nil {
			t.Fatalf("Apply(%q) should fail: no enabled service owns it", dev)
		}
	}
	if exists(backup) || w.setCalls != 0 {
		t.Fatal("nothing may be changed or saved for an unknown interface")
	}
}

func TestDNSCorruptBackupIsDiscardedNotFatal(t *testing.T) {
	w := newDNSWorld()
	d, backup := newDNS(t, w)
	if err := os.MkdirAll(filepath.Dir(backup), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, content := range []string{"{not json", `{"service":"","servers":[]}`, `{"service":"Wi-Fi","servers":["not-an-ip"]}`} {
		if err := os.WriteFile(backup, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := d.RecoverStale(); err == nil {
			t.Fatalf("a bad backup (%q) should be reported", content)
		}
		if exists(backup) {
			t.Fatalf("a bad backup (%q) must be dropped so every start doesn't trip on it", content)
		}
	}
	if err := d.RecoverStale(); err != nil {
		t.Fatalf("with no backup, RecoverStale is a no-op: %v", err)
	}
}

func TestDNSNeverCommandsAreAbsolute(t *testing.T) {
	var seen []string
	w := newDNSWorld()
	d := NewDNSOverride(&fakeRunner{handler: func(name string, args []string) (string, error) {
		seen = append(seen, name)
		return w.fail(name, args)
	}}, filepath.Join(t.TempDir(), "b.json"))
	if err := d.Apply("en0", false); err != nil {
		t.Fatal(err)
	}
	for _, n := range seen {
		if !strings.HasPrefix(n, "/") {
			t.Fatalf("command %q is not an absolute path", n)
		}
	}
}
