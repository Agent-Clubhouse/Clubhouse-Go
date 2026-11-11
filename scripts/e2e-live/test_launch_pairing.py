"""Exercise the real launch helper with inert XCTest doubles, never an app or simulator."""
import json
import pathlib
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

STUBS = r'''
import Foundation
class XCTestCase {
    var continueAfterFailure = false
    var executionTimeAllowance: TimeInterval = 0
    func add(_ attachment: XCTAttachment) {}
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
    static var onLaunch: ((XCUIApplication) -> Void)?
    static var projectListed = false
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
        Self.onLaunch?(self)
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
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    print("ASSERTION FAILED: " + message)
    exit(1)
}
func XCTAssertTrue(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { XCTFail(message(), file: file, line: line) }
}
func XCTAssertNil(_ value: Any?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { XCTFail(message(), file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Harness", code: 1) }
    return value
}
class XCTAttachment {
    enum Lifetime { case keepAlways }
    var name = ""
    var lifetime = Lifetime.keepAlways
    init(string: String) {}
}
class ReliableUITestCase: XCTestCase {
    static let allowanceMargin: TimeInterval = 30
    var deadline = Date.distantFuture
'''


def launch_support():
    source = (ROOT / "Annex/AnnexUITests/UITestSupport.swift").read_text()
    return STUBS + source[source.index("    func launchApp("):source.index("    /// Fails the test")] + "\n}\n"


def run_swift(folder, source):
    script = folder / "launch-pairing.swift"
    script.write_text(source)
    return subprocess.run([
        "env", "-u", "COPILOT_CONNECTION_TOKEN", "GIT_CONFIG_COUNT=1",
        "GIT_CONFIG_KEY_0=safe.bareRepository", "GIT_CONFIG_VALUE_0=all",
        "swift", str(script),
    ], capture_output=True, text=True, timeout=60)


class LaunchPairingTests(unittest.TestCase):
    def test_every_attempt_refreshes_after_termination_and_errors_stop_launch(self):
        checks = r'''
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
        (ROOT / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            result = run_swift(pathlib.Path(folder), launch_support() + checks)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fresh PIN per launch attempt", result.stdout)

    def run_pairing_integration(self, expired=False):
        desktop = (ROOT / "scripts/e2e-live/desktop-fixture.spec.ts").read_text()
        swift = (ROOT / "Annex/AnnexUITests/CompanionLiveE2ETests.swift").read_text()
        request_start = desktop.index("      const requestFile =")
        request = desktop[request_start:desktop.index("      await new Promise((r) => setTimeout(r, 500));", request_start)]
        startup = desktop[desktop.index("    rememberPairingPin(FIXTURE_DIR, status.pin);"):desktop.index("    const stop =")]
        getter = desktop[desktop.index("    const getPairingStatus ="):desktop.index("    let status: any;")]
        writers = desktop[desktop.index("function writeFile("):desktop.index("/** A git repository")]
        launch = swift[swift.index("    private func launchPaired("):swift.index("    private func element(")]
        dispatcher = swift[swift.index("    @discardableResult\n    private func dispatcherFixture("):swift.index("    private func dispatcherRow(")]
        node = r'''
