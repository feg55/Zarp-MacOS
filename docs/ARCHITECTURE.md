# Zarp for macOS: architecture

Target: macOS 14+ on Apple Silicon (arm64 only), Swift, SwiftUI + AppKit, plus a Go networking core.

**Status (2026-09-26): architecture pivot.** Zarp owns the WARP connection itself — the same model
as Zarp-Android — instead of trying to intercept the official Cloudflare WARP client's traffic.
See §9 for why, and §10 for the abandoned approach's own record (kept, not deleted, because the
reasoning and the confirmed findings are still useful).

**Status of the pieces below (2026-10-06):** everything this document describes now exists:
`ZarpCore` (strategy model/catalog/parser, scan/self-heal engine, settings, localization, logging),
the SwiftUI app, and `zarpd` (the Go daemon: MASQUE dial with strategies, utun, routes, DNS, IPC),
installed as a LaunchDaemon via `SMAppService`. `docs/IMPLEMENTATION_PLAN.md` records, phase by
phase, what was verified on a real Mac and how; its Phase 10 covers the full-tunnel mode and the fixes
from a whole-project review. Where this document says something is "open", check the plan for
whether it has been closed since.

## 1. Processes

```
┌────────────── Zarp.app (user, unprivileged, SwiftUI/AppKit) ───────────────┐
│ UI ── ZarpEngine (scan, re-check, score, self-heal, ZarpCore, unchanged)    │
│        │                                                                    │
│        └── ZarpdClient (WarpConnectionProvider/WarpProbe/NetworkInspector   │
│            implementation) ── IPC ──────────────────────────────┐          │
└────────────────────────────────────────────────────────────────┼──────────┘
                                                                    │ local IPC
                                                                    ▼
┌────────────────────── zarpd (root, LaunchDaemon, SMAppService) ───────────────────────┐
│ • owns the utun device: create, addresses, MTU                                         │
│ • routes: replace default route via utun for tunneled traffic;                         │
│   the WARP/MASQUE endpoint itself is excluded, always via the physical interface        │
│ • WARP account registration/config (usque)                                              │
│ • DPI strategy executor: opens the MASQUE UDP/TCP socket itself, sends fake packets      │
│   on it first, then hands that same socket to the real MASQUE/QUIC dial (Android         │
│   dial.go's trick — see §9.2). TLS ClientHello split/disorder for the HTTP/2 transport.  │
│ • MASQUE session (HTTP/3 QUIC or HTTP/2), CONNECT-IP: pumps packets between the utun      │
│   and the MASQUE session directly — no local SOCKS5 proxy, no userspace netstack         │
│   (unlike Android; see §9.1 for why that's possible here and not there)                  │
│ • reconnect after connection loss / network change                                       │
│ • clean shutdown: remove routes, close utun, restore DNS, on both normal stop and crash   │
│ • exposes status/logs/results to the app over the same IPC channel                       │
└───────────────────────────────────────┬──────────────────────────────────────────────────┘
                                          │ physical interface only (never routed back through utun)
                                          ▼
                              Cloudflare WARP MASQUE endpoint (162.159.x.x)
```

Fail-open on the routing side (decided, §11): the full-tunnel routes are bound to the utun interface, so if
`zarpd` dies — even by `kill -9` — the kernel removes them with the interface and traffic goes back out the
normal way; a DNS override saved to disk is restored by the next daemon start.

IPC surface (`zarpd/ipc/protocol.go`, protocol version 2; newline-delimited JSON over a Unix socket):
`ping`, `status`, `register`, `open`, `close`, `measure`, `logs`, `restart`. This deliberately mirrors
`ZarpEngine`'s own vocabulary rather than inventing a new one — `zarpd` is a `WarpConnectionProvider`
implementation (§4), not a second scan engine; scanning, scoring and self-healing stay in Swift.
Strategies are flattened to what the daemon executes (fake-packet steps, a TCP split) and every field
is validated by the daemon itself (bounds, a fixed blob list, endpoints only inside Cloudflare's WARP
ranges): it is a root process taking requests from user-level code.

## 2. Code layout

