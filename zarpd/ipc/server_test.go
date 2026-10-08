package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// startServer runs Serve on a short socket path (macOS limits unix socket paths to ~104 bytes, and
// t.TempDir() paths are close to that) and returns the path plus a stop function.
func startServer(t *testing.T, h Handler, opts Options) (path string, stop func()) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "zipc")
	if err != nil {
		t.Fatal(err)
	}
	path = filepath.Join(dir, "s")
	opts.SocketGID = -1 // chown to staff needs root
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, path, h, opts) }()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(path); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	return path, func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("Serve returned %v", err)
			}
		case <-time.After(3 * time.Second):
			t.Error("Serve did not return after cancel")
		}
		_ = os.RemoveAll(dir)
	}
}

type client struct {
	conn net.Conn
	r    *bufio.Reader
}

func dial(t *testing.T, path string) *client {
	t.Helper()
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return &client{conn: c, r: bufio.NewReader(c)}
}

func (c *client) send(t *testing.T, id uint64, method string, params any) {
	t.Helper()
	raw, _ := json.Marshal(params)
	line, _ := json.Marshal(Request{ID: id, Method: method, Params: raw})
	if _, err := c.conn.Write(append(line, '\n')); err != nil {
		t.Fatal(err)
	}
}

func (c *client) recv(t *testing.T) Response {
	t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		t.Fatalf("reading a response: %v", err)
	}
	var resp Response
	if err := json.Unmarshal(line, &resp); err != nil {
		t.Fatalf("bad response %q: %v", line, err)
	}
	return resp
}

func echoHandler(_ context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "echo":
		var v any
		_ = json.Unmarshal(params, &v)
		return v, nil
	case "fail":
		return nil, &ConnError{Message: "nope", TimedOut: true, Code: CodeNoAccount}
	case "plain":
		return nil, errors.New("plain failure")
	case "panic":
		panic("handler bug")
	}
	return nil, fmt.Errorf("unknown %q", method)
}

func TestServeRoundTripAndErrors(t *testing.T) {
	path, stop := startServer(t, echoHandler, Options{})
	defer stop()
	c := dial(t, path)

	c.send(t, 1, "echo", map[string]int{"a": 1})
	if r := c.recv(t); r.ID != 1 || r.Error != nil || string(r.Result) != `{"a":1}` {
		t.Fatalf("echo: %+v", r)
	}
	c.send(t, 2, "fail", nil)
	r := c.recv(t)
	if r.ID != 2 || r.Error == nil || r.Error.Message != "nope" || !r.Error.TimedOut || r.Error.Code != CodeNoAccount {
		t.Fatalf("ConnError must keep message, timedOut and code: %+v", r)
	}
	c.send(t, 3, "plain", nil)
	if r := c.recv(t); r.Error == nil || r.Error.Message != "plain failure" || r.Error.TimedOut || r.Error.Code != "" {
		t.Fatalf("plain error: %+v", r)
	}
}

func TestServeSurvivesAPanickingHandler(t *testing.T) {
	var logged atomic.Bool
	path, stop := startServer(t, echoHandler, Options{Logf: func(f string, a ...any) {
		if strings.Contains(fmt.Sprintf(f, a...), "panic in") {
			logged.Store(true)
		}
	}})
	defer stop()
	c := dial(t, path)
	c.send(t, 1, "panic", nil)
	r := c.recv(t)
	if r.Error == nil || r.Error.Code != CodeInternal {
		t.Fatalf("a panic must become an internal error, got %+v", r)
	}
	if !logged.Load() {
		t.Error("the panic was not logged")
	}
	// The daemon — and the same connection — keep working.
	c.send(t, 2, "echo", 7)
	if r := c.recv(t); string(r.Result) != "7" {
		t.Fatalf("server did not survive the panic: %+v", r)
	}
}

func TestMalformedRequestGetsAnAnswerInsteadOfSilence(t *testing.T) {
	path, stop := startServer(t, echoHandler, Options{})
	defer stop()
	c := dial(t, path)
	if _, err := c.conn.Write([]byte("this is not json\n")); err != nil {
		t.Fatal(err)
	}
	r := c.recv(t) // previously: silence, and the client waited forever
	if r.Error == nil || r.Error.Code != CodeBadRequest {
		t.Fatalf("got %+v", r)
	}
	c.send(t, 5, "echo", 1)
	if r := c.recv(t); r.ID != 5 || r.Error != nil {
		t.Fatalf("connection should stay usable: %+v", r)
	}
}

func TestSlowRequestDoesNotBlockAnotherOnTheSameConnection(t *testing.T) {
	release := make(chan struct{})
	h := func(ctx context.Context, method string, p json.RawMessage) (any, error) {
		if method == "slow" {
			select {
			case <-release:
			case <-ctx.Done():
			}
			return "slow done", nil
		}
		return "fast", nil
	}
	path, stop := startServer(t, h, Options{})
	defer stop()
	defer close(release)
	c := dial(t, path)
	c.send(t, 1, "slow", nil)
	c.send(t, 2, "fast", nil)
	if r := c.recv(t); r.ID != 2 {
		t.Fatalf("the fast request should answer first, got %+v", r)
	}
}

func TestClientDisconnectCancelsInFlightHandlers(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	h := func(ctx context.Context, method string, p json.RawMessage) (any, error) {
		close(started)
		select {
		case <-ctx.Done():
			close(cancelled)
			return nil, ctx.Err()
		case <-time.After(5 * time.Second):
			return nil, errors.New("handler was never cancelled")
		}
	}
	path, stop := startServer(t, h, Options{})
	defer stop()
	c := dial(t, path)
	c.send(t, 1, "open", nil)
	<-started
	_ = c.conn.Close() // the app crashed / the user pressed Cancel
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("an open request kept running after its client went away")
	}
}

