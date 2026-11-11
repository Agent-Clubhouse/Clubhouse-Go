"""Exercise the real launch helper with inert XCTest doubles, never an app or simulator."""
import pathlib
import subprocess
import tempfile
import unittest


class LaunchPairingTests(unittest.TestCase):
    def test_every_attempt_refreshes_after_termination_and_errors_stop_launch(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / "Annex/AnnexUITests/UITestSupport.swift").read_text()
        methods = source[source.index("    func launchApp("):source.index("    /// Fails the test")]
        stubs = r'''
import Foundation
class XCTestCase {
    var continueAfterFailure = false
    var executionTimeAllowance: TimeInterval = 0
}
class XCUIDevice {
    enum Orientation { case portrait }
    static let shared = XCUIDevice()
    var orientation = Orientation.portrait
}
class XCUIApplication {
    enum State { case notRunning, runningForeground, runningBackground }
    static var events: [String] = []
    static var succeedsOn = 3
    var state = State.runningForeground
    var launchArguments: [String] = []
    var launchEnvironment: [String: String] = [:]
    var attempts = 0
    func terminate() {
        Self.events.append("terminate")
        state = .notRunning
    }
    func wait(for expected: State, timeout: TimeInterval) -> Bool { state == expected }
    func launch() {
        precondition(state == .notRunning)
        attempts += 1
        Self.events.append("launch:" + (launchEnvironment["pin"] ?? "static"))
        state = attempts >= Self.succeedsOn ? .runningForeground : .runningBackground
    }
}
struct Issue { var compactDescription: String }
enum XCTExpectedFailure {
    class Options {
        var isStrict = true
        var issueMatcher: ((Issue) -> Bool)?
    }
}
func XCTExpectFailure(_ message: String, options: XCTExpectedFailure.Options, failingBlock: () -> Void) {
    failingBlock()
}
func XCTFail(_ message: String, file: StaticString, line: UInt) { fatalError(message) }
class ReliableUITestCase: XCTestCase {
    static let allowanceMargin: TimeInterval = 30
    var deadline = Date.distantFuture
'''
        checks = r'''
}
let helper = ReliableUITestCase()
var generation = 0
let app = helper.launchApp([], environment: ["static": "preserved"]) {
    precondition(XCUIApplication.events.last == "terminate")
    generation += 1
    XCUIApplication.events.append("prepare")
    return ["pin": String(generation)]
}
precondition(app.attempts == 3 && app.launchEnvironment["static"] == "preserved")
precondition(XCUIApplication.events == [
    "terminate", "prepare", "launch:1",
    "terminate", "prepare", "launch:2",
    "terminate", "prepare", "launch:3",
])
XCUIApplication.events = []
XCUIApplication.succeedsOn = 1
let ordinary = helper.launchApp([], environment: ["static": "unchanged"], attempts: 1)
precondition(ordinary.launchEnvironment == ["static": "unchanged"])
precondition(XCUIApplication.events == ["terminate", "launch:static"])
XCUIApplication.events = []
enum FixtureError: Error { case unavailable }
do {
    _ = try helper.launchApp([]) { throw FixtureError.unavailable }
    fatalError("Fixture failure must propagate, not launch with old credentials")
} catch FixtureError.unavailable {
    precondition(XCUIApplication.events == ["terminate"])
}
print("Fresh PIN per launch attempt; unchanged default; fixture errors stop launch")
'''
        (root / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root / "build") as folder:
            script = pathlib.Path(folder) / "launch-pairing.swift"
            script.write_text(stubs + methods + checks)
            result = subprocess.run([
                "env", "-u", "COPILOT_CONNECTION_TOKEN", "GIT_CONFIG_COUNT=1",
                "GIT_CONFIG_KEY_0=safe.bareRepository", "GIT_CONFIG_VALUE_0=all",
                "swift", str(script),
            ], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fresh PIN per launch attempt", result.stdout)


if __name__ == "__main__":
    unittest.main()
