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

## Phase 7 — connect the backend to the existing Swift engine and UI

- `ZarpdClient`: a `WarpConnectionProvider` + `WarpProbe` implementation (`EngineProtocols.swift`)
  that talks to `zarpd` over IPC (shape TBD, `ARCHITECTURE.md` §9.4) instead of throwing
  `Unimplemented*` errors.
- `NetworkInspector` real implementation — narrower scope now than the old design assumed, since
  Zarp owns the tunnel outright rather than needing to detect interference from other VPN adapters
  the way a packet filter sitting beside the official WARP client would have.
- `ZarpEngine`'s Connect/Quick Scan/Full Scan/self-healing logic is unchanged — it was written
  against the `WarpConnectionProvider`/`WarpProbe` protocols, not against any concrete backend, so
  this phase is wiring, not re-architecture.

Verified by: real Connect/Scan flows in the actual running app, screenshots, not just "should work."

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
