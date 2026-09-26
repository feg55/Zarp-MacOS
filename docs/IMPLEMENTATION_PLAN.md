# Zarp for macOS: implementation plan

> **Rewritten 2026-09-26** for the architecture pivot in [ARCHITECTURE.md](ARCHITECTURE.md) (Zarp
> owns the WARP connection itself, via a `zarpd` daemon built on the Go dependencies Zarp-Android's
> `zarpcore` uses). The old phase list (NEFilterPacketProvider system extension + root injector
> helper) is kept at the bottom, marked superseded, for the record — phase 1 of it is genuinely
> done and stays done; nothing after that will be built.

Order is fixed: each phase's exit criteria must actually be verified on a real Mac before starting
the next one. "Compiles" and "verified" are different claims; don't conflate them.

## Phase 1 — Swift project compiles and tests pass — DONE (2026-09-25)

Verified on a real Mac, not assumed:
- `cd Packages/ZarpCore && swift build && swift test`: clean, 52/52 tests, including 20 repeated
  runs of a scan-cancellation test that had a real race (fixed, not papered over).
- `xcodegen generate` + `xcodebuild build` for the `Zarp` app target: clean, zero warnings.
- The app actually launched and was visually inspected (screenshots, not just "should render"):
  main window, close confirmation (both "Hide to menu bar" and titlebar-close paths, via a real
  `NSWindowDelegate`), Settings, Strategies table (all 14 built-in strategies, correct "not
  tested" status), English and German. Two real bugs found this way and fixed: a `Text` view
  truncating instead of wrapping (missing `.fixedSize`), and a translation still saying "Windows"
  in 7 non-English language files for the one key that's a live macOS feature.

This phase's outcome doesn't change with the architecture pivot — `ZarpCore` and the UI are
unaffected (see `ARCHITECTURE.md` §2–§6). What changes is everything after it.

## Phase 2 — CLI prototype: open a real utun, move packets, close cleanly — DONE (2026-09-26)

No GUI, no WARP, no MASQUE yet. The single question: can a small Go program, run as root, create
a real macOS utun device, read and write packets on it, and close it cleanly, without needing
Apple entitlements, System Extensions, or SIP changes? **Yes, confirmed on this Mac.**

Delivered: `zarpd/` (Go module, `golang.zx2c4.com/wireguard`'s `tun.CreateTUN` — the same package
Android's `zarpcore` depends on, its real-device constructor rather than `netstack.CreateNetTUN`,
see `ARCHITECTURE.md` §9.1) and `zarpd/cmd/tunpoc`, which opens a utun, assigns it a
point-to-point IPv4 address via `ifconfig`, reads packets for a fixed duration logging each one,
answers ICMP echo requests from its peer address (a real write, not just a read — see below for
why that matters), and closes the device.

Confirmed:
- **Needs root.** Running unprivileged fails with `CreateTUN: operation not permitted`; `sudo`
  is sufficient (no entitlement, no System Extension, no SIP change) — exactly what this
  architecture exists to achieve. The real `SMAppService.daemon` install question is still phase 8.
- **A real bug, found by actually running it**, not by reading the wireguard-go source carefully
  enough first: Darwin's `NativeTun.Read`/`Write` both require 4 bytes of headroom before the IP
  packet (`tun_darwin.go`'s `bufs[0][offset-4:]`) for the kernel's/our own address-family header —
  calling `Read` with `offset=0` panics (`slice bounds out of range [-4:]`). Fixed: buffers
  allocated with the headroom, `Read`/`Write` called with `offset=4`, the IP packet itself lives at
  `buf[4:4+size]`.
- **Read and write both verified with real traffic**, not just "no error returned": `ping
  10.66.0.2` (the point-to-point peer address) from a second terminal got genuine ICMP echo
  replies with correct round-trip times (~0.3–0.5 ms) — proof the checksums, address swap, and
  write path are all actually correct, not just that `Write()` returned nil. After the 15 s test
  duration elapsed and the device closed, the *same* ping session immediately started timing out
  and `ifconfig utun9` reported the interface gone — clean teardown confirmed, not assumed.

Verified by: running it on this Mac as root, with real `ping` traffic in a second terminal, output
inspected directly (not summarized by the tool that ran it).

## Phase 3 — WARP MASQUE core on macOS arm64, no DPI tricks yet — DONE (2026-09-26)

**The core architectural bet is proven: real internet traffic flows utun → MASQUE → Cloudflare →
back on this Mac, with no NetworkExtension entitlement, no paid Apple Developer Program
membership, and no SIP change.** `curl --max-time 5 https://1.1.1.1/cdn-cgi/trace` through a
`zarpd/cmd/tunnelpoc`-managed tunnel returned `warp=on`, colo `HEL`, egress IP `104.28.222.16` — a
genuine Cloudflare WARP address, not the machine's real one. Same signal Windows and Android Zarp
both use to confirm a working tunnel.

Delivered:
- `zarpd/warp`: account registration and MASQUE/HTTP3 dial, built directly on upstream `usque`
  (not Android's GPL-3.0 `zarpcore` — `ARCHITECTURE.md` §8). Verified standalone first
  (`warppoc`/`dialpoc`, no root needed) before combining with anything privileged.
- `zarpd/tunnel`: pumps packets between a real utun (`Read`/`Write`, 4-byte headroom, phase 2) and
  the MASQUE session's `connectip.Conn` (`WritePacketBuffer`/`ReadPacketZeroCopy`) directly — no
  userspace netstack, no local SOCKS5 proxy, unlike Android (`ARCHITECTURE.md` §9.1).
- `zarpd/route`: `CurrentDefault()` (shells out to `route -n get default`, the same pragmatic
  choice as `ifconfig` for address config) plus `BindUDP` (`IP_BOUND_IF`/`IPV6_BOUND_IF`) —
  confirmed to actually prevent the WARP control socket from looping back into its own tunnel,
  which was `ARCHITECTURE.md` §9.3's open question. `AddHostRoute`/`DeleteHostRoute` for now (a
  single narrow route, not the default route — see below).
- `zarpd/cmd/tunnelpoc` ties it together and was run as root on this Mac: registered account →
  bind WARP socket to the physical interface → MASQUE dial → open utun → route exactly one test
  host (`1.1.1.1`) through it → pump packets → `warp=on` confirmed from a second terminal → clean
  teardown (route removed, confirmed by re-running `curl` afterward getting the normal, non-WARP
  answer — not just assumed from the log line saying so).

This milestone's first run was unintentionally confounded: `route -n get default` reported
another VPN's utun (identified afterward as **Happ**, an unrelated third-party proxy client
already connected on the test Mac — not Cloudflare WARP, which remains uninstalled) as the
current default, and `CurrentDefault()` correctly bound to it, meaning that first success actually
routed through Happ's tunnel rather than the raw physical network. Caught before drawing any
conclusion from it, Happ was disconnected, and the default route was confirmed back on `en0` with
a real LAN gateway before redoing the test — see phase 4 below for why re-establishing a clean
baseline mattered a great deal here. `CurrentDefault()`'s behavior itself (bind to whatever's
actually reaching the internet right now) was correct in both cases; the lesson is procedural —
always confirm the physical interface is genuinely physical before trusting a result — not a code
fix. Full default-route takeover (all traffic, not just one test host) is still materially higher
blast radius than this milestone's narrow host route and remains its own next, separate step.

