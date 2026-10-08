package route

import (
	"errors"
	"fmt"
	"net/netip"
	"sync"
)

// Full tunnel: make a utun carry all of the machine's traffic.
//
// The shape is the one wg-quick uses on macOS, and it is chosen for what happens when things go
// wrong, not just for when they go right: instead of replacing the default route, two routes per
// address family that together cover everything — 0.0.0.0/1 and 128.0.0.0/1 (and ::/1, 8000::/1) —
// are added *through the utun interface*. They are more specific than the default route, so they
// win, and the real default route is never touched. Because they are bound to the interface, the
// kernel deletes them the instant the interface goes away — even if zarpd is killed with -9 — so a
// crash fails open (traffic simply goes back out the normal way) instead of leaving the machine
// with a default route into a tunnel that no longer exists.
//
// The one thing those routes cannot do alone is carry the tunnel's own control connection: that
// connection (QUIC/TCP to the WARP endpoint) must keep leaving through the physical network, or the
// tunnel would try to run inside itself. Binding its socket to the physical interface (IP_BOUND_IF)
// looked sufficient and is not — on the primary network service a bound socket falls back to the
// ordinary table, meets the more specific /1 through the utun, and fails with ENETUNREACH (observed on
// a real Mac: the session died within a millisecond of the routes going in). So the endpoint gets an
// *exclusion route* through the physical gateway first (exclusion.go), more specific than any /1; it is
// journaled on disk so a crash can't leave it behind, and removed last on the way out.

// v4Halves and v6Halves are the two routes per family that together span the whole address space.
var (
	v4Halves = []string{"0.0.0.0/1", "128.0.0.0/1"}
	v6Halves = []string{"::/1", "8000::/1"}
)

// FullTunnelConfig describes one full-tunnel setup.
type FullTunnelConfig struct {
	// Utun is the tunnel interface, already created, addressed and up.
	Utun string
	// IPv6Addr is the tunnel's IPv6 address; when empty, only IPv4 is routed.
	IPv6Addr string
	// OverrideDNS also points the active network service's DNS at Cloudflare while the tunnel is
	// up (see DNSOverride).
	OverrideDNS bool
	// Physical is the interface the machine was using before the tunnel: the DNS override targets
	// its network service, and the exclusion route goes through its gateway.
	Physical *Physical
	// Exclude is the WARP endpoint the tunnel's control connection talks to (IPv4). Required: without
	// a route that keeps it on the physical network, the /1 routes swallow the connection that
	// carries the tunnel.
	Exclude netip.Addr
	// Journal records the exclusion route on disk so that a crashed daemon's leftovers are removed at
	// the next start. May be nil (tests).
	Journal *Journal
}

// FullTunnel is an applied full-tunnel configuration that knows how to take itself apart.
type FullTunnel struct {
	mu   sync.Mutex
	undo []undoStep
}

type undoStep struct {
	what string
	fn   func() error
}

func (ft *FullTunnel) push(what string, fn func() error) {
	ft.undo = append(ft.undo, undoStep{what, fn})
}

// EnableFullTunnel applies cfg. IPv4 routing is mandatory: if either IPv4 route can't be added
// everything done so far is rolled back and the error returned, leaving the machine exactly as it
// was. IPv6 and the DNS override are best-effort — each that fails is skipped, rolled back on its
// own, and reported in warnings, because a working IPv4 tunnel with a note beats no tunnel at all.
//
// dns may be nil when cfg.OverrideDNS is false.
func (r *Router) EnableFullTunnel(cfg FullTunnelConfig, dns *DNSOverride) (ft *FullTunnel, warnings []string, err error) {
	if cfg.Utun == "" {
		return nil, nil, errors.New("full tunnel: no interface")
	}
	if !cfg.Exclude.IsValid() || cfg.Physical == nil {
		return nil, nil, errors.New("full tunnel: the endpoint to keep off the tunnel and the physical interface are required")
	}
	ft = &FullTunnel{}

	// First: the tunnel's own connection must be safe before anything can swallow it.
	undoExclusion, err := r.AddExclusion(cfg.Exclude, cfg.Physical, cfg.Journal)
	if err != nil {
		return nil, nil, fmt.Errorf("cannot keep the WARP connection off the tunnel: %w", err)
	}
	ft.push("exclusion route", undoExclusion)

	for _, cidr := range v4Halves {
		if err := r.AddNetRoute(cidr, cfg.Utun); err != nil {
			ft.Disable() // nothing has been committed yet: put everything back
			if errors.Is(err, ErrRouteExists) {
				return nil, nil, fmt.Errorf("another VPN or proxy already routes %s (%w) — turn it off first", cidr, err)
			}
			return nil, nil, err
		}
		cidr := cidr
		ft.push("route "+cidr, func() error {
			_, err := r.DeleteRouteIfOurs(cidr, false, cfg.Utun)
			return err
		})
	}

	v6Active := false
	if cfg.IPv6Addr != "" {
		if err := r.ConfigureAddress6(cfg.Utun, cfg.IPv6Addr); err != nil {
			warnings = append(warnings, "IPv6 is not routed through the tunnel: "+err.Error())
		} else {
			added := 0
			var v6err error
			for _, cidr := range v6Halves {
				if v6err = r.AddNetRoute(cidr, cfg.Utun); v6err != nil {
					break
				}
				cidr := cidr
				ft.push("route "+cidr, func() error {
					_, err := r.DeleteRouteIfOurs(cidr, false, cfg.Utun)
					return err
				})
				added++
			}
			if v6err != nil {
				// Half a pair would route half of the IPv6 space into the tunnel: take back what
				// was added so IPv6 is either fully tunnelled or left alone.
				for i := 0; i < added; i++ {
					last := ft.undo[len(ft.undo)-1]
					ft.undo = ft.undo[:len(ft.undo)-1]
					_ = last.fn()
				}
				warnings = append(warnings, "IPv6 is not routed through the tunnel: "+v6err.Error())
			} else {
				v6Active = true
			}
		}
	}

	if cfg.OverrideDNS {
		if dns == nil {
			warnings = append(warnings, "DNS was not overridden: no DNS manager available")
		} else if err := dns.Apply(cfg.Physical.Interface, v6Active); err != nil {
			warnings = append(warnings, "DNS was not overridden: "+err.Error())
		} else {
			ft.push("dns", dns.Restore)
		}
	}
	return ft, warnings, nil
}

// Disable undoes the configuration in reverse order and returns every error it hit (it always
// attempts every step, so one failure can't strand the others). Safe to call more than once.
func (ft *FullTunnel) Disable() []error {
	ft.mu.Lock()
	steps := ft.undo
	ft.undo = nil
	ft.mu.Unlock()

	var errs []error
	for i := len(steps) - 1; i >= 0; i-- {
		if err := steps[i].fn(); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", steps[i].what, err))
		}
	}
	return errs
}
