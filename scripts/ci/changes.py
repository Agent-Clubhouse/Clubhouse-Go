#!/usr/bin/env python3
"""Decide which CI lanes a change needs, from the changed paths on stdin.

Prints `swift=true|false` and `app=true|false` for $GITHUB_OUTPUT:
  swift  the SwiftPM lane (`swift test` for the transport and Framebriar packages)
  app    the Xcode build, the Release build and the UI shards

A path is classified by the first rule that matches; a path no rule names runs
everything, so a new kind of file is never silently untested.

Usage: git diff --name-only BASE... | changes.py
       changes.py --all        every lane (pushes to main)
"""
import fnmatch
import sys

DOCS = "docs"  # no build at all
SWIFT = "swift"  # `swift test` only
APP = "app"  # everything

RULES = [
    ("*.md", DOCS),
    ("docs/*", DOCS),
    ("LICENSE*", DOCS),
    ("App Icon.png", DOCS),
    (".gitignore", DOCS),
    (".clubhouse/*", DOCS),
    # SwiftPM-only test targets: the app's Xcode project never builds them.
    ("Tests/*", SWIFT),
    ("Vendor/Framebriar/Tests/*", SWIFT),
    (".nvmrc", SWIFT),
    ("coverage-baseline.json", SWIFT),
    ("scripts/coverage.sh", SWIFT),
]
LANES = {DOCS: set(), SWIFT: {"swift"}, APP: {"swift", "app"}}


def classify(path):
    for pattern, kind in RULES:
        if fnmatch.fnmatchcase(path, pattern):
            return kind
    return APP


def lanes(paths):
    needed = set()
    for path in paths:
        needed |= LANES[classify(path)]
    return needed


def main(argv, stdin):
    needed = {"swift", "app"} if "--all" in argv else lanes(line.strip() for line in stdin if line.strip())
    for lane in ("swift", "app"):
        print(f"{lane}={'true' if lane in needed else 'false'}")


if __name__ == "__main__":
    main(sys.argv[1:], sys.stdin)
