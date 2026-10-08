# Changelog

All notable changes to Zarp for macOS are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/) (while it is 0.x, minor versions may change behaviour).

## [Unreleased]

## [0.1.0] - 2026-10-08

The first public release.

### Added

- A native SwiftUI app for Apple Silicon (macOS 14 or later): one power button, a strategy list with results,
  quick and full scan, custom strategies (`strategies.txt`), a menu bar item, a log view, and eight languages
  (English, Русский, Español, Português, 中文, हिन्दी, Français, Deutsch).
- **Zarp is its own Cloudflare WARP client.** It registers an anonymous WARP account after the user accepts
  Cloudflare's terms and speaks MASQUE (CONNECT-IP) over HTTP/3 or HTTP/2, with no dependency on the official
  WARP app.
- **DPI strategies**: decoy QUIC packets sent from the connection's own socket (with TTL and repeat options),
  and TLS ClientHello split and disorder for the HTTP/2 transport. Eleven of the 20 catalog strategies run;
  those that need raw sockets or WireGuard are listed as unavailable, with the reason.
- **`zarpd`, a privileged helper** (a Go daemon registered with `SMAppService`) that owns the tunnel: the
  utun device, the packet pump, routes, DNS, and the measurement used to score strategies.
- **A whole-Mac tunnel** for IPv4 and IPv6 with an optional DNS override. It uses `0/1` + `128/1` routes (and
  `::/1` + `8000::/1`) through the utun, so the real default route is never changed and a crashed daemon fails
  open. The control connection to Cloudflare is kept off the tunnel with a journaled host route; DNS and that
  route are restored on disconnect, on SIGTERM, and at the next start after a crash.
- **Scanning that checks itself**: each test uses a fresh endpoint, a strategy needs a second independent pass
  for the double check mark, a failing saved strategy falls back to the other verified ones, and a lost
  connection is re-established quietly with the same strategy.
- A **real-network integration test** (`scripts/test-integration.sh`) covering the full tunnel, DNS restore,
  `kill -9` and SIGTERM recovery, and a check that the machine ends up as it began.
- A packaging script that produces a signed disk image (`scripts/package.sh`), third-party notices bundled in
  the app, and CI (Go, Swift, build, notices, documentation links).

### Known limitations

- The release is **not notarized** (no paid Apple Developer membership): the first launch needs *Open Anyway*.
- WireGuard and the raw-socket strategies (`badsum`, `tcp_md5`, `seqovl`, `hostfakesplit`) are not available.
- Developed and tested on macOS 15 on a Wi-Fi network; macOS 14 and other network types are not yet tested.
- After sleep or a network change traffic can stall for up to about 30 seconds before the tunnel is
  re-established. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#13-known-limitations) for the full list.
- Translations other than English and Russian have not been reviewed by native speakers.

[Unreleased]: https://github.com/feg55/Zarp-MacOS/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/feg55/Zarp-MacOS/releases/tag/v0.1.0
