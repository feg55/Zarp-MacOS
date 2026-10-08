// Package daemon is zarpd's brain: the registry of live tunnels and the IPC method handlers
// (ping, status, register, open, close, measure, logs, restart) that Zarp.app drives.
//
// What the registry exists to guarantee — each of these was a real failure before:
//
//   - One tunnel at a time. Every connection shares the one measurement route, so a second
//     tunnel cannot coexist with the first. A new `open` therefore closes whatever is still open
//     (the previous persistent connection, or a test connection whose client crashed before it
//     could close it) instead of failing on a stale route and staying broken until a restart.
//   - A test connection can't outlive its owner. Non-persistent connections carry a lease; the
//     app closes them within seconds, so one still open after the lease belongs to a client that
//     is gone.
//   - A tunnel that dies on its own is noticed. When the data plane stops (the MASQUE session
//     drops, the network changes), the connection is torn down — routes and DNS restored, the
//     machine fails open — and reported as lost, instead of lingering as "connected".
//   - A caller that goes away mid-open doesn't leave a tunnel behind: the request context ends,
//     the dial aborts, and a connection that finished just too late is closed on the spot.
//
// The system-touching parts (dialing WARP, the utun, routes) sit behind the Opener interface so all
// of the above can be tested without root or a network.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

// Conn is one live tunnel, as the registry sees it.
type Conn interface {
	// Name is the tunnel interface (utun5).
	Name() string
	// Done is closed when the data plane stops — whether Close was called or the tunnel died on
	// its own.
	Done() <-chan struct{}
	// Err is why the data plane stopped (nil until Done is closed, and for a plain Close).
	Err() error
	// Close tears the tunnel down completely (routes, DNS, device, session). Idempotent.
	Close()
}

// OpenInfo is what an Opener reports about a connection it established.
type OpenInfo struct {
	Endpoint  string // "ip:port" actually dialed
	UtunName  string
	RouteAll  bool     // true: full tunnel; false: test route only
	ConnectMs int      // how long the MASQUE handshake took
	Warnings  []string // non-fatal problems to surface in the app's log
}

// Opener establishes tunnels. The real one dials WARP, creates the utun and installs the routes
// (opener.go); tests substitute a fake.
type Opener interface {
	// Open must honor ctx: when it ends (the requesting client left) the dial is abandoned.
	Open(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error)
}

// Accounts is the WARP account store.
type Accounts interface {
	Has() bool
	Register(ctx context.Context) error
}

// Config assembles a Manager. Opener, Accounts and Measurer are required.
type Config struct {
	Opener   Opener
	Accounts Accounts
	Measurer Measurer
	Logs     *LogRing

	Version     string
	MeasureHost string // the host measurements target (a Cloudflare address, so trace works)
	// TestLease is how long a non-persistent connection may stay open (default 2 minutes).
	TestLease time.Duration
	// Restart is called, in its own goroutine shortly after the response is sent, by the `restart`
	// method. Production exits non-zero so launchd's KeepAlive{SuccessfulExit:false} relaunches the
	// daemon.
	Restart func()
	Logf    func(format string, args ...any)
	Now     func() time.Time
}

// Manager is the registry plus the method handlers. Create it with NewManager.
type Manager struct {
	cfg Config

	// openSem serializes opens: only one tunnel may exist, and an open that arrives while another
	// is mid-dial waits for it (or for its own request to be cancelled).
	openSem chan struct{}
	regMu   sync.Mutex // serializes registration

	mu       sync.Mutex
	conns    map[string]*entry
	nextSeq  uint64
	lastLoss *ipc.LossInfo
}

type entry struct {
	id        string
	seq       uint64
	conn      Conn
	params    ipc.OpenParams
	info      OpenInfo
	startedAt time.Time
	lease     *time.Timer
}

// NewManager returns a ready Manager.
func NewManager(cfg Config) *Manager {
	if cfg.TestLease <= 0 {
		cfg.TestLease = 2 * time.Minute
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logs == nil {
		cfg.Logs = NewLogRing(1000)
	}
	return &Manager{cfg: cfg, openSem: make(chan struct{}, 1), conns: map[string]*entry{}}
}

// Handle is the ipc.Handler: it dispatches one request.
func (m *Manager) Handle(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "ping":
		return ipc.PingResult{
			Version:           m.cfg.Version,
			Pid:               os.Getpid(),
			Protocol:          ipc.ProtocolVersion,
			AccountRegistered: m.cfg.Accounts.Has(),
		}, nil
	case "status":
		return m.Status(), nil
	case "register":
		return m.register(ctx)
	case "open":
		return m.open(ctx, params)
	case "close":
		return m.closeMethod(params)
	case "measure":
		return m.measure(ctx, params)
	case "logs":
		return m.logs(params)
	case "restart":
		return m.restart()
	default:
		return nil, &ipc.ConnError{Message: fmt.Sprintf("unknown method %q", method), Code: ipc.CodeBadRequest}
	}
}

