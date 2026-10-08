package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"

	usqueconfig "github.com/Diniboy1123/usque/config"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

func TestIsolatedEndpointRotation(t *testing.T) {
	// Windows Zarp's Warp.NextEndpoint, value for value: addresses vary fastest, then ports.
	want := []string{
		"162.159.198.1:443", "162.159.198.2:443",
		"162.159.198.1:500", "162.159.198.2:500",
		"162.159.198.1:1701", "162.159.198.2:1701",
		"162.159.198.1:4500", "162.159.198.2:4500",
		"162.159.198.1:4443", "162.159.198.2:4443",
		"162.159.198.1:8443", "162.159.198.2:8443",
		"162.159.198.1:443", // the pool wraps after 12
	}
	for n, w := range want {
		if got := isolatedEndpoint(n, false).String(); got != w {
			t.Errorf("H3 endpoint #%d = %s, want %s", n, got, w)
		}
	}
	// HTTP/2 only has TCP 443: only the address rotates.
	for n, w := range []string{"162.159.198.1:443", "162.159.198.2:443", "162.159.198.1:443", "162.159.198.2:443"} {
		if got := isolatedEndpoint(n, true).String(); got != w {
			t.Errorf("H2 endpoint #%d = %s, want %s", n, got, w)
		}
	}
}

func TestConsecutiveTestsAlwaysUseDifferentEndpoints(t *testing.T) {
	// The point of "isolate tests": a test and the re-check right after it must not share a
	// 5-tuple. ZarpEngine numbers its tokens consecutively.
	for _, h2 := range []bool{false, true} {
		for n := 0; n < 40; n++ {
			if isolatedEndpoint(n, h2) == isolatedEndpoint(n+1, h2) {
				t.Fatalf("h2=%v: endpoints #%d and #%d are identical", h2, n, n+1)
			}
		}
	}
}

func TestEveryPoolEndpointPassesTheDaemonsOwnValidation(t *testing.T) {
	// The pool must never produce an address the same daemon would refuse if a client asked for it.
	for _, h2 := range []bool{false, true} {
		transport := "masqueH3"
		if h2 {
			transport = "masqueH2"
		}
		for n := 0; n < 30; n++ {
			ep := isolatedEndpoint(n, h2).String()
			p := ipc.OpenParams{Transport: transport, Endpoint: ep}
			if err := p.Validate(); err != nil {
				t.Errorf("pool endpoint %s (#%d, %s) fails validation: %v", ep, n, transport, err)
			}
		}
	}
}

func TestResolveEndpoint(t *testing.T) {
	cfg := &usqueconfig.Config{EndpointV4: "162.159.198.7", EndpointH2V4: "162.159.198.2"}
	tests := []struct {
		name string
		p    ipc.OpenParams
		want string
	}{
		{"account default, H3", ipc.OpenParams{Transport: "masqueH3"}, "162.159.198.7:443"},
		{"account default, H2 uses the H2 endpoint", ipc.OpenParams{Transport: "masqueH2"}, "162.159.198.2:443"},
		{"isolation token, H3", ipc.OpenParams{Transport: "masqueH3", Endpoint: "isolated-3"}, "162.159.198.2:500"},
		{"isolation token, H2", ipc.OpenParams{Transport: "masqueH2", Endpoint: "isolated-3"}, "162.159.198.2:443"},
		{"explicit ip", ipc.OpenParams{Transport: "masqueH3", Endpoint: "162.159.192.5"}, "162.159.192.5:443"},
		{"explicit ip:port", ipc.OpenParams{Transport: "masqueH3", Endpoint: "162.159.192.5:4500"}, "162.159.192.5:4500"},
	}
	for _, tt := range tests {
		got, err := resolveEndpoint(tt.p, cfg)
		if err != nil || got.String() != tt.want {
			t.Errorf("%s: got %v, %v want %s", tt.name, got, err, tt.want)
		}
	}
	if _, err := resolveEndpoint(ipc.OpenParams{Transport: "masqueH3"}, &usqueconfig.Config{EndpointV4: "not-an-ip"}); err == nil {
		t.Error("a corrupt account endpoint must be an error, not a zero address")
	}
}

type timeoutNetErr struct{}

func (timeoutNetErr) Error() string   { return "i/o timeout" }
func (timeoutNetErr) Timeout() bool   { return true }
func (timeoutNetErr) Temporary() bool { return true }

var _ net.Error = timeoutNetErr{}

func TestDialErrToConnError(t *testing.T) {
	timedOut := []error{
		context.DeadlineExceeded,
		fmt.Errorf("wrapped: %w", context.DeadlineExceeded),
		timeoutNetErr{},
		errors.New("DialH3: connect-ip: failed to read response: http3: connect timeout"),
		errors.New("timeout after 15s: context canceled"),
		errors.New("context deadline exceeded"),
	}
	for _, e := range timedOut {
		ce := dialErrToConnError(e).(*ipc.ConnError)
		if !ce.TimedOut {
			t.Errorf("%v should count as a timeout", e)
		}
	}
	for _, e := range []error{errors.New("connection refused"), errors.New("tls: access denied"), context.Canceled} {
		ce := dialErrToConnError(e).(*ipc.ConnError)
		if ce.TimedOut || !strings.Contains(ce.Message, e.Error()) {
			t.Errorf("%v: %+v", e, ce)
		}
	}
}
