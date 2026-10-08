# Architecture

How Zarp for macOS is put together, and why. This describes the code as it is today; how it got
here (the rejected designs, the phase-by-phase log of what was verified on a real Mac) is kept in
[history/](history/).

Target: macOS 14+ on Apple Silicon (arm64 only). Swift (SwiftUI + AppKit) for the app, Go for the
networking daemon.

- [1. Overview](#1-overview)
- [2. Code layout](#2-code-layout)
- [3. Connecting through DPI](#3-connecting-through-dpi)
- [4. The engine: scanning, scoring, self-healing](#4-the-engine-scanning-scoring-self-healing)
- [5. The IPC protocol](#5-the-ipc-protocol)
- [6. Routing, DNS and fail-safety](#6-routing-dns-and-fail-safety)
- [7. The privileged daemon: install and update](#7-the-privileged-daemon-install-and-update)
- [8. User interface](#8-user-interface)
- [9. Data, logs and privacy](#9-data-logs-and-privacy)
- [10. Security model](#10-security-model)
- [11. Licensing and provenance](#11-licensing-and-provenance)
- [12. Testing](#12-testing)
- [13. Known limitations](#13-known-limitations)

## 1. Overview

Zarp makes [Cloudflare WARP](https://one.one.one.one/) usable on networks whose DPI (deep packet
inspection) blocks the WARP handshake. It does **not** drive or wrap the official WARP client. Zarp is
itself a WARP client: it registers a WARP account, opens a MASQUE tunnel (CONNECT-IP over HTTP/3 or
HTTP/2) and moves the Mac's packets through it. Because Zarp makes the connection itself, it can apply
the "strategy" (a few decoy packets sent first, or a split of the TLS ClientHello) in exactly the place
the DPI looks at: the first packets of that connection.

```
┌──────────────── Zarp.app (your user, unprivileged, SwiftUI/AppKit) ────────────────┐
│ UI ── ZarpEngine (scan, score, self-heal; ZarpCore, no networking of its own)       │
│        └── ZarpdClient (ZarpdIPC) ──── newline-delimited JSON over a Unix socket ──┼──┐
└──────────────────────────────────────────────────────────────────────────────────────┘  │
                                                                                          ▼
┌──────────────────── zarpd (root; LaunchDaemon registered with SMAppService) ─────────────────┐
│ • WARP account registration (only after the user accepted Cloudflare's terms)                │
│ • DPI strategy executor: opens the UDP/TCP socket itself, sends the decoys on it, then hands │
│   that same socket to the real MASQUE/QUIC dial                                              │
│ • MASQUE session (HTTP/3 or HTTP/2), CONNECT-IP: pumps packets between a utun and the session│
│ • routes, DNS override, crash recovery; the cdn-cgi/trace measurement used to score strategies│
└───────────────────────────────┬──────────────────────────────────────────────────────────────┘
                                │ physical interface only (never routed back into the utun)
                                ▼
                    Cloudflare WARP MASQUE endpoint (162.159.x.x)
```

Why two processes. Creating a utun device and changing routes and DNS needs root; a SwiftUI app should
not run as root. So a small root daemon (`zarpd`) does everything privileged and everything that has to
happen on the connection's own socket, and the app does everything else. The app never runs a shell
command with elevated rights; it asks the daemon, over a socket, to do a small, fixed set of things
(§5), and the daemon validates every field (§10).

Why scanning lives in Swift, not in the daemon. Which strategy to try next, how to score it, when to
re-check it and when to heal are product decisions that need no privileges and are easiest to test as
pure logic. The daemon only ever executes one thing at a time: "open a connection with this strategy",
"measure through it", "close it".

## 2. Code layout

```
App/Sources/Zarp/            SwiftUI app: AppViewModel (wiring, monitor loop), ZarpApp (scenes, menu
                              bar, app delegate), Screens/ (main window, strategies, settings, log,
                              close confirmation), Components/ (power button, toggles, steppers),
                              ZarpdInstaller (SMAppService), SystemNetworkInspector (foreign-VPN check)
Packages/ZarpCore/           SwiftPM package, Foundation only, tests run without Xcode
  Sources/ZarpCore/            Strategy/ (model, catalog, args parser, readiness, custom strategies),
                              Results/ (scoring), Settings/, Localization/, Logging/,
                              Engine/ (ZarpEngine actor; EngineProtocols = the network seam), Support/
  Sources/ZarpdIPC/            ZarpdClient: the Swift side of the daemon protocol
  Tests/ZarpCoreTests, Tests/ZarpdIPCTests (the client against a fake Unix-socket daemon)
zarpd/                       the Go daemon (its own module)
  cmd/zarpd/                   entry point: flags, rotating log file + in-memory ring, signals
  cmd/zarpctl/                 command-line client for the protocol (development, integration test)
  daemon/                      Manager (the connection registry), request handlers, the real Opener
                              (dial + utun + routes), endpoint pool, trace measurement, log ring
  ipc/                         protocol types, request validation, socket server (peer check, limits)
  route/                       routes, utun addressing, full tunnel, endpoint exclusion + journal, DNS
  tunnel/                      the utun <-> MASQUE packet pump
  warp/                        account registration, MASQUE dial (H3 and H2), strategy executor
Resources/Lang/              UI strings, one `key = value` file per language
Resources/blobs/             fake-packet captures (QUIC Initial, TLS ClientHello, STUN) from zapret2
Resources/Licenses/          third-party notices bundled into the app
scripts/                     package.sh (DMG), test-integration.sh (real network), gen-notices.sh, ...
project.yml                  XcodeGen spec; Zarp.xcodeproj is generated from it and not committed
```

`ZarpCore` contains all strategy, scan, settings and localization logic and has no AppKit, SwiftUI or
network dependency. `Engine/EngineProtocols.swift` is the entire seam where networking plugs in
(`WarpConnectionProvider`, `WarpProbe`, `NetworkInspector`); the app wires `ZarpdClient` into it and the
tests wire scripted fakes into it.

## 3. Connecting through DPI

**A strategy** is a transport plus a [zapret2](https://github.com/bol-van/zapret2)-style argument
string, for example `--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6`.
`StrategyArgsParser` turns it into a `DesyncPlan` (which fake blobs, how many times, with what TTL; or
where to split a ClientHello). The plan is what crosses to the daemon, flattened and validated; the daemon
never sees the original string. A built-in catalog of 20 strategies ships with the app, and a user can add
their own in `strategies.txt` (`name | h3/h2/wg | args`).

**The same-socket trick (HTTP/3).** DPI that blocks WARP recognises the QUIC Initial packet sent to a WARP
address. A decoy Initial that the DPI believes is the real one (a captured QUIC Initial for a harmless
site such as google.com) is sent first, from the *same* 5-tuple, and the server ignores it. The sequence,
all in one Go function in `zarpd/warp`:

1. open the UDP socket and bind it to the physical interface (`IP_BOUND_IF`), so it can never loop back
   into the tunnel it is about to carry;
2. for each fake step, optionally set a short TTL (`ip_ttl`, `ip6_ttl`) so the decoy dies before the server,
   send the blob *N* times, restore the TTL;
3. hand that same `net.UDPConn` to quic-go, so the real Initial leaves through the identical 5-tuple.

**Split and disorder (HTTP/2).** For the HTTP/2 transport the ClientHello is split across several TCP
segments (`split`), optionally with the first segment sent at TTL 1 so it dies on the first hop and is
retransmitted later (`disorder`). This wraps the dial's `net.Conn`: the first write, recognised by the TLS
record byte `0x16`, is cut at configured offsets (literal, or relative to the SNI such as `midsld`).

**What macOS cannot do.** Tricks that need raw sockets or packet injection have no equivalent in an
unprivileged-socket model and are shown as "not available on macOS" with the reason as a tooltip; they are
never attempted (the daemon is only sent what a `DesyncPlan` describes, and an unsupported strategy has no
plan). Of the 20 built-in strategies 11 run: seven QUIC fake variants (including the `ttl=4` ones and
google + vk), `split` and `disorder` over HTTP/2, and the two direct (no desync) controls. The nine that do
not: `badsum` (checksum tampering), four WireGuard variants (WireGuard transport is not implemented), and
the TLS ones that need `tcp_md5`, `tcp_seq`, `seqovl` or `hostfakesplit`.

**The packet pump.** `zarpd/tunnel` copies packets between a real utun (wireguard-go's darwin `tun`
package) and the MASQUE session's CONNECT-IP stream directly, in both directions. There is no userspace
network stack and no local SOCKS proxy in between (the Android app needs both because Android's VPN API
gives it a different primitive).

**Endpoints.** By default the account's own endpoint is used. During a scan, "isolate tests" gives every
attempt a different WARP endpoint (the request carries an `isolated-N` token; the daemon maps consecutive
*N* onto a small pool of addresses and ports, address varying fastest) so that an independent re-check
really leaves from a fresh 5-tuple. A client may also name an endpoint, but only inside Cloudflare's WARP
address ranges (§10).

## 4. The engine: scanning, scoring, self-healing

`ZarpEngine` is a Swift actor: one operation at a time (connect, quick or full scan, test selected, use,
disconnect, cancel), written only against the protocols in `EngineProtocols.swift`.

- **Scoring.** A test passes if the tunnel comes up and `cdn-cgi/trace` through it reports `warp=on`
  (or `plus`). Score = connect time + 4 x ping, lower is better.
- **Confirmation.** A strategy that passes once is re-tested on a different endpoint; passing both earns
  "works ✔✔". The kept result is the worse connect time and the average ping of the two. A strategy that
  only passed thanks to something left over from a previous attempt does not survive the second test.
- **Connect.** Use the saved strategy; if that fails, the other confirmed strategies by score; if none is
  left, run a quick scan (which stops after *N* working strategies, 3 by default) and use the best.
- **Self-healing.** If the saved strategy stops working the engine tries the other verified ones before it
  searches again.
- **Unsupported strategies** (§3) are never sent to the daemon and never counted as failures.
- **Losing the connection.** When the daemon reports that the tunnel ended by itself (session lost, network
  changed) the engine reconnects quietly with the same strategy: three attempts with back-off (2 s, 10 s,
  30 s), at most three such cycles in ten minutes, and never a rescan or a mark against the strategy.
- **Cancellation** is honoured at every await point, including mid-dial (the request's socket is shut down
  and the daemon aborts the dial). An epoch counter discards the result of anything that finished after a
  newer operation had already started.

`AppViewModel` runs a monitor loop every four seconds: ping the daemon, reconcile with its status, pull its
log lines into the app's log. Reconciling means the GUI can start (or restart after a crash) while a tunnel
is already up and adopt it instead of fighting it. If the daemon is older than the app (an app update leaves
the old process running) the app restarts it once. Before a connection the app warns about another VPN
(a dialog; you can continue, but the daemon refuses a full tunnel while another VPN owns the default route)
and, the first time, asks for consent to create a WARP account.

## 5. The IPC protocol

Protocol version **2**, defined in `zarpd/ipc/protocol.go` (Go) and `ZarpdClient.swift` (Swift) and pinned
by golden wire-format fixtures that both test suites share.

- **Transport.** Newline-delimited JSON over a Unix domain socket, `/var/run/zarpd.sock`: one request per
  line, one response per line, correlated by `id`. No code generation on either side.
- **Methods.** `ping` (version, pid, protocol, whether an account exists), `status` (the one persistent
  connection, if any, and the last unrequested loss), `register` (create the WARP account; idempotent),
  `open` (dial with a flattened strategy; test connection or persistent; optional full tunnel and DNS),
  `close`, `measure` (trace through a connection), `logs` (lines since a cursor), `restart`.
- **Errors** carry a machine-readable `code`: `bad_request`, `forbidden`, `busy`, `no_account`,
  `foreign_vpn`, `unsupported`, `cancelled`, `internal`, plus `timedOut` for the scan loop's timeout-versus-
  failure distinction.
- **Lifetime.** A client keeps its connection open until it has read the response. The server treats the
  client going away as "abandon what is in flight for it", which is how pressing Cancel aborts an `open`
  that is still dialing.
- **Versioning.** The app compares `ping.protocol` with the version it was built for, so a stale daemon
  left running after an update is noticed instead of failing in confusing ways.

## 6. Routing, DNS and fail-safety

A scan's test connection routes one host (`1.1.1.1`, the measurement target) through the utun, which is all
a measurement needs. A persistent connection (`routeAll`, the normal "Connect") routes everything.

**Routes.** The full tunnel uses the shape `wg-quick` uses on macOS: `0.0.0.0/1` and `128.0.0.0/1` (and
`::/1`, `8000::/1` when WARP assigned an IPv6 address) added *through the utun interface*. They are more
specific than the default route, so they win, and the real default route is never touched. Because they are
bound to the interface, the kernel deletes them when the interface disappears, **even if `zarpd` is killed
with `kill -9`**: a crash fails open (traffic simply goes out the normal way) instead of leaving a default
route into a tunnel that no longer exists. If an IPv4 route cannot be added (typically another VPN already
owns it) everything done so far is rolled back and the connect fails with a clear message; IPv6 and DNS are
best-effort and reported as warnings. The full tunnel is refused when the default route is itself on a
`utun` (another VPN or proxy): two tunnels fighting for the same routes is not a supported configuration.

**The endpoint exclusion route.** The tunnel's own control connection (QUIC or TCP to the WARP endpoint) must
keep using the physical network. Binding its socket to the physical interface is not enough: on the primary
network service there is no interface-scoped default route, so a bound socket falls back to the ordinary
table, meets the more specific `0.0.0.0/1` through the utun, and fails with `ENETUNREACH` (this was found by
the first real-network run). So `route add -host <endpoint> <gateway>` (or `-interface <if>` when the default
route has no gateway) goes in first and comes out last. Unlike the `/1` routes this one is not tied to the
utun and would survive a `kill -9`, so it is written to `/var/db/zarpd/exclusions.json` *before* it is added
and removed from the journal after it is deleted; whatever the journal still lists at the next daemon start is
deleted then. A route for the endpoint that already exists through the same interface is used and left alone;
one through another interface (another VPN pulling the endpoint into its tunnel) fails the connect.

**DNS.** While a full tunnel is up, DNS is pointed at Cloudflare's resolvers with `networksetup
-setdnsservers` on the physical interface's network service. The resolvers are fixed in the daemon and never
taken from a client (a client-chosen DNS server in a root daemon would be a hijack primitive). The original
setting is written to `/var/db/zarpd/dns-backup.json` *before* anything changes, and restored on disconnect,
on SIGTERM and, after a crash, at the next daemon start before any request is served.

**One tunnel at a time.** A new `open` closes whatever is still open (the previous persistent connection, or
a test connection whose client crashed). A test connection carries a lease (2 minutes by default) and is
reaped if its client never closes it. A tunnel whose data plane dies by itself is torn down, with routes and
DNS restored, and reported as lost.

| If the daemon... | what remains | what restores it |
|---|---|---|
| is stopped (SIGTERM, restart, quit) | nothing | it removes routes and restores DNS before exiting |
| is killed with `kill -9` or crashes | the endpoint host route, the DNS override | the `/1` routes vanish with the utun; the next start removes the host route (journal) and restores DNS (backup) |
| is not restarted at all | the endpoint host route (harmless: it only matters for that one address) and the DNS override | `sudo networksetup -setdnsservers <service> Empty` (see [TROUBLESHOOTING](TROUBLESHOOTING.md)) |

Everything in this section is exercised against the real network by `scripts/test-integration.sh` (§12),
including the `kill -9` and SIGTERM cases.

## 7. The privileged daemon: install and update

`zarpd` is built from source by a script phase in `project.yml` and embedded in the app bundle
(`Contents/MacOS/zarpd` and `Contents/Library/LaunchDaemons/io.github.zarp.mac.zarpd.plist`). It is
registered with `SMAppService.daemon` from Settings (`ZarpdInstaller.swift`), which asks for one
administrator authentication and one approval under *System Settings > General > Login Items &
Extensions*. The app and the daemon must be signed by the same Team ID, which is what lets registration work
with a free Apple Development identity. The embedded property list sets `KeepAlive` on unsuccessful exit
only, so `restart` (which exits with status 1 on purpose) brings the daemon back and a normal stop does not.

Because the daemon is root, a release build registers it only when the app runs from `/Applications` (an
executable in a folder the user can write is a path to root). It also refuses to register from a disk image
or an App Translocation path. After an app update the old daemon keeps running; the app compares versions on
every ping and restarts it once when it is stale. Uninstalling unregisters the service
(Settings > zarpd daemon > Uninstall).

## 8. User interface

A main window (380 pt wide, fixed size) with the power button, status line, language and settings
buttons and an expandable log; a settings sheet (strategy table, scan buttons, options, custom-strategy
editor, daemon section); and a menu bar item (Open, Connect/Disconnect/Cancel, Settings, Quit). Closing the
main window asks whether to hide to the menu bar or quit, with "remember my choice", reachable from the
titlebar button, Cmd-Q and the menu bar Quit alike.

The UI follows [Zarp for Windows](https://github.com/feg55/Zarp) so the apps feel the same: a dark theme
with one accent colour.

| Token | RGB | Use |
|---|---|---|
| back | 18, 20, 25 | window background, table header |
| panel | 27, 30, 37 | rows, buttons, log |
| panelHover | 37, 41, 50 | hover, selected row |
| border | 46, 50, 60 | lines, disabled button border |
| text / textDim | 196, 200, 208 / 128, 134, 146 | body text / headers and hints |
| accent | 244, 129, 32 | connected, primary button, toggles |
| busy / ok / bad | 80, 150, 255 / 64, 196, 120 / 232, 84, 84 | searching and "works (1 check)" / "works ✔✔" / errors |

Eight languages ship (English, Russian, Spanish, Portuguese, Chinese, Hindi, French, German). Text is
resolved when it is displayed, so a language change updates status, log and error messages already on screen.

## 9. Data, logs and privacy

| File | Written by | What |
|---|---|---|
| `~/Library/Application Support/Zarp/zarp.json` | app | settings and strategy results |
| `~/Library/Application Support/Zarp/strategies.txt` | you | custom strategies |
| `~/Library/Logs/Zarp/zarp.log` | app | app log (2 MB, rotated to `.1`); daemon lines appear with a `zarpd:` prefix |
| `/Library/Application Support/Zarp/zarp-warp-config.json` | daemon | the WARP account: device id, token and private key. Mode 0600, root only |
| `/Library/Logs/Zarp/zarpd.log` | daemon | daemon log (2 MB, rotated to `.1`) |
| `/var/db/zarpd/dns-backup.json`, `exclusions.json` | daemon | crash-recovery state (§6); present only while a full tunnel is up |
| `/var/run/zarpd.sock` | daemon | the IPC socket |

There is no telemetry and no analytics. The only network requests are:

- **Cloudflare WARP registration** (through the `usque` library), once, after you accept Cloudflare's
  terms in the app. It creates an anonymous device account for this Mac and sends no personal information.
- **The MASQUE tunnel** to the WARP endpoint (Cloudflare address ranges), which is the point of the app.
- **`https://1.1.1.1/cdn-cgi/trace`** through the tunnel, while testing and connecting, to check that
  traffic really goes through WARP and to measure latency.

WARP itself is a Cloudflare service under Cloudflare's own terms and privacy policy.

## 10. Security model

`zarpd` is a root process that accepts requests from user-level code, so its job is to be useless to anyone
who is not the Zarp app, and of limited use even to them.

- **Who can talk to it.** The socket is `0660`, group `staff`. On top of that the server reads the
  connecting process's credentials from the kernel (`LOCAL_PEERCRED`, not anything the peer claims) and
  admits only root and the user currently at the console. Another logged-in user, an SSH session or a
  service account is refused with `forbidden`.
- **What it will do.** Only the eight methods in §5. No request carries a path, a command or a DNS server.
  Strategies arrive flattened and every field is bounded (at most 8 fake steps, 50 repeats each, TTL 1 to
  255, 16 split positions, timeouts up to two minutes); the decoy blobs come from a fixed list; an endpoint
  override must lie inside Cloudflare's WARP ranges; the resolvers are constants. Commands the daemon runs
  (`route`, `ifconfig`, `networksetup`) take arguments from its own state or from validated values (IP
  addresses, interface and service names read from the system), never from request text.
- **Resource limits.** At most 32 connections, 8 requests in flight per connection, 256 KiB per request;
  a panic in a handler is recovered and answered with `internal`.
- **Where it can live.** A release build registers the daemon only from `/Applications` (§7).
- **At rest.** The WARP account file is root-owned, mode 0600.
- **What this does not stop.** A process running as you (the console user) can do what the Zarp app can do:
  open and close tunnels to WARP endpoints. That is by design (the app is that process) and it gives no
  more than connecting your own Mac to Cloudflare WARP.

Please report weaknesses privately; see [SECURITY.md](../SECURITY.md).

## 11. Licensing and provenance

Zarp for macOS is [MIT](../LICENSE). It descends from three projects by the same author and one upstream:

- **Zarp for Windows (MIT).** The strategy list, the scan and scoring algorithms, the UI texts and the first
  translations come from it and are reused under its (identical) licence.
- **zapret2 (MIT, bol-van).** The fake-packet blobs in `Resources/blobs` are captured by it and included
  unmodified; the strategy argument syntax is its `winws2` syntax.
- **Zarp for Android (GPL-3.0).** Its Go core (`zarpcore`) is the design reference for the same-socket
  trick, the MASQUE dial sequence and the TLS split algorithm. Its third-party dependencies (`usque`,
  `connect-ip-go`, `quic-go`, `wireguard-go`) are permissively licensed and are used directly. `zarpd`'s Go
  code is written fresh against those libraries, studied from but not copied from `zarpcore`, so the
  macOS networking core stays MIT instead of becoming GPL-3.0.
- **The Go dependencies of `zarpd`** are statically linked; their licence texts ship in
  `Resources/Licenses/THIRD_PARTY_NOTICES.md` (regenerated by `scripts/gen-notices.sh`, checked in CI).

Cloudflare and WARP are trademarks of Cloudflare, Inc. Zarp is an independent project, not affiliated with
or endorsed by Cloudflare, and ships no Cloudflare software.

## 12. Testing

- **Go** (`cd zarpd && go test -race ./...`): unit tests per package. Routes and DNS run against a fake
  command runner that models a routing table, so tests assert on state, order and rollback. The dial and the
  desync executor are tested on loopback sockets, including TTL on the wire and socket-leak checks. The IPC
  server is tested for peer policy, limits, cancellation and the golden wire fixtures.
- **Swift** (`cd Packages/ZarpCore && swift test`): the engine against scripted fakes (cancellation,
  re-entrancy, reconnect policy), settings and logging robustness, localization parity (every language has
  exactly the English keys and placeholders, and every key is used), and `ZarpdClient` against a fake
  Unix-socket daemon.
- **Real network** (`scripts/test-integration.sh`, VPN off, asks for `sudo`): builds the daemon, runs its
  own copy on a private socket, and drives it with `zarpctl` through the same calls the app makes: real
  tunnel, full tunnel with IPv4 and IPv6, DNS override and exact restore, `kill -9` and SIGTERM recovery. It
  verifies that the machine is back to normal at the end, whatever happens.
- **CI** (`.github/workflows/ci.yml`): gofmt, vet, race tests, Swift tests, the notices check and an
  unsigned app build on Apple Silicon.

## 13. Known limitations

- Apple Silicon and macOS 14 or later only.
- The release is not notarized (there is no paid Apple Developer membership behind the project): the first
  launch needs *Open Anyway*, see [TROUBLESHOOTING](TROUBLESHOOTING.md).
- WireGuard transport and the raw-socket strategies (§3) are not implemented.
- Only IPv4 WARP endpoints are dialed (IPv6 *traffic* is tunnelled; the control connection is IPv4).
- Private-network ranges that are not directly attached are sent into the tunnel with everything else (there
  are no split-tunnel exclusions yet).
- After sleep or a network change, traffic can stall for up to about 30 seconds (QUIC's idle timeout) while
  the routes still point into a session that has silently died; then the tunnel is noticed as dead, torn down
  (traffic goes direct again) and reconnected.
- DNS and routes follow the physical interface's network service; if the Mac moves to another interface while
  connected, the tunnel is lost and re-established there.
- Daemon log history older than its 1000-line in-memory ring, or from before the app started, is not replayed
  into the app's log.
- Another VPN must be off while Zarp connects.
