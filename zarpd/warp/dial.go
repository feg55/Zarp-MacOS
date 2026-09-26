package warp

// dial.go's sequence follows usque/api.ConnectTunnel's own connectTunnelHTTP3 (MIT,
// github.com/Diniboy1123/usque/api/masque.go) with one deliberate difference: it takes an
// already-open *net.UDPConn instead of creating one with net.ListenUDP. That's the whole point —
// docs/ARCHITECTURE.md §9.2 — a strategy gets to send fake packets on that socket, bound to the
// physical interface, before this function ever touches it, so the real QUIC Initial leaves
// through the identical 5-tuple as the fakes. Phase 3 (this file) always passes a plain,
// untouched socket; phase 4 is what starts passing one a strategy has already used.

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
	"time"

	connectip "github.com/Diniboy1123/connect-ip-go"
	usqueapi "github.com/Diniboy1123/usque/api"
	usqueconfig "github.com/Diniboy1123/usque/config"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/yosida95/uritemplate/v3"
)

// These two hostnames/URLs are Cloudflare protocol constants (not usque's own design), the same
// ones usque's internal/consts.go and Android's zarpcore hardcode — reproduced here because
// they're the literal values needed to interoperate with Cloudflare's endpoint, not because
// there's any other reasonable value to pick.
const (
	connectSNI = "consumer-masque.cloudflareclient.com"
	connectURI = "https://cloudflareaccess.com"
)

// Session is one established CONNECT-IP tunnel: the packet-level handle phase 3's utun wiring
// (not yet written) will read/write against, plus everything needed to close it cleanly.
type Session struct {
	IPConn *connectip.Conn

	udpConn *net.UDPConn
	qconn   *quic.Conn
	tr      *http3.Transport
}

// Close tears the session down in reverse order, safe to call once.
func (s *Session) Close() {
	if s.IPConn != nil {
		_ = s.IPConn.Close()
	}
	if s.tr != nil {
		_ = s.tr.Close()
	}
	if s.qconn != nil {
		_ = s.qconn.CloseWithError(0, "")
	}
	if s.udpConn != nil {
		_ = s.udpConn.Close()
	}
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
// caller owns and must already be connected/usable for this endpoint — see the file doc comment.
// keepalive is the QUIC keep-alive period; connectTimeout bounds the whole handshake.
func DialH3(ctx context.Context, udpConn *net.UDPConn, endpoint *net.UDPAddr, tlsConfig *tls.Config, keepalive, connectTimeout time.Duration) (*Session, error) {
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()

	quicConfig := &quic.Config{EnableDatagrams: true, KeepAlivePeriod: keepalive}
	// Without ConnectionIDLength set, the backend occasionally throws PROTOCOL_VIOLATION —
	// confirmed independently by both usque's and Zarp-Android's dial code.
	qtr := &quic.Transport{Conn: udpConn, ConnectionIDLength: 20}
	qconn, err := qtr.Dial(ctx, endpoint, tlsConfig, quicConfig)
	if err != nil {
		_ = qtr.Close()
		return nil, wrapDialErr(err)
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
		_ = udpConn.Close()
		return nil, wrapDialErr(fmt.Errorf("connect-ip: %w", err))
	}
	if rsp.StatusCode != http.StatusOK {
		_ = ipConn.Close()
		_ = tr.Close()
		_ = qconn.CloseWithError(0, "")
		_ = udpConn.Close()
		return nil, fmt.Errorf("connect-ip: %s", rsp.Status)
	}
	return &Session{IPConn: ipConn, udpConn: udpConn, qconn: qconn, tr: tr}, nil
}

func wrapDialErr(err error) error {
	if err != nil && strings.Contains(err.Error(), "tls: access denied") {
		return errors.New("WARP rejected the device key (tls: access denied); re-register the account")
	}
	return err
}
