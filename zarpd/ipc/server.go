package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime/debug"
	"sync"
	"syscall"
	"time"
)

// staffGID is macOS's standard `staff` group (20) — every interactive user account is a member by
// default (System Settings-created accounts, not service/daemon accounts). Used to scope the
// socket to real local users instead of leaving it world-writable. It is only the first filter:
// Options.AllowPeer then checks *which* user is actually on the other end.
const staffGID = 20

// Handler processes one request's params (still-undecoded JSON — decode into the method's own
// Params type) and returns a value to encode as Result, or an error.
//
// ctx is cancelled when the client that sent the request goes away (closes its end of the
// connection) — long handlers (an `open` mid-dial) must honor it. It is *not* the daemon's own
// lifetime: anything that has to outlive the request (a tunnel) needs a context of its own.
type Handler func(ctx context.Context, method string, params json.RawMessage) (any, error)

// Options tunes Serve. The zero value is usable: every field has a safe default.
type Options struct {
	// AllowPeer decides whether the process on the other end of a new connection may use the
	// daemon at all. nil allows everyone the socket's file permissions already let in.
	AllowPeer func(PeerCred) bool
	// MaxConns caps concurrent connections (default 32). Beyond it a connection is answered
	// with a `busy` error and closed, so a flood can't exhaust the daemon.
	MaxConns int
	// MaxInFlight caps concurrent requests per connection (default 8).
	MaxInFlight int
	// FirstRequestTimeout is how long a new connection may sit silent before it is dropped
	// (default 10s).
	FirstRequestTimeout time.Duration
	// MaxRequestBytes caps one request line (default 256 KiB — real requests are a few hundred
	// bytes).
	MaxRequestBytes int
	// SocketGID is the group given the socket (default staff, 20; -1 leaves it alone).
	SocketGID int
	// SocketMode is the socket's permission bits (default 0660).
	SocketMode os.FileMode
	// Logf receives diagnostics; nil discards them.
	Logf func(format string, args ...any)
}

func (o *Options) fill() {
	if o.MaxConns <= 0 {
		o.MaxConns = 32
	}
	if o.MaxInFlight <= 0 {
		o.MaxInFlight = 8
	}
	if o.FirstRequestTimeout <= 0 {
		o.FirstRequestTimeout = 10 * time.Second
	}
	if o.MaxRequestBytes <= 0 {
		o.MaxRequestBytes = 256 * 1024
	}
	if o.SocketMode == 0 {
		o.SocketMode = 0o660
	}
	if o.SocketGID == 0 {
		o.SocketGID = staffGID
	}
	if o.Logf == nil {
		o.Logf = func(string, ...any) {}
	}
}

// Serve listens on a Unix domain socket at socketPath and dispatches every request line to
// handler until ctx is done. One goroutine per connection, one goroutine per request within a
// connection (so a slow `open` doesn't block a concurrent `status`-style call on the same
// connection) — requests are independent by design (docs/ARCHITECTURE.md §9.4), there's no
// server-side state that needs per-connection request ordering.
func Serve(ctx context.Context, socketPath string, handler Handler, opts Options) error {
	opts.fill()
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("removing stale socket %s: %w", socketPath, err)
	}
	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	// The app runs as the logged-in user, not root, so it must be able to connect — but this
	// daemon is privileged and (once Phase 8 installs it permanently) always running, so the
	// socket must not be reachable by every local process either. 0660 + group `staff` admits any
	// real interactive user account on a single-user Mac while excluding service/daemon accounts,
	// which normally aren't in `staff`; AllowPeer then narrows it to the user actually at the
	// console.
	if err := os.Chmod(socketPath, opts.SocketMode); err != nil {
		opts.Logf("ipc: chmod %s: %v", socketPath, err)
	}
	if opts.SocketGID >= 0 {
		if err := syscall.Chown(socketPath, -1, opts.SocketGID); err != nil {
			opts.Logf("ipc: chown %s to gid %d: %v", socketPath, opts.SocketGID, err)
		}
	}
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	slots := make(chan struct{}, opts.MaxConns)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return fmt.Errorf("accept: %w", err)
		}
		if opts.AllowPeer != nil {
			cred, perr := peerCredOf(conn)
			if perr != nil || !opts.AllowPeer(cred) {
				if perr != nil {
					opts.Logf("ipc: peer credentials unavailable, refusing connection: %v", perr)
				} else {
					opts.Logf("ipc: refusing connection from uid %d", cred.UID)
				}
				refuse(conn, CodeForbidden, "this process is not allowed to control zarpd")
				continue
			}
		}
		select {
		case slots <- struct{}{}:
		default:
			refuse(conn, CodeBusy, "too many connections")
			continue
		}
		go func() {
			defer func() { <-slots }()
			serveConn(ctx, conn, handler, opts)
		}()
	}
}

