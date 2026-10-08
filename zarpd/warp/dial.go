package warp

// dial.go's sequence follows usque/api.ConnectTunnel's own connectTunnelHTTP3 (MIT,
// github.com/Diniboy1123/usque/api/masque.go) with one deliberate difference: it takes an
// already-open *net.UDPConn instead of creating one with net.ListenUDP. That's the whole point —
// docs/ARCHITECTURE.md §9.2 — a strategy gets to send fake packets on that socket, bound to the
// physical interface, before this function ever touches it, so the real QUIC Initial leaves
// through the identical 5-tuple as the fakes.

import (
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	connectip "github.com/Diniboy1123/connect-ip-go"
	usqueapi "github.com/Diniboy1123/usque/api"
	usqueconfig "github.com/Diniboy1123/usque/config"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/yosida95/uritemplate/v3"
	"golang.org/x/net/http2"
)

// These two hostnames/URLs are Cloudflare protocol constants (not usque's own design), the same
// ones usque's internal/consts.go and Android's zarpcore hardcode — reproduced here because
// they're the literal values needed to interoperate with Cloudflare's endpoint, not because
// there's any other reasonable value to pick.
const (
	connectSNI = "consumer-masque.cloudflareclient.com"
	connectURI = "https://cloudflareaccess.com"

	// DefaultConnectTimeout is used when a caller passes a non-positive connectTimeout — a zero
	// timeout would otherwise abort the dial before it starts.
	DefaultConnectTimeout = 15 * time.Second
)

// Session is one established CONNECT-IP tunnel: the packet-level handle the utun wiring
// (zarpd/tunnel) reads/writes against, plus everything needed to close it cleanly.
type Session struct {
	IPConn *connectip.Conn

	// closers run in order by Close. Built by the Dial* function that produced the session, so
	// each transport tears down exactly the resources it created — including the ones the
	// underlying libraries deliberately leave to their caller (quic-go's Transport never closes a
	// net.PacketConn it was handed; http2.Transport.CloseIdleConnections skips a connection that
	// still has a stream open).
	closers   []func()
	closeOnce sync.Once
}

// Close tears the session down. Safe to call any number of times, from any goroutine.
func (s *Session) Close() {
	s.closeOnce.Do(func() {
		for _, fn := range s.closers {
			fn()
		}
	})
}

// TLSConfigFromAccount builds the TLS config for the MASQUE handshake from a registered account:
// the device's own key pair (client auth) plus pinning the endpoint's public key (see
// api.PrepareTlsConfig's doc comment — the server's certificate itself isn't meaningfully
// verifiable, so pinning the enrolled key is what actually authenticates the peer).
func TLSConfigFromAccount(cfg *usqueconfig.Config) (*tls.Config, error) {
	privDER, err := base64.StdEncoding.DecodeString(cfg.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("private key: %w", err)
	}
	privKey, err := x509.ParseECPrivateKey(privDER)
	if err != nil {
		return nil, fmt.Errorf("private key: %w", err)
	}
	block, _ := pem.Decode([]byte(cfg.EndpointPubKey))
	if block == nil {
		return nil, errors.New("endpoint public key: bad PEM")
	}
	pk, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("endpoint public key: %w", err)
	}
	peerPub, ok := pk.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("endpoint public key is not ECDSA")
	}
	cert, err := generateSelfSignedCert(privKey)
	if err != nil {
		return nil, err
	}
	return usqueapi.PrepareTlsConfig(privKey, peerPub, cert, connectSNI, false)
}

