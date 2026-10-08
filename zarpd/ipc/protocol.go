// Package ipc is the wire protocol between Zarp.app (Swift) and zarpd (docs/ARCHITECTURE.md §9.4):
// newline-delimited JSON over a Unix domain socket, one request per line, one response per line,
// correlated by ID. Deliberately not gRPC/protobuf for this first cut — no codegen toolchain
// needed on either the Swift or Go side to get something working end to end, and the message
// shapes below map directly onto EngineProtocols.swift's WarpConnectionProvider/WarpProbe, not a
// second scan/state engine: zarpd only ever does what a single open/measure/close call asks for.
// Upgrading the transport later doesn't change ZarpEngine or its protocols at all.
//
// A client must keep its end of the connection open until it has read the response to every
// request it sent: the server treats the client closing (or half-closing) the connection as "the
// caller went away" and aborts whatever is still in flight for it — an `open` mid-dial in
// particular — rather than finishing work nobody will collect.
package ipc

import "encoding/json"

// ProtocolVersion is bumped whenever a request or response changes shape incompatibly. The app
// compares it (PingResult.Protocol) against the version it was built for, so a stale daemon left
// running after an app update is noticed instead of failing in confusing ways.
//
// 1 = Phase 7-8 (open/close/measure/status/ping/restart).
// 2 = lazy account registration (register), daemon log pull (logs), full-tunnel routing
//
//	(OpenParams.RouteAll/OverrideDNS), error codes, endpoint rotation tokens.
const ProtocolVersion = 2

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

// Error codes. Code is empty for an ordinary failure whose Message is all the app needs.
const (
	CodeBadRequest  = "bad_request" // the request itself is malformed or out of bounds
	CodeForbidden   = "forbidden"   // the connecting process isn't allowed to use the daemon
	CodeBusy        = "busy"        // too many connections / requests in flight
	CodeNoAccount   = "no_account"  // no WARP account yet; the app must register first (consent)
	CodeForeignVPN  = "foreign_vpn" // another VPN owns the default route; full tunnel refused
	CodeUnsupported = "unsupported" // valid request for something this daemon doesn't implement
	CodeCancelled   = "cancelled"   // aborted because the caller went away or a newer open superseded it
	CodeInternal    = "internal"    // a bug in the daemon (recovered panic)
)

type ErrorInfo struct {
	Message string `json:"message"`
	// TimedOut mirrors EngineProtocols.swift's WarpConnectionError.timedOut, which drives the
	// same err.timeout-vs-generic-failure distinction the scan loop makes.
	TimedOut bool   `json:"timedOut"`
	Code     string `json:"code,omitempty"`
}

// ConnError is what a Handler returns for a failure that should reach the app as
// WarpConnectionError(message, timedOut:, code:) — see EngineProtocols.swift. A plain error
// becomes ErrorInfo{Message: err.Error()}.
type ConnError struct {
	Message  string
	TimedOut bool
	Code     string
}

func (e *ConnError) Error() string { return e.Message }

// --- ping ---

// PingResult answers "is zarpd alive and what build is it" — no params, no side effects, cheap
// enough for the app to poll (Settings shows it live, and the app uses Version/Protocol to notice
// a daemon that predates the app it's talking to).
type PingResult struct {
	Version  string `json:"version"`
	Pid      int    `json:"pid"`
	Protocol int    `json:"protocol"`
	// AccountRegistered is whether a WARP account exists yet. Registration happens only after the
	// user has accepted Cloudflare's terms in the app (the `register` method), never on its own.
	AccountRegistered bool `json:"accountRegistered"`
}

// --- restart ---

// RestartResult acknowledges the request before zarpd actually exits — see the handler's own
// comment on why the response has to be flushed first.
type RestartResult struct {
	Acknowledged bool `json:"acknowledged"`
}

// --- register ---

// RegisterResult is the answer to `register` (idempotent: registering twice is a no-op).
type RegisterResult struct {
	AccountRegistered bool `json:"accountRegistered"`
}

// --- status ---

// StatusResult answers "what is zarpd's current live connection, if any" — read-only, no side
// effects, safe to call as often as needed. Only ever reports the one *persistent* connection
// (test/scan connections are deliberately short-lived and never worth a GUI adopting), matching
// ZarpEngine's own "one operation at a time" invariant. `Connected: false` with everything else
// empty means genuinely idle, not unreachable — an unreachable daemon fails the IPC call itself
// (same as every other method), it doesn't return a hollow StatusResult.
type StatusResult struct {
	DaemonRunning     bool   `json:"daemonRunning"`
	AccountRegistered bool   `json:"accountRegistered"`
	Connected         bool   `json:"connected"`
	ConnectionID      string `json:"connectionId,omitempty"`
	StrategyID        string `json:"strategyId,omitempty"`
	Endpoint          string `json:"endpoint,omitempty"`
	Transport         string `json:"transport,omitempty"`
	ConnectMs         int    `json:"connectMs,omitempty"`
	ConnectStartedAt  string `json:"connectStartedAt,omitempty"` // RFC3339
	UtunName          string `json:"utunName,omitempty"`
	// RouteAll is true when all traffic goes through the tunnel, false when only the test route does.
	// Deliberately *not* omitempty: "false" is an answer the app must be able to read, and an absent
	// field would be indistinguishable from a daemon that predates the field.
	RouteAll bool `json:"routeAll"`
	// LastLoss describes the most recent persistent connection that ended on its own (the
	// MASQUE session died, the network changed, ...) rather than because the app asked for it.
	// The app uses it to explain why a tunnel it was showing as connected is gone.
	LastLoss *LossInfo `json:"lastLoss,omitempty"`
}

