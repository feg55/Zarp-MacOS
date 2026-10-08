package route

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// DNS override for a full tunnel: while every packet goes into WARP, name resolution should too.
// A resolver handed out by the local network (or the ISP, which is exactly the party that may be
// spoofing answers for blocked sites) is otherwise still the one asked.
//
// This uses `networksetup -setdnsservers` on the network service of the physical interface — the
// same mechanism wg-quick uses — and is built around one rule: **the original setting is written
// to disk before anything is changed, and restored afterwards, even after a crash.** A daemon that
// dies mid-tunnel leaves the backup behind; RecoverStale puts it back the next time zarpd starts,
// before it accepts any request.

// The resolvers are fixed here, never taken from a client: letting a user-level process choose
// the system DNS through a root daemon would be a DNS-hijack primitive.
var (
	CloudflareDNSv4 = []string{"1.1.1.1", "1.0.0.1"}
	CloudflareDNSv6 = []string{"2606:4700:4700::1111", "2606:4700:4700::1001"}
)

type dnsBackup struct {
	Service string `json:"service"`
	// Servers are the service's original manual DNS servers; empty means it had none (automatic,
	// e.g. from DHCP), which is restored by setting the special value "Empty".
	Servers []string `json:"servers"`
}

// DNSOverride applies and restores the DNS servers of one network service.
type DNSOverride struct {
	run        Runner
	backupPath string

	mu     sync.Mutex
	backup *dnsBackup // set while an override is applied (mirrors the file)
}

// NewDNSOverride returns a DNSOverride that keeps its crash-recovery backup at backupPath
// (e.g. /var/db/zarpd/dns-backup.json — root-only).
func NewDNSOverride(r Runner, backupPath string) *DNSOverride {
	return &DNSOverride{run: r, backupPath: backupPath}
}

type serviceEntry struct {
	Name     string
	Device   string
	Disabled bool
}

var (
	serviceLine  = regexp.MustCompile(`^\((\d+|\*)\)\s+(.+?)\s*$`)
	hardwareLine = regexp.MustCompile(`^\(Hardware Port: (.*), Device: (.*)\)\s*$`)
)

// parseServiceOrder parses `networksetup -listnetworkserviceorder`, which prints each service as
//
//	(1) Wi-Fi
//	(Hardware Port: Wi-Fi, Device: en0)
//
// VPN-type services have an empty Device, and a disabled one is numbered "(*)".
func parseServiceOrder(out string) []serviceEntry {
	var entries []serviceEntry
	var cur *serviceEntry
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if m := serviceLine.FindStringSubmatch(line); m != nil {
			entries = append(entries, serviceEntry{Name: m[2], Disabled: m[1] == "*"})
			cur = &entries[len(entries)-1]
			continue
		}
		if m := hardwareLine.FindStringSubmatch(line); m != nil && cur != nil {
			cur.Device = strings.TrimSpace(m[2])
		}
	}
	return entries
}

func (d *DNSOverride) serviceForDevice(device string) (string, error) {
	// VPN-type services (WireGuard, Happ, ...) list an *empty* Device: an empty name must never
	// match one of them and have its DNS rewritten.
	if device == "" {
		return "", errors.New("no network interface given for the DNS override")
	}
	out, err := d.run.Run(networksetup, "-listnetworkserviceorder")
	if err != nil {
		return "", fmt.Errorf("networksetup -listnetworkserviceorder: %w: %s", err, strings.TrimSpace(out))
	}
	for _, e := range parseServiceOrder(out) {
		if e.Device == device && !e.Disabled {
			return e.Name, nil
		}
	}
	return "", fmt.Errorf("no enabled network service uses interface %s", device)
}

// parseDNSServers parses `networksetup -getdnsservers`: one address per line, or a sentence
// ("There aren't any DNS Servers set on Wi-Fi.") when none are set manually.
func parseDNSServers(out string) []string {
	var servers []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if ip := net.ParseIP(line); ip != nil {
			servers = append(servers, line)
		}
	}
	return servers
}

