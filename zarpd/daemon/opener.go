package daemon

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/feg55/zarp-macos/zarpd/ipc"
	"github.com/feg55/zarp-macos/zarpd/route"
	"github.com/feg55/zarp-macos/zarpd/tunnel"
	"github.com/feg55/zarp-macos/zarpd/warp"
)

// blobFiles mirrors ZarpCore's Blob.fileName (Blob.swift) exactly — kept as data here rather than
// shared code because zarpd (Go) and ZarpCore (Swift) are separate modules/languages; the IPC
// layer is the seam, not a shared struct (docs/ARCHITECTURE.md §5). The names a client may use
// are validated against ipc.BlobNames before they ever reach this map.
var blobFiles = map[string]string{
	"quic_google": "quic_initial_www_google_com.bin",
	"quic_vk":     "quic_initial_vk_com.bin",
	"tls_google":  "tls_clienthello_www_google_com.bin",
	"tls_vk":      "tls_clienthello_vk_com.bin",
	"stun_fake":   "stun.bin",
	// "zero64" has no file — 64 zero bytes, synthesized in loadBlob.
}

// RealOpener is the Opener that touches the system: it dials WARP (HTTP/3 or HTTP/2, with the
// strategy's fake packets or ClientHello split applied), creates a utun, assigns its addresses,
// installs routes — a single measurement host route for a scan, the full-tunnel set for a
// persistent connection — and pumps packets.
type RealOpener struct {
	ConfigPath  string
	BlobsDir    string
	MeasureHost string
	MTU         int

	Router *route.Router
	DNS    *route.DNSOverride // may be nil: then the DNS override is skipped with a warning
	// Journal records the endpoint exclusion route a full tunnel installs, so a crash can't leave it
	// behind (route/exclusion.go). May be nil.
	Journal *route.Journal

	// Lifetime is the daemon's own context. An HTTP/2 tunnel's CONNECT-IP stream lives exactly as
	// long as the context it was dialed with, so it must be this — not the short-lived IPC request
	// that asked for the connection.
	Lifetime context.Context

	Logf func(format string, args ...any)
}

func (o *RealOpener) logf(format string, args ...any) {
	if o.Logf != nil {
		o.Logf(format, args...)
	}
}

// Open implements Opener.
func (o *RealOpener) Open(ctx context.Context, p ipc.OpenParams) (Conn, OpenInfo, error) {
	cfg, err := warp.LoadConfig(o.ConfigPath)
	if err != nil {
		return nil, OpenInfo{}, err
	}
	// Validate what we'll hand to ifconfig before anything is created.
	ipv4, err := netip.ParseAddr(cfg.IPv4)
	if err != nil || !ipv4.Is4() {
		return nil, OpenInfo{}, fmt.Errorf("the account's IPv4 tunnel address %q is invalid", cfg.IPv4)
	}
	ipv6 := ""
	if cfg.IPv6 != "" {
		if a, err := netip.ParseAddr(cfg.IPv6); err == nil && a.Is6() {
			ipv6 = a.String()
		}
	}

	phys, err := o.Router.CurrentDefault()
	if err != nil {
		return nil, OpenInfo{}, err
	}
	if phys.IsTunnel() {
		if p.RouteAll {
			return nil, OpenInfo{}, &ipc.ConnError{
				Code:    ipc.CodeForeignVPN,
				Message: fmt.Sprintf("another VPN or proxy is active (the default route is on %s): turn it off, then connect again", phys.Interface),
			}
		}
		o.logf("warning: the default route is on %s (another VPN?) — the WARP connection will ride through it", phys.Interface)
	}

	tlsConfig, err := warp.TLSConfigFromAccount(cfg)
	if err != nil {
		return nil, OpenInfo{}, err
	}
	endpoint, err := resolveEndpoint(p, cfg)
	if err != nil {
		return nil, OpenInfo{}, &ipc.ConnError{Code: ipc.CodeBadRequest, Message: err.Error()}
	}
	timeout := time.Duration(p.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = warp.DefaultConnectTimeout
	}

	start := time.Now()
	var session *warp.Session
	if p.Transport == "masqueH2" {
		session, err = o.dialH2(ctx, phys, tlsConfig, p, endpoint, timeout)
	} else {
		session, err = o.dialH3(ctx, phys, tlsConfig, p, endpoint, timeout)
	}
	if err != nil {
		return nil, OpenInfo{}, dialErrToConnError(err)
	}
	connectMs := int(time.Since(start).Milliseconds())

	// From here on every failure must tear down what's been built so far: conn.Close does exactly
	// that and is safe at any stage.
	dev, err := tun.CreateTUN("utun", o.MTU)
	if err != nil {
		session.Close()
		return nil, OpenInfo{}, err
	}
	name, err := dev.Name()
	if err != nil {
		_ = dev.Close()
		session.Close()
		return nil, OpenInfo{}, err
	}
	conn := &realConn{
		name: name, dev: dev, session: session, router: o.Router, measureHost: o.MeasureHost,
		logf: o.logf, done: make(chan struct{}),
	}
	fail := func(err error) (Conn, OpenInfo, error) {
		conn.Close()
		return nil, OpenInfo{}, err
	}

	if err := o.Router.ConfigureAddress(name, ipv4.String()); err != nil {
		return fail(err)
	}
	info := OpenInfo{Endpoint: endpoint.String(), UtunName: name, ConnectMs: connectMs}
	if p.RouteAll {
		ft, warnings, err := o.Router.EnableFullTunnel(route.FullTunnelConfig{
			Utun: name, IPv6Addr: ipv6, OverrideDNS: p.OverrideDNS, Physical: phys,
			Exclude: endpoint.Addr(), Journal: o.Journal,
		}, o.DNS)
		if err != nil {
			return fail(err)
		}
		conn.full = ft
		info.RouteAll = true
		info.Warnings = warnings
	} else {
		if err := o.Router.AddHostRoute(o.MeasureHost, name); err != nil {
			return fail(err)
		}
		conn.hostRoute = true
	}

	pump := tunnel.New(dev, session, o.MTU)
	go func() { conn.finish(pump.Run()) }()
	return conn, info, nil
}