## Phase 4 — one Zarp strategy: `WARP QUIC: fake google ×6` — DONE (2026-09-26)

**Real DPI evasion, verified against real interference, not a hypothetical.** The control case
first: with Happ disconnected (clean physical `en0`, real gateway) and no fake-packet strategy, a
direct MASQUE dial genuinely times out —
`DialH3: connect-ip: connect-ip: failed to read response: http3: ... connect timeout` — and
`cdn-cgi/trace` confirms `warp=off`. The test Mac's network is in Russia (`loc=RU` in the trace),
which is independently documented to specifically target WARP/MASQUE traffic — this is a real,
currently-active block, not a flaky connection or a bug in `DialH3` (the exact same function
succeeded minutes earlier once Happ's tunnel was in the path, and succeeds below once the fake
strategy is).

Then the actual strategy, same network, same physical interface, nothing else changed: `zarpd/warp`'s
`SendFakes` writes 6 copies of `Resources/blobs/quic_initial_www_google_com.bin` (1200 bytes each,
7200 bytes total) through the UDP socket before `DialH3` reuses that *exact* socket for the real
QUIC Initial — confirmed identical (`local=[::]:53876` before and after, asserted in code, not just
logged) rather than assumed. Full ordering visible in the log: `fake 1/6 sent` … `fake 6/6 sent`,
then `--- real QUIC handshake beginning ---`, then `MASQUE connected`. Result: `warp=on`, a genuine
Cloudflare WARP egress IP, on the same network and the same physical interface that just timed out
seconds before with no strategy. Exit criteria (same socket, fakes first, real Initial after,
tunnel connects, `warp=on`) all met with real evidence, not asserted.

