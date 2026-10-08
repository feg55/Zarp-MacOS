# Releasing

How a release is made. This is for the maintainer; nothing here is needed to use or build Zarp.

Releases are built **locally** by `scripts/package.sh` and uploaded by hand. They cannot be built on a hosted
runner because the app and its embedded daemon are signed with the maintainer's Apple Development
certificate, which stays on the maintainer's Mac.

- [Decisions that shape a release](#decisions-that-shape-a-release)
- [Checklist](#checklist)
- [Release notes template](#release-notes-template)
- [After the release](#after-the-release)

## Decisions that shape a release

- **Unnotarized.** There is no paid Apple Developer Program membership behind the project, so the disk image
  is signed with a free *Apple Development* certificate and is not notarized. Users get Gatekeeper's "was
  blocked" prompt on first launch; the steps are in the disk image's `READ ME FIRST.txt`
  ([`scripts/dmg-readme.txt`](../scripts/dmg-readme.txt)), the README and
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md). This is a deliberate trade-off, not an oversight.
- **A free certificate lasts one year.** An app signed with an expired certificate keeps running, but a new
  build needs a fresh one (Xcode creates it).
- **The signature carries a name.** A development certificate's subject is `Apple Development: <the Apple ID's
  name or email> (<id>)`, and anyone can read it from the finished app with `codesign -dvv Zarp.app`. If that
  is not something you want public, sign with an Apple ID set up for the project.
- **Apple Silicon only, macOS 14+**, matching the daemon's arm64-only build.

## Checklist

1. **Decide the version** (semantic versioning; 0.x while the project is young). Set `MARKETING_VERSION` in
   [`project.yml`](../project.yml) (and bump `CURRENT_PROJECT_VERSION` by one). The daemon is stamped with the
   same version, and the app uses it to notice a stale daemon after an update.
2. **Write the changelog.** Move the *Unreleased* entries in [`CHANGELOG.md`](../CHANGELOG.md) under the new
   version and date, and fix the compare links at the bottom.
3. **Run the checks.**

   ```sh
   make test                    # Go, Swift, documentation links
   scripts/gen-notices.sh --check
   ```

   Then, with every other VPN off, `scripts/test-integration.sh`, and keep its `RESULT` block for the notes.
4. **Build the image.**

   ```sh
   make dmg                     # scripts/package.sh: tests, clean Release build, checks, DMG
   ```

   `package.sh` refuses to continue unless the tests pass, the notices are current, the bundle has the
   daemon, the icon, the languages, the blobs and the licences, both binaries are arm64-only, the app and the
   daemon share a Team ID, and the daemon reports the app's version. It then verifies the image and that the
   signature survives inside it, and writes `build/Zarp-<version>-arm64.dmg` and its `.sha256`.
5. **Smoke-test the artifact** as a user would: mount the image, drag the app to `/Applications` (replacing a
   development copy), pass Gatekeeper, install the daemon from Settings, connect, browse, disconnect, and
   check that the network is back to normal. This is the step that catches packaging problems the script
   cannot.
6. **Commit and tag.**

   ```sh
   git commit -am "Release 0.2.0"
   git tag -a v0.2.0 -m "Zarp for macOS 0.2.0"
   git push && git push origin v0.2.0
   ```

7. **Publish the release** on GitHub with the image and its checksum attached (mark 0.x releases as
   pre-releases if you want the badge to say so):

   ```sh
   gh release create v0.2.0 build/Zarp-0.2.0-arm64.dmg build/Zarp-0.2.0-arm64.dmg.sha256 \
     --title "Zarp for macOS 0.2.0" --notes-file release-notes.md --prerelease
   ```

   or use the *Draft a new release* page and upload the two files.

## Release notes template

```markdown
## Zarp for macOS <version>

<two or three lines: what is new, why you might care>

### Changes
- ...

### Install
Download `Zarp-<version>-arm64.dmg`, drag Zarp to Applications and follow the first-launch steps in the README.
The release is **not notarized**: macOS will block the first launch, and the README explains how to open it.
Requires an Apple Silicon Mac and macOS 14 or later (developed and tested on macOS 15).

### Verify
SHA-256 of `Zarp-<version>-arm64.dmg`:

    <paste the contents of the .sha256 file>

Full list of changes: [CHANGELOG.md](CHANGELOG.md#<anchor>).
```

## After the release

- Check that the README's download link and the badges resolve to the new release.
- Add an empty *Unreleased* section back to the changelog if the release commit removed it.
- Keep the built `.dmg` and its checksum: they are the exact bytes users verify against.
