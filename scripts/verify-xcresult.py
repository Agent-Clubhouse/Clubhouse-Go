#!/usr/bin/env python3
"""Require a nonempty successful XCTest result, even if xcodebuild exits 65.

Also reports to the GitHub job summary: tests that passed only on a retry
(as warning annotations), and time per test class for rebalancing UI shards.

Usage: verify-xcresult.py RESULT.xcresult [TITLE] [--no-retries-in BUNDLE ...]

--no-retries-in fails the run if a test in that bundle (e.g. ClubhouseGoTests) needed a
retry, so unit tests that share an invocation with retried UI tests stay strict.
--tests-json-output publishes the fresh details used for retry checks for a separate
inventory audit. Missing/malformed details then fail the verifier, even without a
strict bundle. Standalone callers without this flag retain advisory reporting.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def xcresult(kind, path):
    return json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path]))


def test_cases(node, bundle=None, suite=None):
    if node.get("nodeType", "").endswith("test bundle"):
        bundle = node.get("name")
    if node.get("nodeType") == "Test Suite":
        suite = node.get("name")
    if node.get("nodeType") == "Test Case":
        yield bundle, suite, node
        return
    for child in node.get("children", []):
        yield from test_cases(child, bundle, suite)


def all_cases(tests):
    for root in tests.get("testNodes", []):
        yield from test_cases(root)


def flaky_tests(tests, bundles=None):
    """(suite, test, failed attempts) for tests that passed after failing at least once."""
    flaky = []
    for bundle, suite, case in all_cases(tests):
        if bundles is not None and bundle not in bundles:
            continue
        runs = [c for c in case.get("children", []) if c.get("nodeType") == "Repetition"]
        failures = sum(run.get("result") == "Failed" for run in runs)
        if case.get("result") == "Passed" and failures:
            flaky.append((suite, case.get("name"), failures))
    return flaky


def class_durations(tests):
    durations = {}
    for _, suite, case in all_cases(tests):
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


def export_details(tests, output):
    """Publish one complete, usable SDK response; never leave a partial JSON file."""
    try:
        cases = list(all_cases(tests)) if isinstance(tests, dict) and isinstance(tests.get("testNodes"), list) else []
        usable = cases and all(isinstance(case.get("name") or case.get("nodeIdentifier"), str)
                               and (case.get("name") or case.get("nodeIdentifier"))
                               and isinstance(case.get("result"), str) and case.get("result")
                               for _, _, case in cases)
    except (AttributeError, TypeError):
        usable = False
    if not usable:
        raise ValueError("Test details have no usable test-case inventory")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, prefix="." + output.name,
                                         suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(tests, stream)
            stream.write("\n")
        os.replace(temporary, output)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(path, title, strict_bundles=(), tests_json_output=None):
    output = Path(tests_json_output) if tests_json_output else None
    if output is not None:
        # A failed SDK read must not let inventory consume a previous invocation.
        output.unlink(missing_ok=True)
    summary_error = None
    try:
        summary = xcresult("summary", path)
        if not isinstance(summary, dict):
            raise ValueError("XCTest summary is not an object")
    except (subprocess.CalledProcessError, ValueError) as error:
        summary_error = error
        summary = {}
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    result = summary.get("result")
    print(f"XCTest result: {result}; passed={passed}, failed={failed}")
    tests = None
    details_error = None
    try:
        started = time.monotonic()
        tests = xcresult("tests", path)
        print(f"XCTest details query: {time.monotonic() - started:.3f}s")
        if output is not None:
            started = time.monotonic()
            export_details(tests, output)
            print(f"XCTest details JSON export: {time.monotonic() - started:.3f}s")
        report(title, tests)
    except (subprocess.CalledProcessError, ValueError) as error:
        details_error = error
        # Standalone reporting is advisory; an explicitly requested inventory
        # export is mandatory, as are details for a strict bundle's retry gate.
        print(f"::warning title=xcresult report::Could not read test details: {error}")
    if summary_error is not None:
        raise SystemExit(f"Could not read complete XCTest summary: {summary_error}")
    if output is not None and details_error is not None:
        raise SystemExit("Could not export fresh test details for inventory verification")
    if result != "Passed" or passed <= 0 or failed != 0:
        raise SystemExit("XCTest did not produce a nonempty passing result")
    if strict_bundles:
        if tests is None:
            raise SystemExit(f"Could not check {', '.join(strict_bundles)} for retries")
        retried = flaky_tests(tests, set(strict_bundles))
        if retried:
            names = ", ".join(f"{suite}/{name}" for suite, name, _ in retried)
            raise SystemExit(f"Tests in {', '.join(strict_bundles)} must pass without a retry: {names}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("title", nargs="?")
    parser.add_argument("--no-retries-in", action="append", default=[], metavar="BUNDLE")
    parser.add_argument("--tests-json-output", help="Atomically export the same fresh details used for retry checks")
    args = parser.parse_args()
    main(args.path, args.title or os.path.basename(args.path), args.no_retries_in, args.tests_json_output)
