# Development guide

How to build, run and test Zarp for macOS, and how the repository is organised. For *why* it is built this
way read [ARCHITECTURE.md](ARCHITECTURE.md); for how to contribute, [../CONTRIBUTING.md](../CONTRIBUTING.md).

- [What you need](#what-you-need)
- [Repository layout](#repository-layout)
- [Tests](#tests)
- [Building the app](#building-the-app)
- [Signing with your own team](#signing-with-your-own-team)
- [Running the daemon by hand](#running-the-daemon-by-hand)
- [The real-network test](#the-real-network-test)
- [Localization](#localization)
- [Other generated files](#other-generated-files)
- [Continuous integration](#continuous-integration)

## What you need

- An Apple Silicon Mac on macOS 14 or later. The daemon uses macOS-only APIs (utun, `IP_BOUND_IF`, routing
  and `networksetup` tooling), so there is no Linux or Intel build.
- Xcode 16 or later (the Swift 5.9+ toolchain and the macOS SDK; it is also what signs the app).
- Go: the version in [`zarpd/go.mod`](../zarpd/go.mod). `brew install go` is enough.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. `Zarp.xcodeproj` is generated
  from [`project.yml`](../project.yml) and is not committed.

```sh
brew install go xcodegen
git clone https://github.com/feg55/Zarp-MacOS.git && cd Zarp-MacOS
make test
```

`make help` lists every target.

## Repository layout

The tree is described in [ARCHITECTURE.md §2](ARCHITECTURE.md#2-code-layout). The pieces you will touch most:

| Path | What |
|---|---|
| `App/Sources/Zarp` | the SwiftUI app |
| `Packages/ZarpCore` | strategy, scan, settings, localization, logging and the IPC client; tested with plain `swift test` |
| `zarpd` | the Go daemon and `zarpctl`; its own Go module |
| `Resources/Lang`, `Resources/blobs`, `Resources/Licenses` | strings, decoy-packet captures, licence texts |
| `scripts` | packaging, the real-network test, icon and notices generators, the documentation link check |
| `docs` | this guide, the architecture, troubleshooting, release steps, and `history/` (the development record) |

## Tests

```sh
make test          # all three below
make test-go       # cd zarpd && gofmt check, go vet, go test -race -count=1 ./...
make test-swift    # cd Packages/ZarpCore && swift test
make check-docs    # every relative link and anchor in the Markdown files resolves
```

None of these needs root or a network: the Go tests drive routes and DNS through a fake command runner, the
dial and desync code over loopback sockets, and the IPC server over a Unix socket in a temporary directory;
the Swift tests use scripted fakes and a fake Unix-socket daemon. Run a single Go package or Swift test with
the usual `go test ./route -run TestName` and `swift test --filter TestName`.

What they cannot cover (root, a real routing table, a real WARP endpoint) is covered by
[the real-network test](#the-real-network-test).

## Building the app

```sh
make build         # an unsigned Release build into build/DerivedData (what CI checks)
```

or generate the project and use Xcode:

```sh
make project       # xcodegen generate
open Zarp.xcodeproj
```

The Xcode target runs a script phase that builds `zarpd` with `go build` and embeds it, with its LaunchDaemon
property list, into the app bundle. An unsigned build is fine for working on the UI and the engine, but it
cannot install the daemon (see below).

## Signing with your own team

The daemon is registered with `SMAppService`, which needs the app and the daemon to be signed by the same
Apple Development team. A free "Personal Team" works. Your Team ID is deliberately not in the repository:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig     # git-ignored
# edit it: DEVELOPMENT_TEAM = <your 10-character Team ID>
```

Find the ID in Xcode > Settings > Accounts, or with `security find-identity -v -p codesigning` (it is in
parentheses after the certificate name). Xcode builds and `make dmg` both read the file; the environment
variable `DEVELOPMENT_TEAM=<id> make dmg` works too.

A **Debug** build may register the daemon from anywhere (Xcode's DerivedData included); a **Release** build
registers it only from `/Applications` (it is a root executable, so it must not live in a folder you can
write; see [ARCHITECTURE.md §7](ARCHITECTURE.md#7-the-privileged-daemon-install-and-update)).

## Running the daemon by hand

You can develop the app against a daemon you started yourself instead of the installed one. A **Debug** app
honours the environment variable `ZARP_SOCKET`:

```sh
cd zarpd && go build -o /tmp/zarpd ./cmd/zarpd && go build -o /tmp/zarpctl ./cmd/zarpctl

# 1. the daemon (root, because creating a utun and changing routes needs it)
sudo /tmp/zarpd -socket /tmp/zarpd-dev.sock -config /tmp/zarpd-dev-config.json \
     -blobs "$PWD/../Resources/blobs" -log - \
     -dns-backup /tmp/zarpd-dev-dns.json -route-journal /tmp/zarpd-dev-routes.json

# 2. the Debug app against it (another terminal)
ZARP_SOCKET=/tmp/zarpd-dev.sock /path/to/Debug/Zarp.app/Contents/MacOS/Zarp

# 3. or talk to it directly
/tmp/zarpctl -socket /tmp/zarpd-dev.sock ping
/tmp/zarpctl -socket /tmp/zarpd-dev.sock register
/tmp/zarpctl -socket /tmp/zarpd-dev.sock open -transport h3 -fake quic_google:6 -endpoint isolated-0
```

Without root the daemon still starts and answers `ping`, `status`, `register` and `logs` (and `zarpctl` needs
no `sudo` to talk to it), which is enough for most UI work; it just cannot open a tunnel. Keep the socket path
short: a Unix socket path is limited to about 100 bytes on macOS, and a longer one fails with `bind: invalid
argument`. Release builds ignore `ZARP_SOCKET`. `zarpctl` prints the daemon's
JSON answer, or `error [code]: message` on stderr; its header comment lists every command and flag.

Use the private files above (`-config`, `-dns-backup`, `-route-journal`) rather than the defaults, so that your
experiments never share state with an installed daemon.

## The real-network test

[`scripts/test-integration.sh`](../scripts/test-integration.sh) checks what unit tests cannot: that a real
tunnel comes up, that every route and DNS change is undone, and that a daemon killed mid-tunnel leaves the
machine working. **Turn off every other VPN, and Cloudflare's WARP app, first**; the script refuses to start
when the default route is on a `utun`.

```sh
scripts/test-integration.sh            # HTTP/3 + quic_google x6; asks for your password once (sudo)
scripts/test-integration.sh --h2       # the HTTP/2 transport with a ClientHello split
scripts/test-integration.sh --no-tunnel   # skip the tests that route all traffic
```

It builds `zarpd` and `zarpctl` from your tree, starts its **own** daemon on a private socket in `/tmp` (the
installed one is untouched), and runs the checks listed in its header: protocol and validation, the leak of
file descriptors on failed dials, a real test connection, orphaned connections and leases, the full tunnel
with and without the DNS override (IPv4, IPv6, an 8 MB download, exact restore), `kill -9` and SIGTERM
recovery. Whatever happens (Ctrl-C included) an exit handler stops the daemon and then **verifies that the
default route, DNS and connectivity are as they were**, printing the repair commands if they are not. A
watchdog ends the run after 15 minutes. It prints a `RESULT` block with the daemon log, which is what to paste
into a pull request.

## Localization

All strings are in `Resources/Lang/<code>.txt`; see [CONTRIBUTING.md](../CONTRIBUTING.md#translations) for the
rules and [`en.txt`](../Resources/Lang/en.txt)'s header for the format. The tests keep the eight files in
step with each other and with the code (no missing keys, no leftover keys, same placeholders).

## Other generated files

| Command | Produces |
|---|---|
| `make notices` | `Resources/Licenses/THIRD_PARTY_NOTICES.md` (from the Go modules actually linked into `zarpd`) and the bundled copy of `LICENSE`. CI fails when they are stale |
| `make icon` | the app icon set, `docs/images/icon.png` and `docs/images/social-preview.png`, drawn by `scripts/make-icon.swift` |
| `make dmg-art` | the disk image's window background, `scripts/dmg/background.png` and `background@2x.png` (also drawn by `scripts/make-icon.swift`); the icon positions on it are in `scripts/dmg/settings.py` |
| `make dmg` | `build/Zarp-<version>-arm64.dmg` and its `.sha256`; see [RELEASING.md](RELEASING.md) |

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on an Apple Silicon macOS runner for every
push to `main` and every pull request: `gofmt`, `go vet` and the Go tests with the race detector, the Swift
tests, the notices check, the documentation link check, and an unsigned Release build of the app. It does not
run the real-network test (a hosted runner has no business rewriting its own routes).
