# macOS network research: can Zarp work beside the official WARP client?

> **SUPERSEDED 2026-09-26.** This whole document researches the "intercept the official WARP
> client's traffic" architecture. That approach is **rejected**, not merely paused: see
> [ARCHITECTURE.md](ARCHITECTURE.md) §10 for why, and §9 for the research that replaces it (Zarp
> owns the WARP connection itself, modeled on Zarp-Android's `zarpcore`). The findings below are
> kept as a historical record — several of them (the NEFilterPacketProvider API shape, the free
> Personal Team account-tier gating, `IP_BOUND_IF`) turned out to still matter for the new
> architecture and are cross-referenced from there. Nothing below should be treated as describing
> current or planned behavior; `docs/IMPLEMENTATION_PLAN.md` no longer follows this document's
> phase 1.

Status: research done, PoC (`PoC/Filter`) wired far enough to get a definitive answer (see
[ARCHITECTURE.md](ARCHITECTURE.md) §10) — then the whole architecture was rejected before finishing
it. Everything under "Confirmed" has a source. Everything under "Open questions" was meant to be
settled by the PoC before the full app was built on this design; most no longer will be.

## 1. Short answer

Yes, the desktop model looks feasible on macOS, but not with zapret2 and not with a
single process:

| Windows Zarp | macOS Zarp (proposed) |
|---|---|
| WinDivert driver catches outbound QUIC Initials to WARP IPs | `NEFilterPacketProvider` system extension sees the same outbound packets on the physical interface and can **delay** one |
| winws2 injects fake packets with the same 5-tuple, then releases the real Initial | a small **root helper daemon** (SMAppService) sends the fakes through a raw socket with the same 5-tuple, then the filter **allows** the delayed Initial |
| warp-cli picks protocol and endpoint | warp-cli (ships with the macOS WARP client, to be confirmed on the test Mac) |
| Tunnel never passes through zapret | Same: only the first QUIC Initial of each WARP flow is held back, everything else gets `.allow` immediately |

The raw sender cannot live in the extension, because Network Extension system extensions
must be sandboxed and raw sockets fail in the sandbox (see 5.4). That is why the helper exists.

If the PoC shows that the packet filter never sees the WARP daemon's packets, or that delay
plus injection breaks the handshake, the fallback is the Android design: Zarp's own MASQUE
core inside an `NEPacketTunnelProvider`, with fakes sent from the tunnel's own UDP socket (section 8).

## 2. What Windows Zarp really does (from source)

Studied: `_reference/Zarp/src/Zarp/**`.

- **Interception.** `Zapret.BuildArgs` (`Core/Zapret.cs:375`) gives winws2 a WinDivert filter:
  - QUIC (`Zapret.cs:63`): `outbound and udp and udp.PayloadLength>=256 and udp.Payload[0]>=0xC0 and udp.Payload[0]<0xD0 and udp.Payload[1]==0 and udp.Payload16[1]==0 and udp.Payload[4]==1`
    — a QUIC v1 long-header Initial.
  - WireGuard (`Zapret.cs:66`): payload of exactly 148 bytes starting with `01 00 00 00`.
  - MASQUE/HTTP2: TCP port 443 (any port when restricted to WARP IPs).
  - With "Intercept WARP addresses only" on (default), `WarpIpFilter` (`Zapret.cs:400`) limits all of it to
    `162.159.192.0–162.159.199.255`, `162.159.204.0/24`, `188.114.96.0–188.114.99.255`,
    `2606:4700:100::–2606:4700:1ff:ffff:ffff:ffff:ffff:ffff`, `2606:4700:d0::–2606:4700:df:ffff:ffff:ffff:ffff:ffff`.
- **Desync.** The strategy args are passed as-is to winws2, e.g.
  `--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6`. In zapret2 `fake`
  (`zapret2/lua/zapret-antidpi.lua:449`) sends the blob with the flow's own addressing, only on the first
  replay piece, before the original packet continues. Blobs are real captures shipped with zapret2
  (`files/fake/quic_initial_www_google_com.bin`, 1200 bytes, itself a QUIC v1 Initial `c3 00000001 …`).
- **WARP control.** `Core/Warp.cs` uses `warp-cli --accept-tos`: `-j status`, `registration show/new`,
  `tunnel protocol set MASQUE|WireGuard`, `tunnel masque-options set h3-only|h2-only`,
  `tunnel endpoint set IP:port|reset`, `connect`, `disconnect`.
- **Test** (`Core/Engine.cs:355`): disconnect → set transport → pin a fresh endpoint (`Warp.NextEndpoint`,
  `Warp.cs:150`, MASQUE `162.159.198.1/2` × ports `443,500,1701,4500,4443,8443`) → start winws2 → connect
  → wait for `Connected` (timeout 15 s default) → `MeasureAsync(3)` (`Warp.cs:198`): 1 warm-up + 3 requests
  to `https://www.cloudflare.com/cdn-cgi/trace?<guid>`, any answer without `warp=on|plus` fails, result is the median.
- **Scan** (`Engine.cs:379`): phase 1 walks the list (Quick stops after N working, default 3; Full tests all),
  phase 2 re-tests every candidate on another endpoint, best score first. Confirmed result: `max(connect)`,
  `avg(ping)`. **Score** (`AppConfig.cs:29`) = `connectMs + 4 × pingMs`.
- **Self-healing** (`Engine.cs:83`): saved strategy → other confirmed strategies by score → quick scan.
  A strategy that fails on apply is marked `result.applyFailed`.

Everything above except the WinDivert/winws2 part is plain logic and ports directly to Swift.

## 3. What Android Zarp does (from source)

Studied: `_reference/Zarp-Android/core/zarpcore/*.go`, `app/src/main/java/.../{core,masque,strategy,net}`.

- No official WARP app. usque (MASQUE client in Go) is embedded; `zarpcore.Register` creates a free WARP
  device and enrolls a P-256 key (`account.go`).
- **Key trick** (`dial.go:87`): before each QUIC dial the Go core asks Kotlin for a UDP socket
  (`SocketFactory.OpenUDP`). Kotlin sends the strategy's fakes from that socket (`FakeStrategy`,
  `ZarpStrategy.kt:46`), then hands the fd back, and quic-go sends the real Initial from the **same socket**.
  Same 5-tuple without raw sockets. TTL variants lower `IP_TTL`/`IPV6_UNICAST_HOPS` only for the fakes.
