# Zarp for macOS: architecture

Target: macOS 14+ on Apple Silicon (arm64 only), Swift, SwiftUI + AppKit.
The design keeps the Windows model: the official Cloudflare WARP client is the VPN, Zarp only
touches the WARP handshake. Why each piece is needed is in [MACOS_NETWORK_RESEARCH.md](MACOS_NETWORK_RESEARCH.md).

> Primary architecture depends on the PoC passing Q1–Q7. If it fails, see "Fallback" at the end.

**Status (2026-09-25):** the platform-independent half of this document — §2's `ZarpCore` package
(strategy model/catalog/parser, scan/self-heal engine, settings, localization, logging) and a
first pass at the SwiftUI UI — is written. None of §1's Filter/Helper processes exist yet, and
none of this has been compiled or run: it was written on a Windows machine with no Swift toolchain
or Xcode available. `docs/IMPLEMENTATION_PLAN.md`'s checklist says exactly what to verify first on
a real Mac.

## 1. Processes

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

Only three things cross process boundaries, all small:
- app → filter: `configure(profile)` (mode, transport, desync steps, blobs, WARP-only flag) and `snapshot()` (counters, recent events);
- filter → helper: `inject(request)` (5-tuple, interface, steps with payload bytes, TTL, badsum);
- app → helper: nothing. The helper only needs to be registered and running.

Fail-open everywhere: no helper, XPC timeout (250 ms) or parse error → the packet is allowed unchanged
and an event is logged. Zarp must never be able to cut the user's network.

## 2. Code layout

Current on-disk layout (superseding the original sketch this section used to have — see the
status note at the top of this document):

```
Packages/ZarpCore/            SwiftPM, Foundation only, builds and tests on Linux too
  Sources/ZarpCore/
    Support/      IPAddress, WarpAddressRanges (reference data/formatting only, no packet code)
    Strategy/     Strategy, Transport, Blob, DesyncPlan, StrategyArgsParser, StrategyCatalog,
                  StrategyReadiness(Registry), CustomStrategyFile, CustomStrategyStore
    Results/      TestResult (score, confirmed merge)
    Settings/     AppSettings, SettingsStore (+ JSON file / in-memory implementations)
    Localization/ Msg, Localization (loads Resources/Lang/*.txt)
    Logging/      LogBus, LogEntry
    Engine/       EngineState, EngineProtocols (the network boundary — see §1 and §8),
                  ZarpEngine (the scan/self-heal state machine, an actor)
  Tests/ZarpCoreTests/   one file per module above, plus the real Resources/Lang files' key parity
App/Sources/Zarp/        SwiftUI app: Theme, PowerButton, ToggleSwitchView, NumberStepperView,
                          DarkButtonStyle, AppViewModel, ZarpApp, Screens/{MainWindow,Strategies,
                          Settings,Log,CloseConfirmation}View
Resources/blobs/  zapret2 fake-packet captures (MIT), vendored unchanged
Resources/Lang/   <code>.txt, same format as Windows Zarp's Lang/*.txt (see that folder's own
                  header note on what's been hand-edited for macOS vs. still verbatim)
project.yml       XcodeGen spec for the App target (not yet run against a real Xcode)
```

Not yet started: `PoC/`, `Filter/` (packet-filter system extension), `Helper/` (root injector
daemon) — these are `docs/IMPLEMENTATION_PLAN.md` phases 1–2, deliberately not implemented until a
real Mac can answer the open questions in `docs/MACOS_NETWORK_RESEARCH.md` §6.

`ZarpCore` holds all strategy/scan/settings/localization logic and has zero AppKit/SwiftUI/network
dependencies, so it is unit-tested without a Mac (`swift test`, once a Swift toolchain is
available — untested from the Windows environment this was written in). `EngineProtocols.swift` is
the entire seam where platform networking plugs in later.

## 3. Mapping from Windows Zarp