// DialH3 performs the MASQUE-over-HTTP/3 handshake and CONNECT-IP request on udpConn, which the
// caller must already have bound/prepared for this endpoint — see the file doc comment.
// keepalive is the QUIC keep-alive period; connectTimeout bounds the whole handshake.
//
// Ownership of udpConn transfers to DialH3: on success the returned Session closes it, and on
// *every* failure path DialH3 has already closed it, so callers must not close it themselves
// after an error. (quic-go's Transport.Close deliberately leaves a caller-supplied connection
// open, which is why this has to be spelled out and done explicitly here — a failed dial is the
// normal outcome while scanning for a strategy that gets past DPI, and each one used to leak a
// socket in a long-running root daemon.)
func DialH3(ctx context.Context, udpConn *net.UDPConn, endpoint *net.UDPAddr, tlsConfig *tls.Config, keepalive, connectTimeout time.Duration) (*Session, error) {
	if connectTimeout <= 0 {
		connectTimeout = DefaultConnectTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()

	quicConfig := &quic.Config{EnableDatagrams: true, KeepAlivePeriod: keepalive}
	// Without ConnectionIDLength set, the backend occasionally throws PROTOCOL_VIOLATION —
	// confirmed independently by both usque's and Zarp-Android's dial code.
	qtr := &quic.Transport{Conn: udpConn, ConnectionIDLength: 20}
	fail := func(err error) (*Session, error) {
		_ = qtr.Close()
		_ = udpConn.Close()
		return nil, err
	}

	qconn, err := qtr.Dial(ctx, endpoint, tlsConfig, quicConfig)
	if err != nil {
		return fail(wrapDialErr(err))
	}

	tr := &http3.Transport{
		EnableDatagrams: true,
		AdditionalSettings: map[uint64]uint64{
			0x276: 1, // SETTINGS_H3_DATAGRAM_00 — the official client still sends this too
		},
		DisableCompression: true,
	}
	hconn := tr.NewClientConn(qconn)
	template := uritemplate.MustNew(connectURI)
	headers := http.Header{"User-Agent": []string{""}}

	stop := context.AfterFunc(ctx, func() { _ = qconn.CloseWithError(0, "connect timeout") })
	ipConn, rsp, err := connectip.Dial(ctx, hconn, template, "cf-connect-ip", headers, true)
	stop()
	if err != nil {
		_ = tr.Close()
		_ = qconn.CloseWithError(0, "")
		return fail(wrapDialErr(fmt.Errorf("connect-ip: %w", err)))
	}
	if rsp.StatusCode != http.StatusOK {
		_ = ipConn.Close()
		_ = tr.Close()
		_ = qconn.CloseWithError(0, "")
		return fail(fmt.Errorf("connect-ip: %s", rsp.Status))
	}

	return &Session{
		IPConn: ipConn,
		closers: []func(){
			func() { _ = ipConn.Close() },
			func() { _ = tr.Close() },
			func() { _ = qconn.CloseWithError(0, "") },
			// The transport must be closed too (it owns the read/send goroutines), and only then
			// the socket it was borrowing — quic-go never closes a connection it didn't create.
			func() { _ = qtr.Close() },
			func() { _ = udpConn.Close() },
		},
	}, nil
}

// DialH2 performs the MASQUE-over-HTTP/2 handshake and CONNECT-IP request, for networks (or DPI)
// that block QUIC/UDP outright — the fallback transport, same role as Android's dialH2. dialer's
// Control (if set) is what keeps this TCP connection on the physical interface, the same job
// BindUDP does for DialH3's socket — see route.Physical.Control. desync, if non-nil, splits the
// TLS ClientHello per spec (desync.go); pass nil to dial plainly.
//
// Unlike DialH3 (where the QUIC connection is a separate object quic-go manages, independent of
// any Go context), HTTP/2's CONNECT-IP stream lives exactly as long as the context its request
// was made with — so two contexts are taken, deliberately separate:
//
//   - sessionCtx is the *session's* lifetime (daemon-scoped, not deadline-bound). Cancelling it
//     later ends the tunnel.
//   - dialCtx only governs the dial itself. If it ends first (the requesting client went away),
//     the dial is aborted; the wiring is severed the instant the dial returns, so a dialCtx that
//     ends *after* success (the short-lived IPC request finishing) never touches the session.
//
// connectTimeout also only bounds the dial.
func DialH2(sessionCtx, dialCtx context.Context, dialer *net.Dialer, endpoint *net.TCPAddr, tlsConfig *tls.Config, desync *DesyncSpec, connectTimeout time.Duration) (*Session, error) {
	if connectTimeout <= 0 {
		connectTimeout = DefaultConnectTimeout
	}
	reqCtx, reqCancel := context.WithCancel(sessionCtx)
	var timedOut atomic.Bool
	timer := time.AfterFunc(connectTimeout, func() {
		timedOut.Store(true)
		reqCancel()
	})
	stopDialWatch := context.AfterFunc(dialCtx, reqCancel)

	h2TLSConfig := tlsConfig.Clone()
	h2TLSConfig.NextProtos = []string{"h2"}

	// The TLS connection the transport dials. Captured so Close can shut it down directly:
	// http2.Transport.CloseIdleConnections leaves a connection alone while a stream (here, the
	// CONNECT-IP one) is still open, so relying on it would leak the TCP connection.
	var connMu sync.Mutex
	var dialed net.Conn

	transport := &http2.Transport{
		DialTLSContext: func(ctx context.Context, network, _ string, _ *tls.Config) (net.Conn, error) {
			raw, err := dialer.DialContext(ctx, network, endpoint.String())
			if err != nil {
				return nil, err
			}
			tcpConn, ok := raw.(*net.TCPConn)
			if !ok {
				_ = raw.Close()
				return nil, fmt.Errorf("dialed connection is %T, not *net.TCPConn", raw)
			}
			var conn net.Conn = tcpConn
			if desync != nil {
				conn = NewDesyncConn(tcpConn, desync, h2TLSConfig.ServerName)
			}
			tlsConn := tls.Client(conn, h2TLSConfig)
			if err := tlsConn.HandshakeContext(ctx); err != nil {
				_ = raw.Close()
				return nil, err
			}
			connMu.Lock()
			dialed = tlsConn
			connMu.Unlock()
			return tlsConn, nil
		},
	}
	closeDialed := func() {
		connMu.Lock()
		c := dialed
		connMu.Unlock()
		if c != nil {
			_ = c.Close()
		}
	}
	client := &http.Client{Transport: transport}
	headers := http.Header{"User-Agent": []string{""}}
	headers.Set("cf-connect-proto", "cf-connect-ip")
	headers.Set("pq-enabled", "false") // TODO: post-quantum, once PQC is verified to work over H2 here
	template := uritemplate.MustNew(connectURI)

	fail := func(err error) (*Session, error) {
		reqCancel()
		transport.CloseIdleConnections()
		closeDialed()
		return nil, err
	}

	ipConn, rsp, err := connectip.DialH2(reqCtx, client, template, headers)
	timerStopped := timer.Stop()
	dialWatchStopped := stopDialWatch()
	if err != nil {
		switch {
		case timedOut.Load():
			// Our own connectTimeout gave up, not the caller's context.
			err = fmt.Errorf("timeout after %s: %w", connectTimeout, err)
		case dialCtx.Err() != nil:
			err = fmt.Errorf("%w (%v)", dialCtx.Err(), err)
		}
		return fail(wrapDialErr(fmt.Errorf("connect-ip over HTTP/2: %w", err)))
	}
	if !timerStopped || !dialWatchStopped {
		// The timeout/cancellation raced the successful return and already cancelled the context
		// the CONNECT-IP stream lives on: what came back is a session that is already dead.
		_ = ipConn.Close()
		cause := context.Canceled
		if timedOut.Load() {
			cause = context.DeadlineExceeded
		}
		return fail(fmt.Errorf("connect-ip over HTTP/2: dial finished at the moment it was cancelled: %w", cause))
	}
	if rsp.StatusCode != http.StatusOK {
		_ = ipConn.Close()
		return fail(fmt.Errorf("connect-ip over HTTP/2: %s", rsp.Status))
	}
	return &Session{
		IPConn: ipConn,
		closers: []func(){
			reqCancel, // resets the CONNECT-IP stream
			func() { _ = ipConn.Close() },
			transport.CloseIdleConnections,
			closeDialed,
		},
	}, nil
}

func wrapDialErr(err error) error {
	if err != nil && strings.Contains(err.Error(), "tls: access denied") {
		return errors.New("WARP rejected the device key (tls: access denied); re-register the account")
	}
	return err
}