Not yet done: a real `tcpdump` capture independently confirming the fake packets and the real
Initial share one 5-tuple on the wire (the application-level evidence above is already strong —
same local socket address, asserted in code, plus a result that flips from timeout to success with
only the strategy changing — but a packet capture would be additional, independent confirmation,
not yet gathered).

Verified by: running it on this Mac as root, with a real `curl` request to a well-known trace
endpoint in a second terminal, output inspected directly — not summarized, not assumed from a
success log line.

## Phase 5 — remaining QUIC strategies — mechanism DONE (2026-09-26), parameter sweep open

`zarpd/warp.SendFakes` already takes an ordered list of `FakeStep{Blob, Repeats, TTL}`, so
"the remaining strategies" turned out to mostly be *arguments* to code that already existed, not
new code paths — confirmed by actually exercising the two that were genuinely untested:

- **Multi-step ordering** (`WARP QUIC: fake google + vk`): `zarpd/cmd/tunnelpoc` now takes a
  repeatable `-fake path[:repeats[:ttl]]` flag. Run with `-fake google...:6:4 -fake vk...:6`: the
  log shows all 6 google fakes (1200 bytes each, `ip_ttl=4`) completing before any vk fakes start
  (1357 bytes each, default TTL), same socket confirmed identical before and after both steps,
  `warp=on` on the same real-DPI network as phase 4. Proves steps genuinely run in order on one
  socket, not just that two independent blobs each work in isolation.
- **`ip_ttl` variant**: the same run set `ip_ttl=4` for the google step — `SendFakes`' TTL
  save/restore path executed with no error and the connection still succeeded, so the sockopt
  dance (`getTTL`/`setTTL`, `IP_TTL`/`IPV6_UNICAST_HOPS`) is confirmed working on this macOS
  version, not just compiling.
- **vk ×6** was exercised as step 2 of the same run.

**Not separately re-tested, deliberately:** google ×3/×10 are pure repeat-count changes to the
exact same, already-proven code path (×6 already proven twice, in phases 4 and 5) — there's no new
mechanism there to verify, just a different number, so no marginal evidence to gain from spending
another real-Mac round-trip on them. `ip6_ttl` follows the same `IPV6_UNICAST_HOPS` sockopt as
`ip_ttl`'s `IP_TTL` in the same function; genuinely IPv6-specific behavior (does the WARP endpoint
even offer a v6 dial path the same way) is still open and matters more than re-proving the sockopt
call itself. `badsum` stays optional/open — macOS's non-raw-socket UDP path doesn't obviously
expose a checksum override; revisit only if the simpler strategies aren't enough.

## Phase 6 — HTTP/2 split/disorder — mostly DONE (2026-09-26), `disorder` mode open

`zarpd/warp.DialH2` (MASQUE over HTTP/2 — TCP dial via a `*net.Dialer` bound to the physical
interface through `route.Physical.Control`, same job as `BindUDP` does for `DialH3`) and
`zarpd/warp.NewDesyncConn`/`ParseDesync` (the TLS ClientHello split/disorder wrapper — see
`ARCHITECTURE.md` §9.2 and §8 for why reimplemented directly rather than adapted from Android's
`desync.go`) are both written and exercised on this Mac's real network.

