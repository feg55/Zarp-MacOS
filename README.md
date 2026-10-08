<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Zarp icon">
</p>

<h1 align="center">Zarp for macOS</h1>

<p align="center">
  One-click Cloudflare WARP for networks that block it.<br>
  A native Apple Silicon app. Open source, no telemetry.
</p>

<p align="center">
  <a href="https://github.com/feg55/Zarp-MacOS/actions/workflows/ci.yml"><img src="https://github.com/feg55/Zarp-MacOS/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/feg55/Zarp-MacOS/releases/latest"><img src="https://img.shields.io/github/v/release/feg55/Zarp-MacOS?include_prereleases" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/feg55/Zarp-MacOS" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey" alt="Apple Silicon">
</p>

<p align="center">
  <b>English</b> · <a href="README.ru.md">Русский</a>
</p>

Zarp finds a [zapret2](https://github.com/bol-van/zapret2)-style strategy that gets the Cloudflare WARP
handshake through your network's DPI, remembers it, and connects. The first press of the button searches;
every press after that connects right away.

<p align="center">
  <img src="docs/images/screenshot.png" width="860" alt="Zarp for macOS: the main window and the strategy list">
</p>

Zarp for macOS is part of a family: [Zarp for Windows](https://github.com/feg55/Zarp) and
[Zarp for Android](https://github.com/feg55/Zarp-Android) use the same strategies and the same one-tap flow.

## Download

Get the latest `Zarp-<version>-arm64.dmg` from **[Releases](https://github.com/feg55/Zarp-MacOS/releases/latest)**.

| | |
|---|---|
| **Mac** | Apple Silicon (M1 or newer) |
| **macOS** | 14 Sonoma or later. Developed and tested on macOS 15; 14 should work but has not been tested |
| **Rights** | An administrator password, once, to install the background service |
| **Other software** | None. Zarp is its own WARP client: you do not install Cloudflare's app |

> [!IMPORTANT]
> The release is **not notarized by Apple** (there is no paid Apple Developer membership behind this
> project), so macOS blocks the first launch. That is expected; [the steps below](#first-launch) take a
> minute. Check the download against the SHA-256 in the release notes first
> ([how](#verify-the-download)).

## Features

- **One button.** The first press looks for the fastest strategy that works on your network (a quick scan
  stops after three that do); later presses connect immediately.
- **A real WARP client.** Zarp registers a free, anonymous WARP account itself (after you accept Cloudflare's
  terms) and speaks MASQUE to Cloudflare directly, over HTTP/3 or HTTP/2. No `warp-cli`, no official app.
- **Whole-Mac tunnel.** While it says *Connected*, all of the Mac's traffic, IPv4 and IPv6, and its DNS go
  through WARP. A switch in Settings limits it to a test route if you only want to experiment.
- **Honest testing.** Every test runs against a fresh WARP endpoint, and a strategy only earns its double
  check mark (✔✔) after passing a second, independent test.
- **Self-healing.** If the saved strategy stops working Zarp tries the other verified ones before searching
  again, and it reconnects by itself when the connection drops.
- **Built to fail safe.** The routes it adds disappear with the tunnel, so even a crashed daemon leaves your
  network working; anything that could outlive a crash (DNS, one host route) is journaled and undone at the
  next start. A real-network test script proves it, including `kill -9`.
- **Eleven working strategies** out of the 20 in the catalog (QUIC fake packets, TLS split and disorder, plus
  two direct controls), and your own in `strategies.txt`. The rest need raw sockets or WireGuard and are shown
  as unavailable, with the reason.
- **Native and small.** SwiftUI app, menu bar item, eight languages: English, Русский, Español, Português,
  中文, हिन्दी, Français, Deutsch.

## First launch

1. Open the disk image and drag **Zarp** onto the **Applications** shortcut, then eject the image. Run Zarp
   from Applications, not from the image or Downloads (the background service only installs from there).
2. Open Zarp. macOS says it cannot verify the developer. Open **System Settings > Privacy & Security**, scroll
   to *Security*, click **Open Anyway** next to "Zarp was blocked", and confirm with your password or Touch ID.
   If the button does not appear, this Terminal command removes the block instead:
   `xattr -dr com.apple.quarantine /Applications/Zarp.app`
3. Click the gear icon, find the **zarpd daemon** section and click **Install**. macOS shows a "background
   item added" notification: open **System Settings > General > Login Items & Extensions** and switch Zarp on
   under *Allow in the Background*. This is needed only once.
4. **Turn off any other VPN** (and Cloudflare's own WARP app), then press the power button. The first time,
   Zarp asks to create a free anonymous WARP account for this Mac and accept Cloudflare's terms on your
   behalf. It then finds a strategy and connects.

Something went wrong? See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### Verify the download

The release notes list the SHA-256 of the disk image:

```sh
shasum -a 256 ~/Downloads/Zarp-0.1.0-arm64.dmg      # compare with the release notes
```

## Using Zarp

- **Connect / disconnect:** the big button, or the menu bar item. The status line says what Zarp is doing.
- **Strategies:** Settings lists them with their results. *Quick scan* stops after the number of working
  strategies you choose; *Full scan* tests all of them, slower but nothing is skipped. *Test selected* tries
  one; *Use* switches to it. A strategy marked ✔✔ passed two independent checks.
- **Your own strategies:** *Custom strategies...* edits `strategies.txt` in the data folder. One per line:

  ```
  # name | transport (h3, h2, wg) | zapret2 profile arguments
  My QUIC | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=8
  ```

  The syntax is zapret2's `--lua-desync`; Zarp supports plain fake packets (with `ip_ttl`, `ip6_ttl`,
  `repeats`) for `h3` and `multisplit` / `multidisorder` for `h2`. Anything else, including every `wg`
  line, is listed as unavailable with the reason.
- **Closing the window** asks whether to hide Zarp in the menu bar or quit; Settings has an *On close* choice.
  Quitting disconnects WARP unless you turn *Disconnect WARP on exit* off.

## What Zarp changes on your system

- **A background service.** When you click *Install*, a root LaunchDaemon (`io.github.zarp.mac.zarpd`) is
  registered with macOS. It is the only part with elevated rights and the only part that touches the network
  configuration; the app itself runs as you. It does nothing until the app asks it to.
- **While connected:** a `utun` interface, two routes that cover the whole IPv4 space (and two for IPv6)
  through it, one host route that keeps Zarp's own connection to Cloudflare off the tunnel, and the DNS of your
  active network service pointed at Cloudflare's resolvers. Your real default route is not modified.
  Disconnecting removes all of it and restores your DNS exactly as it was.
- **Files:** settings and results in `~/Library/Application Support/Zarp`, logs in `~/Library/Logs/Zarp`, and
  the daemon's WARP account (root-only) in `/Library/Application Support/Zarp`. Full list:
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#9-data-logs-and-privacy).
- **Only if you turn it on:** *Start with macOS* adds Zarp to your login items.

### Uninstall

1. In Settings, turn off *Start with macOS* if it is on, and disconnect.
2. Settings > zarpd daemon > **Uninstall**, then quit Zarp and delete `/Applications/Zarp.app`.
3. Optionally remove the data (the second line deletes the WARP account, so the next install registers a new one):

   ```sh
   rm -rf ~/Library/Application\ Support/Zarp ~/Library/Logs/Zarp
   sudo rm -rf "/Library/Application Support/Zarp" /Library/Logs/Zarp /Library/Logs/zarpd.log /var/db/zarpd
   ```

## Privacy

Zarp has no telemetry and sends nothing to its author. It makes exactly these network requests:

- the one-time anonymous **WARP registration** with Cloudflare, after you accept Cloudflare's terms (no
  personal information is sent);
- the **WARP tunnel** itself, to Cloudflare's WARP addresses, which is the point of the app;
- **`https://1.1.1.1/cdn-cgi/trace`** through the tunnel, while testing and connecting, to check that traffic
  really goes through WARP and to measure latency.

WARP is a Cloudflare service covered by
[Cloudflare's WARP terms and privacy policy](https://www.cloudflare.com/application/privacypolicy/). Using
WARP, and using it in your country, is your responsibility.

## How it works

Networks that block WARP usually recognise the first packet of its handshake (the QUIC Initial sent to a WARP
address). Zarp's daemon sends a few decoy packets from the same socket just before the real handshake, so the
DPI classifies the flow as something harmless while Cloudflare ignores the decoys; for the HTTP/2 transport it
splits the TLS ClientHello across TCP segments instead. Zarp then tries strategies until one works on your
network, confirms it on a second endpoint, remembers it, and moves your packets through the resulting MASQUE
tunnel.

The design, the security model and the failure behaviour are described in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Building from source

You need Xcode 16 or later, Go (the version in [`zarpd/go.mod`](zarpd/go.mod)) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install go xcodegen`).

```sh
make test       # Go (vet, race detector) and Swift tests: needs no root, no network
make build      # an unsigned Release build, the same check CI runs
make dmg        # a signed, packaged disk image (needs your Apple Development team, see below)
```

Installing the background service needs a signed app, so signing with your own team is covered in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), which also explains the repository layout, running the
daemon by hand, and the real-network test (`scripts/test-integration.sh`).

## Contributing

Bug reports, strategy results from your network and translations are all welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately: [SECURITY.md](SECURITY.md).

## Credits and license

Zarp for macOS is released under the [MIT License](LICENSE). It builds on:

- [zapret2](https://github.com/bol-van/zapret2) by bol-van (MIT): the strategy vocabulary and the
  fake-packet captures in `Resources/blobs`;
- [usque](https://github.com/Diniboy1123/usque), [connect-ip-go](https://github.com/Diniboy1123/connect-ip-go),
  [quic-go](https://github.com/quic-go/quic-go) and [wireguard-go](https://git.zx2c4.com/wireguard-go)'s `tun`
  package: the WARP registration, the MASQUE session and the utun device;
- [Zarp for Windows](https://github.com/feg55/Zarp) (MIT) and [Zarp for Android](https://github.com/feg55/Zarp-Android)
  (GPL-3.0, studied as a design reference, not copied; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#11-licensing-and-provenance)).

The licences of everything linked into the app are in
[`Resources/Licenses/THIRD_PARTY_NOTICES.md`](Resources/Licenses/THIRD_PARTY_NOTICES.md) (also reachable from
Settings > Licenses).

Cloudflare and WARP are trademarks of Cloudflare, Inc. Zarp is an independent project, not affiliated with or
endorsed by Cloudflare, and ships no Cloudflare software.