func (d *DNSOverride) currentServers(service string) ([]string, error) {
	out, err := d.run.Run(networksetup, "-getdnsservers", service)
	if err != nil {
		return nil, fmt.Errorf("networksetup -getdnsservers: %w: %s", err, strings.TrimSpace(out))
	}
	return parseDNSServers(out), nil
}

func (d *DNSOverride) setServers(service string, servers []string) error {
	args := []string{"-setdnsservers", service}
	if len(servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, servers...)
	}
	if out, err := d.run.Run(networksetup, args...); err != nil {
		return fmt.Errorf("networksetup -setdnsservers: %w: %s", err, strings.TrimSpace(out))
	}
	return nil
}

// flush drops cached answers so names resolved through the old servers aren't reused. Best effort:
// it only affects how quickly the change is noticed.
func (d *DNSOverride) flush() {
	_, _ = d.run.Run(dscacheutilBin, "-flushcache")
}

// Apply points the network service that owns device (e.g. "en0") at Cloudflare's resolvers,
// remembering what it had. includeV6 adds Cloudflare's IPv6 resolvers (only sensible when IPv6 is
// itself going through the tunnel).
func (d *DNSOverride) Apply(device string, includeV6 bool) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	// A backup still on disk means an earlier run died with the override applied: put that back
	// first, so the "original" about to be recorded is the real original, not our own leftovers.
	if err := d.restoreLocked(); err != nil {
		return fmt.Errorf("restoring DNS left over from a previous run: %w", err)
	}

	service, err := d.serviceForDevice(device)
	if err != nil {
		return err
	}
	orig, err := d.currentServers(service)
	if err != nil {
		return err
	}
	b := &dnsBackup{Service: service, Servers: orig}
	if err := d.writeBackup(b); err != nil {
		return fmt.Errorf("saving the original DNS settings: %w", err)
	}
	servers := append([]string(nil), CloudflareDNSv4...)
	if includeV6 {
		servers = append(servers, CloudflareDNSv6...)
	}
	if err := d.setServers(service, servers); err != nil {
		// Nothing was changed (or we can't tell): the backup is what the service has now at worst.
		_ = d.setServers(service, orig)
		d.removeBackup()
		return err
	}
	d.backup = b
	d.flush()
	return nil
}

// Restore puts the original DNS servers back. A no-op when nothing is applied. If the restore
// itself fails the backup stays on disk, so it is retried on the next run instead of being lost.
func (d *DNSOverride) Restore() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.restoreLocked()
}

// RecoverStale restores DNS from a backup left behind by a run that didn't get to clean up. Call
// once at startup, before serving requests.
func (d *DNSOverride) RecoverStale() error { return d.Restore() }

func (d *DNSOverride) restoreLocked() error {
	b := d.backup
	if b == nil {
		var err error
		if b, err = d.readBackup(); err != nil {
			return err
		}
	}
	if b == nil {
		return nil
	}
	if err := d.setServers(b.Service, b.Servers); err != nil {
		return err
	}
	d.backup = nil
	d.removeBackup()
	d.flush()
	return nil
}

func (d *DNSOverride) writeBackup(b *dnsBackup) error {
	data, err := json.Marshal(b)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(d.backupPath), 0o700); err != nil {
		return err
	}
	tmp := d.backupPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, d.backupPath)
}

// readBackup returns nil, nil when there is no backup file.
func (d *DNSOverride) readBackup() (*dnsBackup, error) {
	data, err := os.ReadFile(d.backupPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var b dnsBackup
	if err := json.Unmarshal(data, &b); err != nil || b.Service == "" {
		// A backup we can't read can't be restored; keeping it would make every future start
		// fail on it. Drop it and say so.
		d.removeBackup()
		return nil, fmt.Errorf("unreadable DNS backup %s discarded", d.backupPath)
	}
	for _, s := range b.Servers {
		if net.ParseIP(s) == nil {
			d.removeBackup()
			return nil, fmt.Errorf("DNS backup %s holds an invalid address %q and was discarded", d.backupPath, s)
		}
	}
	return &b, nil
}

func (d *DNSOverride) removeBackup() { _ = os.Remove(d.backupPath) }
