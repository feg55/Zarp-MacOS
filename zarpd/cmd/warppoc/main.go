// warppoc is Phase 3's first, most self-contained step (see docs/IMPLEMENTATION_PLAN.md):
// register a real WARP account against Cloudflare's servers and confirm the resulting config is
// usable, before touching MASQUE dial or utun packet pumping at all. Needs no root privilege.
package main

import (
	"flag"
	"fmt"
	"log"

	"github.com/feg55/zarp-macos/zarpd/warp"
)

func main() {
	configPath := flag.String("config", "/tmp/zarp-warp-config.json", "path to read/write the WARP config")
	deviceName := flag.String("device-name", "Zarp macOS PoC", "device name to register with Cloudflare")
	flag.Parse()

	if warp.HasAccount(*configPath) {
		fmt.Printf("%s already holds a usable registration, skipping Register\n", *configPath)
	} else {
		fmt.Println("registering a new WARP device with Cloudflare (accepting ToS, as instructed)...")
		if err := warp.Register(*configPath, *deviceName); err != nil {
			log.Fatalf("Register: %v", err)
		}
		fmt.Printf("registered, wrote %s\n", *configPath)
	}

	endpoint, err := warp.AccountEndpoint(*configPath)
	if err != nil {
		log.Fatalf("AccountEndpoint: %v", err)
	}
	fmt.Printf("assigned MASQUE endpoint: %s:443\n", endpoint)
}