// LossInfo is one unrequested connection end.
type LossInfo struct {
	ConnectionID string `json:"connectionId"`
	Reason       string `json:"reason"`
	At           string `json:"at"` // RFC3339
}

// --- open ---

// OpenParams mirrors WarpConnectionProvider.open(strategy:endpoint:timeoutMs:persistent:) —
// Strategy is flattened to exactly what zarpd needs to execute it (StrategyArgsParser.parse's
// output, DesyncPlan, plus the transport), not the whole Swift Strategy struct — except StrategyID,
// carried through as an opaque label purely so a later "status" call can report back which saved
// strategy a persistent connection belongs to (ARCHITECTURE.md's GUI/daemon reconciliation notes);
// zarpd never interprets it.
//
// Every field is validated (Validate) before anything is dialed: this is a privileged process
// taking requests from user-level code, so the app's own parser being careful isn't relied on.
type OpenParams struct {
	Transport  string     `json:"transport"` // "masqueH3" | "masqueH2" ("" = masqueH3); "wireGuard" is rejected as unsupported
	StrategyID string     `json:"strategyId,omitempty"`
	FakeSteps  []FakeStep `json:"fakeSteps,omitempty"` // masqueH3 only
	TCPDesync  *TCPDesync `json:"tcpDesync,omitempty"` // masqueH2 only
	// Endpoint pins the WARP endpoint: "" = the account's own; "ip" or "ip:port" within
	// Cloudflare's published WARP ranges; or "isolated-N", ZarpEngine's per-test uniqueness token,
	// which the daemon maps onto a rotating pool of endpoints (daemon/endpoints.go) so every test
	// really does leave from a fresh 5-tuple, like Windows Zarp's Warp.NextEndpoint.
	Endpoint   string `json:"endpoint,omitempty"`
	TimeoutMs  int    `json:"timeoutMs"`
	Persistent bool   `json:"persistent"`
	// RouteAll sends all of the machine's traffic through the tunnel (two /1 routes per address
	// family — the same fail-safe shape wg-quick uses: they vanish with the interface if zarpd
	// dies). Without it the tunnel carries only the measurement target, which is all a scan needs.
	// Only a persistent connection may set it.
	RouteAll bool `json:"routeAll,omitempty"`
	// OverrideDNS additionally points the active network service's DNS at Cloudflare's resolvers
	// while the tunnel is up (original settings are saved and restored, even after a crash). The
	// servers themselves are fixed in the daemon, never taken from the client. Requires RouteAll.
	OverrideDNS bool `json:"overrideDNS,omitempty"`
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

// OpenResult mirrors WarpConnectionHandle's two readable properties, plus the id later
// close/measure calls use.
type OpenResult struct {
	ConnectionID string `json:"connectionId"`
	ConnectMs    int    `json:"connectMs"`
	// Endpoint is the WARP endpoint actually dialed ("ip:port"), for logs and diagnostics.
	Endpoint string `json:"endpoint,omitempty"`
	UtunName string `json:"utunName,omitempty"`
	RouteAll bool   `json:"routeAll"` // not omitempty, for the same reason as StatusResult.RouteAll
	// Warnings are non-fatal problems the app should surface in its log (e.g. the DNS override
	// couldn't be applied, so DNS still goes to the system resolver).
	Warnings []string `json:"warnings,omitempty"`
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
	Detail    string `json:"detail,omitempty"`    // "notWarp" kind: the raw warp= value that was seen ("off", ...)
	LastError string `json:"lastError,omitempty"` // "noTraffic" kind
}

// --- logs ---

// LogsParams asks for every daemon log line newer than Since (0 = everything still buffered).
type LogsParams struct {
	Since uint64 `json:"since"`
}

// LogLine is one buffered daemon log line.
type LogLine struct {
	Seq    uint64 `json:"seq"`
	TimeMs int64  `json:"timeMs"` // Unix milliseconds
	Text   string `json:"text"`
}

// LogsResult carries the new lines and the cursor to pass as Since next time. If lines were
// dropped from the ring in between, Dropped says how many were missed.
type LogsResult struct {
	Lines   []LogLine `json:"lines"`
	Next    uint64    `json:"next"`
	Dropped uint64    `json:"dropped,omitempty"`
}
