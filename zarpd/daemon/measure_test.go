package daemon

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func traceServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *TraceMeasurer) {
	t.Helper()
	srv := httptest.NewTLSServer(handler)
	t.Cleanup(srv.Close)
	return srv, &TraceMeasurer{
		RequestTimeout: 2 * time.Second,
		URLFor:         func(string) string { return srv.URL + "/cdn-cgi/trace" },
		TLSConfig:      &tls.Config{InsecureSkipVerify: true},
	}
}

func warpHandler(value string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("fl=1f1\nh=1.1.1.1\nip=203.0.113.9\nwarp=" + value + "\ngateway=off\n"))
	}
}

func TestMeasureOK(t *testing.T) {
	var reqs atomic.Int32
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) {
		reqs.Add(1)
		warpHandler("on")(w, r)
	})
	res := m.Measure(context.Background(), "1.1.1.1", 3)
	if res.Kind != "ok" || res.Warp != "on" {
		t.Fatalf("%+v", res)
	}
	if got := reqs.Load(); got != 4 {
		t.Fatalf("expected a warm-up plus 3 timed requests, got %d", got)
	}
}

func TestMeasureAcceptsWarpPlus(t *testing.T) {
	_, m := traceServer(t, warpHandler("plus"))
	if res := m.Measure(context.Background(), "1.1.1.1", 1); res.Kind != "ok" || res.Warp != "plus" {
		t.Fatalf("%+v", res)
	}
}

func TestMeasureNotWarpCarriesTheRawValue(t *testing.T) {
	_, m := traceServer(t, warpHandler("off"))
	res := m.Measure(context.Background(), "1.1.1.1", 3)
	// Detail is the bare value: the app prefixes "warp=" itself. (It used to arrive as
	// "warp=off" and be displayed as "warp=warp=off".)
	if res.Kind != "notWarp" || res.Detail != "off" {
		t.Fatalf("%+v", res)
	}
}

func TestMeasureMissingWarpLine(t *testing.T) {
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("fl=1\nip=1.2.3.4\n")) })
	if res := m.Measure(context.Background(), "1.1.1.1", 1); res.Kind != "notWarp" || res.Detail != "" {
		t.Fatalf("%+v", res)
	}
}

func TestMeasureHandlesCRLF(t *testing.T) {
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("fl=1\r\nwarp=on\r\n")) })
	if res := m.Measure(context.Background(), "1.1.1.1", 1); res.Kind != "ok" || res.Warp != "on" {
		t.Fatalf("a CR must not end up inside the value: %+v", res)
	}
}

func TestMeasureNoTrafficWhenTheServerIsUnreachable(t *testing.T) {
	srv, m := traceServer(t, warpHandler("on"))
	srv.Close()
	res := m.Measure(context.Background(), "1.1.1.1", 3)
	if res.Kind != "noTraffic" || res.LastError == "" {
		t.Fatalf("%+v", res)
	}
}

func TestMeasureTreatsHTTPErrorsAsNoTraffic(t *testing.T) {
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) { http.Error(w, "blocked", http.StatusForbidden) })
	res := m.Measure(context.Background(), "1.1.1.1", 1)
	if res.Kind != "noTraffic" || !strings.Contains(res.LastError, "403") {
		t.Fatalf("%+v", res)
	}
}

func TestMeasureTimesOutOnAHungServer(t *testing.T) {
	release := make(chan struct{})
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) { <-release })
	defer close(release)
	m.RequestTimeout = 200 * time.Millisecond
	start := time.Now()
	res := m.Measure(context.Background(), "1.1.1.1", 3)
	if res.Kind != "noTraffic" {
		t.Fatalf("%+v", res)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("measure took %v on a dead path (the warm-up alone should end it)", time.Since(start))
	}
}

func TestMeasureStopsWhenTheCallerGoesAway(t *testing.T) {
	release := make(chan struct{})
	_, m := traceServer(t, func(w http.ResponseWriter, r *http.Request) { <-release })
	defer close(release)
	m.RequestTimeout = 10 * time.Second
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.Measure(ctx, "1.1.1.1", 3); close(done) }()
	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("a cancelled measurement kept going")
	}
}

func TestMeasureDoesNotReuseConnectionsAcrossCalls(t *testing.T) {
	// Each Measure call is for a different tunnel: a pooled connection from the previous call
	// would be dead. Count the distinct TCP connections the server sees across two calls.
	var conns atomic.Int32
	counting := httptest.NewUnstartedServer(warpHandler("on"))
	counting.Config.ConnState = func(_ net.Conn, s http.ConnState) {
		if s == http.StateNew {
			conns.Add(1)
		}
	}
	counting.StartTLS()
	defer counting.Close()
	m := &TraceMeasurer{
		RequestTimeout: 2 * time.Second,
		URLFor:         func(string) string { return counting.URL + "/cdn-cgi/trace" },
		TLSConfig:      &tls.Config{InsecureSkipVerify: true},
	}
	for i := 0; i < 2; i++ {
		if res := m.Measure(context.Background(), "1.1.1.1", 2); res.Kind != "ok" {
			t.Fatalf("%+v", res)
		}
	}
	if got := conns.Load(); got != 2 {
		t.Fatalf("server saw %d connections for 2 measurements, want 2 (one per call; keep-alive only within a call)", got)
	}
}