func TestManyInFlightRequestsDoNotLeakWhenClientVanishes(t *testing.T) {
	const n = 12 // more than the old fixed response buffer of 8
	var running, finished atomic.Int32
	h := func(ctx context.Context, method string, p json.RawMessage) (any, error) {
		running.Add(1)
		<-ctx.Done()
		finished.Add(1)
		return "late", nil
	}
	path, stop := startServer(t, h, Options{MaxInFlight: 32})
	defer stop()
	c := dial(t, path)
	for i := 1; i <= n; i++ {
		c.send(t, uint64(i), "x", nil)
	}
	for running.Load() < n {
		time.Sleep(5 * time.Millisecond)
	}
	_ = c.conn.Close()
	deadline := time.Now().Add(3 * time.Second)
	for finished.Load() < n {
		if time.Now().After(deadline) {
			t.Fatalf("only %d of %d handlers finished: responses to a dead client must not block them", finished.Load(), n)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestPeerPolicyRefusesWithAReason(t *testing.T) {
	var called atomic.Bool
	h := func(ctx context.Context, method string, p json.RawMessage) (any, error) {
		called.Store(true)
		return "ok", nil
	}
	path, stop := startServer(t, h, Options{AllowPeer: func(pc PeerCred) bool { return false }})
	defer stop()
	c := dial(t, path)
	r := c.recv(t) // the refusal arrives without the client sending anything
	if r.Error == nil || r.Error.Code != CodeForbidden {
		t.Fatalf("got %+v", r)
	}
	if called.Load() {
		t.Fatal("handler ran for a refused peer")
	}
}

func TestPeerPolicySeesTheRealCredentials(t *testing.T) {
	var got atomic.Int64
	got.Store(-1)
	path, stop := startServer(t, echoHandler, Options{AllowPeer: func(pc PeerCred) bool {
		got.Store(int64(pc.UID))
		return true
	}})
	defer stop()
	c := dial(t, path)
	c.send(t, 1, "echo", 1)
	c.recv(t)
	if want := int64(os.Getuid()); got.Load() != want {
		t.Fatalf("peer uid = %d, want %d (this test process)", got.Load(), want)
	}
}

func TestConsoleUserPolicy(t *testing.T) {
	allow := ConsoleUserPolicy()
	if !allow(PeerCred{UID: 0}) {
		t.Error("root must be allowed")
	}
	// The console owner is whoever is logged in; when running headless it is root and nobody
	// else qualifies — in both cases a made-up uid must be refused.
	if allow(PeerCred{UID: 0x7ffffff1}) {
		t.Error("an arbitrary uid must be refused")
	}
	if console, err := consoleUID(); err == nil && console != 0 {
		if !allow(PeerCred{UID: console}) {
			t.Error("the console user must be allowed")
		}
	}
}

func TestConnectionLimit(t *testing.T) {
	hold := make(chan struct{})
	h := func(ctx context.Context, m string, p json.RawMessage) (any, error) {
		<-hold
		return nil, nil
	}
	path, stop := startServer(t, h, Options{MaxConns: 2})
	defer stop()
	defer close(hold)
	c1, c2 := dial(t, path), dial(t, path)
	c1.send(t, 1, "x", nil)
	c2.send(t, 1, "x", nil)
	time.Sleep(100 * time.Millisecond) // let both be accepted and occupy their slots
	c3 := dial(t, path)
	if r := c3.recv(t); r.Error == nil || r.Error.Code != CodeBusy {
		t.Fatalf("third connection should be refused as busy, got %+v", r)
	}
}

func TestPerConnectionInFlightLimit(t *testing.T) {
	hold := make(chan struct{})
	h := func(ctx context.Context, m string, p json.RawMessage) (any, error) {
		<-hold
		return "done", nil
	}
	path, stop := startServer(t, h, Options{MaxInFlight: 2})
	defer stop()
	defer close(hold)
	c := dial(t, path)
	c.send(t, 1, "x", nil)
	c.send(t, 2, "x", nil)
	c.send(t, 3, "x", nil)
	if r := c.recv(t); r.ID != 3 || r.Error == nil || r.Error.Code != CodeBusy {
		t.Fatalf("the third request should be refused as busy, got %+v", r)
	}
}

func TestSilentConnectionIsDropped(t *testing.T) {
	path, stop := startServer(t, echoHandler, Options{FirstRequestTimeout: 100 * time.Millisecond})
	defer stop()
	c := dial(t, path)
	_ = c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.r.ReadByte(); err == nil {
		t.Fatal("expected the server to close a connection that never sent a request")
	}
}

func TestOversizedRequestClosesTheConnection(t *testing.T) {
	path, stop := startServer(t, echoHandler, Options{MaxRequestBytes: 1024})
	defer stop()
	c := dial(t, path)
	big := strings.Repeat("a", 4096)
	_, _ = c.conn.Write([]byte(`{"id":1,"method":"echo","params":"` + big + "\"}\n"))
	_ = c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.r.ReadBytes('\n'); err == nil {
		t.Fatal("an oversized request should end the connection, not be served")
	}
}

func TestServeRemovesStaleSocketAndStopsCleanly(t *testing.T) {
	dir, _ := os.MkdirTemp("/tmp", "zipc")
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "s")
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, path, echoHandler, Options{SocketGID: -1}) }()
	var c net.Conn
	var err error
	for i := 0; i < 100; i++ {
		if c, err = net.Dial("unix", path); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("could not connect over a stale socket file: %v", err)
	}
	_ = c.Close()
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Serve: %v", err)
	}
	var wg sync.WaitGroup
	wg.Wait()
}