import * as fs from 'node:fs';
import * as path from 'node:path';
import { rememberPairingPin, writePairingInvitation } from HELPER_PATH;
const FIXTURE_DIR = process.argv[2];
let generation = 1;
let pin = '000001';
const spent = new Map<string, string>();
const trace: { op: string; code?: number }[] = [];
function pair(provided: string, identity: string) {
  const code = spent.has(provided) ? (spent.get(provided) === identity ? 200 : 410) : provided === pin ? 200 : 410;
  if (code === 200 && !spent.has(provided)) {
    spent.set(provided, identity);
    pin = String(++generation).padStart(6, '0');
  }
  trace.push({ op: 'pair', code });
  return code;
}
const window = {
  clubhouse: { annex: {
    getStatus: async () => ({ tlsEnabled: true, advertising: false, pairingPaused: false, port: 43210,
      fingerprint: 'fixture-host', tlsCertificateFingerprint: 'AA:BB:CC', pin }),
    regeneratePin: async () => { pin = String(++generation).padStart(6, '0'); trace.push({ op: 'regenerate' }); },
  } },
  evaluate: async (callback: () => unknown) => callback(),
};
const observeDesktop = async (status: { pin: string }) => {
  if (pair(status.pin, 'observer') !== 200) throw new Error('Observer failed');
  return {};
};
let observer;
const agents = { echo: 'echo', builder: 'builder' };
const projectDir = path.join(FIXTURE_DIR, 'Phone Fixture');
const log = (_message: string) => {};
WRITERS
GETTER
let status: any = await getPairingStatus();
STARTUP
fs.writeFileSync(path.join(FIXTURE_DIR, 'server-ready'), '');
while (!fs.existsSync(path.join(FIXTURE_DIR, 'server-stop'))) {
REQUEST
  const phone = path.join(FIXTURE_DIR, 'phone-pair.json');
  if (fs.existsSync(phone)) {
    const request = JSON.parse(fs.readFileSync(phone, 'utf8'));
    fs.rmSync(phone);
    const code = pair(request.pin, request.id);
    writeFile(path.join(FIXTURE_DIR, 'phone-paired.json'), JSON.stringify({ id: request.id, code }));
  }
  await new Promise(resolve => setTimeout(resolve, 5));
}
writeFile(path.join(FIXTURE_DIR, 'trace.json'), JSON.stringify(trace));
'''
        node = (node.replace("HELPER_PATH", json.dumps(str(ROOT / "scripts/e2e-live/pairing-fixture.ts")))
                .replace("WRITERS", writers)
                .replace("GETTER", getter).replace("STARTUP", startup).replace("REQUEST", request))
        ui = r'''
class XCUIElement {
    let exists: Bool
    init(_ exists: Bool) { self.exists = exists }
    func waitForExistence(timeout: TimeInterval) -> Bool { exists }
    func tap() {}
}
class XCUIElementQuery {
    var buttons: XCUIElementQuery { self }
    subscript(_ label: String) -> XCUIElement { XCUIElement(true) }
    func matching(_ predicate: NSPredicate) -> XCUIElementQuery { self }
    var firstMatch: XCUIElement { XCUIElement(XCUIApplication.projectListed) }
}
extension XCUIApplication {
    enum ElementType { case any }
    var tabBars: XCUIElementQuery { XCUIElementQuery() }
    func descendants(matching: ElementType) -> XCUIElementQuery { XCUIElementQuery() }
}
class LiveFixture: ReliableUITestCase {
    var env: [String: String] { ["CLUBHOUSE_E2E_FIXTURE_DIR": FIXTURE_PATH] }
    var projectName: String { "Phone Fixture" }
LAUNCH
DISPATCHER
    func run() throws { _ = try launchPaired() }
}
XCUIApplication.onLaunch = { app in
    do {
        let invitation = try XCTUnwrap(app.launchEnvironment["CLUBHOUSE_COMPANION_TEST_INVITATION"])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(invitation.utf8)) as? [String: Any])
        let pin = try XCTUnwrap(body["pin"] as? String)
        let id = UUID().uuidString
        let dir = URL(fileURLWithPath: FIXTURE_PATH)
        try JSONSerialization.data(withJSONObject: ["id": id, "pin": pin])
            .write(to: dir.appending(path: "phone-pair.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try? Data(contentsOf: dir.appending(path: "phone-paired.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["id"] as? String == id {
                XCUIApplication.projectListed = reply["code"] as? Int == 200
                if !XCUIApplication.projectListed { print("PHONE PAIR REJECTED: spent or invalid PIN (HTTP 410)") }
                AFTER_PAIRING
                return
            }
            usleep(1000)
        }
        XCTFail("Offline desktop did not answer the phone pair")
    } catch { XCTFail(error.localizedDescription) }
}
CHECKS
'''
        checks = r'''