**A genuinely useful finding, not the result expected going in:** unlike QUIC/UDP (actively
blocked, phase 4), this network does **not** block plain MASQUE-over-HTTP/2 at all — a direct
`DialH2` with no desync already got `warp=on`. Consistent with Russian DPI more commonly
fingerprinting QUIC specifically than generic TLS-over-TCP-443, which is far harder to
distinguish from ordinary HTTPS traffic without deep SNI inspection. That makes this phase's
evidence a different *kind* of proof than phase 4's "broken → fixed": there was nothing broken
here for `split` mode to fix, so its success shows the mechanism works correctly (a real server
accepted the split ClientHello, `warp=on`) without showing it was *necessary* on this particular
network.

- **`split:host,midsld`**: `warp=on`, both with the dial itself and through the full utun tunnel
  (`cdn-cgi/trace` from the self-check). The split write path, SNI-relative position resolution,
  and `SetNoDelay` handling are all confirmed working end to end.
- **`disorder:host`**: **reproducibly fails**, twice, with the same signature — the initial
  MASQUE/CONNECT-IP handshake succeeds ("MASQUE connected" is logged), but the tunnel's data plane
  never actually works: every `cdn-cgi/trace` self-check attempt times out (curl exit 28), and the
  pump eventually dies with `connect-ip read: read tcp ...: read: operation timed out`. Not
  written off as flakiness — it reproduced with an identical failure mode on a clean physical
  network both times, and `split` mode (same code, same network, different mode) works fine. Most
  likely explanation, not yet confirmed: the deliberately-dropped, TTL=1 first TCP segment is
  supposed to reach the destination later via the kernel's own automatic retransmission (at
  whatever TTL is current *then*, which by design is back to normal by the time that happens) —
  something in that recovery path isn't completing correctly on this Mac, or within the test's
  wait budget. Properly diagnosing which needs a `tcpdump` capture of the actual segment/TTL/retransmission
  behavior on the wire — real evidence, not another guess — which hasn't been gathered yet. Not
  blocking phase 6 overall, since `split` mode already proves the desync mechanism family works;
  revisit `disorder` with packet-level evidence before relying on it.

Also worth remembering operationally, not just for this phase: the test Mac has an unrelated,
pre-existing VPN client (Happ) that reconnects on its own fairly quickly once disconnected —
every real-Mac test in phases 3-6 had to confirm (and sometimes re-confirm mid-session) that
`route -n get default` was genuinely the physical interface, not Happ's tunnel, before the result
meant anything.

## Phase 7 — connect the backend to the existing Swift engine and UI — DONE (2026-09-26)

- `ZarpdClient` (`App/Sources/Zarp/ZarpdClient.swift`): a `WarpConnectionProvider` + `WarpProbe`
  implementation (`EngineProtocols.swift`) that talks to `zarpd` over the newline-delimited-JSON
  Unix socket IPC (`zarpd/ipc`, `ARCHITECTURE.md` §9.4), replacing `Unimplemented*`. `AppViewModel`
  now defaults `connections`/`probe` to it instead of the unimplemented placeholders.
- `ZarpEngine`'s Connect/Quick Scan/Full Scan/self-healing logic needed zero changes — it was
  written against the `WarpConnectionProvider`/`WarpProbe` protocols, not any concrete backend, so
  this phase really was wiring, not re-architecture.
- `NetworkInspector` real implementation (`getifaddrs`) is still `UnimplementedNetworkInspector` —
  out of scope for this phase (not on the Connect/Scan critical path) and not built yet.

**Verified with a real, driven GUI end-to-end test — not just "should work":** the built
`Zarp.app` was launched for real and driven via Accessibility automation (`System Events`) with a
real root `zarpd` already listening, while a second, independent verification channel (`curl
https://1.1.1.1/cdn-cgi/trace`, `netstat -rn`, `ifconfig`) confirmed actual OS network state
outside the app entirely, and zarpd's own terminal log served as a third, independent witness:

