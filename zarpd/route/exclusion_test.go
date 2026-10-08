package route

import (
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func journalPath(t *testing.T) string { return filepath.Join(t.TempDir(), "exclusions.json") }

func TestAddExclusionThroughTheGateway(t *testing.T) {
	w := newWorld()
	r, f := w.router()
	undo, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(journalPath(t)))
	if err != nil {
		t.Fatal(err)
	}
	if got := f.log(); len(got) != 1 || got[0] != "/sbin/route -n add -host 162.159.198.2 192.168.34.1" {
		t.Fatalf("commands: %q", got)
	}
	if w.routes[exclusionKey] != "en0" || w.gateways[exclusionKey] != "192.168.34.1" {
		t.Fatalf("route not installed through the gateway: %v %v", w.routes, w.gateways)
	}
	if err := undo(); err != nil || len(w.routes) != 0 {
		t.Fatalf("undo: err=%v routes=%v", err, w.routes)
	}
}

func TestAddExclusionWithoutAGatewayUsesTheInterface(t *testing.T) {
	w := newWorld()
	r, f := w.router()
	if _, err := r.AddExclusion(testEndpoint, &Physical{Interface: "en0"}, nil); err != nil {
		t.Fatal(err)
	}
	if got := f.log(); len(got) != 1 || !strings.HasSuffix(got[0], "add -host 162.159.198.2 -interface en0") {
		t.Fatalf("commands: %q", got)
	}
	// An unspecified gateway (0.0.0.0) is no gateway either.
	w2 := newWorld()
	r2, f2 := w2.router()
	if _, err := r2.AddExclusion(testEndpoint, &Physical{Interface: "en0", Gateway: net.IPv4zero}, nil); err != nil {
		t.Fatal(err)
	}
	if got := f2.log(); !strings.HasSuffix(got[0], "-interface en0") {
		t.Fatalf("commands: %q", got)
	}
}

func TestAddExclusionJournalsBeforeTouchingTheRoutingTable(t *testing.T) {
	w := newWorld()
	path := journalPath(t)
	var journalDuringAdd string
	w.fail = func(name string, args []string) (string, error) {
		if len(args) > 1 && args[1] == "add" {
			data, _ := os.ReadFile(path)
			journalDuringAdd = string(data)
		}
		return "", nil
	}
	r, _ := w.router()
	undo, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(journalDuringAdd, "162.159.198.2") {
		t.Fatalf("the journal must already list the route when it is added, had %q", journalDuringAdd)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the journal must stay while the route is installed: %v", err)
	}
	if err := undo(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the journal must be gone once the route is: %v", err)
	}
}

func TestAddExclusionFailureLeavesNothingBehind(t *testing.T) {
	w := newWorld()
	w.failAdd[exclusionKey] = errors.New("Network is unreachable")
	path := journalPath(t)
	r, _ := w.router()
	if _, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path)); err == nil {
		t.Fatal("expected an error")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a failed add must not leave a journal entry: %v", err)
	}
}

func TestAddExclusionReusesSomeoneElsesRouteThroughTheSameInterface(t *testing.T) {
	w := newWorld()
	w.routes[exclusionKey] = "en0" // the user's own static route
	path := journalPath(t)
	r, _ := w.router()
	undo, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path))
	if err != nil {
		t.Fatalf("a route that already does the job is fine: %v", err)
	}
	if err := undo(); err != nil {
		t.Fatal(err)
	}
	if w.routes[exclusionKey] != "en0" {
		t.Fatal("a route we did not add must not be removed")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("nothing of ours is installed, so the journal must be empty: %v", err)
	}
}

func TestAddExclusionRefusesARouteThroughAnotherInterface(t *testing.T) {
	w := newWorld()
	w.routes[exclusionKey] = "utun9" // another VPN already pulls the endpoint into its tunnel
	r, _ := w.router()
	if _, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(journalPath(t))); err == nil {
		t.Fatal("expected an error: that route is exactly what the exclusion must prevent")
	}
	if w.routes[exclusionKey] != "utun9" {
		t.Fatal("the other VPN's route must be left alone")
	}
}

func TestAddExclusionValidatesItsInput(t *testing.T) {
	r, f := newWorld().router()
	if _, err := r.AddExclusion(netip.MustParseAddr("2606:4700::1"), testPhys, nil); err == nil {
		t.Error("an IPv6 endpoint cannot be excluded with an IPv4 host route")
	}
	if _, err := r.AddExclusion(netip.Addr{}, testPhys, nil); err == nil {
		t.Error("an invalid address must be rejected")
	}
	if _, err := r.AddExclusion(testEndpoint, nil, nil); err == nil {
		t.Error("the physical interface is required")
	}
	if _, err := r.AddExclusion(testEndpoint, &Physical{}, nil); err == nil {
		t.Error("an empty interface name is not an interface")
	}
	if len(f.log()) != 0 {
		t.Errorf("no command may run for invalid input: %q", f.log())
	}
	// An IPv4-mapped IPv6 address is the same endpoint.
	if _, err := r.AddExclusion(netip.MustParseAddr("::ffff:162.159.198.2"), testPhys, nil); err != nil {
		t.Errorf("a mapped address should be unmapped: %v", err)
	}
}

func TestExclusionUndoIsIdempotent(t *testing.T) {
	w := newWorld()
	r, _ := w.router()
	undo, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(journalPath(t)))
	if err != nil {
		t.Fatal(err)
	}
	if err := undo(); err != nil {
		t.Fatal(err)
	}
	if err := undo(); err != nil {
		t.Fatalf("deleting an already-deleted route is not an error: %v", err)
	}
}

