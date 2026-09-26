// dialpoc is Phase 3's second step (see docs/IMPLEMENTATION_PLAN.md): given a registered WARP
// account (warppoc), perform the actual MASQUE/HTTP3 handshake and CONNECT-IP request against
// Cloudflare's real endpoint — no fake packets yet (phase 4), no utun wiring yet (this file),
// just proving the dial itself works end to end before building anything on top of it.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/feg55/zarp-macos/zarpd/warp"
)

func main() {
	configPath := flag.String("config", "/tmp/zarp-warp-config.json", "path to the WARP config written by warppoc")
	timeout := flag.Duration("timeout", 15*time.Second, "connect timeout")
	flag.Parse()

	cfg, err := warp.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("LoadConfig: %v (run warppoc first)", err)
	}
	fmt.Printf("loaded config for device %s, endpoint %s\n", cfg.ID, cfg.EndpointV4)

	tlsConfig, err := warp.TLSConfigFromAccount(cfg)
	if err != nil {
		log.Fatalf("TLSConfigFromAccount: %v", err)
	}

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		log.Fatalf("ListenUDP: %v", err)
	}
	endpoint := &net.UDPAddr{IP: net.ParseIP(cfg.EndpointV4), Port: 443}

	fmt.Printf("dialing MASQUE/HTTP3 to %s (timeout %s)...\n", endpoint, *timeout)
	start := time.Now()
	session, err := warp.DialH3(context.Background(), udpConn, endpoint, tlsConfig, 30*time.Second, *timeout)
	if err != nil {
		log.Fatalf("DialH3 failed after %s: %v", time.Since(start), err)
	}
	fmt.Printf("connected in %s — CONNECT-IP session established\n", time.Since(start))
	session.Close()
	fmt.Println("closed cleanly")
}
