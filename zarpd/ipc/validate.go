package ipc

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// Validation of everything a client can put in an open request. zarpd is a root process taking
// requests from user-level code (the app, but in principle any process that can reach the socket),
// so the app's own parser being careful isn't relied on: nothing below is trusted, and nothing is
// "fixed up" — a request that is out of bounds is refused, not clamped.

const (
	MaxFakeSteps   = 8
	MaxFakeRepeats = 50
	MaxTTL         = 255
	MaxPositions   = 16
	MaxPosition    = 65535
	MaxTimeoutMs   = 120_000
	MaxStrategyID  = 128
	maxIsolatedN   = 999_999_999
)

// BlobNames is the set of fake-packet blobs a client may name; the daemon maps each to a file under
// its own blobs directory (or synthesizes it), so no client-supplied path ever reaches the
// filesystem. Mirrors ZarpCore's Blob enum.
var BlobNames = map[string]bool{
	"quic_google": true,
	"quic_vk":     true,
	"tls_google":  true,
	"tls_vk":      true,
	"stun_fake":   true,
	"zero64":      true,
}

// endpointRanges are Cloudflare's published WARP endpoint ranges (IPv4) — the same ones Windows
// Zarp documents in Zapret.WarpRanges4 and ZarpCore's WarpAddressRanges lists. An endpoint override
// outside them is refused: a root process dialing arbitrary addresses on a local caller's behalf
// would be an open relay for UDP/TCP traffic bound to the physical interface.
var endpointRanges = []netip.Prefix{
	netip.MustParsePrefix("162.159.192.0/21"),
	netip.MustParsePrefix("162.159.204.0/24"),
	netip.MustParsePrefix("188.114.96.0/22"),
}

// h3Ports are the UDP ports the WARP MASQUE endpoints answer on (Windows Zarp's Warp.MasquePorts).
var h3Ports = map[int]bool{443: true, 500: true, 1701: true, 4500: true, 4443: true, 8443: true}