1. Settings opened, "WARP QUIC: fake google ×6" row selected, "Использовать" clicked → app showed
   a live "⏳ Подключение..." progress state, then **"Подключено" / "Стратегия: WARP QUIC: fake
   google ×6"**. Independently: `curl .../cdn-cgi/trace` → `warp=on`, a genuine Cloudflare WARP
   egress IP, `netstat` showed a real `1.1.1.1 → utun8` host route, `ifconfig utun8` showed a real
   WARP-assigned `172.16.0.2`. zarpd's log: `open #2 transport=masqueH3 connectMs=203 dev=utun8
   persistent=true`.
2. Power button clicked → app showed **"Отключено"** and the disconnected hint text.
   Independently: `curl` fell back to the ordinary non-WARP egress IP (`warp=off`), the `utun8`
   route was gone from `netstat`. zarpd's log: `zarpd: closed #2 (utun8)` with a clean
   `H3_NO_ERROR (local)` stream close, logged at the same moment as the click.

This exercised the complete real chain for the first time: SwiftUI → `AppViewModel` →
`ZarpEngine` → `ZarpdClient` → Unix socket IPC → root `zarpd` → real MASQUE/HTTP3 dial with the
QUIC "fake google ×6" desync that phase 4 already proved defeats this network's real DPI → real
utun + narrow route → real packet pump, and the same in reverse for a clean disconnect.

**Two real bugs found by actually running this, both fixed, not worked around:**

- `SettingsView` unconditionally showed a red "The macOS networking layer isn't built yet" banner
  (`vm.isReady` has been `true` since phase 1) — stale copy from before `zarpd` existed, left in
  place through phases 2-6 because nothing exercised the Settings screen against a real backend
  until now. Removed the banner, its `mac.notImplemented` localization key (only ever in `en.txt`),
  and the now-false "networking layer doesn't exist" claims in `StrategiesView`'s and
  `MainWindowView`'s doc comments.
- `PowerButton` (`App/Sources/Zarp/Components/PowerButton.swift`) is a custom `Canvas` control
  wired up with a `DragGesture`, not a real SwiftUI `Button`, with only `.accessibilityAddTraits(
  .isButton)` — which makes Accessibility clients *describe* it as a button but does not wire up
  an actual activation handler. A synthetic AXPress (exactly what VoiceOver's "activate" gesture
  sends, and what this session's own UI automation sent) was silently a no-op: the first
  disconnect attempt produced no state change anywhere (UI, `curl`, `netstat`, or zarpd's log all
  stayed on "connected") even though System Events reported the click as delivered successfully.
  Fixed with `.accessibilityAction(.default) { action() }` alongside the existing trait, then
  re-verified — the second disconnect attempt worked and is the one evidenced above. Checked for
  the same pattern elsewhere (`grep` for `DragGesture`/`TapGesture`/`accessibilityAddTraits` across
  `Components/`/`Screens/`) — `PowerButton` was the only offender.

## Phase 7.5 — real product-behavior validation (Quick Scan, Full Scan, auto-select, self-heal) — DONE (2026-09-26)

Phase 7 proved the IPC chain works end to end with one manually preselected, already-known-good
strategy. This phase validated the actual product workflow through the real app — Quick Scan, Full
Scan, double-check, auto-selection, persistence, and self-healing fallback — the way a real user
would actually drive it, on the real DPI-restricted network. It found and fixed two real bugs
neither Phase 7 nor any CLI test had exercised, then re-verified every item on the user's own
validation checklist against the fixed build.

**Bug 1 — every scan-driven test failed instantly, including already-proven strategies.** The
first real Quick Scan run failed on all 20 strategies in seconds — far too fast to be real DPI
timeouts. Root cause: `ZarpEngine.test()` passes a synthetic per-attempt uniqueness token (e.g.
`"isolated-42"`, whenever "isolate tests" is on — the default) as `endpoint`, documented in
`ZarpEngine.nextEndpoint()`'s own comment as a placeholder never reconciled with a real backend.
`zarpd`'s `dialH3`/`dialH2` blindly fed that string into `net.ParseIP`, got `nil` back, and dialed
`&net.UDPAddr{IP: nil, Port: 443}` — an instant local socket error, not a network condition. Manual
"Использовать" never hit this because `apply()` always passes `endpoint: nil`; only the scan path
(`test()`) passes the token, so nothing before this phase had ever exercised it against the real
`zarpd` backend. Fixed in `zarpd/cmd/zarpd/main.go`: only honor `p.Endpoint` as an override when it
actually parses as an IP, otherwise fall back to the account's real endpoint.

**Bug 2 — any Settings-screen change after a scan silently erased discovered results.** Found by
the user directly: after a real Quick Scan produced a genuine `confirmed: true` result, the main
window read "Рабочая стратегия не найдена" — a message that should only appear when a scan finds
*nothing*. Root cause: `AppViewModel.settings` is captured once at launch and never refreshed from
the engine afterward (`AppViewModel.refresh()` updates `results`/`selectedStrategyId` directly from
the engine, but never touches `settings`); any toggle/picker on the Settings screen calls
`engine.updateSettings(vm.settings)` with that stale whole-struct snapshot, and
`ZarpEngine.updateSettings` wholesale-replaced its own `results`/`selectedStrategyId` with whatever
that snapshot had at launch. Confirmed on disk: `zarp.json` held results timestamped from a much
earlier, already-superseded run, matching exactly what a stale launch-time snapshot would contain.
Fixed in `ZarpEngine.updateSettings`: preserves its own live `results`/`selectedStrategyId` rather
than trusting the caller's copy of them (`ZarpEngineTests.testUpdateSettingsDoesNotClobberResultsOrSelectedStrategy`
locks this in). Re-verified for real, not just in the unit test: a real Quick Scan's
`confirmed: true` result and `selectedStrategyId` survived a disconnect, a real Settings-screen
change (visible in before/after screenshots: "При закрытии" changed from "Закрывать приложение" to
"Спрашивать каждый раз"), and a full Cmd+Q + relaunch, with the final reconnect independently
verified `warp=on`.

