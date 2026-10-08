// Package route handles the routing side of docs/ARCHITECTURE.md §9.3: keeping the WARP control
// socket on the physical interface so it can never loop back through the tunnel it's still
// establishing, adding and removing the routes that send traffic into the utun (one narrow host
// route for a scan, or the full-tunnel set — see fulltunnel.go), and the DNS override that goes
// with a full tunnel (dns.go).
//
// Everything that changes system state goes through a Runner, so the exact commands, their order
// and — most importantly — the rollback when one of them fails are unit-testable without root.
// The commands themselves use absolute paths: this runs as a root LaunchDaemon, so it must not
// depend on (or be steerable through) $PATH.
package route

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	routeBin       = "/sbin/route"
	ifconfigBin    = "/sbin/ifconfig"
	networksetup   = "/usr/sbin/networksetup"
	dscacheutilBin = "/usr/bin/dscacheutil"
)

// Runner runs a system command and returns its combined stdout+stderr.
type Runner interface {
	Run(name string, args ...string) (string, error)
}

// ExecRunner is the real Runner: it executes the command, with a timeout so a wedged system tool
// can never hang the daemon.
type ExecRunner struct {
	Timeout time.Duration // default 15s
}

func (e ExecRunner) Run(name string, args ...string) (string, error) {
	timeout := e.Timeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(out), err
}

// Router changes and inspects the routing table and interface addresses.
type Router struct {
	run Runner
}

// New returns a Router running its commands through r (ExecRunner{} for the real thing).
func New(r Runner) *Router { return &Router{run: r} }

var std = New(ExecRunner{})

// Physical describes the interface/gateway that ordinary traffic uses right now, captured before
// any tunnel-related route changes so the WARP control socket can be bound to it explicitly
// regardless of what the routing table looks like once the tunnel is up.
type Physical struct {
	Interface string
	Index     int
	Gateway   net.IP
}

// IsTunnel reports whether the "physical" interface is itself a tunnel — i.e. another VPN or proxy
// currently owns the default route. On such a machine WARP traffic would ride inside the other
// tunnel, which makes scan results meaningless and a full-tunnel takeover a fight over the same
// routes.
func (p *Physical) IsTunnel() bool { return strings.HasPrefix(p.Interface, "utun") }

var routeGetLine = regexp.MustCompile(`^\s*([A-Za-z][A-Za-z ]*?):\s*(.*?)\s*$`)

// parseRouteGet turns `route -n get` output into key -> value ("interface" -> "en0", ...).
func parseRouteGet(out string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		if sub := routeGetLine.FindStringSubmatch(line); sub != nil {
			if _, dup := m[sub[1]]; !dup {
				m[sub[1]] = sub[2]
			}
		}
	}
	return m
}

// CurrentDefault inspects `route -n get default` — shelling out rather than using a raw
// PF_ROUTE/AF_ROUTE socket, the same pragmatic choice zarpd/cmd/tunpoc's configureAddress makes,
// and much less code to get wrong than parsing routing socket messages by hand for a one-shot
// query.
func (r *Router) CurrentDefault() (*Physical, error) {
	out, err := r.run.Run(routeBin, "-n", "get", "default")
	if err != nil {
		return nil, fmt.Errorf("route -n get default: %w: %s", err, strings.TrimSpace(out))
	}
	fields := parseRouteGet(out)
	p := &Physical{Interface: fields["interface"]}
	if gw := fields["gateway"]; gw != "" {
		p.Gateway = net.ParseIP(gw)
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
	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return fmt.Errorf("BindUDP: %T is not a UDP address", conn.LocalAddr())
	}
	return p.bind(raw, local.IP.To4() == nil)
}

// Control has net.Dialer's Control signature — pass it as a Dialer's Control field to bind
// whatever socket the dialer creates to Physical's interface before it connects, the TCP
// equivalent of BindUDP. address is the resolved "ip:port" net.Dialer.Control hands it, which is
// enough to tell v4 apart from v6 without needing a separate flag from the caller.
func (p *Physical) Control(_, address string, c syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("route.Control: %s: %w", address, err)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return fmt.Errorf("route.Control: %q is not an IP", host)
	}
	return p.bind(c, ip.To4() == nil)
}