func (o *RealOpener) dialH3(ctx context.Context, phys *route.Physical, tlsConfig *tls.Config, p ipc.OpenParams, endpoint netip.AddrPort, timeout time.Duration) (*warp.Session, error) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	// The socket is ours until DialH3 takes it over (and closes it itself on failure).
	if err := phys.BindUDP(udpConn); err != nil {
		_ = udpConn.Close()
		return nil, fmt.Errorf("BindUDP: %w", err)
	}
	dst := net.UDPAddrFromAddrPort(endpoint)

	if len(p.FakeSteps) > 0 {
		steps, err := o.toFakeSteps(p.FakeSteps)
		if err != nil {
			_ = udpConn.Close()
			return nil, err
		}
		if _, _, err := warp.SendFakes(udpConn, dst, steps, nil); err != nil {
			_ = udpConn.Close()
			return nil, fmt.Errorf("SendFakes: %w", err)
		}
	}
	return warp.DialH3(ctx, udpConn, dst, tlsConfig, 30*time.Second, timeout)
}

func (o *RealOpener) dialH2(ctx context.Context, phys *route.Physical, tlsConfig *tls.Config, p ipc.OpenParams, endpoint netip.AddrPort, timeout time.Duration) (*warp.Session, error) {
	var desync *warp.DesyncSpec
	if p.TCPDesync != nil {
		desync = &warp.DesyncSpec{Pos: p.TCPDesync.Positions}
		switch p.TCPDesync.Mode {
		case "disorder":
			desync.Mode = warp.DesyncDisorder
		default:
			desync.Mode = warp.DesyncSplit
		}
	}
	dialer := &net.Dialer{Control: phys.Control}
	return warp.DialH2(o.Lifetime, ctx, dialer, net.TCPAddrFromAddrPort(endpoint), tlsConfig, desync, timeout)
}

func (o *RealOpener) loadBlob(name string) ([]byte, error) {
	if name == "zero64" {
		return make([]byte, 64), nil
	}
	file, ok := blobFiles[name]
	if !ok {
		return nil, fmt.Errorf("unknown blob %q", name)
	}
	return os.ReadFile(filepath.Join(o.BlobsDir, file))
}

func (o *RealOpener) toFakeSteps(in []ipc.FakeStep) ([]warp.FakeStep, error) {
	out := make([]warp.FakeStep, 0, len(in))
	for _, step := range in {
		blob, err := o.loadBlob(step.Blob)
		if err != nil {
			return nil, err
		}
		ttl := 0
		if step.IPTTL != nil {
			ttl = *step.IPTTL
		}
		out = append(out, warp.FakeStep{Blob: blob, Repeats: step.Repeats, TTL: ttl})
	}
	return out, nil
}

// dialErrToConnError classifies a dial failure for the app: a timeout (the signature of DPI
// dropping the handshake, and what the scan loop reports as "no connection within N s") is
// distinguished from every other failure.
func dialErrToConnError(err error) error {
	var ne net.Error
	timedOut := errors.Is(err, context.DeadlineExceeded) ||
		(errors.As(err, &ne) && ne.Timeout()) ||
		strings.Contains(err.Error(), "timeout") ||
		strings.Contains(err.Error(), "deadline exceeded")
	return &ipc.ConnError{Message: err.Error(), TimedOut: timedOut}
}

// realConn is one live tunnel on the real system.
type realConn struct {
	name        string
	dev         tun.Device
	session     *warp.Session
	router      *route.Router
	measureHost string
	hostRoute   bool
	full        *route.FullTunnel
	logf        func(string, ...any)

	done       chan struct{}
	finishOnce sync.Once
	errMu      sync.Mutex
	err        error

	closeOnce sync.Once
}

func (c *realConn) Name() string          { return c.name }
func (c *realConn) Done() <-chan struct{} { return c.done }

func (c *realConn) Err() error {
	c.errMu.Lock()
	defer c.errMu.Unlock()
	return c.err
}

// finish records why the data plane stopped and signals Done. Called once, by the pump goroutine.
func (c *realConn) finish(err error) {
	c.finishOnce.Do(func() {
		c.errMu.Lock()
		c.err = err
		c.errMu.Unlock()
		close(c.done)
	})
}

// Close tears the tunnel down, outermost first: routes and DNS go back to normal *before* the
// interface and session disappear, so traffic is released to the ordinary path the moment teardown
// starts instead of being black-holed into a half-closed tunnel.
func (c *realConn) Close() {
	c.closeOnce.Do(func() {
		if c.full != nil {
			for _, err := range c.full.Disable() {
				c.logf("teardown %s: %v", c.name, err)
			}
		}
		if c.hostRoute {
			if _, err := c.router.DeleteRouteIfOurs(c.measureHost, true, c.name); err != nil {
				c.logf("teardown %s: removing the %s route: %v", c.name, c.measureHost, err)
			}
		}
		_ = c.dev.Close()
		c.session.Close()
	})
}
