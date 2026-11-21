#!/usr/bin/env python3
"""Fail a shard whose planned selection didn't actually execute.

verify-xcresult.py checks that what ran passed. This checks that what was planned ran: every class the shard's
`-only-testing` flags name produced at least one test-case result (passed, failed or skipped), and a target-level
selection produced at least one case in that bundle. A narrowed matrix can't hide a missing class behind a passing
hosted bundle or an empty result.

Usage: verify_selection.py "<selection flags>" <tests.json from `xcresulttool get test-results tests`>
"""
import json
from pathlib import Path
import sys


def executed(tests_json):
    """{bundle: {suite: case count}} from an xcresulttool `tests` document."""
    found = {}

    def walk(node, bundle=None, suite=None):
        kind = node.get("nodeType")
        if kind in ("Unit test bundle", "UI test bundle"):
            bundle = node.get("name")
        elif kind == "Test Suite":
            suite = node.get("name")
        elif kind == "Test Case" and bundle:
            found.setdefault(bundle, {}).setdefault(suite, 0)
            found[bundle][suite] += 1
        for child in node.get("children", []):
            walk(child, bundle, suite)

    for node in tests_json.get("testNodes", []):
        walk(node)
    return found


def missing(selection, tests_json):
    ran = executed(tests_json)
    problems = []
    for flag in selection.split():
        mode, selector = flag.split(":", 1)
        if mode != "-only-testing":
            continue
        bundle, _, rest = selector.partition("/")
        suite = rest.split("/")[0]
        if suite and not ran.get(bundle, {}).get(suite):
            problems.append(f"{bundle}/{suite} was selected but produced no test results")
        elif not suite and not sum(ran.get(bundle, {}).values()):
            problems.append(f"{bundle} was selected but produced no test results")
    return problems


def main(argv):
    problems = missing(argv[0], json.loads(Path(argv[1]).read_text()))
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
