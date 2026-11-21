#!/usr/bin/env python3
"""Execute the exact typed-value helper with inert getters, without XCTest or a simulator."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", nargs="?", type=Path, default=ROOT / "Annex/AnnexUITests/UITestSupport.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("    func assertTypedValue(")
end = source.index("\n    /// Stability needs", start)
helper = source[start:end]
constant = next(line for line in source.splitlines() if "static let typedValuePublicationBudget:" in line)
fixture = '''import Foundation
var failures: [String] = []
func require(_ condition: @autoclosure () -> Bool, _ message: String = "Control failed") {
    guard condition() else { print("FAIL \\(message)"); exit(1) }
}
func XCTFail(_ message: String, file: StaticString, line: UInt) { failures.append(message) }
final class XCUIElement {
    let read: () -> Any?
    init(_ read: @escaping () -> Any?) { self.read = read }
    var value: Any? { read() }
}
class ReliableUITestCase {
''' + constant + "\n" + helper + '''
}
let test = ReliableUITestCase()
var lateReads = 0
let began = ContinuousClock.now
test.assertTypedValue(XCUIElement {
    lateReads += 1
    Thread.sleep(forTimeInterval: 0.04)
    return "complete"
}, equals: "complete", timeout: 0.02)
require(lateReads == 1 && failures.count == 1, "A matching late synchronous read must fail")
print("PASS late-match-rejected elapsed=\\(began.duration(to: .now)) admissionBudget=0.02")
failures = []
var zeroReads = 0
test.assertTypedValue(XCUIElement { zeroReads += 1; return "complete" }, equals: "complete", timeout: 0)
require(zeroReads == 0 && failures.count == 1, "Zero budget admits no read or success")
print("PASS zero-budget-no-read")
failures = []
var timelyReads = 0
test.assertTypedValue(XCUIElement { timelyReads += 1; return "complete" }, equals: "complete", timeout: 1)
require(timelyReads == 1 && failures.isEmpty, "A timely exact match must succeed")
print("PASS timely-exact-match")
failures = []
let values = ["\\u{e9}", "e\\u{301}"]
require(values[0] == values[1] && Array(values[0].utf8) != Array(values[1].utf8))
var distinctReads = 0
test.assertTypedValue(XCUIElement {
    distinctReads += 1
    return values[min(distinctReads - 1, 1)]
}, equals: "different", timeout: 0.15)
require(distinctReads >= 2 && failures.count == 1)
require(failures[0].components(separatedBy: " → ").count == 2,
             "Canonically equivalent but byte-distinct wrong values must both survive trail deduplication")
print("PASS byte-distinct-trail")
failures = []
var nilReads = 0
test.assertTypedValue(XCUIElement {
    nilReads += 1
    return nilReads < 3 ? nil : "complete"
}, equals: "complete", timeout: 1)
require(nilReads == 3 && failures.isEmpty, "Repeated nil observations must not suppress later success")
print("PASS nil-to-timely-match")
'''
scratch = ROOT / ".build"
scratch.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="typed-value-controls-", dir=scratch) as directory:
    path = Path(directory) / "controls.swift"
    path.write_text(fixture)
    result = subprocess.run(["swift", str(path)], cwd=ROOT, capture_output=True, text=True, timeout=60)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    raise SystemExit(result.returncode)