- HTTP/2: `desync.go` splits the first TLS record into segments (`split`), or sends the first segment
  with TTL=1 so the kernel retransmits it later (`disorder`).
- badsum / md5 / seqovl / badseq / WireGuard are marked unsupported (no raw sockets without root).
- Same scan, re-check, score and self-healing as Windows (`ZarpEngine.kt`), same `cdn-cgi/trace` rule.

## 4. zapret / zapret2 on macOS (from upstream source and docs)

- **zapret2 does not support macOS.** `zapret2/docs/manual.en.md:319`: *"macOS is not supported because it
  lacks a suitable packet interception and management tool. The standard BSD tool `ipdivert` was removed
  from the kernel by the manufacturer."* `docs/readme.md:12` (ru): macOS "is not supported and unlikely to
  be for technical reasons". The top-level `Makefile` has no `mac` target (only default, `systemd`,
  `android`, `bsd`), `docs/compile/build_howto_unix.txt` lists no macOS build.
- **zapret v1** has `make mac` (`nfq/Makefile:37`), but `docs/bsd.en.md` ("MacOS") says `dvtws` "does compile
  but is useless": `divert-packet` does not work in macOS `pf`, and a divert socket "behaves exactly as raw
  socket". Only `tpws` (a TCP transparent proxy via `pf rdr` + undocumented `DIOCNATLOOK`) works.
  tpws cannot do UDP/QUIC at all.
