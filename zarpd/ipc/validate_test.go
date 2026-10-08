package ipc

import (
	"errors"
	"net/netip"
	"strings"
	"testing"
)

func intp(n int) *int { return &n }

func TestOpenParamsValidate(t *testing.T) {
	good := func() OpenParams {
		return OpenParams{
			Transport: "masqueH3", TimeoutMs: 15000,
			FakeSteps: []FakeStep{{Blob: "quic_google", Repeats: 6, IPTTL: intp(4)}},
		}
	}
	h2 := func() OpenParams {
		return OpenParams{Transport: "masqueH2", TCPDesync: &TCPDesync{Mode: "split", Positions: []string{"1", "midsld"}}}
	}

	tests := []struct {
		name     string
		mutate   func(p *OpenParams)
		base     func() OpenParams
		wantCode string // "" = valid
		wantText string
	}{
		{name: "valid H3 with fakes", base: good},
		{name: "valid H2 with split", base: h2},
		{name: "empty transport means H3", base: good, mutate: func(p *OpenParams) { p.Transport = "" }},
		{name: "valid persistent full tunnel with DNS", base: good, mutate: func(p *OpenParams) {
			p.Persistent, p.RouteAll, p.OverrideDNS = true, true, true
		}},

		{name: "wireGuard is unsupported, not malformed", base: good, mutate: func(p *OpenParams) { p.Transport = "wireGuard" }, wantCode: CodeUnsupported},
		{name: "unknown transport", base: good, mutate: func(p *OpenParams) { p.Transport = "carrier-pigeon" }, wantCode: CodeBadRequest},

		{name: "too many repeats", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].Repeats = 51 }, wantCode: CodeBadRequest, wantText: "repeats"},
		{name: "huge repeats (flood attempt)", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].Repeats = 1_000_000_000 }, wantCode: CodeBadRequest},
		{name: "zero repeats", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].Repeats = 0 }, wantCode: CodeBadRequest},
		{name: "negative repeats", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].Repeats = -1 }, wantCode: CodeBadRequest},
		{name: "ttl too big", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].IPTTL = intp(256) }, wantCode: CodeBadRequest, wantText: "ipTTL"},
		{name: "ttl zero", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].IPTTL = intp(0) }, wantCode: CodeBadRequest},
		{name: "ip6 ttl too big", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].IP6TTL = intp(999) }, wantCode: CodeBadRequest, wantText: "ip6TTL"},
		{name: "unknown blob", base: good, mutate: func(p *OpenParams) { p.FakeSteps[0].Blob = "../../etc/passwd" }, wantCode: CodeBadRequest, wantText: "blob"},
		{name: "too many steps", base: good, mutate: func(p *OpenParams) {
			p.FakeSteps = make([]FakeStep, MaxFakeSteps+1)
			for i := range p.FakeSteps {
				p.FakeSteps[i] = FakeStep{Blob: "zero64", Repeats: 1}
			}
		}, wantCode: CodeBadRequest},
		{name: "fakes on H2", base: h2, mutate: func(p *OpenParams) {
			p.FakeSteps = []FakeStep{{Blob: "quic_google", Repeats: 1}}
		}, wantCode: CodeBadRequest},
		{name: "split on H3", base: good, mutate: func(p *OpenParams) {
			p.TCPDesync = &TCPDesync{Mode: "split", Positions: []string{"1"}}
		}, wantCode: CodeBadRequest},

		{name: "desync bad mode", base: h2, mutate: func(p *OpenParams) { p.TCPDesync.Mode = "shred" }, wantCode: CodeBadRequest},
		{name: "desync no positions", base: h2, mutate: func(p *OpenParams) { p.TCPDesync.Positions = nil }, wantCode: CodeBadRequest},
		{name: "desync bad position", base: h2, mutate: func(p *OpenParams) { p.TCPDesync.Positions = []string{"midsld+1"} }, wantCode: CodeBadRequest},
		{name: "desync huge position", base: h2, mutate: func(p *OpenParams) { p.TCPDesync.Positions = []string{"99999999"} }, wantCode: CodeBadRequest},
		{name: "desync negative position ok", base: h2, mutate: func(p *OpenParams) { p.TCPDesync.Positions = []string{"-2", "endhost"} }},
		{name: "desync too many positions", base: h2, mutate: func(p *OpenParams) {
			p.TCPDesync.Positions = make([]string, MaxPositions+1)
			for i := range p.TCPDesync.Positions {
				p.TCPDesync.Positions[i] = "1"
			}
		}, wantCode: CodeBadRequest},

		{name: "endpoint: account default", base: good, mutate: func(p *OpenParams) { p.Endpoint = "" }},
		{name: "endpoint: isolation token", base: good, mutate: func(p *OpenParams) { p.Endpoint = "isolated-42" }},
		{name: "endpoint: bad token", base: good, mutate: func(p *OpenParams) { p.Endpoint = "isolated-x" }, wantCode: CodeBadRequest},
		{name: "endpoint: WARP ip", base: good, mutate: func(p *OpenParams) { p.Endpoint = "162.159.198.2" }},
		{name: "endpoint: WARP ip:port", base: good, mutate: func(p *OpenParams) { p.Endpoint = "162.159.198.2:4500" }},
		{name: "endpoint: arbitrary public ip refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "8.8.8.8" }, wantCode: CodeBadRequest, wantText: "outside"},
		{name: "endpoint: loopback refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "127.0.0.1" }, wantCode: CodeBadRequest},
		{name: "endpoint: LAN ip refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "192.168.1.1:443" }, wantCode: CodeBadRequest},
		{name: "endpoint: hostname refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "evil.example" }, wantCode: CodeBadRequest},
		{name: "endpoint: ipv6 refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "2606:4700:100::1" }, wantCode: CodeBadRequest},
		{name: "endpoint: odd H3 port refused", base: good, mutate: func(p *OpenParams) { p.Endpoint = "162.159.198.2:22" }, wantCode: CodeBadRequest},
		{name: "endpoint: H2 non-443 port refused", base: h2, mutate: func(p *OpenParams) { p.Endpoint = "162.159.198.2:500" }, wantCode: CodeBadRequest},
		{name: "endpoint: H2 443 ok", base: h2, mutate: func(p *OpenParams) { p.Endpoint = "162.159.198.2:443" }},

		{name: "timeout negative", base: good, mutate: func(p *OpenParams) { p.TimeoutMs = -1 }, wantCode: CodeBadRequest},
		{name: "timeout absurd", base: good, mutate: func(p *OpenParams) { p.TimeoutMs = 99_999_999 }, wantCode: CodeBadRequest},
		{name: "strategy id too long", base: good, mutate: func(p *OpenParams) { p.StrategyID = strings.Repeat("a", MaxStrategyID+1) }, wantCode: CodeBadRequest},
		{name: "strategy id control char (log injection)", base: good, mutate: func(p *OpenParams) { p.StrategyID = "x\nforged log line" }, wantCode: CodeBadRequest},

		{name: "routeAll needs persistent", base: good, mutate: func(p *OpenParams) { p.RouteAll = true }, wantCode: CodeBadRequest},
		{name: "overrideDNS needs routeAll", base: good, mutate: func(p *OpenParams) { p.Persistent, p.OverrideDNS = true, true }, wantCode: CodeBadRequest},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := tt.base()
			if tt.mutate != nil {
				tt.mutate(&p)
			}
			err := p.Validate()
			if tt.wantCode == "" {
				if err != nil {
					t.Fatalf("expected valid, got %v", err)
				}
				return
			}
			var ce *ConnError
			if !errors.As(err, &ce) {
				t.Fatalf("expected a *ConnError with code %q, got %v", tt.wantCode, err)
			}
			if ce.Code != tt.wantCode {
				t.Fatalf("code = %q, want %q (%v)", ce.Code, tt.wantCode, err)
			}
			if tt.wantText != "" && !strings.Contains(ce.Message, tt.wantText) {
				t.Fatalf("message %q does not mention %q", ce.Message, tt.wantText)
			}
		})
	}
}

func TestMeasureParamsValidate(t *testing.T) {
	if err := (&MeasureParams{ConnectionID: "1", Samples: 3}).Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (&MeasureParams{Samples: 3}).Validate(); err == nil {
		t.Fatal("missing connectionId accepted")
	}
	if err := (&MeasureParams{ConnectionID: "1", Samples: 11}).Validate(); err == nil {
		t.Fatal("11 samples accepted")
	}
}

func TestIsolatedToken(t *testing.T) {
	for in, want := range map[string]struct {
		n  int
		ok bool
	}{
		"isolated-0":          {0, true},
		"isolated-42":         {42, true},
		"isolated-999999999":  {999999999, true},
		"isolated-1000000000": {0, false}, // ten digits
		"isolated-":           {0, false},
		"isolated--1":         {0, false},
		"isolated-1x":         {0, false},
		"isolated-１２":         {0, false}, // full-width digits must not be accepted
		"Isolated-1":          {0, false},
		"":                    {0, false},
		"162.159.198.1":       {0, false},
	} {
		n, ok := IsolatedToken(in)
		if ok != want.ok || (ok && n != want.n) {
			t.Errorf("IsolatedToken(%q) = %d,%v want %d,%v", in, n, ok, want.n, want.ok)
		}
	}
}

func TestParseEndpointAndRanges(t *testing.T) {
	ip, port, err := ParseEndpoint("162.159.198.2:8443")
	if err != nil || ip != netip.MustParseAddr("162.159.198.2") || port != 8443 {
		t.Fatalf("got %v %d %v", ip, port, err)
	}
	ip, port, err = ParseEndpoint("162.159.192.1")
	if err != nil || port != 0 || !InWarpRange(ip) {
		t.Fatalf("got %v %d %v", ip, port, err)
	}
	// IPv4-mapped IPv6 spelling must not sneak a non-WARP address past the range check.
	if ip, _, err := ParseEndpoint("::ffff:8.8.8.8"); err == nil && InWarpRange(ip) {
		t.Fatal("v4-mapped 8.8.8.8 treated as a WARP address")
	}
	for _, s := range []string{"162.159.192.0", "162.159.199.255", "162.159.204.9", "188.114.96.1", "188.114.99.255"} {
		if !InWarpRange(netip.MustParseAddr(s)) {
			t.Errorf("%s should be a WARP address", s)
		}
	}
	for _, s := range []string{"162.159.191.255", "162.159.200.0", "162.159.205.0", "188.114.95.255", "188.114.100.0", "1.1.1.1", "10.0.0.1"} {
		if InWarpRange(netip.MustParseAddr(s)) {
			t.Errorf("%s should not be a WARP address", s)
		}
	}
}
