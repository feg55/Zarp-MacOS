// Package route handles the routing side of docs/ARCHITECTURE.md §9.3: keeping the WARP control
// socket on the physical interface so it can never loop back through the tunnel it's still
// establishing, and (narrowly, for now — see zarpd/cmd/tunnelpoc) adding routes that send traffic
// into the utun. This is the least-verified part of the whole design; every function here is
// meant to be proven against real routing state on this Mac, not trusted from documentation.
package route

import (
	"fmt"
	"net"
	"os/exec"
	"regexp"
	"strings"

	"golang.org/x/sys/unix"
)

// Physical describes the interface/gateway that ordinary traffic uses right now, captured before
// any tunnel-related route changes so the WARP control socket can be bound to it explicitly
// regardless of what the routing table looks like once the tunnel is up.
type Physical struct {
	Interface string
	Index     int
	Gateway   net.IP
}

var routeGetLine = regexp.MustCompile(`^\s*(\S+): (.+)$`)

// CurrentDefault inspects `route -n get default` — shelling out rather than using a raw
// PF_ROUTE/AF_ROUTE socket, the same pragmatic choice zarpd/cmd/tunpoc's configureAddress makes,
// and much less code to get wrong than parsing routing socket messages by hand for a one-shot
// query.
func CurrentDefault() (*Physical, error) {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("route -n get default: %w: %s", err, strings.TrimSpace(string(out)))
	}
	p := &Physical{}
	for _, line := range strings.Split(string(out), "\n") {
		m := routeGetLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		key, val := strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
		switch key {
		case "interface":
			p.Interface = val
		case "gateway":
			p.Gateway = net.ParseIP(val)
		}
	}
	if p.Interface == "" {
		return nil, fmt.Errorf("route -n get default: no interface in output:\n%s", out)
	}
	iface, err := net.InterfaceByName(p.Interface)
	if err != nil {
		return nil, fmt.Errorf("interface %s: %w", p.Interface, err)
	}
	p.Index = iface.Index
	return p, nil
}

// BindUDP binds a UDP socket to Physical's interface (IP_BOUND_IF/IPV6_BOUND_IF) so its traffic
// always leaves that interface regardless of the routing table — macOS's equivalent of Android's
// VpnService.protect(fd), see docs/ARCHITECTURE.md §9.2/§9.3.
func (p *Physical) BindUDP(conn *net.UDPConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	v6 := conn.LocalAddr().(*net.UDPAddr).IP.To4() == nil
	var serr error
	cerr := raw.Control(func(fd uintptr) {
		if v6 {
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, p.Index)
		} else {
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, p.Index)
		}
	})
	if cerr != nil {
		return cerr
	}
	return serr
}

// AddHostRoute routes traffic to host through viaInterface (a utun device name). Used by
// tunnelpoc for a narrow, low-blast-radius first test of packet pumping — one host route, not a
// default-route replacement (docs/IMPLEMENTATION_PLAN.md phase 3's remaining, riskier step).
func AddHostRoute(host, viaInterface string) error {
	out, err := exec.Command("route", "-n", "add", "-host", host, "-interface", viaInterface).CombinedOutput()
	if err != nil {
		return fmt.Errorf("route add -host %s -interface %s: %w: %s", host, viaInterface, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// DeleteHostRoute removes a route added by AddHostRoute. Safe to call even if the route is
// already gone (e.g. the interface disappeared first) — logs are the caller's job, this just
// reports whether the OS actually had something to remove.
func DeleteHostRoute(host string) error {
	out, err := exec.Command("route", "-n", "delete", "-host", host).CombinedOutput()
	if err != nil {
		return fmt.Errorf("route delete -host %s: %w: %s", host, err, strings.TrimSpace(string(out)))
	}
	return nil
}
