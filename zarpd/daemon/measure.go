package daemon

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

// Measurer checks whether traffic really goes through WARP and how fast: Cloudflare's own
// cdn-cgi/trace reports warp=on / warp=plus for a request that arrived through WARP — the same
// signal every Zarp port uses.
type Measurer interface {
	Measure(ctx context.Context, host string, samples int) ipc.MeasureResult
}

// TraceMeasurer is the real Measurer.
type TraceMeasurer struct {
	// RequestTimeout bounds one request (default 5s).
	RequestTimeout time.Duration
	// URLFor builds the trace URL for host (default https://host/cdn-cgi/trace); tests override it.
	URLFor func(host string) string
	// TLSConfig overrides the client TLS settings (tests only).
	TLSConfig *tls.Config
}

func (m *TraceMeasurer) url(host string) string {
	if m.URLFor != nil {
		return m.URLFor(host)
	}
	return "https://" + host + "/cdn-cgi/trace"
}

// Measure makes one warm-up request (not scored) and then `samples` timed ones, and reports the
// median — matching every other Zarp port's WarpProbe contract (EngineProtocols.swift).
//
// Every call builds its own http.Transport and closes it before returning. Sharing
// http.DefaultTransport instead would keep an idle connection to the measurement host alive after
// the tunnel it ran through was torn down, and the next test — which has a brand-new tunnel —
// would pick that dead connection for its warm-up and report "no traffic" for a strategy that
// works. Keep-alive *within* one call is deliberate: the warm-up opens the connection and the
// timed requests reuse it, so the reported ping is request latency, not connection setup.
func (m *TraceMeasurer) Measure(ctx context.Context, host string, samples int) ipc.MeasureResult {
	if samples <= 0 {
		samples = 3
	}
	timeout := m.RequestTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	tr := &http.Transport{
		Proxy:               nil, // never an environment proxy: the request must take the tunnel's route
		TLSClientConfig:     m.TLSConfig,
		TLSHandshakeTimeout: timeout,
		DisableCompression:  true,
		MaxIdleConns:        1,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: timeout}
	url := m.url(host)

	if _, errStr := traceOnce(ctx, client, url); errStr != "" {
		return ipc.MeasureResult{Kind: "noTraffic", LastError: errStr}
	}

	var pings []int
	var warpVal, lastErr string
	for i := 0; i < samples; i++ {
		start := time.Now()
		warpv, errStr := traceOnce(ctx, client, url)
		if errStr != "" {
			lastErr = errStr
			if ctx.Err() != nil {
				break
			}
			continue
		}
		if warpv != "on" && warpv != "plus" {
			// Reached the server, but the request did not come through WARP. Detail is the raw
			// value ("off", or "" when the line was missing); the app adds its own "warp=" label.
			return ipc.MeasureResult{Kind: "notWarp", Detail: warpv}
		}
		pings = append(pings, int(time.Since(start).Milliseconds()))
		warpVal = warpv
	}
	if len(pings) == 0 {
		return ipc.MeasureResult{Kind: "noTraffic", LastError: lastErr}
	}
	sort.Ints(pings)
	return ipc.MeasureResult{Kind: "ok", PingMs: pings[len(pings)/2], Warp: warpVal}
}

// traceOnce fetches cdn-cgi/trace and returns the warp= value, or (on failure) an error string —
// two returns instead of an error so the caller can tell "reached the server but warp isn't on"
// apart from "never reached the server at all" (noTraffic vs. notWarp).
func traceOnce(ctx context.Context, client *http.Client, url string) (warpVal, errStr string) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err.Error()
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err.Error()
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return "", fmt.Sprintf("HTTP %d", resp.StatusCode)
	}
	// cdn-cgi/trace is a few hundred bytes, but a single Read() call on a network response body
	// is not guaranteed to return the whole thing at once — ReadAll loops until EOF instead of
	// risking a truncated read that happens to cut off the warp= line.
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8192))
	if err != nil {
		return "", err.Error()
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimRight(line, "\r"), "warp="); ok {
			warpVal = v
		}
	}
	return warpVal, ""
}