```
Packages/ZarpCore/            SwiftPM, Foundation only, builds and tests on Linux too — UNCHANGED
  Sources/ZarpCore/
    Support/      IPAddress, WarpAddressRanges
    Strategy/     Strategy, Transport, Blob, DesyncPlan, StrategyArgsParser, StrategyCatalog,
                  StrategyReadiness(Registry), CustomStrategyFile, CustomStrategyStore
    Results/      TestResult (score, confirmed merge)
    Settings/     AppSettings, SettingsStore (+ JSON file / in-memory implementations)
    Localization/ Msg, Localization (loads Resources/Lang/*.txt)
    Logging/      LogBus, LogEntry
    Engine/       EngineState, EngineProtocols (the network boundary — see §4),
                  ZarpEngine (the scan/self-heal state machine, an actor)
  Tests/ZarpCoreTests/   one file per module above, plus the real Resources/Lang files' key parity
App/Sources/Zarp/        SwiftUI app: Theme, PowerButton, ToggleSwitchView, NumberStepperView,
                          DarkButtonStyle, AppViewModel, ZarpApp, Screens/{MainWindow,Strategies,
                          Settings,Log,CloseConfirmation}View — UNCHANGED by this pivot
Resources/blobs/  zapret2 fake-packet captures (MIT), vendored unchanged
Resources/Lang/   <code>.txt, same format as Windows Zarp's Lang/*.txt
project.yml       XcodeGen spec for the App target

PoC/Filter/       REJECTED approach (NEFilterPacketProvider) — kept only as a record, not built
                  on. See §10.

zarpd/            the Go daemon (its own module)
    cmd/zarpd/         daemon entry point: flags, logging (rotating file + in-memory ring), signals
    cmd/zarpctl/       command-line client for the IPC protocol (development and the integration test)
    daemon/            the connection registry (Manager), request handlers, the real Opener (dial +
                        utun + routes), endpoint rotation pool, trace measurement, log ring
    ipc/               the app<->daemon protocol, request validation, the socket server (peer
                        credential check, limits, per-request cancellation)
    route/             routing table / interface / DNS changes behind a command Runner: single host
                        route, full tunnel (§11), DNS override with crash-safe backup
    tunnel/            the utun <-> MASQUE packet pump
    warp/              account registration, MASQUE dial (H3/H2), strategy executor (fake packets,
                        TTL, TLS split/disorder)
    cmd/*poc           the phase 2-6 proof-of-concept commands, kept compiling as a record

`ZarpCore` still holds all strategy/scan/settings/localization logic and has zero
AppKit/SwiftUI/network dependencies (`swift test` runs it standalone). `EngineProtocols.swift`
(§4) is still the entire seam where platform networking plugs in — that seam does not change
shape with this pivot, only what sits behind it.

## 3. Mapping from Windows Zarp

| Windows (`src/Zarp`) | macOS | Notes |
|---|---|---|
| `Core/Engine.cs` | `ZarpCore/Sources/ZarpCore/Engine/ZarpEngine.swift` (actor) | Same states, same flows: Connect, Quick/Full scan, test selected, use, disconnect, cancel, self-heal. Unchanged by this pivot — only depends on `EngineProtocols.swift`, not on any concrete networking |
| `Core/Warp.cs` | `ZarpdClient`, a `WarpConnectionProvider` + `WarpProbe` implementation talking to `zarpd` over IPC — not written yet | Windows drives `warp-cli`; macOS's `zarpd` *is* the WARP client, so this implementation calls `zarpd`'s `connect`/`disconnect`/`testStrategy` instead of shelling out to anything |
| `Core/Zapret.cs` | `zarpd/warp`'s strategy executor (§9.2) | No bundled backend binary to download or update, no antivirus handling, on any platform |
| `Core/Strategy.cs` | `ZarpCore/Sources/ZarpCore/Strategy/*` | Same ids, names, order, args; `strategies.txt` same format (`name | h3/h2/wg | args`) |
| `Core/AppConfig.cs` | `AppSettings` (Codable) + `SettingsStore` → `~/Library/Application Support/Zarp/zarp.json` | Same field names so the logic and tests port 1:1 (minus `AutoUpdateZapret`, which has no macOS counterpart) |
| `Core/NetCheck.cs` | `NetworkInspector` protocol (`EngineProtocols.swift`); real implementation not written yet | Less relevant now that Zarp owns the tunnel outright rather than needing to detect other VPN adapters interfering with a filter — revisit once `zarpd` exists |
| `Core/Autostart.cs` | `SMAppService.mainApp`, wired as a TODO in `SettingsView.swift` | "Start with macOS" |
| `Core/L.cs` + `Lang/*.txt` | `Localization` reading the same `key = value` files from `Resources/Lang` | Windows files copied verbatim (MIT) then hand-edited for macOS wording in `en.txt` only — see that file's header |
| `Core/Log.cs` | `LogBus`: file `~/Library/Logs/Zarp/zarp.log` (2 MB cap) + in-app history | Same `[HH:mm:ss] text` format; `zarpd`'s own logs reach this via `getLogs()`/status push over IPC |
| `UI/MainForm.cs` | `MainWindowView` (SwiftUI) + `MenuBarExtra` | Unchanged by this pivot |
| `UI/SettingsForm.cs` | `SettingsView` wrapping `StrategiesView` (SwiftUI native `Table`) + options | Unchanged by this pivot |
| `UI/CloseActionForm.cs` | `CloseConfirmationView` sheet | Unchanged by this pivot; titlebar close button now wired via `NSWindowDelegate` (`ZarpApp.swift`'s `WindowCloseInterceptor`) |
| `UI/PowerButton.cs`, `Controls.cs`, `Theme.cs` | `PowerButton` (SwiftUI `Canvas`), `ToggleSwitchView`, `NumberStepperView`, `DarkButtonStyle`, `Theme` | Unchanged by this pivot |

## 4. Strategy engine on macOS

A strategy is still `transport + winws2-style args`. `StrategyArgs.parse` turns the args into a
`DesyncPlan` — this parsing is platform-independent and unchanged. What changes is who *executes*
the plan: `zarpd`'s strategy executor, not a packet filter + helper pair.

| winws2 syntax | macOS implementation (`zarpd/warp`) | Phase |
|---|---|---|
| `--payload=quic_initial --lua-desync=fake:blob=B:repeats=N` | before the MASQUE/QUIC dial, open the UDP socket, send B ×N through it, then hand that same socket to quic-go for the real Initial — Android `dial.go`'s trick, §9.2 | 3–4 |
| `…:ip_ttl=N:ip6_ttl=N` | `setsockopt(IP_TTL/IPV6_UNICAST_HOPS)` on that socket around the fake sends only, restored before the real Initial — portable unix code, see §9.2 | 4–5 |
| two `fake` steps (google + vk) | steps run in order, same socket | 5 |
| `…:badsum` | possible (raw enough access via the same UDP socket's IP_TTL-style sockopts does *not* cover checksum override on macOS without raw sockets) — open, revisit once the basic fake path works | later, optional |
| `--payload=wireguard_initiation --lua-desync=fake:…` | same socket-reuse mechanism, once WireGuard is prioritized (§9.6 says not yet) | later |
| `--payload=tls_client_hello --lua-desync=multisplit:pos=…` / `multidisorder` | HTTP/2 MASQUE only: wrap the dial's `net.Conn` so the first `Write` (the ClientHello) is split, optionally with TTL=1 on the first segment — Android `desync.go`'s algorithm, 100% portable Go stdlib, §9.2 | 6 |
| `tcp_md5`, `seqovl`, `tcp_seq`, `hostfakesplit` | shown as "not supported on macOS" (like Android), never faked | — |

No flow table, no packet filter, no detector rules: `zarpd` doesn't have to *recognize* WARP's
handshake packets among unrelated traffic, because it never sees unrelated traffic in the first
place — it only ever dials WARP itself. This whole layer of the old design (§10) is gone, not
reimplemented.

Scan, re-check, scoring and self-healing are the Windows algorithms without changes:
score = `connectMs + 4 × pingMs`; confirmed = passed a second test on a different endpoint;
merged result = `max(connectMs)`, `avg(pingMs)`; Connect = saved → other confirmed by score → quick scan.

## 5. UI

Reference: the Windows settings window (attached screenshot) and `SettingsForm.cs`. Unchanged by
this pivot — verified live on a real Mac, see `docs/IMPLEMENTATION_PLAN.md` phase 4.

Theme (from `Theme.cs`, sRGB):

| Token | RGB | Use |
|---|---|---|
| back | 18,20,25 | window background, table header |
| panel | 27,30,37 | table rows, buttons, log |
| panelHover | 37,41,50 | hover, selected row |
| border | 46,50,60 | lines, disabled button border |
| borderHover | 64,69,81 | |
| text | 196,200,208 | |
| textDim | 128,134,146 | headers, hints |
| textDisabled | 78,83,94 | |
| accent | 244,129,32 | Connected, primary button, toggles |
| busy | 80,150,255 | searching, "works (1 check)" |
| ok | 64,196,120 | "works ✔✔" |
| bad | 232,84,84 | errors |
| off | 70,75,88 | power ring when off |

Strategy table — implemented in `StrategiesView.swift` using SwiftUI's native macOS `Table`:
- Columns: `✔` (26) | Strategy (min 160/ideal 230) | Protocol (min 90/ideal 108) | Result (min 140/ideal 220,
  fills remaining width) | Connect, ms (min 60/ideal 76, right) | Ping, ms (min 54/ideal 68, right).
- Result text/color: not tested (textDim) · works ✔✔ (ok) · works (1 check) (busy) · error / "not confirmed: …" (bad).
- Buttons under the table: Use (primary, enabled with exactly 1 row) · Test selected · Quick scan · Full scan
  (replaced by Cancel while busy) · Custom strategies…; status line under them with `⏳ detail [n/m]`.

Main window: 380×500 pt, not resizable. Power button 200 pt with ring, glow when on, rotating
arc when busy. Log expands the window by 190 pt.

Settings window: resizable, minimum 760×700; the table grows with the window; option labels wrap
instead of clipping (`.fixedSize(horizontal: false, vertical: true)` — a real bug found and fixed
by actually running the app, not a design note anymore).

Menu bar item replaces the tray icon: Open, Connect/Disconnect/Cancel, Settings, Quit. Closing the
main window asks "Hide to menu bar / Quit" with "Remember my choice", reachable from the titlebar
close button, ⌘Q, and the menu bar Quit item alike (`WindowCloseInterceptor`).

## 6. Data and logs

- `~/Library/Application Support/Zarp/zarp.json` — settings and results (same fields as Windows `AppConfig`).
- `~/Library/Application Support/Zarp/strategies.txt` — custom strategies.
- `~/Library/Logs/Zarp/zarp.log` — app log (2 MB, rotated to `.1`); `zarpd`'s own log lines reach it via
  the `logs` IPC method, prefixed "zarpd:". The daemon itself writes `/Library/Logs/Zarp/zarpd.log`
  (2 MB, rotated).
- No telemetry. Network requests: `cdn-cgi/trace` during tests, as on Windows. No zapret2 downloads.

## 7. Privileged daemon installation

`zarpd` runs as root (it needs to create a utun device and change routes and DNS) but the GUI app does
not. It is installed with `SMAppService.daemon` (`ZarpdInstaller.swift`), which requires one admin
authentication and one approval in System Settings. Because the daemon is root, a release build only
registers it from `/Applications` (an executable in a folder the user can write would be a path to
root); the app also refuses a disk image or an App Translocation path. The IPC socket
(`/var/run/zarpd.sock`, group `staff`, 0660) is further restricted by a kernel-reported peer check: only
root and the console user may talk to the daemon. After an app update the old daemon keeps running; the
app compares versions on every ping and restarts it once when it is stale.

## 8. Licensing

- Windows Zarp: MIT (strategy list, texts, translations, algorithms can be reused with notice).
- zapret2 blobs: MIT.
- **Zarp-Android: GPL-3.0.** `zarpcore` (the Go package this document's design is modeled on) is
  Android's own copyrightable code. Its actual third-party dependencies — `usque`
  (`github.com/Diniboy1123/usque`, MIT), `connect-ip-go`, `quic-go`, `wireguard-go`
  (`golang.zx2c4.com/wireguard`, including its `tun` package) — are **not** GPL and are not part of
  Zarp-Android's own license grant; they're independently available upstream under their own
  permissive terms. `usque` itself is vendored in Android's tree at commit
  `6aa03fc97d12848dce34eedbd187fb1077b5d1ea` with two small additive patches (`pub/pub.go`,
  `internal/socks5_zarp.go` — see `_reference/Zarp-Android/core/third_party/usque/ZARP_PATCHES.md`),
  upstream files unchanged.
- **Decision:** `zarpd`'s Go code is written fresh, depending directly on the same upstream MIT/BSD
  libraries Android's `zarpcore` uses — not copied from `zarpcore` itself. Android's source is
  studied as a design reference (the same-socket fake-packet trick, the MASQUE dial sequence, the
  TLS split/disorder algorithm, the TTL sockopts) and reimplemented, not pasted in. This keeps
  `zarpd` MIT-compatible rather than making the whole macOS networking core GPL-3.0. Where Android's
  code is *already* thin, portable, dependency-free Go (e.g. the TLS desync wrapper, the TTL
  sockopts) reimplementing it is barely more work than copying it would have been, so there's no
  practical reuse actually sacrificed by keeping licenses clean — see §9.2 for specifics.

## 9. Design notes from studying Zarp-Android's `zarpcore`

Read in full for this pivot (commit `1b80c30`, the one `_reference/Zarp-Android` is pinned to):
`core/zarpcore/{tunnel,dial,desync,account,ttl_unix,ttl_other,log}.go`,
`app/src/main/java/.../{masque/QuicSocketFactory.kt,strategy/ZarpStrategy.kt}`.

### 9.1 Android's `zarpcore.Tunnel` is not a raw-packet API — and macOS doesn't need what it is

`Tunnel` creates its *own* in-process userspace network stack
(`golang.zx2c4.com/wireguard/tun/netstack.CreateNetTUN`, gVisor-backed) and exposes it as a local
SOCKS5 proxy (`usque/pub.SOCKS5Server` on `127.0.0.1`). The actual bridge from Android's OS-level
VPN interface to that SOCKS5 proxy is Android's own `VpnService` + the separate `hev-socks5-tunnel`
process — neither of which is part of `zarpcore` at all. So `zarpcore.Tunnel` as written is not
directly reusable for "utun → raw packets → zarpcore" the way the pivot brief first framed it;
that framing undersold what's actually needed.

What *is* directly usable: `wireguard-go`'s `tun` package (the same dependency, already proven to
work for Android) also has a **real** darwin implementation (`tun.CreateTUN`, not just
`netstack.CreateNetTUN`) that opens an actual macOS utun device. So the plan is: skip the
netstack+SOCKS5 layer entirely, and write a new, smaller piece of glue that reads/writes a real
utun's packets directly against the MASQUE session's `connectip.Conn` (`s.ipConn.WritePacketBuffer`
/ `ReadPacketZeroCopy`, same calls `tunnel.go`'s `readDevice`/`pumpIn` already make against the
netstack device). This is *less* code than Android's version, not more, because there's no SOCKS5
server and no second network stack to run.

### 9.2 The same-socket fake-packet trick, and why macOS's version is actually simpler

Android's sequence, from `dial.go` + `QuicSocketFactory.kt` + `ZarpStrategy.kt`:

1. Kotlin's `QuicSocketFactory.openUDP` opens a UDP socket, calls `VpnService.protect(fd)` (exclude
   it from the VPN), then runs `ZarpStrategy.beforeHandshake` synchronously on it — `FakeStrategy`
   sends each fake blob N times, temporarily lowering TTL via `setTtl`/`getTtl` when the strategy's
   `ip_ttl`/`ip6_ttl` is set, restoring it before returning.
2. The socket's fd crosses back into Go (`udpConnFromFd`).
3. `&quic.Transport{Conn: udpConn, ConnectionIDLength: 20}` — quic-go is handed the *already-used*
   socket, so the real QUIC Initial leaves through the identical 5-tuple as the fakes.

Steps 1 and 3 need to cross the JNI/Kotlin boundary on Android only because `VpnService.protect()`
is a privileged JVM API the Go/native side can't call directly. On macOS, `zarpd` is a single root
Go process — there is no such boundary. The whole sequence (open UDP socket → bind it to the
physical interface, not the tunnel's default route → run the fake-send step → hand the same
`net.UDPConn` to `quic.Transport`) happens in one Go function, no FD-passing IPC needed at all.
"Bind to the physical interface" is macOS's equivalent of `VpnService.protect()` — see §9.3.

The fake-send algorithm itself (`ZarpStrategy.kt`'s `FakeStrategy.beforeHandshake`) has zero
Android-specific concepts: for each fake step, optionally set a temporary TTL, send the blob N
times, restore TTL. Trivially reimplemented in Go directly against `zarpd`'s socket.

`desync.go`'s HTTP/2 TLS ClientHello split/disorder is, independently of the above, already 100% portable
Go: a `net.Conn` wrapper around `*net.TCPConn` that on the first `Write()` (detected by the TLS
handshake record byte `0x16`) splits the payload at computed offsets (SNI-relative or literal), and
for "disorder" mode sends the first segment with `IP_TTL`/`IPV6_UNICAST_HOPS` set to 1 via
`SyscallConn()`, then restores it. `ttl_unix.go`'s `getTTL`/`setTTL` (behind a `//go:build unix` tag,
which covers darwin) use only `syscall.IPPROTO_IP`/`IP_TTL`/`IPPROTO_IPV6`/`IPV6_UNICAST_HOPS` —
standard BSD socket option constants, unchanged on macOS.

### 9.3 Routing: avoiding a loop back into utun

**VERIFIED 2026-09-26** (`zarpd/route`, `docs/IMPLEMENTATION_PLAN.md` phase 3): `IP_BOUND_IF`
(`zarpd/route.Physical.BindUDP`) does prevent the WARP control socket from looping back into the
tunnel, confirmed with real traffic — `curl .../cdn-cgi/trace` through the resulting tunnel
returned `warp=on`. `CurrentDefault()` gets the interface to bind to from `route -n get default`
(shelled out to, like `ifconfig` for address config — no raw `PF_ROUTE` socket code needed).

**Still open**, because phase 3 deliberately tested with one narrow host route rather than a
default-route replacement (much lower blast radius for a first test — see
`docs/IMPLEMENTATION_PLAN.md` phase 3): whether `IP_BOUND_IF` alone stays sufficient once the
*default* route (not just one host route) points at the utun, or whether an explicit higher-priority
route for the WARP endpoint IP is also needed defensively; IPv6 handling; DNS while the tunnel is
up; and cleanup after a crash (stale routes left behind if `zarpd` dies without running its
shutdown path). This is squarely the next thing to verify, not guessed at.

**Update (Phase 10):** the full-tunnel mode and everything listed as open above are implemented (§11).
The expectation written here at first — that `IP_BOUND_IF` alone keeps the control socket off the tunnel
once the default route is taken over — **was wrong**, and the first real-network run of
`scripts/test-integration.sh` (2026-10-08) showed it: the narrow-route connections worked, but a full
tunnel died within a millisecond of its routes going in, with `ENETUNREACH` on the bound control socket.
On the primary network service there is no interface-scoped default route, so a bound socket falls back to
the ordinary table, meets the more specific `0.0.0.0/1` via the utun, and gives up. The fix is the
standard one (wg-quick, OpenVPN): before any `/1` route goes in, the WARP endpoint gets a **host route
through the physical gateway** (`zarpd/route/exclusion.go`), which is more specific than any `/1`. **Verified
2026-10-08 on a real Mac (Wi-Fi, VPN off), second run of the script, 56/56 checks:** the tunnel stays up;
the routing table shows `0/1` and `128.0/1` via the utun plus `162.159.198.2 → 192.168.34.1 UGHS en0`;
`route get` for the endpoint answers `en0`; traffic is `warp=on` for IPv4 and IPv6, an 8 MB download
completes, DNS points at `1.1.1.1` and is restored exactly (here: "no DNS servers set" → set to Empty
again); after `kill -9` the `/1` routes vanish by themselves while the host route stays until the next
start removes it via the journal; SIGTERM restores everything at once.

**Real-world wrinkle already found:** on the Mac this was tested on, `route -n get default`
reported another tunnel interface (a `utunN`, presumably an existing corporate VPN or similar) as
the current default, not a hardware NIC — `CurrentDefault()` handled this correctly (it binds to
whatever is *actually* reaching the internet right now, which is the right behavior), but it's a
reminder that "physical interface" here means "whatever currently gets to the real internet," not
literally always Wi-Fi/Ethernet, and that Zarp running on a Mac that's already behind another VPN
is a real scenario to keep handling correctly, not an edge case to dismiss.

### 9.4 IPC shape (decided)

The call shape (`ping`, `status`, `register`, `open`, `close`, `measure`, `logs`, `restart`) maps directly
onto `EngineProtocols.swift`'s `WarpConnectionProvider`/`WarpProbe` — deliberately, so `zarpd` is *a*
`WarpConnectionProvider` implementation (talking over IPC) rather than a second scan/state engine
duplicating `ZarpEngine`. Transport: a Unix domain socket with newline-delimited JSON (simple on both the
Swift and Go sides, no code generation); XPC was the old design's choice (§10) for a Swift-to-Swift/ObjC
boundary and is less natural for Swift-to-Go. A client keeps its connection open until it has read the
answer: the server treats the client going away as "abandon what's in flight for it", which is how an
`open` that is still dialing is cancelled when the user presses Cancel.

### 9.5 What Zarp-Android does *not* have that this design still needs

Account registration (`account.go`'s `Register`/`HasAccount`/`AccountEndpoint`) is a thin, already
fully portable wrapper around `usque/api` calls — no Android dependency at all, reusable as a
reference essentially as-is. WireGuard transport is out of scope for both Android and this first
macOS milestone (§9.6).

### 9.6 WireGuard is explicitly deprioritized

Order for the first working macOS build: MASQUE HTTP/3 → MASQUE HTTP/2 → QUIC fake strategies →
TCP split/disorder → only then WireGuard. The first working version can ship MASQUE-only.

## 10. Rejected approach: NEFilterPacketProvider / System Extension (kept for the record)

This was the original plan for this document (see git history) and was implemented far enough to
get a real, definitive answer before being rejected — not abandoned on guesswork. Kept here,
unchanged in substance, because the reasoning and the confirmed findings remain useful (e.g. if
Apple's account-tier policy ever changes) and because throwing away a validated negative result
would just invite re-discovering it later.

**Why rejected:** the product goal was never "modify the official WARP app" — it's "make WARP work
under DPI." Intercepting another process's traffic was one way to get there; owning the connection
directly (this document's new §1–§9) is a more direct one, and avoids three hard requirements the
interception approach turned out to need: a paid Apple Developer Program membership (confirmed,
not assumed — see below), System Extension user-approval UX, and — in the fallback case actually
tried — disabling SIP.

**What was confirmed, empirically, on a real Mac, before rejection** (not just documented —
verified by actually building `PoC/Filter`, a minimal `NEFilterPacketProvider` system extension
target, entitlements and Info.plist configured correctly per Apple's own sample code and
Technotes): a free Xcode "Personal Team" account **cannot** get either the Network Extensions or
System Extension capability, under any configuration. Verbatim from Apple's own provisioning
server: *"Cannot create a Mac App Development provisioning profile for
'io.github.zarp.mac.filter'. Personal development teams, including 'feg55', do not support
the Network Extensions capability."* Matches Apple's "Supported capabilities (macOS)" reference
table and multiple Apple DTS forum answers. The only way past it within that architecture was
either a paid Apple Developer Program membership ($99/yr) or disabling SIP for
`systemextensionsctl developer on` local-only development loading — exactly the two costs the
pivot brief asks this new architecture to avoid requiring for basic functionality.

**Original process diagram, for the record:**

```
┌──────────────────────── Zarp.app (user, not sandboxed, Developer ID) ────────────────────────┐
│ SwiftUI/AppKit UI ── ZarpEngine (scan, re-check, score, self-heal) ── WarpClient (warp-cli)    │
│        │                    │                                          TraceProbe (warp=on)    │
│        │                    └── FilterControl (XPC client) ────────────────┐                   │
└────────┼──────────────────────────────────────────────────────────────────┼───────────────────┘
         │ activates (OSSystemExtensionRequest)        XPC (NEMachServiceName)│
         ▼                                                                    ▼
┌──────── ZarpFilter.systemextension (root, sandboxed) ────────┐    ┌── ZarpHelper (LaunchDaemon, root) ──┐
│ NEFilterPacketProvider                                        │◄──►│ registers as injector over XPC        │
│  • parse outbound packet (IPv4/IPv6, UDP/TCP)                 │    │ raw socket: builds IP+UDP frames      │
│  • WARP range + handshake detector (QUIC Initial / WG / TLS)  │    │  with the flow's own 5-tuple,         │
│  • flow table: first handshake packet of a new 5-tuple        │    │  TTL, checksum (or badsum)            │
│      → delayCurrentPacket → ask helper to send fakes          │    │ binds to the packet's interface       │
│      → allow(packet)                                          │    │  (IP_BOUND_IF)                        │
│  • everything else → .allow immediately                       │    └───────────────────────────────────────┘
└───────────────────────────────────────────────────────────────┘
                     ▲ outer WARP packets on en0/Wi-Fi
┌──────────── Cloudflare WARP (official, root daemon) ────────────┐
│ MASQUE/HTTP3, MASQUE/HTTP2 or WireGuard to 162.159.x.x           │
└──────────────────────────────────────────────────────────────────┘
```

`PoC/Filter/` (the minimal system extension target that produced the confirmation above),
`App/Zarp.entitlements`, and the NetworkExtension-related `project.yml` settings are left in the
repo as that record rather than deleted; they are not built into the app going forward. See
`docs/MACOS_NETWORK_RESEARCH.md` for the full research trail (Q1–Q8, the entitlement findings,
sources) and `docs/IMPLEMENTATION_PLAN.md`'s old phase list (also kept, marked superseded).

## 11. Full tunnel, fail-safety and recovery (Phase 10)

A persistent connection (`routeAll`) makes the utun carry **all** of the machine's traffic; a scan's test
connection still routes only the measurement host (`1.1.1.1`), which is all a scan needs.

**Routes** follow `wg-quick`'s macOS shape: `0.0.0.0/1` and `128.0.0.0/1` (and `::/1`, `8000::/1` when WARP
assigned an IPv6 address) added *through the utun interface*. They are more specific than the default
route, so they win, and the real default route is never modified. Because they are bound to the interface,
the kernel removes them when the interface disappears — **even if `zarpd` is killed with `-9`** — so a
crash fails open (traffic goes back out the normal way) instead of leaving a default route into a dead
tunnel. If either IPv4 route cannot be added (typically because another VPN already owns it) everything
done so far is rolled back and the connect fails with a clear message; IPv6 and DNS are best-effort and
reported as warnings. The full tunnel is refused outright when the default route is itself on a `utun`
(another VPN/proxy): two tunnels fighting for the same routes is not a supported configuration.

**The endpoint exclusion route.** The tunnel's own control connection (QUIC/TCP to the WARP endpoint) must
keep using the physical network, or the tunnel would run inside itself. Binding its socket to the physical
interface is not enough (§9.3), so `route -n add -host <endpoint> <gateway>` (or `-interface <if>` when the
default route has no gateway) goes in *first* and comes out *last*. Unlike the `/1` routes this one is not
tied to the utun and would survive a `kill -9`, so it is written to `/var/db/zarpd/exclusions.json`
**before** it is added and deleted from the journal after it is removed; whatever the journal still lists at
the next daemon start is deleted then, together with the DNS recovery. A route for the endpoint that
already exists through the same interface is used as it is and left alone afterwards; one through another
interface (another VPN pulling the endpoint into its tunnel) fails the connect.

**DNS** is overridden with `networksetup -setdnsservers` on the network service of the physical
interface (Cloudflare's resolvers; fixed in the daemon, never taken from a client — a client-chosen DNS
through a root daemon would be a hijack primitive). The original setting is written to
`/var/db/zarpd/dns-backup.json` **before** anything changes and restored on disconnect, on SIGTERM, and —
after a crash — at the next daemon start, before any request is served. The exclusion-route journal is
recovered at the same moment.

**One tunnel at a time.** All connections share the one measurement route, so a new `open` closes whatever
is still open (the previous persistent connection, or a test connection whose client crashed). A test
connection also carries a lease and is reaped if its client never closes it. A tunnel whose data plane dies
by itself (MASQUE session lost, network change) is torn down — routes and DNS restored — and reported as
lost; the app polls every few seconds, shows the loss, and (if enabled) reconnects with the same strategy a
few times, never rescanning and never counting it against the strategy.

**What cannot be tested without root and a network** lives in `scripts/test-integration.sh`, which runs a
private `zarpd` against the real network and checks every claim above, including the `kill -9` case.
