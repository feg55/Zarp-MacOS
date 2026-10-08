// zarpd is the privileged daemon Zarp.app talks to over IPC (docs/ARCHITECTURE.md §1, §9.4):
// WARP account registration (only when the app asks, after the user accepted Cloudflare's terms),
// MASQUE dial with a strategy applied, the utun and its routes — a single measurement route for a
// scan, or all of the machine's traffic for a persistent connection — and the cdn-cgi/trace
// measurement ZarpEngine needs to score a strategy: everything
// WarpConnectionProvider/WarpProbe (EngineProtocols.swift) ask for, nothing ZarpEngine already
// does itself (scan ordering, scoring, self-healing stay in Swift).
//
// Needs root (utun, routes, DNS). Installed as a LaunchDaemon via SMAppService
// (App/Sources/Zarp/ZarpdInstaller.swift); can also be run by hand (`sudo zarpd`) for development.
package main

import (
	"context"
	"flag"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/feg55/zarp-macos/zarpd/daemon"
	"github.com/feg55/zarp-macos/zarpd/ipc"
	"github.com/feg55/zarp-macos/zarpd/route"
)

// version is stamped at build time from the app's MARKETING_VERSION (project.yml's "Build and
// embed zarpd daemon" phase passes -ldflags "-X main.version=..."), so the app and daemon can tell
// when a stale daemon is still running after an app update. "dev" marks an unstamped build.
var version = "dev"

func main() {
	socketPath := flag.String("socket", "/var/run/zarpd.sock", "Unix domain socket to listen on")
	blobsDir := flag.String("blobs", defaultBlobsDir(), "directory holding the fake-packet blobs (Resources/blobs)")
	configPath := flag.String("config", "/Library/Application Support/Zarp/zarp-warp-config.json", "WARP account config path")
	measureHost := flag.String("measure-host", "1.1.1.1", "IP used for the cdn-cgi/trace measurement and its narrow per-connection route")
	mtu := flag.Int("mtu", 1280, "tunnel MTU")
	logPath := flag.String("log", "/Library/Logs/Zarp/zarpd.log", `daemon log file, size-capped and rotated ("-" logs to stderr only)`)
	dnsBackup := flag.String("dns-backup", "/var/db/zarpd/dns-backup.json", "where the original DNS settings are saved while a full tunnel overrides them")
	routeJournal := flag.String("route-journal", "/var/db/zarpd/exclusions.json", "where the endpoint exclusion route of a full tunnel is recorded, so a crash can't leave it behind")
	testLease := flag.Duration("test-lease", 2*time.Minute, "how long a non-persistent (test) connection may stay open before it is reaped")
	anyPeer := flag.Bool("allow-any-peer", false, "DEVELOPMENT ONLY: skip the check that the client is root or the console user")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()

	if *showVersion {
		os.Stdout.WriteString(version + "\n")
		return
	}

	ring := daemon.NewLogRing(1000)
	closeLog := setupLogging(ring, *logPath)
	defer closeLog()

	// Put the original DNS back if a previous run died with a full tunnel's override applied —
	// before anything else, so a crash never leaves the machine on borrowed resolvers.
	dns := route.NewDNSOverride(route.ExecRunner{}, *dnsBackup)
	if err := dns.RecoverStale(); err != nil {
		log.Printf("zarpd: restoring DNS from a previous run: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	router := route.New(route.ExecRunner{})
	// Likewise delete the exclusion route a previous run died without removing.
	journal := route.NewJournal(*routeJournal)
	for _, err := range journal.Recover(router) {
		log.Printf("zarpd: cleaning up routes from a previous run: %v", err)
	}
	mgr := daemon.NewManager(daemon.Config{
		Opener: &daemon.RealOpener{
			ConfigPath: *configPath, BlobsDir: *blobsDir, MeasureHost: *measureHost, MTU: *mtu,
			Router: router, DNS: dns, Journal: journal, Lifetime: ctx, Logf: log.Printf,
		},
		Accounts:    &daemon.FileAccounts{Path: *configPath, DeviceName: "Zarp macOS"},
		Measurer:    &daemon.TraceMeasurer{},
		Logs:        ring,
		Version:     version,
		MeasureHost: *measureHost,
		TestLease:   *testLease,
		Restart:     func() { os.Exit(1) }, // non-zero on purpose: launchd's KeepAlive relaunches only on an unsuccessful exit
		Logf:        log.Printf,
	})

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("zarpd: shutting down")
		cancel() // ends Serve and aborts any open still dialing
	}()

	opts := ipc.Options{Logf: log.Printf}
	if !*anyPeer {
		opts.AllowPeer = ipc.ConsoleUserPolicy()
	} else {
		log.Println("zarpd: WARNING: -allow-any-peer is set — the console-user check is off")
	}

	log.Printf("zarpd %s: listening on %s (blobs=%s config=%s measure-host=%s)", version, *socketPath, *blobsDir, *configPath, *measureHost)
	err := ipc.Serve(ctx, *socketPath, mgr.Handle, opts)
	// Whether Serve ended because of a signal or a failure, every tunnel is torn down — routes and
	// DNS back to normal — before the process exits.
	mgr.CloseAll()
	if err != nil {
		log.Printf("zarpd: ipc.Serve: %v", err)
		closeLog()
		os.Exit(1)
	}
}

// setupLogging routes the standard logger to the in-memory ring (which the app pulls over IPC) and
// to the log file — or to stderr when path is "-". It returns a function that flushes and closes
// the file.
func setupLogging(ring *daemon.LogRing, path string) (closeFn func()) {
	log.SetFlags(0) // the ring stamps lines itself; the file sink below adds a timestamp prefix
	var sink io.Writer = timestamped{os.Stderr}
	closeFn = func() {}
	if path != "-" {
		f, err := newRotatingFile(path, 2<<20)
		if err != nil {
			// Not fatal: a daemon that can't write its log file should still run (and say so).
			log.SetOutput(newNoiseFilter(io.MultiWriter(ring, timestamped{os.Stderr})))
			log.Printf("zarpd: cannot open the log file %s: %v (logging to stderr)", path, err)
			return closeFn
		}
		sink = timestamped{f}
		closeFn = func() { _ = f.Close() }
	}
	log.SetOutput(newNoiseFilter(io.MultiWriter(ring, sink)))
	return closeFn
}

// defaultBlobsDir looks for a "Resources/blobs" subdirectory under each of the executable's
// ancestor directories in turn (closest first) and uses the first one that actually exists —
// covers both the installed-bundle layout (Zarp.app/Contents/{MacOS,Resources}/, one level up
// from the executable) and the repo-relative dev layout (running as /tmp/zarpd or similar next to
// a checkout, three levels up) without assuming which one applies. Nothing matching just means
// -blobs must be passed explicitly.
func defaultBlobsDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "Resources/blobs"
	}
	if abs, err := filepath.Abs(exe); err == nil {
		exe = abs
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Dir(exe)
	for i := 0; i < 6; i++ {
		if candidate := filepath.Join(dir, "Resources", "blobs"); dirExists(candidate) {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return filepath.Join(filepath.Dir(exe), "..", "..", "..", "Resources", "blobs")
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