- **What is reusable:** the fake blobs (`files/fake/*.bin`, MIT), the strategy argument syntax, and knowledge
  from `darkmagic.c`: on `__APPLE__` zapret sends injected frames through `socket(family, SOCK_RAW, IPPROTO_DIVERT)`
  with a full IP header (`nfq/darkmagic.c:1732`). The engine itself (nfqws2/winws2 + LuaJIT) is not reusable
  on macOS because nothing can feed it packets.
- **Conclusion:** a small native backend is required. It only has to implement what Zarp uses:
  QUIC `fake` ×N with blobs (google, vk, google+vk), `ip_ttl`/`ip6_ttl`, optionally `badsum`,
  and TLS `multisplit`/`multidisorder`.

## 5. macOS APIs: what is confirmed

### 5.1 NEFilterPacketProvider (packet filter, system extension)

Apple documentation ([NEFilterPacketProvider](https://developer.apple.com/documentation/networkextension/nefilterpacketprovider), via Context7):

- Handler signature: `(NEFilterPacketContext, NWInterface, NETrafficDirection, UnsafeRawBufferPointer) -> NEFilterPacketProvider.Verdict`.
- `Verdict`: `.allow`, `.drop`, `.delay`.
- `func delayCurrentPacket(_ context: NEFilterPacketContext) -> NEPacket` — "Use this method to delay a packet and later allow or block it".
- `func allow(_ packet: NEPacket)` — "Allows delivery of a previously delayed packet."
- Enabled through `NEFilterManager` with `NEFilterProviderConfiguration.filterPackets = true` and
  `filterPacketProviderBundleIdentifier` (macOS 10.15+). Info.plist `NEProviderClasses` key:
  `com.apple.networkextension.filter-packet`.
- **Interfaces:** per Apple DTS on the developer forums, packets are seen on interfaces with Ethernet or
  raw-IP link layer (physical interfaces and NE `utun`), **not** loopback or PPP
  ([thread 133622](https://developer.apple.com/forums/thread/133622)). For a VPN that does not use a
  NetworkExtension tunnel, the filter sees "only the outer VPN packets (port 443 TCP/UDP)"
  ([thread 705738](https://developer.apple.com/forums/thread/705738)). The outer packets are exactly what Zarp needs.
- The API offers no way to **create** packets: "This handler is not meant to tag or alter packets"
  (Apple DTS, [thread 660179](https://developer.apple.com/forums/thread/660179)). Injection must happen elsewhere.

### 5.2 NETransparentProxyProvider (flow-level)

- Works on flows: `handleNewFlow(_:)` / `handleNewUDPFlow(_:initialRemoteEndpoint:)`; returning `false`
  lets the flow go directly to its destination (transparent proxy only). Matching is by `NENetworkRule`s.
- To add fakes, Zarp would have to **own** the WARP UDP flow and relay every datagram for the lifetime of the
  tunnel from its own socket. That breaks the "tunnel never passes through Zarp" property, adds CPU/latency,
  and it is not documented whether flows from a root daemon like `CloudflareWARP` are delivered. Kept as plan C.

### 5.3 Other options, rejected

| Option | Why not |
|---|---|
| `pf divert-packet` + divert sockets (zapret way on BSD) | Not in macOS pf (zapret `docs/bsd.en.md`) |
| `pf rdr` + local relay (tpws way) | TCP only upstream; UDP original-destination lookup relies on undocumented `DIOCNATLOOK`; the WARP daemon runs as root and tpws's loop avoidance exempts root |
| BPF (`/dev/bpf*`) | Can observe, cannot hold a packet back, so fakes would arrive after the real Initial |
| `NEFilterDataProvider` | Flow/data verdicts only; no per-packet delay, no injection |
| `NEPacketTunnelProvider` in front of WARP | Would make Zarp the VPN; that is the fallback architecture, not the desktop model |
| Kernel extension | Deprecated; on Apple Silicon needs reduced security mode. Unacceptable for users |

### 5.4 Sandboxing, raw sockets, helper

- "Network Extension system extensions must be sandboxed", Developer ID included; raw sockets from the
  extension fail with "Operation not permitted" (Apple DTS, [thread 660179](https://developer.apple.com/forums/thread/660179)).
  System extensions do run as root.
- So injection goes to a **LaunchDaemon helper** (root, not sandboxed), registered with
  `SMAppService.daemon(plistName:)`; the plist lives in `Zarp.app/Contents/Library/LaunchDaemons/`
  (Apple ServiceManagement docs via Context7). The user approves it in System Settings → Login Items.
- XPC: the extension publishes a Mach service named in Info.plist `NetworkExtension.NEMachServiceName`,
  which must be a child of the app group (`$(TeamIdentifierPrefix)…`), as in Apple's SimpleFirewall sample.
  The helper and the app connect to it; the helper registers itself as the injector on that connection.

### 5.5 Official WARP client on macOS

- Cloudflare docs: daemon `/Applications/Cloudflare WARP.app/Contents/Resources/CloudflareWARP`,
  LaunchDaemon `/Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist`
  ([macOS client](https://developers.cloudflare.com/warp-client/get-started/macos/),
  [architecture](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/configure-warp/route-traffic/warp-architecture/)).
  The daemon keeps the tunnel (WireGuard or MASQUE over UDP).
- Not stated in those docs: whether the tunnel is a NetworkExtension or a plain `utun`, and where `warp-cli`
  is installed. **This does not change the design**: the packet filter acts on the outer UDP packets to
  `162.159.x.x` on Wi-Fi/Ethernet, whatever creates them. The PoC script prints both facts.

## 6. Open questions (the PoC must answer these)

| # | Question | Pass criterion | How the PoC checks it |
|---|---|---|---|
| Q1 | Does the packet filter see the WARP daemon's outbound QUIC Initial? | ≥1 `initial` event per `warp-cli connect`, dst in WARP ranges | filter `observe` mode, event log |
| Q2 | Does the buffer start at the IP header or at a link header? | Parser finds IPv4/IPv6 in either case | parser detects both, logs `l3Offset` once |
| Q3 | Does WARP still connect when its first Initial is delayed ~1–20 ms? | `Connected` + `warp=on` in `active` mode with a no-op strategy | `active` mode, strategy `direct` |
| Q4 | Can the root helper send a raw IPv4/UDP frame with a spoofed source port on current macOS? Which byte order for `ip_len`/`ip_off`? | `sendto` succeeds, frame seen by the filter and by `tcpdump` | helper tries host order, then network order on `EINVAL`, logs the winner |
| Q5 | Are fakes and the real Initial one flow, fakes first? | Filter log for one 5-tuple: `fake ×6` then `initial (released)`; `tcpdump` shows the same order | per-flow event log + `tools/poc-run.sh` tcpdump capture |
| Q6 | `warp=on` with `WARP QUIC: fake google ×6` | trace shows `warp=on` | `ZarpPoC --cli test warp-q-google6` |
| Q7 | Does warp-cli on macOS accept the same commands as on Windows? | exit code 0 for each | `tools/poc-run.sh preflight` |
| Q8 | Does the delayed-packet path hold up for IPv6 endpoints? | not required for PoC | v6 Initials are logged and allowed unmodified (injection is IPv4-only in the PoC) |

Q4 note: XNU's `rip_output` compares `ip_len` against the mbuf length in host order for `IP_HDRINCL`
(historical BSD behaviour), while zapret sends through a "divert" socket. The PoC does not guess, it tries
both and logs the result.

## 7. Distribution requirements (confirmed parts only)

- System extension: app entitlement `com.apple.developer.system-extension.install`, activation through
  `OSSystemExtensionRequest`, the app must be in `/Applications`, the user approves it in System Settings.
- Network Extension entitlement `com.apple.developer.networking.networkextension`: for a Developer ID
  build the value is `content-filter-provider-systemextension`. This entitlement comes with a provisioning
  profile from a **paid Apple Developer Program** account. Xcode's capability editor writes the non-`-systemextension`
  value, which is for development/App Store; check Apple DTS's "Exporting a Developer ID Network Extension" post before release.
- Helper daemon: `SMAppService.daemon`, macOS 13+. Notarization is needed for a normal install.
- For local development only: `systemextensionsctl developer on` (needs SIP off) lets the extension load outside `/Applications`.
- **VERIFIED 2026-09-25**: a free "Personal Team" (Xcode account with no paid Apple Developer Program
  membership) cannot get either capability, under any configuration — confirmed directly by Apple's
  provisioning server, not just documentation, when actually trying to build `PoC/Filter`'s minimal
  `ZarpFilter` target with entitlements set correctly:
  `Cannot create a Mac App Development provisioning profile for "io.github.zarp.mac.filter". Personal
  development teams, including "feg55", do not support the Network Extensions capability.`
  (and similarly for the app target's `system-extension.install`). Matches Apple's "Supported
  capabilities (macOS)" reference table and multiple Apple DTS forum answers. Xcode's own signing
  phase also refuses to ad-hoc-sign (`CODE_SIGN_IDENTITY=-`) a target with these entitlements at all —
  `PoC/Filter` therefore builds with `CODE_SIGNING_ALLOWED=NO` and gets signed manually afterward, the
  `systemextensionsctl developer on` route. A paid Apple Developer Program membership is the only way
  to get a real provisioning profile for this capability.

## 8. Fallback architecture (if Q1/Q3/Q5 fail)

Android model on macOS: Zarp becomes the VPN, the official WARP app is not used.

- `NEPacketTunnelProvider` system extension. IP packets from `packetFlow` go straight into a CONNECT-IP
  session (usque/connect-ip-go already work with raw IP packets, so no gVisor/SOCKS layer is needed on macOS).
- The MASQUE core in Go (usque + quic-go, both build for `darwin/arm64`) compiled with `gomobile bind -target=macos`
  or as a `c-archive`, linked into the extension.
- The UDP socket for quic-go is created in-process, the fakes go out from it first (exactly `dial.go:87`).
  TTL variants via `setsockopt`. No raw sockets, no helper daemon, no packet filter.
- WARP registration through `api.cloudflareclient.com` after the user accepts Cloudflare's ToS.
- Cost: a different product (Zarp is the VPN, WARP app must be off), NE entitlement `packet-tunnel-provider-systemextension`,
  and licensing: the Android core is GPL-3.0, Windows Zarp is MIT. Reusing Android code makes the macOS app GPL-3.0;
  usque itself is MIT, so a clean port that only uses usque stays MIT-compatible.

## 9. Sources

- Apple: [NEFilterPacketProvider](https://developer.apple.com/documentation/networkextension/nefilterpacketprovider),
  [NETransparentProxyProvider](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider),
  [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) (queried via Context7, `/websites/developer_apple_de`).
- Apple Developer Forums: [133622](https://developer.apple.com/forums/thread/133622), [705738](https://developer.apple.com/forums/thread/705738),
  [660179](https://developer.apple.com/forums/thread/660179), [127991 filter-packet setup](https://developer.apple.com/forums/thread/127991).
- Cloudflare: [WARP macOS client](https://developers.cloudflare.com/warp-client/get-started/macos/), [client architecture](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/configure-warp/route-traffic/warp-architecture/).
- Upstream code at the commits cloned into `_reference/` on 2026-09-25: Zarp `faf5515`, Zarp-Android `1b80c30`, zapret `d437963`, zapret2 `00f5aaa`.