// InWarpRange reports whether ip is inside one of the WARP endpoint ranges.
func InWarpRange(ip netip.Addr) bool {
	ip = ip.Unmap()
	for _, p := range endpointRanges {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

// IsolatedToken parses ZarpEngine's "isolated-N" per-test uniqueness token.
func IsolatedToken(s string) (n int, ok bool) {
	rest, found := strings.CutPrefix(s, "isolated-")
	if !found || rest == "" || len(rest) > 9 {
		return 0, false
	}
	for _, r := range rest {
		if r < '0' || r > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n > maxIsolatedN {
		return 0, false
	}
	return n, true
}

// ParseEndpoint parses "ip" or "ip:port" (IPv4). port is 0 when the string had none.
func ParseEndpoint(s string) (ip netip.Addr, port int, err error) {
	if ap, perr := netip.ParseAddrPort(s); perr == nil {
		ip, port = ap.Addr(), int(ap.Port())
	} else if a, aerr := netip.ParseAddr(s); aerr == nil {
		ip = a
	} else {
		return netip.Addr{}, 0, fmt.Errorf("%q is not an IP address or ip:port", s)
	}
	ip = ip.Unmap()
	if !ip.Is4() {
		return netip.Addr{}, 0, fmt.Errorf("endpoint %s: only IPv4 endpoints are supported", ip)
	}
	return ip, port, nil
}

func badRequest(format string, args ...any) error {
	return &ConnError{Message: fmt.Sprintf(format, args...), Code: CodeBadRequest}
}

// Validate checks every field of an open request. The returned error is always a *ConnError with
// a code, ready to go back to the client as-is.
func (p *OpenParams) Validate() error {
	switch p.Transport {
	case "", "masqueH3", "masqueH2":
	case "wireGuard":
		return &ConnError{Message: "the wireGuard transport is not supported by this daemon", Code: CodeUnsupported}
	default:
		return badRequest("unknown transport %q", p.Transport)
	}
	h2 := p.Transport == "masqueH2"

	if len(p.StrategyID) > MaxStrategyID {
		return badRequest("strategyId is longer than %d bytes", MaxStrategyID)
	}
	for _, r := range p.StrategyID {
		if r < 0x20 || r == 0x7f {
			return badRequest("strategyId contains a control character")
		}
	}

	if p.TimeoutMs < 0 || p.TimeoutMs > MaxTimeoutMs {
		return badRequest("timeoutMs %d out of range 0-%d", p.TimeoutMs, MaxTimeoutMs)
	}

	if len(p.FakeSteps) > 0 && h2 {
		return badRequest("fake packets apply to the HTTP/3 (QUIC) transport only")
	}
	if len(p.FakeSteps) > MaxFakeSteps {
		return badRequest("%d fake steps (maximum %d)", len(p.FakeSteps), MaxFakeSteps)
	}
	for i, s := range p.FakeSteps {
		if !BlobNames[s.Blob] {
			return badRequest("fake step %d: unknown blob %q", i+1, s.Blob)
		}
		if s.Repeats < 1 || s.Repeats > MaxFakeRepeats {
			return badRequest("fake step %d: repeats %d out of range 1-%d", i+1, s.Repeats, MaxFakeRepeats)
		}
		if s.IPTTL != nil && (*s.IPTTL < 1 || *s.IPTTL > MaxTTL) {
			return badRequest("fake step %d: ipTTL %d out of range 1-%d", i+1, *s.IPTTL, MaxTTL)
		}
		if s.IP6TTL != nil && (*s.IP6TTL < 1 || *s.IP6TTL > MaxTTL) {
			return badRequest("fake step %d: ip6TTL %d out of range 1-%d", i+1, *s.IP6TTL, MaxTTL)
		}
	}

	if p.TCPDesync != nil {
		if !h2 {
			return badRequest("TCP segmentation applies to the HTTP/2 transport only")
		}
		switch p.TCPDesync.Mode {
		case "split", "disorder":
		default:
			return badRequest("tcpDesync mode %q is not split or disorder", p.TCPDesync.Mode)
		}
		if n := len(p.TCPDesync.Positions); n < 1 || n > MaxPositions {
			return badRequest("tcpDesync needs 1-%d positions, got %d", MaxPositions, n)
		}
		for _, pos := range p.TCPDesync.Positions {
			if err := validatePosition(pos); err != nil {
				return badRequest("tcpDesync: %v", err)
			}
		}
	}

	if err := p.validateEndpoint(h2); err != nil {
		return err
	}

	if p.RouteAll && !p.Persistent {
		return badRequest("routeAll is only allowed on a persistent connection")
	}
	if p.OverrideDNS && !p.RouteAll {
		return badRequest("overrideDNS requires routeAll")
	}
	return nil
}

func (p *OpenParams) validateEndpoint(h2 bool) error {
	if p.Endpoint == "" {
		return nil
	}
	if _, ok := IsolatedToken(p.Endpoint); ok {
		return nil
	}
	ip, port, err := ParseEndpoint(p.Endpoint)
	if err != nil {
		return badRequest("endpoint: %v", err)
	}
	if !InWarpRange(ip) {
		return badRequest("endpoint %s is outside Cloudflare's WARP address ranges", ip)
	}
	if port != 0 {
		ok := h3Ports[port]
		if h2 {
			ok = port == 443
		}
		if !ok {
			return badRequest("endpoint port %d is not one the WARP endpoints use for this transport", port)
		}
	}
	return nil
}

func validatePosition(pos string) error {
	switch pos {
	case "host", "endhost", "sld", "midsld":
		return nil
	}
	n, err := strconv.Atoi(pos)
	if err != nil {
		return fmt.Errorf("bad position %q", pos)
	}
	if n < -MaxPosition || n > MaxPosition {
		return fmt.Errorf("position %d out of range", n)
	}
	return nil
}

// Validate checks a measure request.
func (p *MeasureParams) Validate() error {
	if p.ConnectionID == "" {
		return badRequest("connectionId is required")
	}
	if p.Samples < 0 || p.Samples > 10 {
		return badRequest("samples %d out of range 0-10", p.Samples)
	}
	return nil
}
