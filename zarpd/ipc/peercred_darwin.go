package ipc

import (
	"errors"
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// PeerCred identifies the process on the other end of a Unix socket connection, as the kernel
// recorded it when the connection was made (LOCAL_PEERCRED) — not anything the peer claims.
type PeerCred struct {
	UID  uint32
	GIDs []uint32
}

// peerCredOf reads the connecting process's credentials from the kernel.
func peerCredOf(conn net.Conn) (PeerCred, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return PeerCred{}, errors.New("not a unix socket connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return PeerCred{}, err
	}
	var cred *unix.Xucred
	var serr error
	if err := raw.Control(func(fd uintptr) {
		cred, serr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil {
		return PeerCred{}, err
	}
	if serr != nil {
		return PeerCred{}, serr
	}
	n := int(cred.Ngroups)
	if n < 0 || n > len(cred.Groups) {
		n = len(cred.Groups)
	}
	return PeerCred{UID: cred.Uid, GIDs: append([]uint32(nil), cred.Groups[:n]...)}, nil
}

// consoleUID returns the uid that owns /dev/console — the user logged in at the machine's own
// screen (macOS hands the device to whoever logs in; at the login window it belongs to root).
func consoleUID() (uint32, error) {
	fi, err := os.Stat("/dev/console")
	if err != nil {
		return 0, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("no stat info for /dev/console")
	}
	return st.Uid, nil
}

// ConsoleUserPolicy admits root and the user at the console — the account Zarp.app actually runs
// as — and nobody else. Together with the socket's group permissions this keeps other local
// accounts (another logged-in user under fast user switching, an SSH session, a service account)
// from steering a root daemon that rewrites the machine's routes.
func ConsoleUserPolicy() func(PeerCred) bool {
	return func(pc PeerCred) bool {
		if pc.UID == 0 {
			return true
		}
		console, err := consoleUID()
		if err != nil {
			return false
		}
		return pc.UID == console
	}
}
