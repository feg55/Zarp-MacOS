package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

// ---- fakes

type fakeConn struct {
	name string
	done chan struct{}
	once sync.Once

	mu     sync.Mutex
	err    error
	closes int
}

func newFakeConn(name string) *fakeConn { return &fakeConn{name: name, done: make(chan struct{})} }

func (c *fakeConn) Name() string          { return c.name }
func (c *fakeConn) Done() <-chan struct{} { return c.done }
func (c *fakeConn) Err() error            { c.mu.Lock(); defer c.mu.Unlock(); return c.err }
func (c *fakeConn) Close() {
	c.mu.Lock()
	c.closes++
	c.mu.Unlock()
	c.once.Do(func() { close(c.done) })
}
func (c *fakeConn) closeCount() int { c.mu.Lock(); defer c.mu.Unlock(); return c.closes }

// die simulates the data plane stopping by itself (the MASQUE session dropped).
func (c *fakeConn) die(err error) {
	c.mu.Lock()
	c.err = err
	c.mu.Unlock()
	c.once.Do(func() { close(c.done) })
}

type fakeOpener struct {
	mu     sync.Mutex
	opened []*fakeConn
	params []ipc.OpenParams
	seen   atomic.Int32  // opens that reached Open
	block  chan struct{} // when non-nil, Open waits for it (or for ctx)
	err    error
	warns  []string
}