| Windows (`src/Zarp`) | macOS | Notes |
|---|---|---|
| `Core/Engine.cs` | `ZarpCore/Sources/ZarpCore/Engine/ZarpEngine.swift` (actor) | Same states, same flows: Connect, Quick/Full scan, test selected, use, disconnect, cancel, self-heal. Lives in `ZarpCore`, not `App` — it only depends on the protocols in `EngineProtocols.swift`, not on any concrete networking |
| `Core/Warp.cs` | A future `WarpConnectionProvider` + `WarpProbe` implementation (`EngineProtocols.swift`) — not written yet | Windows' warp-cli sequencing (SetTransport/StartZapret/Connect/WaitConnected) becomes the implementation's internal business; `ZarpEngine` only sees `open(strategy:endpoint:timeoutMs:persistent:)` |
| `Core/Zapret.cs` | Folded into the same future `WarpConnectionProvider` implementation (packet filter + helper, or a MASQUE tunnel — see §1/§8) | No bundled backend binary to download or update, no antivirus handling, on any platform |
| `Core/Strategy.cs` | `ZarpCore/Sources/ZarpCore/Strategy/*` | Same ids, names, order, args; `strategies.txt` same format (`name | h3/h2/wg | args`) |
| `Core/AppConfig.cs` | `AppSettings` (Codable) + `SettingsStore` → `~/Library/Application Support/Zarp/zarp.json` | Same field names so the logic and tests port 1:1 (minus `AutoUpdateZapret`, which has no macOS counterpart) |
| `Core/NetCheck.cs` | `NetworkInspector` protocol (`EngineProtocols.swift`); real `getifaddrs`-based implementation not written yet | Windows' `IsForeignVpnAdapter` rules (exclude WARP's own interface and system IPv6 transition adapters, require a real gateway) are the spec for that future implementation |
| `Core/Autostart.cs` | `SMAppService.mainApp`, wired as a TODO in `SettingsView.swift` | "Start with macOS" |
| `Core/L.cs` + `Lang/*.txt` | `Localization` reading the same `key = value` files from `Resources/Lang` | Windows files copied verbatim (MIT) then hand-edited for macOS wording in `en.txt` only — see that file's header |
| `Core/Log.cs` | `LogBus`: file `~/Library/Logs/Zarp/zarp.log` (2 MB cap) + in-app history | Same `[HH:mm:ss] text` format |
| `UI/MainForm.cs` | `MainWindowView` (SwiftUI) + `MenuBarExtra` | Title, subtitle, globe, gear, power button, status, detail, progress, hint, collapsible log |
| `UI/SettingsForm.cs` | `SettingsView` wrapping `StrategiesView` (SwiftUI native `Table`, not `NSTableView`) + options | See section 5 |
| `UI/CloseActionForm.cs` | `CloseConfirmationView` sheet | "Hide to menu bar / Quit", remember choice — reachable today from the menu bar Quit item and ⌘Q; the titlebar close button still needs real `NSWindowDelegate` wiring, see that view's doc comment |
| `UI/PowerButton.cs`, `Controls.cs`, `Theme.cs` | `PowerButton` (SwiftUI `Canvas`), `ToggleSwitchView`, `NumberStepperView`, `DarkButtonStyle`, `Theme` | Same colors and geometry |

## 4. Strategy engine on macOS

A strategy is still `transport + winws2-style args`. `StrategyArgs.parse` turns the args into a `DesyncPlan`:

| winws2 syntax | macOS implementation | Phase |
|---|---|---|
| `--payload=quic_initial --lua-desync=fake:blob=B:repeats=N` | filter delays the first QUIC Initial of the flow, helper sends B ×N with the flow's 5-tuple | 2 |
| `…:ip_ttl=N:ip6_ttl=N` | same, IP TTL / hop limit N in the fake frames | 3 |
| two `fake` steps (google + vk) | steps run in order | 3 |
| `…:badsum` | fake frames with a wrong UDP checksum (possible with raw frames, unlike Android) | 3 (optional) |
| `--payload=wireguard_initiation --lua-desync=fake:…` | same mechanism, detector = 148-byte WG initiation | later |
| `--payload=tls_client_hello --lua-desync=multisplit:pos=…` / `multidisorder` | filter drops the ClientHello segment, helper sends the pieces as raw TCP; **raw TCP send on macOS is unverified** | 5+ |
| `tcp_md5`, `seqovl`, `tcp_seq`, `hostfakesplit` | shown as "not supported on macOS" (like Android), never faked | — |

Detector rules are the Windows filter rules, byte for byte (see research §2). "Intercept WARP addresses only"
maps to the same IP ranges. With the option off, the detector matches any destination, as on Windows.

Flow table: key = (src IP, src port, dst IP, dst port, proto). States: `new → injecting → done`, 120 s idle expiry.
Only a `new` flow's first handshake packet is delayed. Fakes injected by the helper pass the filter on a
`injecting` flow and are allowed (also recognised by comparing with the blob bytes, so they cannot trigger
another round). The second post-quantum Initial goes through untouched, as with winws2.