func decode(raw json.RawMessage, v any) error {
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return &ipc.ConnError{Message: "malformed parameters: " + err.Error(), Code: ipc.CodeBadRequest}
	}
	return nil
}

// ---- register

func (m *Manager) register(ctx context.Context) (any, error) {
	m.regMu.Lock()
	defer m.regMu.Unlock()
	if m.cfg.Accounts.Has() {
		return ipc.RegisterResult{AccountRegistered: true}, nil
	}
	m.cfg.Logf("registering a WARP account (the user accepted Cloudflare's terms in Zarp)...")
	if err := m.cfg.Accounts.Register(ctx); err != nil {
		m.cfg.Logf("WARP registration failed: %v", err)
		return nil, fmt.Errorf("WARP registration failed: %w", err)
	}
	m.cfg.Logf("WARP account registered")
	return ipc.RegisterResult{AccountRegistered: m.cfg.Accounts.Has()}, nil
}

// ---- open / close

func (m *Manager) open(ctx context.Context, raw json.RawMessage) (any, error) {
	var p ipc.OpenParams
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if p.Transport == "" {
		p.Transport = "masqueH3"
	}
	if !m.cfg.Accounts.Has() {
		return nil, &ipc.ConnError{Code: ipc.CodeNoAccount, Message: "no WARP account yet: accept Cloudflare's terms in Zarp to register one"}
	}

	// One open at a time; a second waits for the first to finish — or abort, if its client left.
	select {
	case m.openSem <- struct{}{}:
	case <-ctx.Done():
		return nil, cancelled()
	}
	defer func() { <-m.openSem }()

	// The single-tunnel invariant: anything still open is closed first (see the package comment).
	m.closeAll("superseded by a new connection request")

	started := m.cfg.Now()
	conn, info, err := m.cfg.Opener.Open(ctx, p)
	if err != nil {
		if ctx.Err() != nil && !isTimeoutErr(err) {
			return nil, cancelled()
		}
		return nil, err
	}
	if ctx.Err() != nil {
		// The client left between the dial finishing and now: nobody will ever close this.
		conn.Close()
		return nil, cancelled()
	}
	if info.ConnectMs <= 0 {
		info.ConnectMs = int(m.cfg.Now().Sub(started).Milliseconds())
	}

	m.mu.Lock()
	m.nextSeq++
	e := &entry{
		id: strconv.FormatUint(m.nextSeq, 10), seq: m.nextSeq,
		conn: conn, params: p, info: info, startedAt: started,
	}
	m.conns[e.id] = e
	if p.Persistent {
		m.lastLoss = nil // a fresh tunnel supersedes the report of the last one that died
	}
	if !p.Persistent {
		id := e.id
		e.lease = time.AfterFunc(m.cfg.TestLease, func() { m.closeConn(id, "test connection lease expired (its client never closed it)") })
	}
	m.mu.Unlock()

	go func() {
		<-conn.Done()
		m.onDead(e)
	}()

	m.cfg.Logf("open #%s transport=%s endpoint=%s connectMs=%d dev=%s persistent=%v routeAll=%v",
		e.id, p.Transport, info.Endpoint, info.ConnectMs, info.UtunName, p.Persistent, info.RouteAll)
	for _, w := range info.Warnings {
		m.cfg.Logf("open #%s: warning: %s", e.id, w)
	}
	return ipc.OpenResult{
		ConnectionID: e.id, ConnectMs: info.ConnectMs, Endpoint: info.Endpoint,
		UtunName: info.UtunName, RouteAll: info.RouteAll, Warnings: info.Warnings,
	}, nil
}

func cancelled() error {
	return &ipc.ConnError{Code: ipc.CodeCancelled, Message: "cancelled: the caller went away or a newer request replaced this one"}
}

func isTimeoutErr(err error) bool {
	var ce *ipc.ConnError
	if errors.As(err, &ce) && ce.TimedOut {
		return true
	}
	return errors.Is(err, context.DeadlineExceeded)
}

func (m *Manager) closeMethod(raw json.RawMessage) (any, error) {
	var p ipc.CloseParams
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	m.closeConn(p.ConnectionID, "closed by the app")
	return struct{}{}, nil
}

