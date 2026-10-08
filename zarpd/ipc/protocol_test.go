package ipc

import (
	"encoding/json"
	"testing"
)

// The exact bytes zarpd puts on the wire for each result type. The Swift client's tests
// (Packages/ZarpCore/Tests/ZarpdIPCTests) decode these very strings, so a field renamed — or an
// `omitempty` added to a value whose zero is meaningful — on either side breaks a test here or
// there instead of the running app. If you change one, change the other.
func TestWireFormat(t *testing.T) {
	tests := []struct {
		name string
		v    any
		want string
	}{
		{"ping", PingResult{Version: "0.1.0", Pid: 4242, Protocol: 2, AccountRegistered: true},
			`{"version":"0.1.0","pid":4242,"protocol":2,"accountRegistered":true}`},
		{"status, idle", StatusResult{DaemonRunning: true, AccountRegistered: true},
			`{"daemonRunning":true,"accountRegistered":true,"connected":false,"routeAll":false}`},
		{"status, full tunnel", StatusResult{
			DaemonRunning: true, AccountRegistered: true, Connected: true, ConnectionID: "7", StrategyID: "warp-q-google6",
			Endpoint: "162.159.198.2:500", Transport: "masqueH3", ConnectMs: 203, ConnectStartedAt: "2026-10-06T10:00:00Z",
			UtunName: "utun8", RouteAll: true},
			`{"daemonRunning":true,"accountRegistered":true,"connected":true,"connectionId":"7","strategyId":"warp-q-google6","endpoint":"162.159.198.2:500","transport":"masqueH3","connectMs":203,"connectStartedAt":"2026-10-06T10:00:00Z","utunName":"utun8","routeAll":true}`},
		{"status, test route only", StatusResult{DaemonRunning: true, Connected: true, ConnectionID: "2", RouteAll: false},
			`{"daemonRunning":true,"accountRegistered":false,"connected":true,"connectionId":"2","routeAll":false}`},
		{"status, after a loss", StatusResult{DaemonRunning: true, AccountRegistered: true,
			LastLoss: &LossInfo{ConnectionID: "3", Reason: "no recent network activity", At: "2026-10-06T10:01:00Z"}},
			`{"daemonRunning":true,"accountRegistered":true,"connected":false,"routeAll":false,"lastLoss":{"connectionId":"3","reason":"no recent network activity","at":"2026-10-06T10:01:00Z"}}`},
		{"open result", OpenResult{ConnectionID: "9", ConnectMs: 120, Endpoint: "162.159.198.1:443", UtunName: "utun8", RouteAll: true,
			Warnings: []string{"DNS was not overridden: boom"}},
			`{"connectionId":"9","connectMs":120,"endpoint":"162.159.198.1:443","utunName":"utun8","routeAll":true,"warnings":["DNS was not overridden: boom"]}`},
		{"open result, test connection", OpenResult{ConnectionID: "1", ConnectMs: 10},
			`{"connectionId":"1","connectMs":10,"routeAll":false}`},
		{"measure ok", MeasureResult{Kind: "ok", PingMs: 31, Warp: "on"}, `{"kind":"ok","pingMs":31,"warp":"on"}`},
		{"measure notWarp", MeasureResult{Kind: "notWarp", Detail: "off"}, `{"kind":"notWarp","detail":"off"}`},
		{"measure noTraffic", MeasureResult{Kind: "noTraffic", LastError: "i/o timeout"}, `{"kind":"noTraffic","lastError":"i/o timeout"}`},
		{"logs", LogsResult{Lines: []LogLine{{Seq: 5, TimeMs: 1791284063527, Text: "closed #1"}}, Next: 5, Dropped: 2},
			`{"lines":[{"seq":5,"timeMs":1791284063527,"text":"closed #1"}],"next":5,"dropped":2}`},
		{"logs, empty ring", LogsResult{}, `{"lines":null,"next":0}`},
		{"restart", RestartResult{Acknowledged: true}, `{"acknowledged":true}`},
		{"register", RegisterResult{AccountRegistered: true}, `{"accountRegistered":true}`},
		{"error", Response{ID: 7, Error: &ErrorInfo{Message: "no WARP account yet", Code: CodeNoAccount}},
			`{"id":7,"error":{"message":"no WARP account yet","timedOut":false,"code":"no_account"}}`},
		{"error, timeout without a code", Response{ID: 8, Error: &ErrorInfo{Message: "timeout after 15s", TimedOut: true}},
			`{"id":8,"error":{"message":"timeout after 15s","timedOut":true}}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.v)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tt.want {
				t.Fatalf("wire format changed:\n got %s\nwant %s", got, tt.want)
			}
		})
	}
}

// What the app sends: these field names are what the Swift side's Encodable structs produce.
func TestOpenParamsDecodesWhatTheAppSends(t *testing.T) {
	raw := `{"transport":"masqueH3","strategyId":"warp-q-google-ttl","fakeSteps":[{"blob":"quic_google","repeats":6,"ipTTL":4,"ip6TTL":4}],` +
		`"endpoint":"isolated-3","timeoutMs":15000,"persistent":true,"routeAll":true,"overrideDNS":true}`
	var p OpenParams
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	if p.Transport != "masqueH3" || p.StrategyID != "warp-q-google-ttl" || p.Endpoint != "isolated-3" || p.TimeoutMs != 15000 ||
		!p.Persistent || !p.RouteAll || !p.OverrideDNS || len(p.FakeSteps) != 1 {
		t.Fatalf("decoded %+v", p)
	}
	s := p.FakeSteps[0]
	if s.Blob != "quic_google" || s.Repeats != 6 || s.IPTTL == nil || *s.IPTTL != 4 || s.IP6TTL == nil || *s.IP6TTL != 4 {
		t.Fatalf("decoded step %+v", s)
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("what the app sends must validate: %v", err)
	}

	split := `{"transport":"masqueH2","strategyId":"x","tcpDesync":{"mode":"disorder","positions":["1","midsld"]},"endpoint":"","timeoutMs":1000,"persistent":false}`
	var h2 OpenParams
	if err := json.Unmarshal([]byte(split), &h2); err != nil {
		t.Fatal(err)
	}
	if h2.TCPDesync == nil || h2.TCPDesync.Mode != "disorder" || len(h2.TCPDesync.Positions) != 2 {
		t.Fatalf("decoded %+v", h2)
	}
	if err := h2.Validate(); err != nil {
		t.Fatalf("what the app sends for HTTP/2 must validate: %v", err)
	}
}
