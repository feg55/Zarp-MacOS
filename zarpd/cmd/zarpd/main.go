// zarpd is the privileged daemon Zarp.app talks to over IPC (docs/ARCHITECTURE.md §1, §9.4):
// account registration, MASQUE dial with a strategy applied, utun + narrow routing, and the
// cdn-cgi/trace measurement ZarpEngine needs to score a strategy — everything
// WarpConnectionProvider/WarpProbe (EngineProtocols.swift) ask for, nothing ZarpEngine already
// does itself (scan ordering, scoring, self-healing stay in Swift).
//
// Phase 7 scope, deliberately: every open() — test or persistent alike — gets its own utun and a
// route to exactly the measurement target, the same narrow, low-blast-radius approach
// tunnelpoc's real-Mac testing already proved (docs/IMPLEMENTATION_PLAN.md phases 3-6). A
// persistent connection carrying the user's actual general traffic via a full default-route
// takeover is real future work (IMPLEMENTATION_PLAN.md phase 7's own notes), not silently assumed
// to already work here.
//
// Needs root (utun). Run manually for now (`sudo zarpd`); SMAppService installation is phase 8.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	usqueconfig "github.com/Diniboy1123/usque/config"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/feg55/zarp-macos/zarpd/ipc"
	"github.com/feg55/zarp-macos/zarpd/route"
	"github.com/feg55/zarp-macos/zarpd/tunnel"
	"github.com/feg55/zarp-macos/zarpd/warp"
)

// blobFiles mirrors ZarpCore's Blob.fileName (Blob.swift) exactly — kept as data here rather
// than shared code because zarpd (Go) and ZarpCore (Swift) are separate modules/languages; the
// IPC layer is the seam, not a shared struct (docs/ARCHITECTURE.md §9.4).
var blobFiles = map[string]string{
	"quic_google": "quic_initial_www_google_com.bin",
	"quic_vk":     "quic_initial_vk_com.bin",
	"tls_google":  "tls_clienthello_www_google_com.bin",
	"tls_vk":      "tls_clienthello_vk_com.bin",
	"stun_fake":   "stun.bin",
	// "zero64" has no file — 64 zero bytes, synthesized in loadBlob.
}

type server struct {
	blobsDir     string
	configPath   string
	measureHost  string // IP, not hostname — see dial()'s comment on why
	mtu          int

	mu    sync.Mutex
	conns map[string]*liveConn
	nextID uint64
}

type liveConn struct {
	session *warp.Session
	dev     tun.Device
	name    string
	handle  bool // false once Close has already torn this down
	connectMs int
	endpoint  string
}

func main() {
	socketPath := flag.String("socket", "/tmp/zarpd.sock", "Unix domain socket to listen on")
	blobsDir := flag.String("blobs", defaultBlobsDir(), "directory holding the fake-packet blobs (Resources/blobs)")
	configPath := flag.String("config", "/tmp/zarp-warp-config.json", "WARP account config path")
	measureHost := flag.String("measure-host", "1.1.1.1", "IP used for the cdn-cgi/trace measurement and its narrow per-connection route")
	mtu := flag.Int("mtu", 1280, "tunnel MTU")
	flag.Parse()

	if !warp.HasAccount(*configPath) {
		log.Printf("no WARP account at %s, registering one now (accepting ToS, as instructed)...", *configPath)
		if err := warp.Register(*configPath, "Zarp macOS"); err != nil {
			log.Fatalf("Register: %v", err)
		}
	}

	s := &server{
		blobsDir:    *blobsDir,
		configPath:  *configPath,
		measureHost: *measureHost,
		mtu:         *mtu,
		conns:       map[string]*liveConn{},
	}

	ctx, cancel := context.WithCancel(context.Background())
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("zarpd: shutting down")
		s.closeAll()
		cancel()
	}()

	log.Printf("zarpd: listening on %s (blobs=%s config=%s measure-host=%s)", *socketPath, *blobsDir, *configPath, *measureHost)
	if err := ipc.Serve(ctx, *socketPath, s.handle); err != nil {
		log.Fatalf("ipc.Serve: %v", err)
	}
}

func defaultBlobsDir() string {
	// Repo-relative default for development; a real install would pass -blobs explicitly at a
	// fixed path (see docs/IMPLEMENTATION_PLAN.md phase 8, not yet written).
	exe, err := os.Executable()
	if err != nil {
		return "Resources/blobs"
	}
	return filepath.Join(filepath.Dir(exe), "..", "..", "..", "Resources", "blobs")
}

