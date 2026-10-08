#!/usr/bin/env python3
"""Checks that every relative link and anchor in the repository's Markdown files resolves.

    python3 scripts/check-docs.py

Covers [text](target) links, ![alt](target) images, and the src= / href= attributes of the HTML some of
the READMEs use. External (http/https/mailto) links are not fetched. A link to `file.md#section` must
point at a heading that exists in that file, using GitHub's anchor rules. Exits 1 and lists the
problems if anything is broken, so it can run in CI and in `make test`.
"""
import os
import re
import subprocess
import sys
import unicodedata

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML = re.compile(r"""\b(?:src|href)\s*=\s*["']([^"']+)["']""")
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def markdown_files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return sorted(f for f in out if f and os.path.exists(os.path.join(ROOT, f)))


def slug(heading):
    """GitHub's heading anchor: lowercase, drop punctuation, spaces to hyphens."""
    text = re.sub(r"`([^`]*)`", r"\1", heading)           # inline code keeps its text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links keep their label
    text = re.sub(r"<[^>]+>", "", text)                   # inline html
    text = unicodedata.normalize("NFC", text).lower()
    kept = []
    for ch in text:
        if ch.isalnum() or ch in "-_":
            kept.append(ch)
        elif ch.isspace():
            kept.append("-")
    return "".join(kept)


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def anchors_of(path, cache={}):
    if path in cache:
        return cache[path]
    seen, found, in_fence = {}, set(), False
    for line in read_lines(path):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING.match(line)
        if not m:
            continue
        base = slug(m.group(2))
        n = seen.get(base, 0)
        seen[base] = n + 1
        found.add(base if n == 0 else f"{base}-{n}")
    cache[path] = found
    return found


def targets_in(path):
    in_fence = False
    for number, line in enumerate(read_lines(path), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        no_code = re.sub(r"`[^`]*`", "", line)  # `[x](y)` inside inline code is not a link
        for pattern in (LINK, HTML):
            for m in pattern.finditer(no_code):
                yield number, m.group(1)


def main():
    problems = []
    files = markdown_files()
    for rel in files:
        path = os.path.join(ROOT, rel)
        for number, target in targets_in(path):
            if re.match(r"^(https?:|mailto:|tel:)", target):
                continue
            file_part, _, anchor = target.partition("#")
            if file_part:
                resolved = os.path.normpath(os.path.join(os.path.dirname(path), file_part))
            else:
                resolved = path
            if not os.path.exists(resolved):
                problems.append(f"{rel}:{number}: '{target}' does not exist")
                continue
            if anchor and resolved.endswith(".md"):
                if anchor.lower() not in anchors_of(resolved):
                    problems.append(f"{rel}:{number}: '{target}': no heading with that anchor in {os.path.relpath(resolved, ROOT)}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        print(f"\n{len(problems)} broken link(s) in {len(files)} Markdown files", file=sys.stderr)
        return 1
    print(f"docs ok: every relative link and anchor resolves ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