func TestFullTunnelAddsTheExclusionFirstAndRemovesItLast(t *testing.T) {
	w := newWorld()
	r, f := w.router()
	ft, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", Exclude: testEndpoint, Physical: testPhys, Journal: NewJournal(journalPath(t))}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if errs := ft.Disable(); len(errs) != 0 {
		t.Fatal(errs)
	}
	var addExcl, addFirstHalf, delLastHalf, delExcl = -1, -1, -1, -1
	for i, c := range f.log() {
		switch {
		case strings.Contains(c, "add -host 162.159.198.2"):
			addExcl = i
		case strings.Contains(c, "add -inet 0.0.0.0/1"):
			addFirstHalf = i
		case strings.Contains(c, "delete") && strings.Contains(c, "128.0.0.0/1"):
			delLastHalf = i
		case strings.Contains(c, "delete -host 162.159.198.2"):
			delExcl = i
		}
	}
	if addExcl < 0 || addFirstHalf < 0 || delLastHalf < 0 || delExcl < 0 {
		t.Fatalf("missing commands (excl add %d, half add %d, half del %d, excl del %d): %q", addExcl, addFirstHalf, delLastHalf, delExcl, f.log())
	}
	if addExcl > addFirstHalf {
		t.Errorf("the exclusion must be in place before the /1 routes swallow the endpoint: %q", f.log())
	}
	if delExcl < delLastHalf {
		t.Errorf("the exclusion must go last, or the control connection breaks during teardown: %q", f.log())
	}
}

func TestFullTunnelFailsWhenTheExclusionCannotBeAdded(t *testing.T) {
	w := newWorld()
	w.failAdd[exclusionKey] = errors.New("Network is unreachable")
	r, _ := w.router()
	ft, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", Exclude: testEndpoint, Physical: testPhys}, nil)
	if err == nil || ft != nil {
		t.Fatalf("a full tunnel without a protected control connection can't work: ft=%v err=%v", ft, err)
	}
	if len(w.routes) != 0 {
		t.Fatalf("no /1 route may be added when the exclusion failed: %v", w.routes)
	}
}

func TestFullTunnelRequiresTheEndpointAndThePhysicalInterface(t *testing.T) {
	r := New(&fakeRunner{})
	if _, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", Physical: testPhys}, nil); err == nil {
		t.Error("Exclude is required")
	}
	if _, _, err := r.EnableFullTunnel(FullTunnelConfig{Utun: "utun5", Exclude: testEndpoint}, nil); err == nil {
		t.Error("Physical is required")
	}
}

func TestJournalRecoverDeletesWhatACrashedRunLeft(t *testing.T) {
	path := journalPath(t)
	// The previous daemon added the route, then died: the journal and the route both remain.
	w := newWorld()
	r, _ := w.router()
	if _, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path)); err != nil {
		t.Fatal(err)
	}
	if len(w.routes) != 1 {
		t.Fatal("setup: the route should exist")
	}

	// A fresh daemon starts.
	if errs := NewJournal(path).Recover(r); len(errs) != 0 {
		t.Fatalf("Recover: %v", errs)
	}
	if len(w.routes) != 0 {
		t.Fatalf("the stale exclusion route must be deleted: %v", w.routes)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the journal must be cleared: %v", err)
	}
	// And again with nothing to do.
	if errs := NewJournal(path).Recover(r); len(errs) != 0 {
		t.Fatalf("Recover on a clean machine: %v", errs)
	}
}

func TestJournalRecoverToleratesARouteThatIsAlreadyGone(t *testing.T) {
	path := journalPath(t)
	w := newWorld()
	r, _ := w.router()
	if _, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path)); err != nil {
		t.Fatal(err)
	}
	delete(w.routes, exclusionKey) // e.g. the machine rebooted: routes are gone, the journal stayed
	if errs := NewJournal(path).Recover(r); len(errs) != 0 {
		t.Fatalf("a route that no longer exists is not a problem: %v", errs)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the journal must be cleared: %v", err)
	}
}

func TestJournalRecoverReportsADeleteFailureButStillClearsTheJournal(t *testing.T) {
	path := journalPath(t)
	w := newWorld()
	r, _ := w.router()
	if _, err := r.AddExclusion(testEndpoint, testPhys, NewJournal(path)); err != nil {
		t.Fatal(err)
	}
	w.fail = func(name string, args []string) (string, error) {
		if len(args) > 1 && args[1] == "delete" {
			return "route: writing to routing socket: Operation not permitted", errors.New("exit status 1")
		}
		return "", nil
	}
	errs := NewJournal(path).Recover(r)
	if len(errs) != 1 {
		t.Fatalf("expected the delete failure to be reported: %v", errs)
	}
	// Retrying forever on a route that can't be deleted would wedge every start; it was reported.
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the journal must be cleared anyway: %v", err)
	}
}

func TestJournalRecoverDiscardsACorruptFile(t *testing.T) {
	path := journalPath(t)
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	r, f := newWorld().router()
	errs := NewJournal(path).Recover(r)
	if len(errs) == 0 {
		t.Fatal("a corrupt journal should be reported")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a corrupt journal must not survive to trip the next start: %v", err)
	}
	if len(f.log()) != 0 {
		t.Fatalf("nothing can be deleted from a journal nobody can read: %q", f.log())
	}
}

func TestJournalSurvivesConcurrentUse(t *testing.T) {
	j := NewJournal(journalPath(t))
	done := make(chan struct{})
	for i := 0; i < 8; i++ {
		go func(i int) {
			defer func() { done <- struct{}{} }()
			e := journalEntry{Host: "162.159.198." + string(rune('1'+i)), Interface: "en0"}
			_ = j.add(e)
			j.remove(e.Host)
		}(i)
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	if _, err := os.Stat(j.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("every entry was removed again, so the journal should be gone: %v", err)
	}
}
