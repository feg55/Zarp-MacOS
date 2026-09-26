package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
)

// ConnError is what a Handler returns for a failure that should reach the app as
// WarpConnectionError(message, timedOut:) — see EngineProtocols.swift. A plain error becomes
// ErrorInfo{Message: err.Error(), TimedOut: false}.
type ConnError struct {
	Message  string
	TimedOut bool
}

func (e *ConnError) Error() string { return e.Message }

// Handler processes one request's params (still-undecoded JSON — decode into the method's own
// Params type) and returns a value to encode as Result, or an error.
type Handler func(ctx context.Context, method string, params json.RawMessage) (any, error)

// Serve listens on a Unix domain socket at socketPath and dispatches every request line to
// handler until ctx is done. One goroutine per connection, one goroutine per request within a
// connection (so a slow `open` doesn't block a concurrent `getStatus`-style call on the same
// connection) — requests are independent by design (docs/ARCHITECTURE.md §9.4), there's no
// server-side state that needs per-connection request ordering.
func Serve(ctx context.Context, socketPath string, handler Handler) error {
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("removing stale socket %s: %w", socketPath, err)
	}
	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	// Swift's default file permissions on a freshly-created socket may not be group/other
	// writable; the app runs as the logged-in user, not root, so it must be able to connect.
	if err := os.Chmod(socketPath, 0o666); err != nil {
		log.Printf("ipc: chmod %s: %v", socketPath, err)
	}
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go serveConn(ctx, conn, handler)
	}
}

func serveConn(ctx context.Context, conn net.Conn, handler Handler) {
	defer func() { _ = conn.Close() }()

	// Requests are handled concurrently (a slow `open` shouldn't block a concurrent `getStatus`
	// on the same connection), but net.Conn.Write from multiple goroutines at once would
	// interleave partial writes and garble the JSON stream — so every response goes through this
	// channel to the one goroutine below that's actually allowed to write to conn.
	responses := make(chan Response, 8)
	done := make(chan struct{})
	go func() {
		defer close(done)
		enc := json.NewEncoder(conn)
		for resp := range responses {
			if err := enc.Encode(resp); err != nil {
				log.Printf("ipc: writing response for #%d: %v", resp.ID, err)
				return
			}
		}
	}()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024) // strategies with several fake steps are still tiny JSON, but leave headroom
	var pending sync.WaitGroup
	for scanner.Scan() {
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			log.Printf("ipc: bad request: %v", err)
			continue
		}
		pending.Add(1)
		go func(req Request) {
			defer pending.Done()
			responses <- dispatch(ctx, handler, req)
		}(req)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("ipc: connection read: %v", err)
	}
	pending.Wait()
	close(responses)
	<-done
}

func dispatch(ctx context.Context, handler Handler, req Request) Response {
	result, err := handler(ctx, req.Method, req.Params)
	if err != nil {
		var ce *ConnError
		if errors.As(err, &ce) {
			return Response{ID: req.ID, Error: &ErrorInfo{Message: ce.Message, TimedOut: ce.TimedOut}}
		}
		return Response{ID: req.ID, Error: &ErrorInfo{Message: err.Error()}}
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return Response{ID: req.ID, Error: &ErrorInfo{Message: fmt.Sprintf("encoding result: %v", err)}}
	}
	return Response{ID: req.ID, Result: raw}
}
