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
	fmt.Printf("WARP control socket bound to %s (won't be captured by the utun route below)\n", phys.Interface)

	endpoint := &net.UDPAddr{IP: net.ParseIP(cfg.EndpointV4), Port: 443}
	fmt.Printf("dialing MASQUE/HTTP3 to %s...\n", endpoint)
	session, err := warp.DialH3(context.Background(), udpConn, endpoint, tlsConfig, 30*time.Second, 15*time.Second)
	if err != nil {
		log.Fatalf("DialH3: %v", err)
	}
	defer session.Close()
	fmt.Println("MASQUE session established")

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

	fmt.Printf("pumping packets for up to %s — try in another terminal:\n", *duration)
	fmt.Printf("  curl --max-time 5 https://%s/cdn-cgi/trace\n", *target)
	fmt.Printf("  ping %s\n", *target)

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
