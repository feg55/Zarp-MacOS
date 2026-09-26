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

## Phase 3 — WARP MASQUE core on macOS arm64, no DPI tricks yet — IN PROGRESS (2026-09-26)

Deliverables:
- **Done, verified against real Cloudflare infrastructure:** `zarpd/warp` account registration
  (`Register`, `HasAccount`, `LoadConfig`, `AccountEndpoint`) and a MASQUE/HTTP3 dial (`DialH3`),
  built directly on upstream `usque`'s public `api`/`config`/`models` packages (not Android's
  GPL-3.0 `zarpcore` — see `ARCHITECTURE.md` §8) plus two small original helpers
  (`zarpd/warp/cert.go`) for the two things upstream only exposes via its own unimportable
  `internal` package (self-signed cert + EC key pair generation — both trivial, standard
  `crypto/x509` usage). `zarpd/cmd/warppoc` registered a real (free, anonymous) WARP device and
  got back a live MASQUE endpoint (`162.159.198.2`); `zarpd/cmd/dialpoc` then performed the actual
  QUIC/TLS handshake and CONNECT-IP request against that real endpoint and got a session back in
  ~1 second, closed cleanly. Neither needs root — both ran directly, no sudo help needed.
- **Not yet done:** wire the resulting `connectip.Conn` to the phase-2 utun
  (`ipConn.WritePacketBuffer`/`ReadPacketZeroCopy`, the same calls Android's `tunnel.go` makes
  against its netstack device, now against the real one) — no SOCKS5 proxy, no second network
  stack. This is genuinely higher-risk than everything above: it needs root (utun) and touches
  routing, so expect to need the same real-Mac back-and-forth phase 2 did.
- **Not yet done, not yet researched in depth:** route setup — replace the default route via the
  utun for general traffic; the WARP endpoint's own socket must still go out the physical
  interface (`IP_BOUND_IF`/`IPV6_BOUND_IF`, unverified on this exact macOS version — see
  `ARCHITECTURE.md` §9.3, open question, not guessed at).
- No strategy executor yet — direct connection, to isolate "does MASQUE + real utun work at all"
  from "does the fake-packet trick work."

Exit criteria: register a WARP account, connect, and have *ordinary internet traffic on this Mac*
actually flow through the tunnel — verified with `curl https://www.cloudflare.com/cdn-cgi/trace`
showing `warp=on`, and a basic browsing/ping sanity check that nothing else on the Mac lost
connectivity (the routing loop risk in `ARCHITECTURE.md` §9.3).

Verified by: running it, on this Mac, with real network traffic — not a mock.

## Phase 4 — one Zarp strategy: `WARP QUIC: fake google ×6`

Deliverables:
- The socket-reuse trick itself (`ARCHITECTURE.md` §9.2): open the UDP socket, bind it to the
  physical interface, send `quic_initial_www_google_com.bin` (already vendored in
  `Resources/blobs/`, MIT) ×6 through it, then hand that same socket to quic-go for the real
  Initial.
- Confirm — with a packet capture (`tcpdump`), not just application-level success — that the fakes
  and the real Initial share one 5-tuple and leave in that order.

Exit criteria: `warp=on` via `cdn-cgi/trace`, connect time and ping recorded the same way as
Windows (median of 3 after one warm-up), and the tcpdump capture actually shows `fake ×6 → real
Initial` on one flow.

## Phase 5 — remaining QUIC strategies

google ×3/×10, vk ×6, google+vk, `ip_ttl`/`ip6_ttl` variants (TTL sockopts around the fake sends
only — `ARCHITECTURE.md` §9.2, `ttl_unix.go`'s approach, portable as-is to darwin via its
`//go:build unix` tag). `badsum` stays optional/open — macOS's non-raw-socket UDP path doesn't
obviously expose a checksum override; revisit only if the simpler strategies aren't enough.

## Phase 6 — HTTP/2 split/disorder

The MASQUE-over-HTTP/2 dial (`dialH2` in Android's `dial.go`, minus `VpnService.protect` which
becomes the same `IP_BOUND_IF` binding as phase 3/4) plus the TLS ClientHello desync wrapper
(`desync.go` — already 100% portable Go stdlib, reimplemented directly, see `ARCHITECTURE.md`
§9.2 and §8 on why reimplemented rather than copied).

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