XCUIApplication.succeedsOn = 2
try LiveFixture().run() // Initial launch and a hosted-launch retry that already spent its PIN.
XCUIApplication.succeedsOn = 1
let next = LiveFixture()
try next.run() // Explicit relaunch.
try LiveFixture().run() // Fresh runner has no frozen invitation environment.
print("Real preparePairing request/ack and launchPaired closure paired four fresh identities")
'''
        if expired:
            checks = r'''
XCUIApplication.succeedsOn = 1
do {
    try LiveFixture().run()
    XCTFail("An expired invitation must fail before waiting for the project")
} catch {
    XCTAssertTrue(error.localizedDescription.contains("Fixture pairing PIN expired"), error.localizedDescription)
    print("Expired invitation failed clearly before project wait")
}
'''
        clock = r'''
struct Date: Comparable {
    static var offset: TimeInterval = 0
    let raw: Foundation.Date
    init() { raw = Foundation.Date().addingTimeInterval(Self.offset) }
    init(timeIntervalSince1970: TimeInterval) { raw = Foundation.Date(timeIntervalSince1970: timeIntervalSince1970) }
    static var distantPast: Date { Date(timeIntervalSince1970: Foundation.Date.distantPast.timeIntervalSince1970) }
    static var distantFuture: Date { Date(timeIntervalSince1970: Foundation.Date.distantFuture.timeIntervalSince1970) }
    var timeIntervalSince1970: TimeInterval { raw.timeIntervalSince1970 }
    var timeIntervalSinceNow: TimeInterval { timeIntervalSince1970 - Date().timeIntervalSince1970 }
    func addingTimeInterval(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: timeIntervalSince1970 + value) }
    static func < (lhs: Date, rhs: Date) -> Bool { lhs.raw < rhs.raw }
    static func == (lhs: Date, rhs: Date) -> Bool { lhs.raw == rhs.raw }
}
''' if expired else ""
        (ROOT / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            folder = pathlib.Path(folder)
            script = folder / "desktop.ts"
            script.write_text(node)
            server = subprocess.Popen(["node", str(script), str(folder)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            failure = None
            try:
                deadline = time.monotonic() + 10
                while not (folder / "server-ready").exists() and time.monotonic() < deadline and server.poll() is None:
                    time.sleep(0.01)
                self.assertTrue((folder / "server-ready").exists(), "Offline fixture did not start")
                source = (clock + launch_support() + ui.replace("FIXTURE_PATH", json.dumps(str(folder)))
                          .replace("LAUNCH", launch).replace("DISPATCHER", dispatcher).replace("CHECKS", checks)
                          .replace("AFTER_PAIRING", "Date.offset += 11 * 60" if expired else ""))
                result = run_swift(folder, source)
            except subprocess.TimeoutExpired as error:
                failure = error
            finally:
                (folder / "server-stop").touch()
                try:
                    output, errors = server.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    server.terminate()
                    output, errors = server.communicate(timeout=10)
            if failure:
                diagnostics = {name: (folder / name).read_text() for name in
                               ("dispatcher-request.json", "dispatcher-done.json") if (folder / name).exists()}
                self.fail(f"Swift fixture timed out: {diagnostics}; server: {output}{errors}; "
                          f"Swift: {failure.stdout!r} {failure.stderr!r}")
            self.assertEqual(server.returncode, 0, output + errors)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            trace = json.loads((folder / "trace.json").read_text())
        return result.stdout, trace

    def test_real_request_ack_and_launch_paired_use_regenerated_not_observer_pin(self):
        output, trace = self.run_pairing_integration()
        self.assertIn("paired four fresh identities", output)
        self.assertEqual([item["code"] for item in trace if item["op"] == "pair"], [200] * 5)
        self.assertEqual(sum(item["op"] == "regenerate" for item in trace), 4)

    def test_real_launch_paired_reports_expiry_instead_of_project_timeout(self):
        output, trace = self.run_pairing_integration(expired=True)
        self.assertIn("Expired invitation failed clearly before project wait", output)
        self.assertEqual([item["code"] for item in trace if item["op"] == "pair"], [200, 200])


if __name__ == "__main__":
    unittest.main()
