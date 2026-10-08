#!/bin/bash
# Regenerates Resources/Licenses/THIRD_PARTY_NOTICES.md: the notices that must accompany the
# distributed binaries (and keeps Resources/Licenses/Zarp-macOS-LICENSE.txt, the copy of the
# project's own LICENSE that goes into the app bundle, in sync with the one at the repository root). MIT and BSD licenses require the copyright notice and license text to be
# included in binary distributions, and zarpd statically links every Go module listed here.
#
#   scripts/gen-notices.sh            # rewrite the file
#   scripts/gen-notices.sh --check    # exit 1 if it is out of date (used by package.sh)
#
# The Go part comes from the modules actually linked into zarpd (`go list -deps`), read from the Go
# module cache, so it tracks go.mod automatically. The zapret2 and Windows Zarp texts are checked in
# next to the output (they come from _reference/, which is not part of a clone).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/Resources/Licenses/THIRD_PARTY_NOTICES.md"
LICENSE_COPY="$ROOT/Resources/Licenses/Zarp-macOS-LICENSE.txt"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$PATH"
export GOOS=darwin GOARCH=arm64 CGO_ENABLED=1

# The Go distribution's license: normally $GOROOT/LICENSE, one level up for Homebrew's layout, and
# as a last resort golang.org/x/sys's identical BSD-3 text ("Copyright 2009 The Go Authors").
go_license() {
  local root
  root=$(go env GOROOT)
  for candidate in "$root/LICENSE" "$root/../LICENSE"; do
    if [[ -f "$candidate" ]]; then cat "$candidate"; return; fi
  done
  local sysdir
  sysdir=$(cd "$ROOT/zarpd" && go list -m -f '{{.Dir}}' golang.org/x/sys)
  cat "$sysdir/LICENSE"
}

generate() {
  cat <<'HEADER'
# Third-party notices

Zarp for macOS is an independent project, not affiliated with or endorsed by Cloudflare, Inc.
Cloudflare and WARP are trademarks of Cloudflare, Inc. It contains no Cloudflare software: it
talks to Cloudflare's public WARP service through the open-source components listed below.

Zarp for macOS itself is released under the MIT License (Zarp-macOS-LICENSE.txt, next to this file).

The app bundle contains:

- **Zarp.app** — the SwiftUI application. Its strategy catalog, scan/scoring algorithms, interface
  texts and translations derive from [Zarp for Windows](https://github.com/feg55/Zarp) (MIT; its
  license is reproduced below).
- **zarpd** — a privileged helper (a Go program) that is statically linked with the Go standard
  library and the Go modules listed below.
- **Resources/blobs/\*.bin** — fake-packet captures from [zapret2](https://github.com/bol-van/zapret2)
  by bol-van (MIT; reproduced below), included unmodified.

HEADER

  echo "## Zarp for Windows (MIT)"
  echo
  echo '```text'
  cat "$ROOT/Resources/Licenses/Zarp-Windows-LICENSE.txt"
  echo '```'
  echo
  echo "## zapret2 (MIT)"
  echo
  echo '```text'
  cat "$ROOT/Resources/Licenses/zapret2-LICENSE.txt"
  echo '```'
  echo
  echo "## Go standard library and runtime (BSD-3-Clause)"
  echo
  echo "Go $(go env GOVERSION | sed 's/^go//')"
  echo
  echo '```text'
  go_license
  echo '```'

  cd "$ROOT/zarpd"
  go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}|{{.Version}}|{{.Dir}}{{end}}{{end}}' ./cmd/zarpd \
    | sort -u | while IFS='|' read -r path version dir; do
      echo
      echo "## $path $version"
      echo
      found=0
      for name in LICENSE LICENSE.md LICENSE.txt LICENCE COPYING COPYING.md NOTICE; do
        if [[ -f "$dir/$name" ]]; then
          echo '```text'
          cat "$dir/$name"
          echo '```'
          found=1
          break
        fi
      done
      if [[ $found -eq 0 ]]; then
        echo "_No license file was found in this module's source; see https://pkg.go.dev/$path._"
        echo "warning: no license file for $path $version" >&2
      fi
    done
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
generate > "$TMP"

if [[ "${1:-}" == "--check" ]]; then
  ok=1
  cmp -s "$TMP" "$OUT" || { echo "Resources/Licenses/THIRD_PARTY_NOTICES.md is out of date: run scripts/gen-notices.sh" >&2; ok=0; }
  cmp -s "$ROOT/LICENSE" "$LICENSE_COPY" || { echo "Resources/Licenses/Zarp-macOS-LICENSE.txt differs from LICENSE: run scripts/gen-notices.sh" >&2; ok=0; }
  [[ $ok -eq 1 ]] || exit 1
  exit 0
fi

install -m 644 "$TMP" "$OUT"
install -m 644 "$ROOT/LICENSE" "$LICENSE_COPY"
echo "wrote ${OUT#"$ROOT"/} ($(wc -c < "$OUT" | tr -d ' ') bytes, $(grep -c '^## ' "$OUT") sections) and ${LICENSE_COPY#"$ROOT"/}"