Scan, re-check, scoring and self-healing are the Windows algorithms without changes:
score = `connectMs + 4 × pingMs`; confirmed = passed a second test on a different endpoint;
merged result = `max(connectMs)`, `avg(pingMs)`; Connect = saved → other confirmed by score → quick scan.

## 5. UI

Reference: the Windows settings window (attached screenshot) and `SettingsForm.cs`.

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

Strategy table (fidelity matters most here) — implemented in `StrategiesView.swift` using SwiftUI's
native macOS `Table` (multi-selection, resizable/sortable columns for free) rather than an
`NSTableView` bridge, since `Table` already supports per-cell custom content (needed for per-row
colors and bold-when-current text):
- Columns: `✔` (26) | Strategy (min 160/ideal 230) | Protocol (min 90/ideal 108) | Result (min 140/ideal 220,
  fills remaining width) | Connect, ms (min 60/ideal 76, right) | Ping, ms (min 54/ideal 68, right).
- Row font 12pt system, header styled by `Table`'s own `.inset` style rather than a custom-drawn
  header (Windows draws its own header because its system ListView header is always light; macOS's
  `Table` header already follows the app's appearance).
- Result text/color: not tested (textDim) · works ✔✔ (ok) · works (1 check) (busy) · error / "not confirmed: …" (bad) —
  `StrategiesView.resultCell(_:using:)` mirrors Windows `FillList`'s exact branching.
- Buttons under the table: Use (primary, enabled with exactly 1 row) · Test selected · Quick scan · Full scan
  (replaced by Cancel while busy) · Custom strategies…; status line under them with `⏳ detail [n/m]`.
- Use = `engine.use(_:)`. TODO(real Mac): confirm whether `Table` exposes a double-click action the
  way Windows' `ListView.DoubleClick` does, or whether that needs an `NSViewRepresentable` escape
  hatch — flagged inline in `StrategiesView.swift`.
- Hovering a strategy name shows its `args` as a tooltip (`.help(...)`), same as Windows'
  `ToolTipText`; for a strategy whose `DesyncPlan.parseIssue` is set, that's where a maintainer
  would surface it too — not wired up yet.

Main window: 380×500 pt, not resizable (like Windows). Power button 200 pt with ring, glow when on, rotating
arc when busy. Log expands the window by 190 pt.

Settings window: resizable, minimum 760×700 like Windows; the table grows with the window; option labels wrap.
Long translations: every button width = max(min width, measured text + 28), labels wrap instead of clipping,
same rule as the Windows UI tests. Retina is automatic with vector drawing (Canvas/NSBezierPath, SF Symbols not needed).

Menu bar item replaces the tray icon: Open, Connect/Disconnect/Cancel, Settings, Quit. Closing the main window
asks "Hide to menu bar / Quit" with "Remember my choice" (Windows `CloseActionForm`).

## 6. Data and logs

- `~/Library/Application Support/Zarp/zarp.json` — settings and results (same fields as Windows `AppConfig`).
- `~/Library/Application Support/Zarp/strategies.txt` — custom strategies.
- `~/Library/Logs/Zarp/zarp.log` — app log. Extension and helper log through `os.Logger`
  (subsystem `io.github.zarp`), the app shows their events via `snapshot()`.
- No telemetry. Network requests: `cdn-cgi/trace` during tests, as on Windows. No zapret2 downloads.

## 7. Licensing

- Windows Zarp: MIT (strategy list, texts, translations, algorithms can be reused with notice).
- zapret2 blobs: MIT.
- Zarp-Android: **GPL-3.0**. The macOS primary architecture does not copy Android code; only ideas are reused.
- The fallback (own MASQUE core) should build on usque (MIT) directly. Copying `zarpcore` from Android would make the app GPL-3.0.

## 8. Fallback

If the PoC fails, the app keeps sections 2–6 (engine, UI, data) and replaces Filter + Helper + WarpClient with:
`ZarpTunnel.systemextension` (`NEPacketTunnelProvider`) + Go MASQUE core (usque/quic-go, `darwin/arm64`) whose
UDP socket sends the fakes before quic-go's Initial (Android `dial.go` design). WARP registration moves into the app.
The Strategy/Result/Scan logic is identical because it was written against a `Tester` protocol, not against warp-cli.
