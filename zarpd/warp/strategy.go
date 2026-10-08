package warp

// The DPI strategy executor: sends fake packets on the UDP socket before the real MASQUE dial
// reuses it (docs/ARCHITECTURE.md §9.2). The algorithm itself — for each step, optionally lower
// TTL, send the blob N times, restore TTL — is the same one Zarp-Android's FakeStrategy.kt
// implements, reimplemented directly against Go's syscall package rather than adapted from it
// (it has no Android-specific concept in it to begin with).

import (
	"errors"
	"fmt"
	"net"
)

// Bounds enforced on every strategy, whichever way it reached this package. The Swift parser
// already caps repeats at 50 (StrategyArgsParser.maxRepeats); enforcing the same limits here means
// a malformed or hostile IPC request can't make a root process flood an address, whatever the
// client claims.
const (
	MaxFakeSteps   = 8
	MaxFakeRepeats = 50
	MaxFakeTTL     = 255
)

// FakeStep is one `fake:blob=B:repeats=N[:ip_ttl=N]` step from a strategy's DesyncPlan
// (ZarpCore's parsed representation, mirrored here rather than imported — zarpd is a separate
// Go module from the Swift ZarpCore package; the IPC layer, docs/ARCHITECTURE.md §9.4, is what
// translates one into the other).
type FakeStep struct {
	Blob    []byte
	Repeats int
	TTL     int // 0 means "don't change it"
}

// ValidateFakeSteps rejects step lists SendFakes must never be asked to run.
func ValidateFakeSteps(steps []FakeStep) error {
	if len(steps) > MaxFakeSteps {
		return fmt.Errorf("%d fake steps (maximum %d)", len(steps), MaxFakeSteps)
	}
	for i, s := range steps {
		if s.Repeats < 1 || s.Repeats > MaxFakeRepeats {
			return fmt.Errorf("fake step %d: repeats %d out of range 1-%d", i+1, s.Repeats, MaxFakeRepeats)
		}
		if s.TTL < 0 || s.TTL > MaxFakeTTL {
			return fmt.Errorf("fake step %d: ttl %d out of range 0-%d", i+1, s.TTL, MaxFakeTTL)
		}
		if len(s.Blob) == 0 {
			return fmt.Errorf("fake step %d: empty blob", i+1)
		}
	}
	return nil
}

// SendFakes writes each step's blob through conn, addressed at endpoint, in order. Must be
// called before conn is handed to DialH3 — that's what makes the fakes and the real QUIC Initial
// share one 5-tuple, the entire point of the exercise. onSent, if non-nil, is called synchronously
// right after each individual packet leaves (stepIndex/packetIndex are both 0-based), so a caller
// can make the fake/real ordering explicit in its own log rather than this function guessing what
// level of detail matters to it.
//
// The socket's TTL is always restored to its original value before returning, including on every
// error path.
func SendFakes(conn *net.UDPConn, endpoint *net.UDPAddr, steps []FakeStep, onSent func(stepIndex, packetIndex int, n int)) (packets, bytes int, err error) {
	if err := ValidateFakeSteps(steps); err != nil {
		return 0, 0, err
	}
	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return 0, 0, errors.New("SendFakes: connection has no UDP local address")
	}
	v6 := local.IP.To4() == nil
	for si, step := range steps {
		var normal int
		lowered := false
		if step.TTL > 0 {
			normal, err = getTTL(conn, v6)
			if err != nil {
				return packets, bytes, err
			}
			if err = setTTL(conn, v6, step.TTL); err != nil {
				return packets, bytes, err
			}
			lowered = true
		}
		for i := 0; i < step.Repeats; i++ {
			n, werr := conn.WriteToUDP(step.Blob, endpoint)
			if werr != nil {
				if lowered {
					_ = setTTL(conn, v6, normal)
				}
				return packets, bytes, werr
			}
			packets++
			bytes += n
			if onSent != nil {
				onSent(si, i, n)
			}
		}
		if lowered {
			if err = setTTL(conn, v6, normal); err != nil {
				return packets, bytes, err
			}
		}
	}
	return packets, bytes, nil
}
