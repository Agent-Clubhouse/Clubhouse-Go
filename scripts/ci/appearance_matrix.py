#!/usr/bin/env python3
"""The scheduled appearance lane's selection and its fail-closed result check.

UI test methods that call `appearanceMatrix(` or `requireFullAppearanceMatrix(` (UIAppearanceMatrix.swift) run one
representative appearance on every push and every variant when CLUBHOUSE_UI_APPEARANCE_MATRIX=full.

  appearance_matrix.py selectors
      Prints one -only-testing selector per gated method, derived from the sources, so the nightly selection can't
      drift, be commented out or name a missing method.
  appearance_matrix.py verify <tests.json> <xcodebuild.log>
      Fails unless every gated method ran and passed (not skipped), no selected test was skipped or failed, and each
      gated method printed a full-mode APPEARANCE_MATRIX line that ran every variant it lists. <tests.json> is
      `xcrun xcresulttool get test-results tests --path <bundle>`.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
UI_TARGET = "ClubhouseGoUITests"
GATES = ("requireFullAppearanceMatrix(", "appearanceMatrix(")
CLASS = re.compile(r"\bclass\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b")
MARKER = re.compile(r"APPEARANCE_MATRIX test=-\[\w+\.(\w+) (\w+)\] mode=(full|push) variants=(.*?) ran=(.*)$")


def gated_methods(root=ROOT):
    """Sorted (class, method) for zero-argument test methods whose bodies use the appearance switch."""
    found = set()
    for source in sorted((root / "Annex/AnnexUITests").glob("*.swift")):
        if source.name == "UIAppearanceMatrix.swift":
            continue
        text = source.read_text()
        classes = CLASS.findall(text)
        if not classes:
            continue
        for match in re.finditer(r"\bfunc\s+(test\w+)\s*\(\s*\)[^{]*\{", text):
            depth, index = 1, match.end()
            while depth and index < len(text):
                depth += {"{": 1, "}": -1}.get(text[index], 0)
                index += 1
            body = "\n".join(line for line in text[match.end():index].splitlines() if not line.strip().startswith("//"))
            if any(gate in body for gate in GATES):
                found.add((classes[0], match.group(1)))
    return sorted(found)


def selectors(root=ROOT):
    return [f"-only-testing:{UI_TARGET}/{cls}/{method}" for cls, method in gated_methods(root)]


def test_cases(tests_json):
    """{'Class/method': result} for every test case in an xcresulttool `tests` document."""
    cases = {}

    def walk(node):
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "")
            cases[identifier[:-2] if identifier.endswith("()") else identifier] = node.get("result")
        for child in node.get("children", []):
            walk(child)

    for node in tests_json.get("testNodes", []):
        walk(node)
    return cases


def problems(tests_json, log_text, expected):
    cases = test_cases(tests_json)
    issues = []
    expected_ids = {f"{cls}/{method}" for cls, method in expected}
    if not expected_ids:
        issues.append("no gated appearance methods were found in the sources")
    for identifier in sorted(expected_ids):
        result = cases.get(identifier)
        if result is None:
            issues.append(f"{identifier} did not run")
        elif result != "Passed":
            issues.append(f"{identifier} {result.lower()}, expected passed")
    for identifier, result in sorted(cases.items()):
        if identifier not in expected_ids and result != "Passed":
            issues.append(f"unexpected {result.lower()} test {identifier}")

    markers = {}
    for line in log_text.splitlines():
        match = MARKER.search(line)
        if match:
            cls, method, mode, variants, ran = match.groups()
            markers.setdefault(f"{cls}/{method}", []).append((mode, variants.split("|"), [v for v in ran.split("|") if v]))
    for identifier in sorted(expected_ids):
        seen = markers.get(identifier, [])
        if not seen:
            issues.append(f"{identifier} printed no APPEARANCE_MATRIX line")
            continue
        for mode, variants, ran in seen:
            if mode != "full":
                issues.append(f"{identifier} ran in {mode} mode; the full matrix switch did not reach the test runner")
            elif ran != variants:
                issues.append(f"{identifier} ran {ran} of its variants {variants}")
    return issues


def main(argv):
    if argv[:1] == ["selectors"]:
        print(" ".join(selectors()))
        return 0
    if argv[:1] == ["verify"] and len(argv) == 3:
        found = problems(json.loads(Path(argv[1]).read_text()), Path(argv[2]).read_text(errors="replace"), gated_methods())
        for issue in found:
            print(f"::error::Appearance matrix: {issue}")
        print(f"Appearance matrix: {len(gated_methods())} gated methods, {len(found)} problems")
        return 1 if found else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
