package warp

// Transport-agnostic IP_TTL/IPV6_UNICAST_HOPS sockopt access, shared by strategy.go (UDP fakes)
// and desync.go (TCP ClientHello disorder) — both need to lower TTL for exactly one write and
// restore it, just on different socket types. `syscall.Conn` is what *net.UDPConn and *net.TCPConn
// both implement, so one implementation covers both instead of duplicating it per transport.

import (
	"syscall"

	"golang.org/x/sys/unix"
)

func getTTL(conn syscall.Conn, v6 bool) (int, error) {
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

func setTTL(conn syscall.Conn, v6 bool, ttl int) error {
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
