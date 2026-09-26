// tunnelpoc is Phase 3's last, highest-risk step (see docs/IMPLEMENTATION_PLAN.md): does real
// internet traffic actually flow utun -> MASQUE -> Cloudflare -> back? It deliberately does NOT
// touch the default route — only a single narrow host route (-target, default 1.1.1.1) — to keep
// the blast radius small while proving the exact same packet-pumping mechanism a real default
// route replacement would need. That's the next, separate step once this one is verified.
//
// Needs root (utun). Modifies routing state; -target's route is removed on exit, including
// Ctrl-C, but if this process is killed harder than that (-9), run manually to check:
//
//	netstat -rn | grep <target>
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/feg55/zarp-macos/zarpd/route"
	"github.com/feg55/zarp-macos/zarpd/tunnel"
	"github.com/feg55/zarp-macos/zarpd/warp"
)

func main() {
	configPath := flag.String("config", "/tmp/zarp-warp-config.json", "path to the WARP config written by warppoc")
	target := flag.String("target", "1.1.1.1", "single host to route through the tunnel for this test")
	mtu := flag.Int("mtu", 1280, "tunnel MTU (usque/MASQUE supports up to 1280)")
	duration := flag.Duration("duration", 25*time.Second, "how long to keep the tunnel up")
	fakeBlob := flag.String("fake-blob", "", "path to a fake-packet blob (e.g. Resources/blobs/quic_initial_www_google_com.bin); empty = no strategy, direct dial")
	fakeRepeats := flag.Int("fake-repeats", 6, "how many times to send -fake-blob before the real QUIC Initial")
	fakeTTL := flag.Int("fake-ttl", 0, "if >0, IP TTL to use for the fake packets only (0 = don't change it)")
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
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		log.Fatalf("ListenUDP: %v", err)
	}
	if err := phys.BindUDP(udpConn); err != nil {
		log.Fatalf("BindUDP (IP_BOUND_IF): %v — this is the routing-loop guard, not optional", err)
	}

	endpoint := &net.UDPAddr{IP: net.ParseIP(cfg.EndpointV4), Port: 443}
	socketBefore := udpConn.LocalAddr().String()
	strategyName := "direct (no fake-blob given)"
	if *fakeBlob != "" {
		strategyName = fmt.Sprintf("fake %s x%d ttl=%d", *fakeBlob, *fakeRepeats, *fakeTTL)
	}
	fmt.Printf("UDP socket created: local=%s\n", socketBefore)
	fmt.Printf("target=%s\n", endpoint)
	fmt.Printf("strategy=%s\n", strategyName)
	fmt.Printf("(bound to physical interface %s, won't be captured by the utun route below)\n\n", phys.Interface)

	if *fakeBlob != "" {
		blob, err := os.ReadFile(*fakeBlob)
		if err != nil {
			log.Fatalf("reading -fake-blob: %v", err)
		}
		steps := []warp.FakeStep{{Blob: blob, Repeats: *fakeRepeats, TTL: *fakeTTL}}
		packets, sent, err := warp.SendFakes(udpConn, endpoint, steps, func(_, packetIndex, n int) {
			fmt.Printf("fake %d/%d sent: %d bytes\n", packetIndex+1, *fakeRepeats, n)
		})
		if err != nil {
			log.Fatalf("SendFakes: %v (sent %d packets, %d bytes before failing)", err, packets, sent)
		}
		fmt.Printf("(%d fake packet(s) sent, %d bytes total)\n\n", packets, sent)
	}

	socketNow := udpConn.LocalAddr().String()
	fmt.Println("--- handing THE SAME UDP socket to quic-go ---")
	fmt.Printf("local socket before QUIC=%s\n", socketNow)
	if socketNow != socketBefore {
		// Would mean udpConn got replaced somewhere above instead of reused — it didn't (this
		// function only ever holds the one *net.UDPConn from ListenUDP), but assert it rather
		// than just assert it in a doc comment: the whole strategy is worthless if this ever
		// stops being true.
		log.Fatalf("BUG: socket address changed (%s -> %s) — fakes and the real Initial would NOT share a 5-tuple", socketBefore, socketNow)
	}
	fmt.Println("--- real QUIC handshake beginning ---")
	session, err := warp.DialH3(context.Background(), udpConn, endpoint, tlsConfig, 30*time.Second, 15*time.Second)
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
	fmt.Println("--- self-check: curl --max-time 5 https://" + *target + "/cdn-cgi/trace ---")
	time.Sleep(500 * time.Millisecond) // let the pump goroutines actually start reading/writing first
	if out, err := exec.Command("curl", "-s", "--max-time", "5", "https://"+*target+"/cdn-cgi/trace").CombinedOutput(); err != nil {
		fmt.Printf("self-check curl failed: %v\n%s\nwarp=off (curl itself failed)\n", err, out)
	} else {
		verdict := "warp=off"
		if strings.Contains(string(out), "warp=on") {
			verdict = "warp=on"
		}
		fmt.Printf("%s\n%s\n", indent(string(out)), verdict)
	}
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
