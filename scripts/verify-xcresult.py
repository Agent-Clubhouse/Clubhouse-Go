#!/usr/bin/env python3
"""Require a nonempty successful XCTest result, even if xcodebuild exits 65."""
import json
import subprocess
import sys

summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1]
]))
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
result = summary.get("result")
print(f"XCTest result: {result}; passed={passed}, failed={failed}")
if result != "Passed" or passed <= 0 or failed != 0:
    raise SystemExit("XCTest did not produce a nonempty passing result")