func (p *Physical) bind(c syscall.RawConn, v6 bool) error {
	var serr error
	cerr := c.Control(func(fd uintptr) {
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

// ---- interface addresses

// ConfigureAddress gives a utun its IPv4 point-to-point address (the same address on both ends,
// as the WARP tunnel hands out a single /32) and brings it up.
func (r *Router) ConfigureAddress(name, ipv4 string) error {
	if out, err := r.run.Run(ifconfigBin, name, "inet", ipv4, ipv4, "up"); err != nil {
		return fmt.Errorf("configuring %s: %w: %s", name, err, strings.TrimSpace(out))
	}
	return nil
}

// ConfigureAddress6 adds the tunnel's IPv6 address to a utun (the `alias` form wg-quick uses, so
// it adds to rather than replaces what the interface already has).
func (r *Router) ConfigureAddress6(name, ipv6 string) error {
	if out, err := r.run.Run(ifconfigBin, name, "inet6", ipv6, "prefixlen", "128", "alias"); err != nil {
		return fmt.Errorf("configuring %s (IPv6): %w: %s", name, err, strings.TrimSpace(out))
	}
	return nil
}

// ---- routes

// ErrRouteExists is returned by Add* when the destination already has a route — most often
// because another VPN or proxy installed the same ones.
var ErrRouteExists = fmt.Errorf("route already exists")

func familyFlag(dst string) string {
	if strings.Contains(dst, ":") {
		return "-inet6"
	}
	return "-inet"
}

// AddHostRoute routes traffic to host through viaInterface (a utun device name). Used for the
// narrow scan route: one host route, not a default-route replacement.
func (r *Router) AddHostRoute(host, viaInterface string) error {
	out, err := r.run.Run(routeBin, "-n", "add", "-host", host, "-interface", viaInterface)
	return routeErr(err, out, "add -host "+host+" -interface "+viaInterface)
}

// AddNetRoute routes a CIDR through viaInterface, e.g. ("0.0.0.0/1", "utun5") or ("::/1", "utun5")
// — wg-quick's own invocation for the same job on macOS.
func (r *Router) AddNetRoute(cidr, viaInterface string) error {
	out, err := r.run.Run(routeBin, "-n", "add", familyFlag(cidr), cidr, "-interface", viaInterface)
	return routeErr(err, out, "add "+cidr+" -interface "+viaInterface)
}

func routeErr(err error, out, what string) error {
	if err == nil {
		return nil
	}
	msg := strings.TrimSpace(out)
	if strings.Contains(msg, "File exists") {
		return fmt.Errorf("route %s: %w (%s)", what, ErrRouteExists, msg)
	}
	return fmt.Errorf("route %s: %w: %s", what, err, msg)
}

// routeInterface returns which interface the routing table would use for dst ("" if there is no
// route at all). get with a CIDR or host returns the *best match*, which may be an unrelated
// broader route — the caller compares the interface to decide whether the match is its own.
func (r *Router) routeInterface(dst string, host bool) (string, error) {
	args := []string{"-n", "get"}
	if host {
		args = append(args, "-host")
	} else {
		args = append(args, familyFlag(dst))
	}
	args = append(args, dst)
	out, err := r.run.Run(routeBin, args...)
	if err != nil {
		if strings.Contains(out, "not in table") {
			return "", nil
		}
		return "", fmt.Errorf("route get %s: %w: %s", dst, err, strings.TrimSpace(out))
	}
	return parseRouteGet(out)["interface"], nil
}

// DeleteRouteIfOurs removes the route for dst (a host address if host is true, else a CIDR) only
// when it currently points at viaInterface — i.e. is the one this process added. A route to the
// same destination that someone else owns (the user's own static route, another VPN's) is left
// alone, and a route that is already gone (the interface disappeared first, which takes its routes
// with it) is not an error. It reports whether it deleted anything.
func (r *Router) DeleteRouteIfOurs(dst string, host bool, viaInterface string) (bool, error) {
	iface, err := r.routeInterface(dst, host)
	if err != nil {
		return false, err
	}
	if iface != viaInterface {
		return false, nil
	}
	args := []string{"-n", "delete"}
	if host {
		args = append(args, "-host")
	} else {
		args = append(args, familyFlag(dst))
	}
	args = append(args, dst)
	if out, err := r.run.Run(routeBin, args...); err != nil {
		if strings.Contains(out, "not in table") {
			return false, nil
		}
		return false, fmt.Errorf("route delete %s: %w: %s", dst, err, strings.TrimSpace(out))
	}
	return true, nil
}

// ---- package-level conveniences for the proof-of-concept commands (cmd/*poc), which predate
// Router and run against the real system.

// CurrentDefault is Router.CurrentDefault against the real system.
func CurrentDefault() (*Physical, error) { return std.CurrentDefault() }

// AddHostRoute is Router.AddHostRoute against the real system.
func AddHostRoute(host, viaInterface string) error { return std.AddHostRoute(host, viaInterface) }

// DeleteHostRoute removes a route added by AddHostRoute, whichever interface it points at — the
// proof-of-concept commands own the single host route they add. (zarpd itself uses
// Router.DeleteRouteIfOurs, which never removes a route it didn't create.)
func DeleteHostRoute(host string) error {
	out, err := std.run.Run(routeBin, "-n", "delete", "-host", host)
	if err != nil && !strings.Contains(out, "not in table") {
		return fmt.Errorf("route delete -host %s: %w: %s", host, err, strings.TrimSpace(out))
	}
	return nil
}
