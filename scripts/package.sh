#!/bin/bash
# Builds a Release, arm64-only Zarp.app from scratch and packages it as a .dmg.
#
#   scripts/package.sh
#
# Output (all under build/, which is gitignored): build/Zarp-<version>-arm64.dmg and its .sha256.
#
# UNNOTARIZED, by decision (docs/RELEASING.md): there is no paid Apple
# Developer Program membership behind this project, so the app is signed with the free Personal
# Team's "Apple Development" identity (the same one Xcode uses for local builds) and a user's first
# launch hits Gatekeeper's "was blocked to protect your Mac" prompt; the window of the disk image
# (scripts/dmg/) and the README walk them through System Settings > Privacy & Security > Open Anyway.
# Needs Go and xcodegen on the *build* machine only — the finished app has no such dependency.
#
# The disk image opens as a drag-to-Applications window (background art, icon positions): dmgbuild
# writes that layout straight into the image, without driving Finder. If it is not on PATH it is
# installed once into build/.dmgbuild-venv (needs python3 and a network that one time).
#
# Before anything is built it runs the test suites (Go: vet + tests with the race detector; Swift:
# ZarpCore) and checks THIRD_PARTY_NOTICES.md is current — an installer must never be produced from
# code that fails its own tests. `--skip-tests` is for repeating a packaging step only.
#
# Always builds from a clean DerivedData directory, never an incremental one: an incremental
# build once hid a real bug for an entire session (resources never actually copied into the
# bundle; docs/history/development-log.md, Phase 8), and a script whose whole job is producing the
# artifact people install is exactly where a stale-cache success is least acceptable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
DERIVED="$BUILD/DerivedData"
LOG="$BUILD/xcodebuild.log"

fail() { echo "package.sh: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

DMGBUILD_VERSION=1.6.7
# Prints the path of a dmgbuild executable, installing a pinned one into build/ if there is none.
ensure_dmgbuild() {
  if command -v dmgbuild >/dev/null 2>&1; then command -v dmgbuild; return; fi
  local venv="$BUILD/.dmgbuild-venv"
  if [[ ! -x "$venv/bin/dmgbuild" ]]; then
    echo "installing dmgbuild $DMGBUILD_VERSION into ${venv#"$ROOT"/} (once)" >&2
    { python3 -m venv "$venv" && "$venv/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"; } >&2 \
      || fail "could not install dmgbuild: it needs python3 and a network connection (or install it yourself: pip3 install dmgbuild)"
  fi
  echo "$venv/bin/dmgbuild"
}

SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    *) fail "unknown argument: $arg" ;;
  esac
done
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$PATH"

# The signing team is not in the repository. It comes from the environment (DEVELOPMENT_TEAM=... ) or
# from Config/Local.xcconfig (copy Config/Local.xcconfig.example). Checked up front so a missing
# team is a clear message here rather than an Xcode signing error after the tests have run.
TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" && -f "$ROOT/Config/Local.xcconfig" ]]; then
  TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' "$ROOT/Config/Local.xcconfig" | sed -n 1p)
fi
[[ -n "$TEAM" && "$TEAM" != "ABCDE12345" ]] \
  || fail "no signing team: copy Config/Local.xcconfig.example to Config/Local.xcconfig and set DEVELOPMENT_TEAM (or run with DEVELOPMENT_TEAM=<id> in the environment). See docs/DEVELOPMENT.md."

if [[ $SKIP_TESTS -eq 0 ]]; then
  step "Go: vet and tests (race detector)"
  ( cd "$ROOT/zarpd" && go vet ./... && go test -race -count=1 ./... ) || fail "Go checks failed"
  step "Swift: ZarpCore tests"
  ( cd "$ROOT/Packages/ZarpCore" && swift test ) >"$BUILD/swift-test.log" 2>&1 \
    || { tail -40 "$BUILD/swift-test.log" >&2; fail "ZarpCore tests failed (log: ${BUILD#"$ROOT"/}/swift-test.log)"; }
  step "Third-party notices"
  "$ROOT/scripts/gen-notices.sh" --check || fail "run scripts/gen-notices.sh and commit the result"
fi

rm -rf "$DERIVED"

step "Generating Xcode project"
xcodegen generate

step "Building Release (arm64) — full log: ${LOG#"$ROOT"/}"
if ! xcodebuild -project Zarp.xcodeproj -scheme Zarp -configuration Release \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
      DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build >"$LOG" 2>&1; then
  tail -60 "$LOG" >&2
  fail "xcodebuild failed (see $LOG)"
fi

APP="$DERIVED/Build/Products/Release/Zarp.app"
DAEMON="$APP/Contents/MacOS/zarpd"
LAUNCHD_PLIST="$APP/Contents/Library/LaunchDaemons/io.github.zarp.mac.zarpd.plist"

