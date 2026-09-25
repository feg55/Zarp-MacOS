# Zarp for macOS: implementation plan

Order is fixed: nothing after phase 2 starts until phases 1–2 pass on a real Mac.

Legend for "Verified by": **Linux** = `swift test` of `ZarpCore` in Docker (possible without a Mac);
**Mac** = needs an Apple Silicon Mac with Cloudflare WARP installed and a paid Apple Developer account
(Network Extension entitlement).

## Phase 0 — research (done)

- `_reference/` with the 4 upstream repositories (ignored by git).
- `docs/MACOS_NETWORK_RESEARCH.md`, `docs/ARCHITECTURE.md`, this file.

## Phase 1 — network PoC: can we see and hold the WARP handshake?

Deliverables (in the repo now):
- `Packages/ZarpCore`: packet parser (IPv4/IPv6, optional Ethernet header), WARP ranges, QUIC Initial detector
  (the Windows filter rule), flow key, IPv4/UDP frame builder with checksums, strategy-args parser, built-in catalog,
  blob registry, IPC types. Unit tests.
- `PoC/Filter`: `NEFilterPacketProvider` with modes `off | observe | active`, flow table, per-flow event log.
- `PoC/Helper`: root LaunchDaemon, raw IPv4 sender, connects to the filter over XPC.
- `PoC/App`: minimal window + `--cli` commands (activate, enable/disable filter, register helper, mode, snapshot, test).
- `tools/poc-run.sh`: preflight (WARP, warp-cli, SIP, interfaces), capture with tcpdump, run scenarios, collect logs.
- `project.yml` for XcodeGen.

Exit criteria on a Mac (research §6):
1. Q7: `tools/poc-run.sh preflight` passes (warp-cli commands work).
2. Q1/Q2: `observe` mode logs WARP QUIC Initials: destination, port, protocol, sizes, `l3Offset`.
3. Q3: `active` + `direct` (delay only, no fakes) still reaches `Connected` and `warp=on`.
4. Q4: helper sends a raw frame, the byte-order choice is logged.

Verified by: Linux (ZarpCore), Mac (rest).

## Phase 2 — one working QUIC strategy

`WARP QUIC: fake google ×6` end-to-end:
- filter delays the first Initial, helper sends 6 × `quic_initial_www_google_com.bin` with the same 5-tuple, filter releases the Initial;
- Q5: the filter's per-flow log and the tcpdump capture both show `fake ×6 → real Initial` on one 5-tuple;
- Q6: `warp=on`; connect time and ping recorded as in Windows (`cdn-cgi/trace`, median of 3 after warm-up).

If Q1, Q3 or Q5 fail and cannot be fixed → stop and switch to the fallback (research §8), re-plan phases 3–8.

## Phase 3 — strategy engine

- All QUIC strategies: google ×3/×6/×10, vk ×6, google + vk, `ip_ttl`/`ip6_ttl` variants; `badsum` (optional).
- `ZarpEngine` port of `Engine.cs`: Connect, Quick scan (stop after N), Full scan, Test selected, Use, Disconnect, Cancel;
  phase-2 re-check on another endpoint; score `connect + 4×ping`; confirmed merge; save working strategy;
  endpoint isolation via `warp-cli tunnel endpoint set`, reset afterwards; transport switching with the
  Windows "wait until the protocol is applied" logic.
- `Tester` protocol so the engine is testable with fakes (port of the Windows/Android engine tests).
- WireGuard fakes (same mechanism, other detector) if time allows. TLS split/disorder behind a raw-TCP spike (unverified on macOS).

Verified by: Linux (engine with fake Tester, parser, scoring), Mac (real scans).

## Phase 4 — UI

- Theme, PowerButton, DarkButton, ToggleSwitch, NumberBox, DarkSelect, strategy `NSTableView` (ARCHITECTURE §5).
- Main window, settings window, close prompt, menu bar item, language menu.
- Snapshot tests: render every window in every language at 1× and 2×, fail on clipped/overlapping text
  (the same idea as Windows `tests/Zarp.Tests`).

Verified by: Mac (Xcode, XCTest snapshot rendering).

## Phase 5 — Quick/Full Scan polish

Progress `[n/m]`, cancel at any point (stops scan, resets endpoint, disconnects), tooltips with the stop-after
count / total, results persisted after each test, custom strategies file (open in default editor, reload on return).

## Phase 6 — self-healing

- Connect: saved → other confirmed (by score) → quick scan (Windows `ConnectAsync`).
- Watch `warp-cli -j status`: if WARP drops while Zarp says Connected, re-apply the strategy; after N failures run the Connect flow.
- Network change (`NWPathMonitor`): the next WARP reconnect gets fakes automatically (new 5-tuple); verify `warp=on` again.
- Extension/helper crash: detect via XPC invalidation, re-register, log.

## Phase 7 — settings, logs, localization

- Options: auto-connect, start with macOS (`SMAppService.mainApp`), on close, disconnect on exit, WARP addresses only,
  isolate tests, timeout, quick-scan count; data folder, licenses.
- Log panel + file log; extension/helper events merged in.
- 8 languages from Windows `Lang/*.txt` + `mac.*` keys; key/placeholder parity test (Linux).

## Phase 8 — packaging and signing

- Developer ID Application certificate, NE entitlement `content-filter-provider-systemextension`, provisioning profiles for app and extension.
- Hardened runtime, notarization (`notarytool`), stapling, `.dmg`.
- First-run flow: move to /Applications → approve system extension → allow content filter → approve helper in Login Items.
- Uninstall: disable filter, deactivate extension, unregister helper, `warp-cli tunnel … reset` like the Windows README.
- CI: GitHub Actions macOS runner builds, runs tests, notarizes on tags.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Filter does not see WARP packets (Q1) | Desktop model impossible | Fallback architecture |
| Delay makes the WARP handshake fail (Q3) | Same | Measure delay; keep injection under a few ms; fallback |
| Raw send blocked or changed in a future macOS | Fakes not sent | Helper logs errors; engine marks strategies failed; fallback |
| NE entitlement / notarization process | Cannot distribute | Apply early (phase 1 needs the entitlement anyway) |
| Raw TCP send not allowed on macOS | No H2 split/disorder | Show as unsupported; QUIC is WARP's default transport |
| User runs another VPN or content filter | Wrong scan results | Same warning as Windows; filter order is not controllable (Apple DTS) |
