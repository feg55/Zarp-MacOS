// Package ipc is the wire protocol between Zarp.app (Swift) and zarpd (docs/ARCHITECTURE.md §9.4):
// newline-delimited JSON over a Unix domain socket, one request per line, one response per line,
// correlated by ID. Deliberately not gRPC/protobuf for this first cut — no codegen toolchain
// needed on either the Swift or Go side to get something working end to end, and the message
// shapes below map directly onto EngineProtocols.swift's WarpConnectionProvider/WarpProbe, not a
// second scan/state engine: zarpd only ever does what a single open/measure/close call asks for.
// Upgrading the transport later doesn't change ZarpEngine or its protocols at all.
package ipc

import "encoding/json"

// Request is one line the app sends. Params is left as raw JSON and re-decoded per Method by the
// handler, rather than a big union struct, so adding a method doesn't touch every existing one.
type Request struct {
	ID     uint64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response is one line zarpd sends back. Exactly one of Result/Error is set.
type Response struct {
	ID     uint64          `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *ErrorInfo      `json:"error,omitempty"`
}

type ErrorInfo struct {
	Message string `json:"message"`
	// TimedOut mirrors EngineProtocols.swift's WarpConnectionError.timedOut, which drives the
	// same err.timeout-vs-generic-failure distinction the scan loop makes.
	TimedOut bool `json:"timedOut"`
}

// --- open ---

// OpenParams mirrors WarpConnectionProvider.open(strategy:endpoint:timeoutMs:persistent:) —
// Strategy is flattened to exactly what zarpd needs to execute it (StrategyArgsParser.parse's
// output, DesyncPlan, plus the transport), not the whole Swift Strategy struct (id/name/args are
// the app's concern, not the daemon's).
type OpenParams struct {
	Transport  string      `json:"transport"` // "masqueH3" | "masqueH2" | "wireGuard"
	FakeSteps  []FakeStep  `json:"fakeSteps,omitempty"`
	TCPDesync  *TCPDesync  `json:"tcpDesync,omitempty"`
	Endpoint   string      `json:"endpoint,omitempty"` // pin a specific WARP endpoint; "" = let zarpd choose
	TimeoutMs  int         `json:"timeoutMs"`
	Persistent bool        `json:"persistent"`
}

// FakeStep mirrors ZarpCore's FakeStep (DesyncPlan.swift) exactly, field for field — Blob is the
// same rawValue string as Swift's Blob enum ("quic_google", "quic_vk", ...), which zarpd resolves
// to a Resources/blobs/*.bin path itself rather than the app sending file bytes over the socket.
type FakeStep struct {
	Blob    string `json:"blob"`
	Repeats int    `json:"repeats"`
	IPTTL   *int   `json:"ipTTL,omitempty"`
	IP6TTL  *int   `json:"ip6TTL,omitempty"`
}

// TCPDesync mirrors ZarpCore's TCPDesyncStep.
type TCPDesync struct {
	Mode      string   `json:"mode"` // "split" | "disorder"
	Positions []string `json:"positions"`
}

// OpenResult mirrors WarpConnectionHandle's two readable properties, plus the id later open/close/measure calls use.
type OpenResult struct {
	ConnectionID string `json:"connectionId"`
	ConnectMs    int    `json:"connectMs"`
	Endpoint     string `json:"endpoint,omitempty"`
}

// --- close ---

type CloseParams struct {
	ConnectionID string `json:"connectionId"`
}

// --- measure ---

type MeasureParams struct {
	ConnectionID string `json:"connectionId"`
	Samples      int    `json:"samples"`
}

// MeasureResult mirrors WarpMeasurement's three cases (EngineProtocols.swift) as a tagged union;
// Kind selects which of the other fields is meaningful.
type MeasureResult struct {
	Kind      string `json:"kind"` // "ok" | "notWarp" | "noTraffic"
	PingMs    int    `json:"pingMs,omitempty"`
	Warp      string `json:"warp,omitempty"`      // "ok" kind: the cdn-cgi/trace warp= value
	Detail    string `json:"detail,omitempty"`    // "notWarp" kind: same field, optional
	LastError string `json:"lastError,omitempty"` // "noTraffic" kind
}
