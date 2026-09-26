// tunnelpoc is the real-Mac test harness for docs/IMPLEMENTATION_PLAN.md phases 3-6: does real
// internet traffic actually flow utun -> MASQUE -> Cloudflare -> back, with or without a DPI
// strategy applied first? It deliberately does NOT touch the default route — only a single
// narrow host route (-target, default 1.1.1.1) — to keep the blast radius small while proving the
// exact same packet-pumping mechanism a real default route replacement would need.
//
// Needs root (utun). Modifies routing state; -target's route is removed on exit, including
// Ctrl-C, but if this process is killed harder than that (-9), run manually to check:
//
//	netstat -rn | grep <target>
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	usqueconfig "github.com/Diniboy1123/usque/config"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/feg55/zarp-macos/zarpd/route"
	"github.com/feg55/zarp-macos/zarpd/tunnel"
	"github.com/feg55/zarp-macos/zarpd/warp"
)

// fakeStepList accumulates one -fake flag per step, format "path[:repeats[:ttl]]" — repeats
// defaults to 6, ttl to 0 (don't change it). Repeatable so a strategy like "WARP QUIC: fake
// google + vk" (two steps, each with its own blob) can be expressed on the command line instead
// of needing a code change per strategy combination. QUIC/HTTP3 only — see -desync for HTTP/2.
type fakeStepList struct {
	specs []string
	steps []warp.FakeStep
}

func (f *fakeStepList) String() string { return strings.Join(f.specs, ",") }

func (f *fakeStepList) Set(spec string) error {
	parts := strings.Split(spec, ":")
	path := parts[0]
	repeats, ttl := 6, 0
	if len(parts) > 1 {
		n, err := strconv.Atoi(parts[1])
		if err != nil {
			return fmt.Errorf("-fake %q: bad repeats %q: %w", spec, parts[1], err)
		}
		repeats = n
	}
	if len(parts) > 2 {
		n, err := strconv.Atoi(parts[2])
		if err != nil {
			return fmt.Errorf("-fake %q: bad ttl %q: %w", spec, parts[2], err)
		}
		ttl = n
	}
	blob, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("-fake %q: %w", spec, err)
	}
	f.specs = append(f.specs, spec)
	f.steps = append(f.steps, warp.FakeStep{Blob: blob, Repeats: repeats, TTL: ttl})
	return nil
}

func main() {
	configPath := flag.String("config", "/tmp/zarp-warp-config.json", "path to the WARP config written by warppoc")
	target := flag.String("target", "1.1.1.1", "single host to route through the tunnel for this test")
	mtu := flag.Int("mtu", 1280, "tunnel MTU (usque/MASQUE supports up to 1280)")
	duration := flag.Duration("duration", 25*time.Second, "how long to keep the tunnel up")
	http2 := flag.Bool("http2", false, "dial MASQUE over HTTP/2 (TCP) instead of HTTP/3 (QUIC/UDP) — the fallback transport")
	desyncSpec := flag.String("desync", "", "HTTP/2 only: TLS ClientHello desync, e.g. \"split:host,midsld\" or \"disorder:1\" (see warp/desync.go)")
	var fakes fakeStepList
	flag.Var(&fakes, "fake", "HTTP/3 only, repeatable: path/to/blob.bin[:repeats[:ttl]] (repeats default 6, ttl default 0=unchanged); "+
		"e.g. two -fake flags = google then vk, matching \"WARP QUIC: fake google + vk\". None given = no strategy, direct dial.")
	flag.Parse()

	cfg, err := warp.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("LoadConfig: %v (run warppoc first)", err)
	}
	phys, err := route.CurrentDefault()
	if err != nil {
		log.Fatalf("CurrentDefault: %v", err)
	}
	fmt.Printf("physical default route: %s via %s (gw %s)\n", "0.0.0.0/0", phys.Interface, phys.Gateway)

	tlsConfig, err := warp.TLSConfigFromAccount(cfg)
	if err != nil {
		log.Fatalf("TLSConfigFromAccount: %v", err)
	}

	var session *warp.Session
	if *http2 {
		session, err = dialH2(cfg, phys, tlsConfig, *desyncSpec)
	} else {
		session, err = dialH3(cfg, phys, tlsConfig, fakes)
	}
	if err != nil {
		log.Fatalf("MASQUE connected / failed: %v", err)
	}
	defer session.Close()
	fmt.Println("MASQUE connected / CONNECT-IP session established")

	dev, err := tun.CreateTUN("utun", *mtu)
	if err != nil {
		log.Fatalf("CreateTUN: %v", err)
	}
	name, _ := dev.Name()
	defer func() { _ = dev.Close() }()

	if err := configureAddress(name, cfg.IPv4); err != nil {
		log.Fatalf("configure %s: %v", name, err)
	}
	fmt.Printf("opened %s, assigned WARP address %s\n", name, cfg.IPv4)

	if err := route.AddHostRoute(*target, name); err != nil {
		log.Fatalf("AddHostRoute: %v", err)
	}
	fmt.Printf("routed %s through %s (narrow test route, not the default route)\n", *target, name)
	defer func() {
		if err := route.DeleteHostRoute(*target); err != nil {
			log.Printf("cleanup: %v", err)
		} else {
			fmt.Printf("removed the %s route\n", *target)
		}
	}()

	pump := tunnel.New(dev, session, *mtu)
	pumpErr := make(chan error, 1)
	go func() { pumpErr <- pump.Run() }()

	fmt.Printf("pumping packets for up to %s\n", *duration)
	fmt.Println("--- self-check: curl --max-time 5 https://" + *target + "/cdn-cgi/trace (up to 4 attempts, 1s apart) ---")
	verdict := "warp=off"
	for attempt := 1; attempt <= 4; attempt++ {
		time.Sleep(time.Second) // let the pump goroutines actually start reading/writing first, and give retransmits (e.g. disorder mode) room
		out, err := exec.Command("curl", "-s", "--max-time", "5", "https://"+*target+"/cdn-cgi/trace").CombinedOutput()
		if err != nil {
			fmt.Printf("attempt %d/4: curl failed: %v\n", attempt, err)
			continue
		}
		if strings.Contains(string(out), "warp=on") {
			fmt.Printf("attempt %d/4:\n%s\n", attempt, indent(string(out)))
			verdict = "warp=on"
			break
		}
		fmt.Printf("attempt %d/4: reached the server but no warp=on:\n%s\n", attempt, indent(string(out)))
	}
	fmt.Println(verdict)
	fmt.Println("(feel free to also try `ping " + *target + "` yourself in another terminal)")

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)

	select {
	case <-time.After(*duration):
		fmt.Println("duration elapsed")
	case <-sigs:
		fmt.Println("\ninterrupted")
	case err := <-pumpErr:
		fmt.Printf("pump stopped on its own: %v\n", err)
	}
	fmt.Println("shutting down (route, tunnel, session all torn down by deferred cleanup)")
}

