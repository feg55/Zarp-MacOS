# Security policy

Zarp for macOS installs a small background service that runs as **root** (it has to: creating a network
tunnel and changing routes and DNS needs it) and accepts requests from the Zarp app over a local socket. That
makes the daemon the part of this project where a bug matters most, and reports about it are taken seriously.

## Supported versions

Only the latest release receives security fixes. The project is young (0.x); there are no long-term branches.

## Reporting a vulnerability

**Please do not open a public issue or pull request for a security problem.**

Report it privately through GitHub: on the repository page open **Security > Report a vulnerability**
(<https://github.com/feg55/Zarp-MacOS/security/advisories/new>). That creates a private conversation with the
maintainer. If that option is not available to you, open a public issue that says only "I have a security
report" and no details, and a private channel will be arranged.

Please include what you can of:

- what is affected (the daemon, the app, the installer, the packaging) and the version;
- how to reproduce it, ideally a short script or a sequence of IPC requests;
- what an attacker needs (a local user account? the console user? root?) and what they gain.

You can expect an acknowledgement within about a week and a fix or a clear answer after that; this is a
spare-time project, so there is no guaranteed turnaround. You will be credited in the release notes unless
you prefer otherwise.

## What is in scope

- Anything that lets a process **other than the Zarp app, running as the console user**, make the daemon do
  something: the socket permissions, the peer-credential check, request validation.
- Anything that lets a client make the daemon **run a command, touch a file, contact an address or set a DNS
  server** of the client's choosing.
- Ways to make the daemon **leave the machine's routing or DNS in a broken state** that its recovery does not
  repair (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#6-routing-dns-and-fail-safety)).
- Flaws in the **install path**: how the daemon is registered, where it may live, how its version is checked.
- Leaks of the **WARP account** (device token and private key) or of anything that identifies the user.
- Vulnerabilities in a bundled third-party library that are reachable through Zarp.

## What is out of scope

- A process running **as you** asking the daemon to open or close tunnels to WARP endpoints. That is what the
  app does; the daemon cannot be asked for anything beyond connecting to Cloudflare WARP.
- Whether a particular DPI evasion strategy works on a particular network.
- The Cloudflare WARP service itself, or macOS.
- The absence of Apple notarization: the release is unnotarized by decision (no paid Apple Developer
  membership), and the first-launch steps are documented.

## How the daemon limits its exposure

In short (the full model is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#10-security-model)): the socket is
mode `0660` and group `staff`, and the daemon additionally reads the connecting process's credentials from the
kernel and admits only root and the console user. It accepts eight fixed methods. Requests carry no path,
command or DNS server; every field is bounded, endpoints must lie inside Cloudflare's WARP ranges, decoy blobs
come from a fixed list. Connection, request and size limits apply, and a panic is recovered. A release build
registers the daemon only from `/Applications`, and the WARP account file is root-owned with mode `0600`.

## Verifying a download

Releases are built by the maintainer on their own Mac and are signed with a free Apple Development
certificate. The release notes list the SHA-256 of the disk image; compare it before you open it:

```sh
shasum -a 256 ~/Downloads/Zarp-*.dmg
```

Building from source is the strongest check: see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
