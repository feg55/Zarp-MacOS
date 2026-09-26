# Zarp for macOS: architecture

Target: macOS 14+ on Apple Silicon (arm64 only), Swift, SwiftUI + AppKit, plus a Go networking core.

**Status (2026-09-26): architecture pivot.** Zarp owns the WARP connection itself — the same model
as Zarp-Android — instead of trying to intercept the official Cloudflare WARP client's traffic.
See §9 for why, and §10 for the abandoned approach's own record (kept, not deleted, because the
reasoning and the confirmed findings are still useful).

**Status of the pieces below:** §2's `ZarpCore` Swift package (strategy model/catalog/parser,
scan/self-heal engine, settings, localization, logging) and the SwiftUI UI are written, compiling,
and passing tests on a real Mac (`docs/IMPLEMENTATION_PLAN.md` phase 1, done). None of `zarpd` (the
new Go daemon this document describes) exists yet — that starts at `docs/IMPLEMENTATION_PLAN.md`
phase 2.

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

Fail-open on the routing side: if `zarpd` dies, its routes/utun should be torn down (either by
`zarpd` itself on exit, or detected and cleaned up on the next launch) rather than leaving the
user with no default route. Exactly how — a `LaunchDaemon` exit handler, a watchdog, or both — is
open, see `docs/IMPLEMENTATION_PLAN.md` phase 2/8.

IPC surface (shape only, not a wire format yet — see §9.4):
`connect(strategyID)`, `disconnect()`, `testStrategy(strategyID, endpoint)`, `startQuickScan()`,
`startFullScan()`, `cancelScan()`, `getStatus()`, `getLogs()`. This deliberately mirrors
`ZarpEngine`'s own vocabulary rather than inventing a new one — `zarpd` is a `Tester`
implementation (§4), not a second scan engine.

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

zarpd/            NOT YET STARTED — this document's new subject. Planned layout, subject to change
                  once phase 2/3 (docs/IMPLEMENTATION_PLAN.md) are actually written and run:
    cmd/zarpd/         daemon entry point, IPC server
    tun/               utun open/configure/close (darwin-specific)
    route/             default-route replace/restore, endpoint exclusion, DNS
    warp/              account registration/config (usque-based), MASQUE dial (H3/H2),
                        strategy executor (fake packets on the dial socket, TTL, TLS split/disorder)
    ipc/               the app<->daemon protocol
```

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
- `~/Library/Logs/Zarp/zarp.log` — app log; `zarpd`'s own log lines reach it via IPC (`getLogs()`).
- No telemetry. Network requests: `cdn-cgi/trace` during tests, as on Windows. No zapret2 downloads.

## 7. Privileged daemon installation

`zarpd` runs as root (it needs to create a utun device and change routes) but the GUI app does
not. Planned mechanism: `SMAppService.daemon`, which requires one admin authentication at install
time (System Settings prompts the user), same as the LaunchDaemon helper the old design (§10)
already planned to use for its injector — this part of the plan survives the pivot unchanged.
Not yet implemented; see `docs/IMPLEMENTATION_PLAN.md` phase 8.

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

**Real-world wrinkle already found:** on the Mac this was tested on, `route -n get default`
reported another tunnel interface (a `utunN`, presumably an existing corporate VPN or similar) as
the current default, not a hardware NIC — `CurrentDefault()` handled this correctly (it binds to
whatever is *actually* reaching the internet right now, which is the right behavior), but it's a
reminder that "physical interface" here means "whatever currently gets to the real internet," not
literally always Wi-Fi/Ethernet, and that Zarp running on a Mac that's already behind another VPN
is a real scenario to keep handling correctly, not an edge case to dismiss.

### 9.4 IPC shape (not decided)

The pivot brief's proposed call shape (`connect`, `disconnect`, `testStrategy`, `startQuickScan`,
`startFullScan`, `cancelScan`, `getStatus`, `getLogs`) maps directly onto `EngineProtocols.swift`'s
existing `WarpConnectionProvider`/`WarpProbe` shape — deliberately, so `zarpd` is *a*
`WarpConnectionProvider` implementation (talking over IPC) rather than a second scan/state engine
duplicating `ZarpEngine`. Transport is not decided: a local Unix domain socket with a small
length-prefixed or line-delimited JSON protocol is the likely first cut (simple on both the Swift
and Go sides, no code-generation tooling required to start), upgradeable later. XPC was the old
design's choice (§10) for a Swift-to-Swift/ObjC boundary; it's less natural for a Swift-to-Go one.

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
'io.github.zarp.mac.filter'. Personal development teams, including 'Andru Moskow', do not support
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