**Full checklist, verified against the fixed build, all through the real app on the real
DPI-restricted network (not synthetic/CLI):**

- Quick Scan and Full Scan both run for real through `zarpd`, with per-strategy progress text
  (`"N/20: <strategy name>"`) matching zarpd's own log line for line.
- WireGuard strategies fail cleanly and immediately with zarpd's real `"transport \"wireGuard\" not
  supported yet"` error — correctly surfaced as a normal failed result, not a hang or crash.
- Direct/no-desync (`Без zapret`) reliably times out (`"нет подключения за 15 с"`), matching Phase
  4's original finding; the HTTP/2 direct variant is more variable run to run (sometimes passes,
  sometimes fails) — consistent with Phase 6's finding that this network's QUIC blocking is more
  consistent than its handling of plain TLS-over-TCP-443.
- Working strategies get real connect-ms/ping values (e.g. 216ms/26ms, 134ms/38ms, 155ms/27ms,
  136ms/26ms across different runs — real, varying numbers, not placeholders).
- The phase-2 independent recheck genuinely produces `✔✔` only for strategies that pass *twice*;
  strategies that passed once but failed their recheck correctly show as not confirmed
  (`"не подтвердилась"`), and the catalog's originally-proven strategy (`fake google ×6`) was
  observed both confirming and failing its recheck across different runs — real DPI/network
  variability the double-check mechanism exists to catch, not a bug.
- Auto-selection connects with the best confirmed candidate and persists the selection.
- Every connected state was independently verified via `curl https://1.1.1.1/cdn-cgi/trace` →
  `warp=on`, not just the app's own self-report.
- Disconnect tears down cleanly: `curl` falls back to the ordinary non-WARP IP, the narrow
  `1.1.1.1` route disappears from `netstat`, no utun device is left holding an IP.
- Self-healing fallback exercised for real: pointed `selectedStrategyId` at a strategy with a
  genuine (not fabricated) failure — an unimplemented WireGuard transport — while leaving
  previously-confirmed results in place, then pressed Connect once. The saved strategy failed as
  expected; the engine tried the other previously-confirmed candidates, which *also* failed under
  that run's real network conditions; it then correctly escalated to a full automatic rescan and
  connected with whatever that rescan found working, independently verified `warp=on`. A messier,
  more complete demonstration than "falls back to the known-good strategy" alone — it walked every
  tier of `ZarpEngine.connect()`'s fallback chain for real.

