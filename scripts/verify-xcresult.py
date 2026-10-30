#!/usr/bin/env python3
"""Require a nonempty successful XCTest result, even if xcodebuild exits 65.

Also reports to the GitHub job summary: tests that passed only on a retry
(as warning annotations), and time per test class for rebalancing UI shards.

Usage: verify-xcresult.py RESULT.xcresult [TITLE]
"""
import json
import os
import subprocess
import sys


def xcresult(kind, path):
    return json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path]))


def test_cases(node, suite=None):
    if node.get("nodeType") == "Test Suite":
        suite = node.get("name")
    if node.get("nodeType") == "Test Case":
        yield suite, node
        return
    for child in node.get("children", []):
        yield from test_cases(child, suite)


def all_cases(tests):
    for root in tests.get("testNodes", []):
        yield from test_cases(root)


def flaky_tests(tests):
    """(suite, test, failed attempts) for tests that passed after failing at least once."""
    flaky = []
    for suite, case in all_cases(tests):
        runs = [c for c in case.get("children", []) if c.get("nodeType") == "Repetition"]
        failures = sum(run.get("result") == "Failed" for run in runs)
        if case.get("result") == "Passed" and failures:
            flaky.append((suite, case.get("name"), failures))
    return flaky


def class_durations(tests):
    durations = {}
    for suite, case in all_cases(tests):
        durations[suite] = durations.get(suite, 0) + (case.get("durationInSeconds") or 0)
    return {suite: round(seconds) for suite, seconds in durations.items()}


def report(title, tests):
    flaky = flaky_tests(tests)
    for suite, name, failures in flaky:
        print(f"::warning title=Flaky test::{suite}/{name} passed only after {failures} failed attempt"
              f"{'s' if failures > 1 else ''} ({title})")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = [f"### {title}", ""]
    if flaky:
        lines += [f"⚠️ **{len(flaky)} test(s) passed only on a retry:**", ""]
        lines += [f"- `{suite}/{name}`: failed {failures}×, then passed" for suite, name, failures in flaky]
        lines.append("")
    lines += ["<details><summary>Seconds per test class</summary>", "", "| Class | Seconds |", "| --- | --- |"]
    durations = class_durations(tests)
    lines += [f"| {suite} | {seconds} |" for suite, seconds in sorted(durations.items(), key=lambda i: -i[1])]
    lines += ["", "</details>", ""]
    with open(summary_path, "a") as summary:
        summary.write("\n".join(lines) + "\n")


def main(path, title):
    summary = xcresult("summary", path)
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    result = summary.get("result")
    print(f"XCTest result: {result}; passed={passed}, failed={failed}")
    try:
        report(title, xcresult("tests", path))
    except (subprocess.CalledProcessError, ValueError) as error:
        # Reporting is advisory; the pass/fail verdict below is what gates the job.
        print(f"::warning title=xcresult report::Could not read test details: {error}")
    if result != "Passed" or passed <= 0 or failed != 0:
        raise SystemExit("XCTest did not produce a nonempty passing result")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.path.basename(sys.argv[1]))
