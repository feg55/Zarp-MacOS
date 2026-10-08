package warp

// TCP desync for MASQUE over HTTP/2: splitting the TLS ClientHello into several TCP segments so
// a DPI middlebox inspecting only the first segment (or reassembling naively) doesn't recognize
// it, matching zapret's multisplit/multidisorder and Zarp-Android's desync.go — whose algorithm
// has no Android-specific concept in it either (plain net.Conn + syscall), reimplemented directly
// rather than adapted from it (docs/ARCHITECTURE.md §8 on why: keeps this module's dependency
// graph MIT-clean, not GPL-3.0, and there's barely a second way to write this short an algorithm).
//
//   split    - the ClientHello leaves as several TCP segments, in order
//   disorder - like split, but the first segment is sent with TTL=1 so it dies on the first hop;
//              the kernel retransmits it later, after the rest has already gone out
//
// Positions: N (byte offset, negative = from the end), host (SNI start), endhost (SNI end),
// sld (second-level domain start), midsld (middle of it).

import (
	"bytes"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type DesyncMode int

const (
	DesyncSplit DesyncMode = iota
	DesyncDisorder
)

// DesyncSpec is one `multisplit:pos=...`/`multidisorder:pos=...` strategy argument.
type DesyncSpec struct {
	Mode DesyncMode
	Pos  []string
}

// ParseDesync parses "split:host,midsld" / "disorder:-2,endhost" style specs.
func ParseDesync(s string) (*DesyncSpec, error) {
	name, args, ok := strings.Cut(strings.TrimSpace(s), ":")
	if !ok || args == "" {
		return nil, fmt.Errorf("tcp desync %q: expected mode:positions", s)
	}
	spec := &DesyncSpec{}
	switch name {
	case "split":
		spec.Mode = DesyncSplit
	case "disorder":
		spec.Mode = DesyncDisorder
	default:
		return nil, fmt.Errorf("tcp desync %q: unknown mode %q", s, name)
	}
	for _, p := range strings.Split(args, ",") {
		p = strings.TrimSpace(p)
		switch p {
		case "host", "endhost", "sld", "midsld":
		default:
			if _, err := strconv.Atoi(p); err != nil {
				return nil, fmt.Errorf("tcp desync %q: bad position %q", s, p)
			}
		}
		spec.Pos = append(spec.Pos, p)
	}
	return spec, nil
}

// splitPositions resolves the spec's symbolic/numeric positions against a payload containing
// host (the TLS SNI), returning sorted, unique offsets strictly inside the payload.
func splitPositions(data []byte, pos []string, host string) []int {
	hostAt := -1
	if host != "" {
		hostAt = bytes.Index(data, []byte(host))
	}
	sldAt, sldLen := -1, 0
	if hostAt >= 0 {
		labels := strings.Split(host, ".")
		if len(labels) >= 2 {
			sld := labels[len(labels)-2]
			sldAt = hostAt + len(host) - len(labels[len(labels)-1]) - 1 - len(sld)
			sldLen = len(sld)
		}
	}
	seen := map[int]bool{}
	var out []int
	for _, p := range pos {
		off := -1
		switch p {
		case "host":
			off = hostAt
		case "endhost":
			if hostAt >= 0 {
				off = hostAt + len(host)
			}
		case "sld":
			off = sldAt
		case "midsld":
			if sldAt >= 0 {
				off = sldAt + sldLen/2
			}
		default:
			n, _ := strconv.Atoi(p)
			if n < 0 {
				n += len(data)
			}
			off = n
		}
		if off > 0 && off < len(data) && !seen[off] {
			seen[off] = true
			out = append(out, off)
		}
	}
	sort.Ints(out)
	return out
}

// desyncConn applies the desync to the first Write only (expected to be the TLS ClientHello);
// every later write passes straight through.
type desyncConn struct {
	*net.TCPConn
	spec *DesyncSpec
	host string
	once sync.Once
}

// NewDesyncConn wraps c so its first Write (the TLS ClientHello, detected by the handshake record
// byte 0x16) is split per spec. host is the SNI to split around ("host"/"endhost"/"sld"/"midsld"
// positions); pass "" if spec only uses numeric offsets.
func NewDesyncConn(c *net.TCPConn, spec *DesyncSpec, host string) net.Conn {
	return &desyncConn{TCPConn: c, spec: spec, host: host}
}

func (c *desyncConn) Write(b []byte) (int, error) {
	first := false
	c.once.Do(func() { first = true })
	if !first || len(b) < 6 || b[0] != 0x16 { // not a TLS handshake record
		return c.TCPConn.Write(b)
	}
	parts := splitPositions(b, c.spec.Pos, c.host)
	if len(parts) == 0 {
		return c.TCPConn.Write(b)
	}
	if err := c.TCPConn.SetNoDelay(true); err != nil {
		return 0, err
	}
	prev := 0
	written := 0
	ends := append(parts, len(b))
	for i, end := range ends {
		seg := b[prev:end]
		if i == 0 && c.spec.Mode == DesyncDisorder {
			if err := c.writeLowTTL(seg); err != nil {
				return written, err
			}
		} else if _, err := c.TCPConn.Write(seg); err != nil {
			return written, err
		}
		written += len(seg)
		prev = end
		if i < len(ends)-1 {
			time.Sleep(time.Millisecond) // give the kernel a chance to emit each piece as its own segment
		}
	}
	return written, nil
}

func (c *desyncConn) writeLowTTL(seg []byte) error {
	v6 := c.TCPConn.RemoteAddr().(*net.TCPAddr).IP.To4() == nil
	old, err := getTTL(c.TCPConn, v6)
	if err != nil {
		return err
	}
	if err := setTTL(c.TCPConn, v6, 1); err != nil {
		return err
	}
	_, werr := c.TCPConn.Write(seg)
	if rerr := setTTL(c.TCPConn, v6, old); rerr != nil && werr == nil {
		werr = fmt.Errorf("restore TTL: %w", rerr)
	}
	return werr
}