// refuse answers a connection we're not going to serve with one error response (request ID 0 — we
// never read the request) and closes it, so the client fails fast with a reason instead of hanging.
func refuse(conn net.Conn, code, message string) {
	_ = conn.SetWriteDeadline(time.Now().Add(time.Second))
	_ = json.NewEncoder(conn).Encode(Response{Error: &ErrorInfo{Message: message, Code: code}})
	_ = conn.Close()
}

func serveConn(ctx context.Context, conn net.Conn, handler Handler, opts Options) {
	defer func() { _ = conn.Close() }()

	// Cancelled the moment the client's side closes, so requests still in flight for it (an
	// `open` mid-dial) abort instead of finishing work nobody will collect.
	connCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Requests are handled concurrently (a slow `open` shouldn't block a concurrent `status` on
	// the same connection), but net.Conn.Write from multiple goroutines at once would interleave
	// partial writes and garble the JSON stream — so every response goes through this channel to
	// the one goroutine below that's actually allowed to write to conn.
	responses := make(chan Response)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		enc := json.NewEncoder(conn)
		for resp := range responses {
			if err := enc.Encode(resp); err != nil {
				opts.Logf("ipc: writing response for #%d: %v", resp.ID, err)
				cancel()
				return
			}
		}
	}()
	// send never blocks forever on a writer that has already given up (the client vanished
	// mid-response): writerDone is closed in that case and the response is simply dropped.
	send := func(resp Response) {
		select {
		case responses <- resp:
		case <-writerDone:
		}
	}

	scanner := bufio.NewScanner(conn)
	// bufio.Scanner's real limit is the *larger* of max and the initial buffer's capacity, so the
	// initial buffer must not exceed the cap or the cap is silently ignored.
	initial := 64 * 1024
	if opts.MaxRequestBytes < initial {
		initial = opts.MaxRequestBytes
	}
	scanner.Buffer(make([]byte, 0, initial), opts.MaxRequestBytes)
	inFlight := make(chan struct{}, opts.MaxInFlight)
	var pending sync.WaitGroup

	_ = conn.SetReadDeadline(time.Now().Add(opts.FirstRequestTimeout))
	for scanner.Scan() {
		_ = conn.SetReadDeadline(time.Time{})
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			opts.Logf("ipc: bad request: %v", err)
			send(Response{Error: &ErrorInfo{Message: "malformed request: " + err.Error(), Code: CodeBadRequest}})
			continue
		}
		select {
		case inFlight <- struct{}{}:
		default:
			send(Response{ID: req.ID, Error: &ErrorInfo{Message: "too many requests in flight", Code: CodeBusy}})
			continue
		}
		pending.Add(1)
		go func(req Request) {
			defer pending.Done()
			defer func() { <-inFlight }()
			send(dispatch(connCtx, handler, req, opts.Logf))
		}(req)
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, net.ErrClosed) {
		opts.Logf("ipc: connection read: %v", err)
	}
	// The client is gone (or gave up, or sent something we can't parse): abort what's in flight.
	cancel()
	pending.Wait()
	close(responses)
	<-writerDone
}

func dispatch(ctx context.Context, handler Handler, req Request, logf func(string, ...any)) (resp Response) {
	// A bug in one handler must not take the whole daemon — and every tunnel it holds — down.
	defer func() {
		if r := recover(); r != nil {
			logf("ipc: panic in %q: %v\n%s", req.Method, r, debug.Stack())
			resp = Response{ID: req.ID, Error: &ErrorInfo{Message: "internal error in " + req.Method, Code: CodeInternal}}
		}
	}()

	result, err := handler(ctx, req.Method, req.Params)
	if err != nil {
		var ce *ConnError
		if errors.As(err, &ce) {
			return Response{ID: req.ID, Error: &ErrorInfo{Message: ce.Message, TimedOut: ce.TimedOut, Code: ce.Code}}
		}
		if errors.Is(err, context.Canceled) {
			return Response{ID: req.ID, Error: &ErrorInfo{Message: err.Error(), Code: CodeCancelled}}
		}
		return Response{ID: req.ID, Error: &ErrorInfo{Message: err.Error()}}
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return Response{ID: req.ID, Error: &ErrorInfo{Message: fmt.Sprintf("encoding result: %v", err), Code: CodeInternal}}
	}
	return Response{ID: req.ID, Result: raw}
}