**Operational finding, not a bug:** the same pre-existing Happ VPN confound from earlier phases
recurred repeatedly during this phase's multi-minute scans — it auto-reconnects within roughly a
minute or two of being disconnected, which is long enough to corrupt a scan that started clean. One
full Quick Scan run had to be discarded and cancelled after `route -n get default` showed Happ's
`utun` had silently become the default route partway through, producing suspiciously fast "no route
to host" failures instead of real DPI timeouts. Per explicit user instruction, VPN
connect/disconnect is never done by Claude directly — only reported, with the user toggling it
themselves.

## Phase 8 — install/manage `zarpd` cleanly

- `SMAppService.daemon` registration (one admin authentication at install, matching what the old
  design already planned for its helper — `ARCHITECTURE.md` §7).
- Crash/restart cleanup: routes and utun must not be left dangling if `zarpd` dies unexpectedly —
  `ARCHITECTURE.md` §9.3, open question.
- Uninstall flow: disable/unregister the daemon, remove routes, reset WARP registration state.
- Notarization, `.dmg`, CI — same shape as the old design's phase 8, not revisited in depth until
  the earlier phases are real.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| `IP_BOUND_IF`/route-exclusion doesn't cleanly prevent a loop (`ARCHITECTURE.md` §9.3) | WARP control traffic gets routed back into its own tunnel, connection can't establish | Phase 3's exit criteria specifically tests this with real traffic before building anything on top |
| utun creation needs more privilege/entitlement than expected | Blocks phase 2 outright | Phase 2 is deliberately the very first thing tried, before any WARP/MASQUE code exists to waste |
| MASQUE dial works but real utun packet pumping has framing/MTU issues netstack would have hidden | Silent packet loss or corruption | Phase 3's exit criteria requires real traffic, not just a successful handshake |
| Reimplementing (not copying) Android's dial/desync logic introduces subtle bugs the proven code didn't have | Wasted debugging time | Reference Android's code closely while writing macOS's version (`ARCHITECTURE.md` §9.2 documents exactly what's being reimplemented and why), and verify each phase's exit criteria with real network captures, not just "connects" |
| User runs another VPN | Routing conflicts | Detect and warn, same spirit as Windows' `IsForeignVpnAdapter` check — design once phase 7's `NetworkInspector` is written |

---

## Superseded: NEFilterPacketProvider / System Extension plan (kept for the record)

This was the plan before the 2026-09-26 pivot (`ARCHITECTURE.md` §10). Phase 1 below is the same
phase 1 above (unaffected by the pivot). Phases past it were **rejected**, not merely deprioritized
— a free Apple Developer "Personal Team" account was confirmed, empirically, unable to get the
Network Extensions or System Extension capability at all, and the only ways past that (a paid
Apple Developer Program membership, or disabling SIP for local-only `systemextensionsctl developer
on` loading) are exactly what the new architecture exists to avoid requiring for basic
functionality. Nothing past phase 1 below will be built; kept only so the reasoning isn't lost.

### Phase 1 — research (done)

- `_reference/` with the 4 upstream repositories (ignored by git).
- `docs/MACOS_NETWORK_RESEARCH.md`, `docs/ARCHITECTURE.md`, this file (all now superseded/rewritten).

### Phase 2 (superseded) — network PoC: can we see and hold the WARP handshake?

Deliverables that were actually built before rejection: `Packages/ZarpCore`'s parser/detector
pieces were never written (the packet parser, QUIC Initial detector, flow key, and IPv4/UDP frame
builder this phase called for turned out not to exist yet when checked against the real repo —
only `Support/IPAddress.swift` and `WarpAddressRanges.swift` did). `PoC/Filter` — a minimal
`NEFilterPacketProvider` system extension target — was built far enough to get the account-tier
signing error above; `PoC/Helper` and `PoC/App`'s CLI were never started.

### Phases 3–8 (superseded)

One working QUIC strategy end-to-end via packet delay+injection, full strategy engine, UI
(already done independently of this — see phase 1 above and `ARCHITECTURE.md` §5), Quick/Full
Scan polish, self-healing, settings/logs/localization (also already done), packaging and signing.
None of these were reached; the architecture they were designed for is rejected.
