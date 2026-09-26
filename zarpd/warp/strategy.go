package warp

// The DPI strategy executor: sends fake packets on the UDP socket before the real MASQUE dial
// reuses it (docs/ARCHITECTURE.md §9.2). The algorithm itself — for each step, optionally lower
// TTL, send the blob N times, restore TTL — is the same one Zarp-Android's FakeStrategy.kt
// implements, reimplemented directly against Go's syscall package rather than adapted from it
// (it has no Android-specific concept in it to begin with).

import (
	"net"

	"golang.org/x/sys/unix"
)

// FakeStep is one `fake:blob=B:repeats=N[:ip_ttl=N]` step from a strategy's DesyncPlan
// (ZarpCore's parsed representation, mirrored here rather than imported — zarpd is a separate
// Go module from the Swift ZarpCore package; the IPC layer, docs/ARCHITECTURE.md §9.4, is what
// will eventually translate one into the other).
type FakeStep struct {
	Blob    []byte
	Repeats int
	TTL     int // 0 means "don't change it"
}

// SendFakes writes each step's blob through conn, addressed at endpoint, in order. Must be
// called before conn is handed to DialH3 — that's what makes the fakes and the real QUIC Initial
// share one 5-tuple, the entire point of the exercise. onSent, if non-nil, is called synchronously
// right after each individual packet leaves (stepIndex/packetIndex are both 0-based), so a caller
// can make the fake/real ordering explicit in its own log rather than this function guessing what
// level of detail matters to it.
func SendFakes(conn *net.UDPConn, endpoint *net.UDPAddr, steps []FakeStep, onSent func(stepIndex, packetIndex int, n int)) (packets, bytes int, err error) {
	for si, step := range steps {
		var normal int
		lowered := false
		if step.TTL > 0 {
			normal, err = getTTL(conn)
			if err != nil {
				return packets, bytes, err
			}
			if err = setTTL(conn, step.TTL); err != nil {
				return packets, bytes, err
			}
			lowered = true
		}
		for i := 0; i < step.Repeats; i++ {
			n, werr := conn.WriteToUDP(step.Blob, endpoint)
			if werr != nil {
				if lowered {
					_ = setTTL(conn, normal)
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
			if err = setTTL(conn, normal); err != nil {
				return packets, bytes, err
			}
		}
	}
	return packets, bytes, nil
}

func getTTL(conn *net.UDPConn) (int, error) {
	v6 := conn.LocalAddr().(*net.UDPAddr).IP.To4() == nil
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var ttl int
	var serr error
	cerr := raw.Control(func(fd uintptr) {
		if v6 {
			ttl, serr = unix.GetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_UNICAST_HOPS)
		} else {
			ttl, serr = unix.GetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_TTL)
		}
	})
	if cerr != nil {
		return 0, cerr
	}
	return ttl, serr
}

func setTTL(conn *net.UDPConn, ttl int) error {
	v6 := conn.LocalAddr().(*net.UDPAddr).IP.To4() == nil
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var serr error
	cerr := raw.Control(func(fd uintptr) {
		if v6 {
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_UNICAST_HOPS, ttl)
		} else {
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_TTL, ttl)
		}
	})
	if cerr != nil {
		return cerr
	}
	return serr
}
