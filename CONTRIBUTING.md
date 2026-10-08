# Contributing to Zarp for macOS

Thank you for looking. Bug reports, results from your network, translations and code are all welcome.
This is a small project maintained in spare time, so please keep changes focused and expect replies to
take a few days.

- [Reporting a bug](#reporting-a-bug)
- [Sharing what works on your network](#sharing-what-works-on-your-network)
- [Translations](#translations)
- [Code](#code)
- [Changes that touch the network, routes or the daemon](#changes-that-touch-the-network-routes-or-the-daemon)
- [Security problems](#security-problems)
- [License](#license)

## Reporting a bug

Open an issue with the **Bug report** form. The form asks for the things that decide almost every
diagnosis here:

- the Zarp version (*Zarp > About Zarp*, or `defaults read /Applications/Zarp.app/Contents/Info
  CFBundleShortVersionString`) and your macOS version;
- the kind of network (home Wi-Fi, mobile hotspot, Ethernet), your provider and country if you are
  comfortable sharing them: whether a strategy works depends on the DPI in between;
- whether another VPN or Cloudflare's own WARP app was running;
- the log: open the log in the main window (or `~/Library/Logs/Zarp/zarp.log`, plus
  `/Library/Logs/Zarp/zarpd.log` for the daemon) and paste the lines around the problem. Remove anything
  you consider private; the logs contain WARP endpoint addresses and nothing about your browsing.

Before you file it, [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers the usual first-launch and
"no strategy works" problems.

## Sharing what works on your network

Which strategies pass depends on the network, so reports from different providers are genuinely useful.
Use the **Strategy report** form: the provider and country, the kind of connection, and the list of
strategies marked ✔✔ after a *Full scan*. Do not paste your WARP account file or anything from
`/Library/Application Support/Zarp`: it holds a private key.

## Translations

All UI text lives in [`Resources/Lang`](Resources/Lang), one `key = value` file per language, with
[`en.txt`](Resources/Lang/en.txt) as the reference. Eight languages ship: English, Russian, Spanish,
Portuguese, Chinese, Hindi, French and German.

- **Fix a translation:** edit the value in `<code>.txt`. Keep the `{0}`, `{1}` placeholders and the `\n`
  line breaks; they are replaced and interpreted by the app.
- **Add a language:** copy `en.txt` to `<code>.txt`, translate the values, and add the language to
  `Localization.languages` in
  [`Packages/ZarpCore/Sources/ZarpCore/Localization/Localization.swift`](Packages/ZarpCore/Sources/ZarpCore/Localization/Localization.swift).
  A key missing from a language falls back to English, so a partial translation still works.
- **Add or remove a string** in the code: change `en.txt` and every other language file together. The tests
  (`swift test`) enforce that every language has exactly the English keys and placeholders, that no value
  mentions Windows-only concepts, and that every key is used by the code.

Translations other than English and Russian were written with AI assistance and have not been reviewed by
native speakers. Corrections from native speakers are especially welcome.

## Code

Setup, the repository layout and how to run things are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md); the
design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short:

```sh
brew install go xcodegen
make test       # Go (gofmt, vet, race detector) + Swift tests + documentation links
make build      # an unsigned Release build, as CI does
```

Please:

- **Match the surrounding code.** Go is `gofmt`-formatted and `go vet`-clean; Swift uses four spaces and the
  naming of the files around it. `ZarpCore` stays free of AppKit, SwiftUI and networking: everything that
  touches the network goes behind the protocols in `Engine/EngineProtocols.swift`.
- **Add tests** with the change. This codebase is tested at the seams (a fake command runner for routes and
  DNS, a fake Unix-socket daemon for the client, scripted fakes for the engine); a fix without a test that
  fails before it and passes after it is much harder to trust.
- **Keep the change focused** and describe *why* in the pull request. A refactor and a behaviour change
  belong in separate pull requests.
- **Update the docs** that the change makes untrue, and add a line under *Unreleased* in
  [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
- **Do not commit** your signing team (it belongs in the git-ignored `Config/Local.xcconfig`), build output,
  or anything from your WARP account.

CI runs the same checks on every pull request on an Apple Silicon runner.

## Changes that touch the network, routes or the daemon

The daemon runs as root and rewrites routes and DNS, and much of what it does cannot be exercised by a unit
test: it needs root and a real network. If your change affects `zarpd/route`, `zarpd/tunnel`, `zarpd/warp`,
the daemon's recovery paths or the install flow, run the real-network test and say so in the pull request:

```sh
# turn off every other VPN (and Cloudflare's WARP app) first
scripts/test-integration.sh
```

It builds your tree, runs a private copy of the daemon (it never touches the installed one), exercises a real
tunnel including `kill -9` and SIGTERM, and verifies at the end that your default route, DNS and
connectivity are exactly as they were; if they are not, it prints the commands that repair them. Paste its
`RESULT` block into the pull request.

Please never test routing code with a VPN running, and never edit the script's safety checks to make it
skip one.

## Security problems

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE), the same as
the rest of the project.