// closeConn removes and tears down one connection. It reports whether there was one.
func (m *Manager) closeConn(id, why string) bool {
	m.mu.Lock()
	e, ok := m.conns[id]
	if ok {
		delete(m.conns, id)
	}
	m.mu.Unlock()
	if !ok {
		return false
	}
	m.finish(e, why)
	return true
}

func (m *Manager) finish(e *entry, why string) {
	if e.lease != nil {
		e.lease.Stop()
	}
	e.conn.Close()
	m.cfg.Logf("closed #%s (%s): %s", e.id, e.conn.Name(), why)
}

// closeAll closes every live connection.
func (m *Manager) closeAll(why string) {
	m.mu.Lock()
	all := make([]*entry, 0, len(m.conns))
	for _, e := range m.conns {
		all = append(all, e)
	}
	m.conns = map[string]*entry{}
	m.mu.Unlock()
	for _, e := range all {
		m.finish(e, why)
	}
}

// CloseAll tears every tunnel down — called on shutdown, so routes and DNS are restored before the
// process exits.
func (m *Manager) CloseAll() { m.closeAll("daemon shutting down") }

// onDead handles a tunnel whose data plane stopped on its own.
func (m *Manager) onDead(e *entry) {
	m.mu.Lock()
	cur, ok := m.conns[e.id]
	if !ok || cur != e {
		// Already removed by a close request / supersede: this is just the echo of that.
		m.mu.Unlock()
		return
	}
	delete(m.conns, e.id)
	reason := "the connection ended"
	if err := e.conn.Err(); err != nil {
		reason = err.Error()
	}
	if e.params.Persistent {
		m.lastLoss = &ipc.LossInfo{
			ConnectionID: e.id, Reason: reason, At: m.cfg.Now().UTC().Format(time.RFC3339),
		}
	}
	m.mu.Unlock()
	m.finish(e, "lost: "+reason)
}

// ---- status

// Status reports the one persistent connection, if any.
func (m *Manager) Status() ipc.StatusResult {
	m.mu.Lock()
	defer m.mu.Unlock()
	res := ipc.StatusResult{
		DaemonRunning:     true,
		AccountRegistered: m.cfg.Accounts.Has(),
		LastLoss:          m.lastLoss,
	}
	var newest *entry
	for _, e := range m.conns {
		if e.params.Persistent && (newest == nil || e.seq > newest.seq) {
			newest = e
		}
	}
	if newest == nil {
		return res
	}
	res.Connected = true
	res.ConnectionID = newest.id
	res.StrategyID = newest.params.StrategyID
	res.Endpoint = newest.info.Endpoint
	res.Transport = newest.params.Transport
	res.ConnectMs = newest.info.ConnectMs
	res.ConnectStartedAt = newest.startedAt.UTC().Format(time.RFC3339)
	res.UtunName = newest.conn.Name()
	res.RouteAll = newest.info.RouteAll
	// A live tunnel supersedes an old loss report.
	res.LastLoss = nil
	return res
}

// ---- measure

func (m *Manager) measure(ctx context.Context, raw json.RawMessage) (any, error) {
	var p ipc.MeasureParams
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	_, ok := m.conns[p.ConnectionID]
	m.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("no open connection #%s", p.ConnectionID)
	}
	return m.cfg.Measurer.Measure(ctx, m.cfg.MeasureHost, p.Samples), nil
}

// ---- logs / restart

func (m *Manager) logs(raw json.RawMessage) (any, error) {
	var p ipc.LogsParams
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	lines, next, dropped := m.cfg.Logs.Since(p.Since)
	return ipc.LogsResult{Lines: lines, Next: next, Dropped: dropped}, nil
}

// restart is how the app restarts a root LaunchDaemon that the unprivileged app
// cannot itself start or stop (launchd's own security boundary — no `sudo`/root needed from the
// app's side is the whole point): closes every live connection cleanly, acknowledges the request,
// then — from a separate goroutine, after a short delay so the acknowledgement actually reaches
// the caller before the process disappears — exits with a non-zero status. The LaunchDaemon plist
// has `KeepAlive: {SuccessfulExit: false}`, which restarts on exactly that (an *unsuccessful*
// exit) but deliberately not on a clean `os.Exit(0)`/SIGTERM shutdown, so this is what tells
// launchd "bring it back," as distinct from "stop." Real "stop" only exists via `unregister()`
// (App/Sources/Zarp/ZarpdInstaller.swift) — no in-between, unprivileged, "paused but still
// installed" state exists without root.
func (m *Manager) restart() (any, error) {
	m.closeAll("daemon restarting")
	if m.cfg.Restart != nil {
		go func() {
			time.Sleep(200 * time.Millisecond)
			m.cfg.Restart()
		}()
	}
	return ipc.RestartResult{Acknowledged: true}, nil
}