// dialH3 is phases 3-5's path: QUIC/UDP, optionally with fake packets sent on the exact socket
// the real Initial reuses.
func dialH3(cfg *usqueconfig.Config, phys *route.Physical, tlsConfig *tls.Config, fakes fakeStepList) (*warp.Session, error) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, fmt.Errorf("ListenUDP: %w", err)
	}
	if err := phys.BindUDP(udpConn); err != nil {
		return nil, fmt.Errorf("BindUDP (IP_BOUND_IF): %w — this is the routing-loop guard, not optional", err)
	}

	endpoint := &net.UDPAddr{IP: net.ParseIP(cfg.EndpointV4), Port: 443}
	socketBefore := udpConn.LocalAddr().String()
	strategyName := "direct (no -fake given)"
	if len(fakes.steps) > 0 {
		strategyName = fmt.Sprintf("fake %s", fakes.String())
	}
	fmt.Printf("UDP socket created: local=%s\n", socketBefore)
	fmt.Printf("target=%s\n", endpoint)
	fmt.Printf("strategy=%s\n", strategyName)
	fmt.Printf("(bound to physical interface %s, won't be captured by the utun route below)\n\n", phys.Interface)

	if len(fakes.steps) > 0 {
		packets, sent, err := warp.SendFakes(udpConn, endpoint, fakes.steps, func(stepIndex, packetIndex, n int) {
			step := fakes.steps[stepIndex]
			fmt.Printf("step %d/%d (%s) fake %d/%d sent: %d bytes\n",
				stepIndex+1, len(fakes.steps), fakes.specs[stepIndex], packetIndex+1, step.Repeats, n)
		})
		if err != nil {
			return nil, fmt.Errorf("SendFakes: %w (sent %d packets, %d bytes before failing)", err, packets, sent)
		}
		fmt.Printf("(%d fake packet(s) sent across %d step(s), %d bytes total)\n\n", packets, len(fakes.steps), sent)
	}

	socketNow := udpConn.LocalAddr().String()
	fmt.Println("--- handing THE SAME UDP socket to quic-go ---")
	fmt.Printf("local socket before QUIC=%s\n", socketNow)
	if socketNow != socketBefore {
		return nil, fmt.Errorf("BUG: socket address changed (%s -> %s) — fakes and the real Initial would NOT share a 5-tuple", socketBefore, socketNow)
	}
	fmt.Println("--- real QUIC handshake beginning ---")
	return warp.DialH3(context.Background(), udpConn, endpoint, tlsConfig, 30*time.Second, 15*time.Second)
}

// dialH2 is phase 6's path: TCP/TLS, optionally with the ClientHello split/disordered.
func dialH2(cfg *usqueconfig.Config, phys *route.Physical, tlsConfig *tls.Config, desyncSpecStr string) (*warp.Session, error) {
	v4 := cfg.EndpointH2V4
	if v4 == "" {
		v4 = "162.159.198.2" // usqueconfig.DefaultEndpointH2V4, avoiding an import just for the fallback
	}
	endpoint := &net.TCPAddr{IP: net.ParseIP(v4), Port: 443}

	var desync *warp.DesyncSpec
	if desyncSpecStr != "" {
		var err error
		desync, err = warp.ParseDesync(desyncSpecStr)
		if err != nil {
			return nil, err
		}
	}

	fmt.Printf("target=%s (HTTP/2)\n", endpoint)
	strategyName := "direct (no -desync given)"
	if desync != nil {
		strategyName = "desync " + desyncSpecStr
	}
	fmt.Printf("strategy=%s\n", strategyName)
	fmt.Printf("(dialer bound to physical interface %s, won't be captured by the utun route below)\n\n", phys.Interface)

	dialer := &net.Dialer{Control: phys.Control}
	fmt.Println("--- TCP + TLS handshake beginning ---")
	return warp.DialH2(context.Background(), dialer, endpoint, tlsConfig, desync, 15*time.Second)
}

func configureAddress(name, local string) error {
	cmd := exec.Command("ifconfig", name, "inet", local, local, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func indent(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		lines[i] = "  " + l
	}
	return strings.Join(lines, "\n")
}
