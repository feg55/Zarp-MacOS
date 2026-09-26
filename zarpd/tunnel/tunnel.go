// Package tunnel pumps packets between a real macOS utun device and a warp.Session's CONNECT-IP
// stream directly — no userspace netstack, no local SOCKS5 proxy (see docs/ARCHITECTURE.md §9.1
// for why Android's zarpcore.Tunnel does something different and why that doesn't apply here).
package tunnel

import (
	"errors"
	"fmt"
	"log"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/feg55/zarp-macos/zarpd/warp"
)

// headroom matches tun_darwin.go's contract (see zarpd/cmd/tunpoc, phase 2): both Read and Write
// need 4 bytes before the IP packet for the kernel's/our own address-family header.
const headroom = 4

// Pump moves packets between dev and session in both directions until either side stops (the
// device closes, the session fails, or ctx-like cancellation happens via closing one of them
// from the caller). It blocks; run it in a goroutine and Close the Tunnel's pieces to stop it.
type Pump struct {
	dev     tun.Device
	session *warp.Session
	mtu     int

	errs chan error
}

// New wraps an already-open device and an already-connected session. Neither is started or
// closed by New; the caller owns both lifetimes (mirrors Zarp-Android's Tunnel.maintain, which
// re-dials on reconnect without recreating the device — same shape expected here later).
func New(dev tun.Device, session *warp.Session, mtu int) *Pump {
	return &Pump{dev: dev, session: session, mtu: mtu, errs: make(chan error, 2)}
}

// Run starts both pump directions and blocks until one of them fails. The returned error is
// whichever side failed first; the caller is responsible for tearing down dev/session afterward.
func (p *Pump) Run() error {
	go p.pumpDeviceToSession()
	go p.pumpSessionToDevice()
	return <-p.errs
}

// pumpDeviceToSession reads packets the kernel routes into the utun and forwards them into the
// MASQUE session.
func (p *Pump) pumpDeviceToSession() {
	bufs := make([][]byte, 1)
	bufs[0] = make([]byte, headroom+p.mtu+64) // slack for any header growth
	sizes := make([]int, 1)
	for {
		n, err := p.dev.Read(bufs, sizes, headroom)
		if err != nil {
			p.errs <- fmt.Errorf("utun read: %w", err)
			return
		}
		for i := 0; i < n; i++ {
			icmp, err := p.session.IPConn.WritePacketBuffer(bufs[i], headroom, sizes[i])
			if err != nil {
				p.errs <- fmt.Errorf("connect-ip write: %w", err)
				return
			}
			if len(icmp) > 0 {
				if werr := p.writeToDevice(icmp); werr != nil {
					log.Printf("tunnel: writing ICMP response to utun: %v", werr)
				}
			}
		}
	}
}

// pumpSessionToDevice reads packets the MASQUE session delivers (real internet traffic coming
// back through WARP) and writes them into the utun so the kernel delivers them locally.
func (p *Pump) pumpSessionToDevice() {
	for {
		pkt, err := p.session.IPConn.ReadPacketZeroCopy(true)
		if err != nil {
			p.errs <- fmt.Errorf("connect-ip read: %w", err)
			return
		}
		if err := p.writeToDevice(pkt); err != nil {
			p.errs <- fmt.Errorf("utun write: %w", err)
			return
		}
	}
}

func (p *Pump) writeToDevice(pkt []byte) error {
	buf := make([]byte, headroom+len(pkt))
	copy(buf[headroom:], pkt)
	n, err := p.dev.Write([][]byte{buf}, headroom)
	if err == nil && n != 1 {
		return errors.New("short write to utun")
	}
	return err
}