func (s *server) handle(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "open":
		return s.handleOpen(ctx, params)
	case "close":
		return s.handleClose(params)
	case "measure":
		return s.handleMeasure(params)
	default:
		return nil, fmt.Errorf("unknown method %q", method)
	}
}

func (s *server) loadBlob(name string) ([]byte, error) {
	if name == "zero64" {
		return make([]byte, 64), nil
	}
	file, ok := blobFiles[name]
	if !ok {
		return nil, fmt.Errorf("unknown blob %q", name)
	}
	return os.ReadFile(filepath.Join(s.blobsDir, file))
}

func (s *server) handleOpen(ctx context.Context, raw json.RawMessage) (any, error) {
	var p ipc.OpenParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	cfg, err := warp.LoadConfig(s.configPath)
	if err != nil {
		return nil, err
	}
	phys, err := route.CurrentDefault()
	if err != nil {
		return nil, err
	}
	tlsConfig, err := warp.TLSConfigFromAccount(cfg)
	if err != nil {
		return nil, err
	}
	timeout := time.Duration(p.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 15 * time.Second
	}

	start := time.Now()
	var session *warp.Session
	switch p.Transport {
	case "masqueH2":
		session, err = s.dialH2(ctx, phys, cfg, tlsConfig, p, timeout)
	case "masqueH3", "":
		session, err = s.dialH3(ctx, phys, cfg, tlsConfig, p, timeout)
	default:
		return nil, &ipc.ConnError{Message: fmt.Sprintf("transport %q not supported yet (wireGuard is phase 9+, IMPLEMENTATION_PLAN.md §9.6)", p.Transport)}
	}
	if err != nil {
		return nil, dialErrToConnError(err, timeout)
	}
	connectMs := int(time.Since(start).Milliseconds())

	dev, err := tun.CreateTUN("utun", s.mtu)
	if err != nil {
		session.Close()
		return nil, err
	}
	name, _ := dev.Name()
	if err := exec.Command("ifconfig", name, "inet", cfg.IPv4, cfg.IPv4, "up").Run(); err != nil {
		_ = dev.Close()
		session.Close()
		return nil, fmt.Errorf("configuring %s: %w", name, err)
	}
	if err := route.AddHostRoute(s.measureHost, name); err != nil {
		_ = dev.Close()
		session.Close()
		return nil, err
	}

	pump := tunnel.New(dev, session, s.mtu)
	go func() {
		if err := pump.Run(); err != nil {
			log.Printf("zarpd: pump for %s stopped: %v", name, err)
		}
	}()

	s.mu.Lock()
	s.nextID++
	id := strconv.FormatUint(s.nextID, 10)
	s.conns[id] = &liveConn{session: session, dev: dev, name: name, handle: true, connectMs: connectMs, endpoint: p.Endpoint}
	s.mu.Unlock()

	log.Printf("zarpd: open #%s transport=%s connectMs=%d dev=%s persistent=%v", id, p.Transport, connectMs, name, p.Persistent)
	return ipc.OpenResult{ConnectionID: id, ConnectMs: connectMs, Endpoint: cfg.EndpointV4}, nil
}

func (s *server) handleClose(raw json.RawMessage) (any, error) {
	var p ipc.CloseParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	s.closeConn(p.ConnectionID)
	return struct{}{}, nil
}

func (s *server) closeConn(id string) {
	s.mu.Lock()
	c, ok := s.conns[id]
	if ok {
		delete(s.conns, id)
	}
	s.mu.Unlock()
	if !ok || !c.handle {
		return
	}
	c.handle = false
	if err := route.DeleteHostRoute(s.measureHost); err != nil {
		log.Printf("zarpd: close #%s: route cleanup: %v", id, err)
	}
	_ = c.dev.Close()
	c.session.Close()
	log.Printf("zarpd: closed #%s (%s)", id, c.name)
}