func (o *fakeOpener) Open(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error) {
	o.seen.Add(1)
	if o.block != nil {
		select {
		case <-o.block:
		case <-ctx.Done():
			return nil, OpenInfo{}, ctx.Err()
		}
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.err != nil {
		return nil, OpenInfo{}, o.err
	}
	c := newFakeConn(fmt.Sprintf("utun%d", 10+len(o.opened)))
	o.opened = append(o.opened, c)
	o.params = append(o.params, p)
	return c, OpenInfo{Endpoint: "162.159.198.1:443", UtunName: c.name, RouteAll: p.RouteAll, ConnectMs: 123, Warnings: o.warns}, nil
}

func (o *fakeOpener) conn(i int) *fakeConn {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.opened[i]
}

type fakeAccounts struct {
	mu       sync.Mutex
	has      bool
	regErr   error
	regCalls int
	regBlock chan struct{}
}

func (a *fakeAccounts) Has() bool { a.mu.Lock(); defer a.mu.Unlock(); return a.has }
func (a *fakeAccounts) Register(ctx context.Context) error {
	a.mu.Lock()
	a.regCalls++
	block := a.regBlock
	a.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.regErr != nil {
		return a.regErr
	}
	a.has = true
	return nil
}

type fakeMeasurer struct {
	hosts []string
	res   ipc.MeasureResult
}

func (m *fakeMeasurer) Measure(ctx context.Context, host string, samples int) ipc.MeasureResult {
	m.hosts = append(m.hosts, fmt.Sprintf("%s/%d", host, samples))
	return m.res
}

type harness struct {
	m        *Manager
	opener   *fakeOpener
	accounts *fakeAccounts
	measurer *fakeMeasurer
	logs     *LogRing
	restarts atomic.Int32
}

func newHarness(t *testing.T, lease time.Duration) *harness {
	t.Helper()
	h := &harness{
		opener:   &fakeOpener{},
		accounts: &fakeAccounts{has: true},
		measurer: &fakeMeasurer{res: ipc.MeasureResult{Kind: "ok", PingMs: 30, Warp: "on"}},
		logs:     NewLogRing(100),
	}
	h.m = NewManager(Config{
		Opener: h.opener, Accounts: h.accounts, Measurer: h.measurer, Logs: h.logs,
		Version: "9.9.9", MeasureHost: "1.1.1.1", TestLease: lease,
		Restart: func() { h.restarts.Add(1) },
		Logf:    h.logs.Printf,
	})
	return h
}

func (h *harness) call(t *testing.T, ctx context.Context, method string, params any) (any, error) {
	t.Helper()
	var raw json.RawMessage
	if params != nil {
		b, err := json.Marshal(params)
		if err != nil {
			t.Fatal(err)
		}
		raw = b
	}
	return h.m.Handle(ctx, method, raw)
}

func (h *harness) open(t *testing.T, p ipc.OpenParams) ipc.OpenResult {
	t.Helper()
	res, err := h.call(t, context.Background(), "open", p)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return res.(ipc.OpenResult)
}

func (h *harness) status(t *testing.T) ipc.StatusResult {
	t.Helper()
	res, err := h.call(t, context.Background(), "status", nil)
	if err != nil {
		t.Fatal(err)
	}
	return res.(ipc.StatusResult)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func codeOf(err error) string {
	var ce *ipc.ConnError
	if errors.As(err, &ce) {
		return ce.Code
	}
	return ""
}

var persistent = ipc.OpenParams{Transport: "masqueH3", StrategyID: "warp-q-google6", Persistent: true, TimeoutMs: 15000}
var scanTest = ipc.OpenParams{Transport: "masqueH3", StrategyID: "warp-q-google3", TimeoutMs: 15000}

// ---- tests

func TestPing(t *testing.T) {
	h := newHarness(t, time.Minute)
	res, err := h.call(t, context.Background(), "ping", nil)
	if err != nil {
		t.Fatal(err)
	}
	p := res.(ipc.PingResult)
	if p.Version != "9.9.9" || p.Protocol != ipc.ProtocolVersion || !p.AccountRegistered || p.Pid == 0 {
		t.Fatalf("%+v", p)
	}
}

func TestOpenPersistentThenStatus(t *testing.T) {
	h := newHarness(t, time.Minute)
	if st := h.status(t); st.Connected || !st.DaemonRunning || !st.AccountRegistered {
		t.Fatalf("idle status: %+v", st)
	}
	p := persistent
	p.RouteAll, p.OverrideDNS = true, true
	res := h.open(t, p)
	if res.ConnectionID == "" || res.ConnectMs != 123 || res.UtunName != "utun10" || !res.RouteAll {
		t.Fatalf("open result: %+v", res)
	}
	st := h.status(t)
	if !st.Connected || st.ConnectionID != res.ConnectionID || st.StrategyID != "warp-q-google6" ||
		st.Transport != "masqueH3" || st.UtunName != "utun10" || !st.RouteAll || st.Endpoint != "162.159.198.1:443" {
		t.Fatalf("connected status: %+v", st)
	}
	if st.ConnectStartedAt == "" {
		t.Fatal("missing start time")
	}
}

func TestEmptyTransportDefaultsToH3(t *testing.T) {
	h := newHarness(t, time.Minute)
	p := persistent
	p.Transport = ""
	h.open(t, p)
	if got := h.opener.params[0].Transport; got != "masqueH3" {
		t.Fatalf("the opener should see a normalized transport, got %q", got)
	}
	if st := h.status(t); st.Transport != "masqueH3" {
		t.Fatalf("status transport %q", st.Transport)
	}
}

func TestTestConnectionsAreNotReportedAsConnected(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.open(t, scanTest)
	if st := h.status(t); st.Connected {
		t.Fatalf("a throwaway scan connection must never be adopted by a GUI: %+v", st)
	}
}

func TestNewOpenSupersedesWhateverIsStillOpen(t *testing.T) {
	// The orphan scenario: the GUI crashed mid-scan after `open` but before `close`, then the user
	// relaunched and connected. Used to fail on a stale route until the daemon was restarted.
	h := newHarness(t, time.Minute)
	orphan := h.open(t, scanTest)
	h.open(t, persistent)
	if got := h.opener.conn(0).closeCount(); got != 1 {
		t.Fatalf("the orphaned test connection should have been closed exactly once, closes=%d", got)
	}
	if _, err := h.call(t, context.Background(), "measure", ipc.MeasureParams{ConnectionID: orphan.ConnectionID, Samples: 1}); err == nil {
		t.Fatal("the superseded connection should be gone")
	}
	if st := h.status(t); !st.Connected || st.ConnectionID == orphan.ConnectionID {
		t.Fatalf("status: %+v", st)
	}
	// And a second persistent open replaces the first (a stale handle in a restarted GUI).
	h.open(t, persistent)
	if h.opener.conn(1).closeCount() != 1 {
		t.Fatal("the previous persistent connection should have been closed")
	}
}

func TestCloseIsIdempotentAndIgnoresUnknownIDs(t *testing.T) {
	h := newHarness(t, time.Minute)
	res := h.open(t, persistent)
	for i := 0; i < 3; i++ {
		if _, err := h.call(t, context.Background(), "close", ipc.CloseParams{ConnectionID: res.ConnectionID}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.call(t, context.Background(), "close", ipc.CloseParams{ConnectionID: "nope"}); err != nil {
		t.Fatal(err)
	}
	if got := h.opener.conn(0).closeCount(); got != 1 {
		t.Fatalf("closes = %d, want exactly 1", got)
	}
	if st := h.status(t); st.Connected {
		t.Fatalf("%+v", st)
	}
}

func TestTestConnectionLeaseReapsAnOrphan(t *testing.T) {
	h := newHarness(t, 80*time.Millisecond)
	h.open(t, scanTest)
	waitFor(t, "the lease to close the orphaned test connection", func() bool { return h.opener.conn(0).closeCount() == 1 })
	// A persistent connection has no lease.
	h.open(t, persistent)
	time.Sleep(250 * time.Millisecond)
	if h.opener.conn(1).closeCount() != 0 {
		t.Fatal("a persistent connection must not be reaped by the test lease")
	}
}

func TestClosingBeforeTheLeaseStopsTheTimer(t *testing.T) {
	h := newHarness(t, 80*time.Millisecond)
	res := h.open(t, scanTest)
	h.call(t, context.Background(), "close", ipc.CloseParams{ConnectionID: res.ConnectionID})
	time.Sleep(200 * time.Millisecond)
	if got := h.opener.conn(0).closeCount(); got != 1 {
		t.Fatalf("closes = %d (the lease must not close it a second time)", got)
	}
}

func TestATunnelThatDiesOnItsOwnIsNoticedAndReported(t *testing.T) {
	h := newHarness(t, time.Minute)
	res := h.open(t, persistent)
	if !h.status(t).Connected {
		t.Fatal("not connected")
	}
	h.opener.conn(0).die(errors.New("connect-ip read: timeout: no recent network activity"))

	waitFor(t, "the dead tunnel to be removed", func() bool { return !h.status(t).Connected })
	st := h.status(t)
	if st.LastLoss == nil || st.LastLoss.ConnectionID != res.ConnectionID || !strings.Contains(st.LastLoss.Reason, "no recent network activity") || st.LastLoss.At == "" {
		t.Fatalf("the loss must be reported with its reason: %+v", st.LastLoss)
	}
	if h.opener.conn(0).closeCount() < 1 {
		t.Fatal("a dead tunnel must still be torn down (routes/DNS restored)")
	}
	// A fresh connection clears the report.
	h.open(t, persistent)
	if st := h.status(t); !st.Connected || st.LastLoss != nil {
		t.Fatalf("%+v", st)
	}
}

func TestADeadTestConnectionIsNotReportedAsALostTunnel(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.open(t, scanTest)
	h.opener.conn(0).die(errors.New("boom"))
	waitFor(t, "cleanup", func() bool { return h.opener.conn(0).closeCount() >= 1 })
	if st := h.status(t); st.LastLoss != nil {
		t.Fatalf("only a persistent tunnel's loss is interesting to the GUI: %+v", st.LastLoss)
	}
}

func TestClosingARequestedTunnelIsNotALoss(t *testing.T) {
	h := newHarness(t, time.Minute)
	res := h.open(t, persistent)
	h.call(t, context.Background(), "close", ipc.CloseParams{ConnectionID: res.ConnectionID})
	time.Sleep(50 * time.Millisecond) // let the watcher see Done
	if st := h.status(t); st.LastLoss != nil {
		t.Fatalf("a close the app asked for is not a loss: %+v", st.LastLoss)
	}
}

func TestOpenAbortsWhenTheCallerGoesAway(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.opener.block = make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	errc := make(chan error, 1)
	go func() {
		_, err := h.call(t, ctx, "open", scanTest)
		errc <- err
	}()
	waitFor(t, "the open to reach the opener", func() bool { return h.opener.seen.Load() == 1 })
	cancel() // the app crashed / the user pressed Cancel
	select {
	case err := <-errc:
		if codeOf(err) != ipc.CodeCancelled {
			t.Fatalf("expected a cancelled error, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("open kept dialing after its caller left")
	}
	if len(h.opener.opened) != 0 {
		t.Fatal("no tunnel may exist for a cancelled open")
	}
}

func TestATunnelFinishedJustAfterTheCallerLeftIsClosed(t *testing.T) {
	// Opener ignores ctx and completes anyway (the dial finished at the very moment of cancel).
	h := newHarness(t, time.Minute)
	ctx, cancel := context.WithCancel(context.Background())
	late := &lateOpener{fakeOpener: h.opener, cancel: cancel}
	h.m.cfg.Opener = late
	_, err := h.call(t, ctx, "open", persistent)
	if codeOf(err) != ipc.CodeCancelled {
		t.Fatalf("expected cancelled, got %v", err)
	}
	if h.opener.conn(0).closeCount() != 1 {
		t.Fatal("the tunnel nobody will ever collect must be closed immediately")
	}
	if h.status(t).Connected {
		t.Fatal("it must not be registered either")
	}
}

type lateOpener struct {
	*fakeOpener
	cancel func()
}

func (l *lateOpener) Open(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error) {
	c, info, err := l.fakeOpener.Open(context.Background(), p)
	l.cancel() // caller leaves right as the dial completes
	return c, info, err
}

func TestOpensAreSerialized(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.opener.block = make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			h.call(t, context.Background(), "open", scanTest)
		}()
	}
	waitFor(t, "the first open to reach the opener", func() bool { return h.opener.seen.Load() >= 1 })
	time.Sleep(100 * time.Millisecond)
	if n := h.opener.seen.Load(); n != 1 {
		t.Fatalf("a second open started while the first was still dialing (%d in the opener)", n)
	}
	close(h.opener.block)
	wg.Wait()
	if n := h.opener.seen.Load(); n != 2 {
		t.Fatalf("both opens should eventually run, %d did", n)
	}
	// The second open superseded the first: only one tunnel is left open.
	open := 0
	for _, c := range h.opener.opened {
		if c.closeCount() == 0 {
			open++
		}
	}
	if open != 1 {
		t.Fatalf("%d tunnels left open, want 1", open)
	}
}

func TestOpenErrorsPropagateUnchanged(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.opener.err = &ipc.ConnError{Message: "no connection within 15 s", TimedOut: true}
	_, err := h.call(t, context.Background(), "open", scanTest)
	var ce *ipc.ConnError
	if !errors.As(err, &ce) || !ce.TimedOut {
		t.Fatalf("got %v", err)
	}
}

func TestAConnectTimeoutIsNotMistakenForACancel(t *testing.T) {
	// The caller's context ended at the same moment the dial gave up on its own timeout: the
	// scan loop must still hear "timed out" (it drives err.timeout), not "cancelled".
	h := newHarness(t, time.Minute)
	ctx, cancel := context.WithCancel(context.Background())
	h.m.cfg.Opener = openerFunc(func(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error) {
		cancel()
		return nil, OpenInfo{}, &ipc.ConnError{Message: "timeout after 15s", TimedOut: true}
	})
	_, err := h.call(t, ctx, "open", scanTest)
	var ce *ipc.ConnError
	if !errors.As(err, &ce) || !ce.TimedOut || ce.Code == ipc.CodeCancelled {
		t.Fatalf("got %v", err)
	}
}

type openerFunc func(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error)

func (f openerFunc) Open(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error) {
	return f(ctx, p)
}

func TestOpenValidatesBeforeDoingAnything(t *testing.T) {
	h := newHarness(t, time.Minute)
	bad := scanTest
	bad.FakeSteps = []ipc.FakeStep{{Blob: "quic_google", Repeats: 1_000_000}}
	_, err := h.call(t, context.Background(), "open", bad)
	if codeOf(err) != ipc.CodeBadRequest {
		t.Fatalf("got %v", err)
	}
	if h.opener.seen.Load() != 0 {
		t.Fatal("an invalid request reached the opener")
	}
	wg := scanTest
	wg.Transport = "wireGuard"
	if _, err := h.call(t, context.Background(), "open", wg); codeOf(err) != ipc.CodeUnsupported {
		t.Fatalf("got %v", err)
	}
	if _, err := h.m.Handle(context.Background(), "open", json.RawMessage(`{"timeoutMs":"soon"}`)); codeOf(err) != ipc.CodeBadRequest {
		t.Fatalf("malformed params: %v", err)
	}
}

func TestOpenWithoutAnAccountAsksForRegistration(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.accounts.has = false
	_, err := h.call(t, context.Background(), "open", scanTest)
	if codeOf(err) != ipc.CodeNoAccount {
		t.Fatalf("got %v", err)
	}
	if h.opener.seen.Load() != 0 {
		t.Fatal("nothing may be dialed without an account")
	}
}

func TestRegisterIsLazyIdempotentAndSerialized(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.accounts.has = false
	h.accounts.regBlock = make(chan struct{})
	var wg sync.WaitGroup
	results := make([]ipc.RegisterResult, 3)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := h.call(t, context.Background(), "register", nil)
			if err != nil {
				t.Error(err)
				return
			}
			results[i] = res.(ipc.RegisterResult)
		}()
	}
	time.Sleep(100 * time.Millisecond)
	close(h.accounts.regBlock)
	wg.Wait()
	if h.accounts.regCalls != 1 {
		t.Fatalf("registered %d times, want exactly once", h.accounts.regCalls)
	}
	for _, r := range results {
		if !r.AccountRegistered {
			t.Fatalf("%+v", results)
		}
	}
	if _, err := h.call(t, context.Background(), "register", nil); err != nil || h.accounts.regCalls != 1 {
		t.Fatalf("a registered account must not register again (calls=%d err=%v)", h.accounts.regCalls, err)
	}
}

func TestRegisterFailureIsReported(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.accounts.has = false
	h.accounts.regErr = errors.New("network is down")
	_, err := h.call(t, context.Background(), "register", nil)
	if err == nil || !strings.Contains(err.Error(), "network is down") {
		t.Fatalf("got %v", err)
	}
	// And the daemon is still serving: registration failure must never kill it.
	if _, err := h.call(t, context.Background(), "ping", nil); err != nil {
		t.Fatal(err)
	}
}

func TestMeasure(t *testing.T) {
	h := newHarness(t, time.Minute)
	res := h.open(t, scanTest)
	out, err := h.call(t, context.Background(), "measure", ipc.MeasureParams{ConnectionID: res.ConnectionID, Samples: 3})
	if err != nil {
		t.Fatal(err)
	}
	if m := out.(ipc.MeasureResult); m.Kind != "ok" || m.PingMs != 30 {
		t.Fatalf("%+v", m)
	}
	if len(h.measurer.hosts) != 1 || h.measurer.hosts[0] != "1.1.1.1/3" {
		t.Fatalf("measured %v", h.measurer.hosts)
	}
	if _, err := h.call(t, context.Background(), "measure", ipc.MeasureParams{ConnectionID: "999", Samples: 3}); err == nil {
		t.Fatal("measuring an unknown connection must fail")
	}
	if _, err := h.call(t, context.Background(), "measure", ipc.MeasureParams{ConnectionID: res.ConnectionID, Samples: 500}); codeOf(err) != ipc.CodeBadRequest {
		t.Fatalf("absurd sample count: %v", err)
	}
}

func TestLogsMethod(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.open(t, persistent)
	out, err := h.call(t, context.Background(), "logs", ipc.LogsParams{})
	if err != nil {
		t.Fatal(err)
	}
	lr := out.(ipc.LogsResult)
	if len(lr.Lines) == 0 || !strings.Contains(lr.Lines[0].Text, "open #1") || lr.Next == 0 {
		t.Fatalf("%+v", lr)
	}
	out, _ = h.call(t, context.Background(), "logs", ipc.LogsParams{Since: lr.Next})
	if again := out.(ipc.LogsResult); len(again.Lines) != 0 || again.Next != lr.Next {
		t.Fatalf("nothing new expected: %+v", again)
	}
}

func TestOpenWarningsAreLogged(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.opener.warns = []string{"DNS was not overridden: boom"}
	res := h.open(t, persistent)
	if len(res.Warnings) != 1 {
		t.Fatalf("%+v", res)
	}
	lines, _, _ := h.logs.Since(0)
	found := false
	for _, l := range lines {
		found = found || strings.Contains(l.Text, "DNS was not overridden")
	}
	if !found {
		t.Fatal("a warning from the opener must reach the log the app pulls")
	}
}

func TestRestartClosesEverythingThenExits(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.open(t, persistent)
	out, err := h.call(t, context.Background(), "restart", nil)
	if err != nil || !out.(ipc.RestartResult).Acknowledged {
		t.Fatalf("%v %v", out, err)
	}
	if h.opener.conn(0).closeCount() != 1 {
		t.Fatal("restart must tear tunnels down first (routes/DNS restored)")
	}
	waitFor(t, "the restart hook", func() bool { return h.restarts.Load() == 1 })
}

func TestCloseAllOnShutdown(t *testing.T) {
	h := newHarness(t, time.Minute)
	h.open(t, persistent)
	h.m.CloseAll()
	if h.opener.conn(0).closeCount() != 1 || h.status(t).Connected {
		t.Fatal("shutdown must close every tunnel")
	}
}

func TestUnknownMethod(t *testing.T) {
	h := newHarness(t, time.Minute)
	if _, err := h.call(t, context.Background(), "format-disk", nil); codeOf(err) != ipc.CodeBadRequest {
		t.Fatalf("got %v", err)
	}
}

func TestStatusPicksTheNewestPersistentConnection(t *testing.T) {
	// Only one can exist now, but if two ever did, the answer must be deterministic.
	h := newHarness(t, time.Minute)
	h.m.mu.Lock()
	for i, id := range []string{"1", "2", "3"} {
		h.m.conns[id] = &entry{id: id, seq: uint64(i + 1), conn: newFakeConn("utun" + id), params: ipc.OpenParams{Persistent: true, Transport: "masqueH3"}}
	}
	h.m.mu.Unlock()
	for i := 0; i < 20; i++ {
		if st := h.status(t); st.ConnectionID != "3" {
			t.Fatalf("status picked #%s", st.ConnectionID)
		}
	}
}
