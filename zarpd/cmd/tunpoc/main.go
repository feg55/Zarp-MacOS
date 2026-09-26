// tunpoc is Phase 2 of the macOS architecture pivot (see docs/IMPLEMENTATION_PLAN.md): the
// smallest possible proof that a Go program can open a real macOS utun device, move packets on
// it, and close it cleanly — before any WARP/MASQUE code is written on top of it.
//
// It answers "read" by logging every packet the kernel routes into the device, and "write" by
// acting as the point-to-point peer for ICMP echo: `ping <peer>` gets real replies this program
// constructs and writes back, which is a much less ambiguous signal than a log line claiming a
// write "succeeded".
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

// Darwin's NativeTun.Read/Write both require 4 bytes of headroom before the IP packet for the
// kernel's/our own address-family header (golang.zx2c4.com/wireguard/tun/tun_darwin.go) — Read
// does bufs[0][offset-4:] and panics on a negative slice if offset is 0 as this PoC first (wrongly)
// called it with; Write refuses outright if offset < 4.
const headroom = 4

func main() {
	addr := flag.String("addr", "10.66.0.1", "local address to assign the utun device")
	peer := flag.String("peer", "10.66.0.2", "peer address of the point-to-point link")
	mtu := flag.Int("mtu", 1400, "MTU to set on the device")
	duration := flag.Duration("duration", 20*time.Second, "how long to read packets before exiting")
	flag.Parse()

	dev, err := tun.CreateTUN("utun", *mtu)
	if err != nil {
		log.Fatalf("CreateTUN: %v (root/sudo needed? see docs/IMPLEMENTATION_PLAN.md phase 2)", err)
	}
	name, err := dev.Name()
	if err != nil {
		log.Fatalf("Name: %v", err)
	}
	fmt.Printf("opened %s (requested mtu=%d)\n", name, *mtu)

	if err := configureAddress(name, *addr, *peer); err != nil {
		_ = dev.Close()
		log.Fatalf("configure address: %v", err)
	}
	fmt.Printf("assigned %s <-> %s, verifying with ifconfig:\n", *addr, *peer)
	if out, err := exec.Command("ifconfig", name).CombinedOutput(); err == nil {
		fmt.Print(indent(string(out)))
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)

	deadline := time.After(*duration)
	fmt.Printf("reading packets for up to %s (Ctrl-C to stop early; `ping %s` in another terminal should get real replies)\n", *duration, *peer)

	bufs := make([][]byte, 1)
	bufs[0] = make([]byte, headroom+2048)
	sizes := make([]int, 1)
	count, echoed := 0, 0

readLoop:
	for {
		select {
		case <-deadline:
			break readLoop
		case <-sigs:
			fmt.Println("\ninterrupted")
			break readLoop
		default:
		}
		n, err := dev.Read(bufs, sizes, headroom)
		if err != nil {
			log.Printf("read: %v", err)
			break
		}
		for i := 0; i < n; i++ {
			count++
			pkt := bufs[i][headroom : headroom+sizes[i]]
			describePacket(count, pkt)
			if reply, ok := icmpEchoReply(pkt); ok {
				if err := writePacket(dev, reply); err != nil {
					log.Printf("write echo reply: %v", err)
				} else {
					echoed++
					fmt.Printf("  -> wrote ICMP echo reply #%d\n", echoed)
				}
			}
		}
	}

	fmt.Printf("read %d packet(s) total, replied to %d ping(s); closing %s\n", count, echoed, name)
	if err := dev.Close(); err != nil {
		log.Fatalf("close: %v", err)
	}

	fmt.Println("closed. verifying it's actually gone:")
	if out, err := exec.Command("ifconfig", name).CombinedOutput(); err != nil {
		fmt.Printf("  %s no longer exists (expected): %v\n", name, strings.TrimSpace(string(out)))
	} else {
		fmt.Printf("  WARNING: %s still exists after Close():\n%s", name, indent(string(out)))
	}
}

// configureAddress assigns a point-to-point IPv4 address to the utun device and brings it up,
// via ifconfig rather than raw ioctls — the same pragmatic approach many macOS VPN clients use,
// and enough to answer phase 2's question without building route/ioctl code yet (that's phase 3).
func configureAddress(name, local, peer string) error {
	cmd := exec.Command("ifconfig", name, "inet", local, peer, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// writePacket adds the headroom Write requires and hands the packet to the device.
func writePacket(dev tun.Device, pkt []byte) error {
	buf := make([]byte, headroom+len(pkt))
	copy(buf[headroom:], pkt)
	_, err := dev.Write([][]byte{buf}, headroom)
	return err
}

// icmpEchoReply turns an IPv4 ICMP echo request into the corresponding echo reply (swapped
// addresses, type 0, recomputed checksums), acting as whatever the destination address was since
// nothing else answers on this point-to-point link. Returns ok=false for anything else.
func icmpEchoReply(pkt []byte) ([]byte, bool) {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return nil, false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || len(pkt) < ihl+8 || pkt[9] != 1 { // protocol 1 = ICMP
		return nil, false
	}
	icmp := pkt[ihl:]
	if icmp[0] != 8 { // type 8 = echo request
		return nil, false
	}

	reply := append([]byte(nil), pkt...)
	// swap source/destination
	copy(reply[12:16], pkt[16:20])
	copy(reply[16:20], pkt[12:16])
	reply[8] = 64 // fresh TTL, this program originates the reply
	reply[10], reply[11] = 0, 0
	putChecksum(reply[10:12], checksum(reply[:ihl]))

	ricmp := reply[ihl:]
	ricmp[0] = 0 // echo reply
	ricmp[2], ricmp[3] = 0, 0
	putChecksum(ricmp[2:4], checksum(ricmp))
	return reply, true
}

// checksum is the standard Internet checksum (RFC 1071), used for both the IPv4 header and ICMP.
func checksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

func putChecksum(b []byte, v uint16) {
	b[0] = byte(v >> 8)
	b[1] = byte(v)
}

func describePacket(n int, pkt []byte) {
	if len(pkt) == 0 {
		fmt.Printf("#%d: empty packet\n", n)
		return
	}
	version := pkt[0] >> 4
	switch version {
	case 4:
		if len(pkt) < 20 {
			fmt.Printf("#%d: truncated IPv4 packet (%d bytes)\n", n, len(pkt))
			return
		}
		proto := pkt[9]
		src := fmt.Sprintf("%d.%d.%d.%d", pkt[12], pkt[13], pkt[14], pkt[15])
		dst := fmt.Sprintf("%d.%d.%d.%d", pkt[16], pkt[17], pkt[18], pkt[19])
		fmt.Printf("#%d: IPv4 proto=%d %s -> %s (%d bytes)\n", n, proto, src, dst, len(pkt))
	case 6:
		if len(pkt) < 40 {
			fmt.Printf("#%d: truncated IPv6 packet (%d bytes)\n", n, len(pkt))
			return
		}
		next := pkt[6]
		fmt.Printf("#%d: IPv6 next=%d (%d bytes)\n", n, next, len(pkt))
	default:
		fmt.Printf("#%d: unknown IP version %d, first bytes % x (%d bytes)\n", n, version, pkt[:min(8, len(pkt))], len(pkt))
	}
}

func indent(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		lines[i] = "  " + l
	}
	return strings.Join(lines, "\n") + "\n"
}