func (s *server) closeAll() {
	s.mu.Lock()
	ids := make([]string, 0, len(s.conns))
	for id := range s.conns {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	sort.Strings(ids)
	for _, id := range ids {
		s.closeConn(id)
	}
}

func (s *server) handleMeasure(raw json.RawMessage) (any, error) {
	var p ipc.MeasureParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	s.mu.Lock()
	_, ok := s.conns[p.ConnectionID]
	s.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("no open connection #%s", p.ConnectionID)
	}

	samples := p.Samples
	if samples <= 0 {
		samples = 3
	}
	client := &http.Client{Timeout: 5 * time.Second}
	url := "https://" + s.measureHost + "/cdn-cgi/trace"

	// One warm-up request (not scored), matching every other Zarp port's WarpProbe contract
	// (EngineProtocols.swift's doc comment).
	if _, lastErr := traceOnce(client, url); lastErr != "" {
		return ipc.MeasureResult{Kind: "noTraffic", LastError: lastErr}, nil
	}

	var pings []int
	var warpVal string
	var lastErr string
	for i := 0; i < samples; i++ {
		start := time.Now()
		warpv, errStr := traceOnce(client, url)
		if errStr != "" {
			lastErr = errStr
			continue
		}
		if warpv != "on" && warpv != "plus" {
			return ipc.MeasureResult{Kind: "notWarp", Detail: "warp=" + warpv}, nil
		}
		pings = append(pings, int(time.Since(start).Milliseconds()))
		warpVal = warpv
	}
	if len(pings) == 0 {
		return ipc.MeasureResult{Kind: "noTraffic", LastError: lastErr}, nil
	}
	sort.Ints(pings)
	return ipc.MeasureResult{Kind: "ok", PingMs: pings[len(pings)/2], Warp: warpVal}, nil
}

// traceOnce fetches cdn-cgi/trace and returns the warp= value, or (on failure) an error string —
// two returns instead of an error so the caller can tell "reached the server but warp isn't on"
// apart from "never reached the server at all" (noTraffic vs. notWarp).
func traceOnce(client *http.Client, url string) (warpVal, errStr string) {
	resp, err := client.Get(url)
	if err != nil {
		return "", err.Error()
	}
	defer func() { _ = resp.Body.Close() }()
	// cdn-cgi/trace is a few hundred bytes, but a single Read() call on a network response body
	// is not guaranteed to return the whole thing at once — ReadAll loops until EOF instead of
	// risking a truncated read that happens to cut off the warp= line.
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8192))
	if err != nil {
		return "", err.Error()
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "warp=") {
			warpVal = strings.TrimPrefix(line, "warp=")
		}
	}
	return warpVal, ""
}

func dialErrToConnError(err error, timeout time.Duration) error {
	msg := err.Error()
	timedOut := strings.Contains(msg, "timeout") || strings.Contains(msg, "deadline exceeded")
	return &ipc.ConnError{Message: msg, TimedOut: timedOut}
}

func (s *server) dialH3(ctx context.Context, phys *route.Physical, cfg *usqueconfig.Config, tlsConfig *tls.Config, p ipc.OpenParams, timeout time.Duration) (*warp.Session, error) {
	// p.Endpoint is ZarpEngine's opaque per-test uniqueness token when "isolate tests" is on
	// (e.g. "isolated-3"), not necessarily a real address — see ZarpEngine.nextEndpoint's doc
	// comment. Only honor it as an override when it actually parses as an IP; otherwise fall back
	// to the account's real endpoint rather than dialing a garbage net.UDPAddr{IP: nil}.
	endpointIP := cfg.EndpointV4
	if p.Endpoint != "" && net.ParseIP(p.Endpoint) != nil {
		endpointIP = p.Endpoint
	}
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	if err := phys.BindUDP(udpConn); err != nil {
		return nil, fmt.Errorf("BindUDP: %w", err)
	}
	endpoint := &net.UDPAddr{IP: net.ParseIP(endpointIP), Port: 443}

	if len(p.FakeSteps) > 0 {
		steps, err := s.toFakeSteps(p.FakeSteps)
		if err != nil {
			return nil, err
		}
		if _, _, err := warp.SendFakes(udpConn, endpoint, steps, nil); err != nil {
			return nil, fmt.Errorf("SendFakes: %w", err)
		}
	}
	return warp.DialH3(ctx, udpConn, endpoint, tlsConfig, 30*time.Second, timeout)
}

func (s *server) dialH2(ctx context.Context, phys *route.Physical, cfg *usqueconfig.Config, tlsConfig *tls.Config, p ipc.OpenParams, timeout time.Duration) (*warp.Session, error) {
	// Same "isolated-N" caveat as dialH3 above.
	v4 := cfg.EndpointH2V4
	if p.Endpoint != "" && net.ParseIP(p.Endpoint) != nil {
		v4 = p.Endpoint
	}
	endpoint := &net.TCPAddr{IP: net.ParseIP(v4), Port: 443}
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
	return warp.DialH2(ctx, dialer, endpoint, tlsConfig, desync, timeout)
}

func (s *server) toFakeSteps(in []ipc.FakeStep) ([]warp.FakeStep, error) {
	out := make([]warp.FakeStep, 0, len(in))
	for _, step := range in {
		blob, err := s.loadBlob(step.Blob)
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
