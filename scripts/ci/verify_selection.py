#!/usr/bin/env python3
"""Fail a shard whose planned selection didn't actually execute as expected.

verify-xcresult.py checks that what ran passed. This checks that what was planned ran:
- every test method the source declares in each class named by `-only-testing:<bundle>/<Class>` has a result;
- a result of Skipped is accepted only for a method whose source has a documented skip guard (an XCTSkip call or the
  appearance-matrix switch); any other skip is an unexpected non-execution;
- a target-level selection (the catch-all) produced at least one executed (not skipped) case in that bundle.
So a narrowed matrix can't hide a missing class, a missing method or an unintended skip behind other passing results.

Usage: verify_selection.py "<selection flags>" <tests.json from `xcresulttool get test-results tests`> [<source root>]
"""
import json
from pathlib import Path
import re
import sys

SOURCES = {"ClubhouseGoUITests": "Annex/AnnexUITests", "ClubhouseGoTests": "Annex/AnnexTests"}
SKIP_GUARDS = ("XCTSkip", "requireFullAppearanceMatrix(")


def results(tests_json):
    """{(bundle, suite): {method: result}} from an xcresulttool `tests` document."""
    found = {}

    def walk(node, bundle=None, suite=None):
        kind = node.get("nodeType")
        if kind in ("Unit test bundle", "UI test bundle"):
            bundle = node.get("name")
        elif kind == "Test Suite":
            suite = node.get("name")
        elif kind == "Test Case" and bundle:
            method = (node.get("name") or node.get("nodeIdentifier", "").split("/")[-1]).removesuffix("()")
            found.setdefault((bundle, suite), {})[method] = node.get("result")
        for child in node.get("children", []):
            walk(child, bundle, suite)

    for node in tests_json.get("testNodes", []):
        walk(node)
    return found


def declared(root, bundle, suite):
    """{method: has documented skip guard} for the class's zero-argument test methods, or None if not found."""
    directory = root / SOURCES.get(bundle, "")
    for source in directory.glob("*.swift"):
        text = source.read_text(errors="replace")
        if not re.search(rf"\bclass\s+{suite}\s*:", text):
            continue
        methods = {}
        for match in re.finditer(r"\bfunc\s+(test\w+)\s*\(\s*\)[^{]*\{", text):
            depth, index = 1, match.end()
            while depth and index < len(text):
                depth += {"{": 1, "}": -1}.get(text[index], 0)
                index += 1
            methods[match.group(1)] = any(guard in text[match.end():index] for guard in SKIP_GUARDS)
        return methods
    return None


def problems(selection, tests_json, root):
    ran = results(tests_json)
    issues = []
    for flag in selection.split():
        mode, selector = flag.split(":", 1)
        if mode != "-only-testing":
            continue
        bundle, _, rest = selector.partition("/")
        suite, _, method = rest.partition("/")
        if not suite:
            executed = sum(1 for (b, _), cases in ran.items() if b == bundle for r in cases.values() if r != "Skipped")
            if not executed:
                issues.append(f"{bundle} was selected but executed no test case")
            continue
        expected = declared(root, bundle, suite)
        if expected is None:
            issues.append(f"{bundle}/{suite} was selected but its source class was not found")
            continue
        if method:
            expected = {method: expected.get(method, False)}
        actual = ran.get((bundle, suite), {})
        for name, guarded in sorted(expected.items()):
            outcome = actual.get(name)
            if outcome is None:
                issues.append(f"{bundle}/{suite}/{name} was selected but produced no result")
            elif outcome == "Skipped" and not guarded:
                issues.append(f"{bundle}/{suite}/{name} was skipped without a documented skip guard")
    return issues


def main(argv):
    root = Path(argv[2]) if len(argv) > 2 else Path(__file__).resolve().parents[2]
    found = problems(argv[0], json.loads(Path(argv[1]).read_text()), root)
    for issue in found:
        print(f"::error::{issue}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