step "Checking the bundle"
[[ -d "$APP" ]]                              || fail "no app bundle at $APP"
[[ -x "$DAEMON" ]]                           || fail "zarpd missing from the bundle"
[[ -f "$LAUNCHD_PLIST" ]]                    || fail "LaunchDaemon plist missing from the bundle"
[[ -d "$APP/Contents/Resources/Lang" ]]      || fail "Resources/Lang missing from the bundle"
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] \
                                             || fail "the app icon is missing from the bundle"
compgen -G "$APP/Contents/Resources/blobs/*.bin" >/dev/null \
                                             || fail "Resources/blobs has no .bin files"
[[ ! -e "$APP/Contents/MacOS/Zarp.debug.dylib" ]] \
                                             || fail "debug-only dylib present in a Release bundle"
# Captured first, not piped into `grep -q`: grep exits at its first match, plutil then dies of
# SIGPIPE, and `pipefail` would report that as a failure of a check that actually passed.
DAEMON_PLIST=$(plutil -p "$DAEMON" 2>&1 || true)
[[ "$DAEMON_PLIST" == *'"CFBundleIdentifier" => "io.github.zarp.mac.zarpd"'* ]] \
                                             || fail "zarpd has no embedded Info.plist"
for bin in "$APP/Contents/MacOS/Zarp" "$DAEMON"; do
  [[ "$(lipo -archs "$bin")" == "arm64" ]]   || fail "$bin is not arm64-only"
done
codesign --verify --deep --strict "$APP"     || fail "codesign verification failed"
APP_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
DAEMON_TEAM=$(codesign -dv "$DAEMON" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ -n "$APP_TEAM" && "$APP_TEAM" == "$DAEMON_TEAM" ]] \
                                             || fail "Team ID mismatch: app '$APP_TEAM' vs zarpd '$DAEMON_TEAM' (SMAppService requires them to match)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# The app compares the daemon's reported version with its own to notice a stale daemon after an
# update: an unstamped or mismatched build would make it restart the daemon on every launch.
DAEMON_VERSION=$("$DAEMON" -version)
[[ "$DAEMON_VERSION" == "$VERSION" ]]        || fail "zarpd reports version '$DAEMON_VERSION' but the app is '$VERSION'"
[[ -d "$APP/Contents/Resources/Licenses" && -f "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md" \
   && -f "$APP/Contents/Resources/Licenses/Zarp-macOS-LICENSE.txt" ]] \
                                             || fail "Resources/Licenses is missing from the bundle"
echo "version $VERSION, team $APP_TEAM, arm64, zarpd embedded + signed, resources present"

step "What Gatekeeper makes of it (informational — rejection is expected, this build is unnotarized)"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true

step "Creating the disk image (drag-to-Applications window)"
DMG="$BUILD/Zarp-$VERSION-arm64.dmg"
rm -f "$DMG" "$DMG.sha256"
DMGBUILD=$(ensure_dmgbuild)
# The app is copied with ditto (so its signature survives), the volume gets Zarp's icon, and the window
# gets the background and icon positions of scripts/dmg/settings.py.
"$DMGBUILD" -s "$ROOT/scripts/dmg/settings.py" \
    -D app="$APP" -D volume_icon="$APP/Contents/Resources/AppIcon.icns" -D background="$ROOT/scripts/dmg/background.png" \
    "Zarp" "$DMG" >"$BUILD/dmgbuild.log" 2>&1 \
  || { tail -20 "$BUILD/dmgbuild.log" >&2; fail "dmgbuild failed (log: ${BUILD#"$ROOT"/}/dmgbuild.log)"; }
hdiutil verify "$DMG" >/dev/null || fail "hdiutil verify failed"

step "Checking the signature survived packaging (mounting the image read-only)"
MOUNT=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
codesign --verify --deep --strict "$MOUNT/Zarp.app" || fail "app inside the image fails codesign verification"
[[ -L "$MOUNT/Applications" ]] || fail "image is missing its Applications shortcut"
# What makes it open as an install window rather than a plain folder: the Finder layout, the background art
# (a multi-resolution TIFF, so it is sharp on Retina) and the volume icon.
[[ -f "$MOUNT/.DS_Store" && -f "$MOUNT/.background.tiff" && -f "$MOUNT/.VolumeIcon.icns" ]] \
  || fail "image has no window layout (.DS_Store, background or volume icon missing)"
[[ "$(tiffutil -info "$MOUNT/.background.tiff" 2>&1 | grep -c '^Directory')" -ge 2 ]] \
  || fail "the window background is not a multi-resolution TIFF (the @2x artwork was not picked up)"

( cd "$BUILD" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | sed -n 1p)

step "Done"
ls -lh "$DMG" | awk '{print $5, $9}'
cat "$DMG.sha256"
echo "signed by: ${SIGNER:-unknown}"
echo "(free Apple Development certificates last one year; release steps: docs/RELEASING.md)"
