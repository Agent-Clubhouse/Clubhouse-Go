"""Exercise the real live field replacement helper without an app or simulator."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

STUBS = r'''
import Foundation
import CoreGraphics

var failures: [String] = []
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures.append(message)
}
enum XCUIKeyboardKey: String { case delete = "\u{7f}" }
class Coordinate {
    let field: XCUIElement
    init(_ field: XCUIElement) { self.field = field }
    func tap() { field.cursor = field.text.count }
}
class XCUIElement: NSObject {
    var text = "phone-12345"
    var cursor = 0
    var ignoresDeletion = false
    var typed: [String] = []
    @objc dynamic var placeholderValue: String? = "Name"
    @objc dynamic var value: Any? { text.isEmpty ? placeholderValue : text }
    func tap() {}
    func coordinate(withNormalizedOffset offset: CGVector) -> Coordinate {
        precondition(offset.dx > 0.9)
        return Coordinate(self)
    }
    func typeText(_ value: String) {
        typed.append(value)
        for character in value {
            if character == "\u{7f}" {
                if cursor > 0 && !ignoresDeletion {
                    text.remove(at: text.index(text.startIndex, offsetBy: cursor - 1))
                    cursor -= 1
                }
            } else {
                text.insert(character, at: text.index(text.startIndex, offsetBy: cursor))
                cursor += 1
            }
        }
    }
}
class XCUIApplication {}
class Harness {
    func waitFor(_ field: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        predicate.evaluate(with: field)
    }
'''


def helper_source():
    source = (ROOT / "Annex/AnnexUITests/CompanionLiveE2ETests.swift").read_text()
    start = source.index("    private func replaceText(")
    end = source.index("    /// Waits until", start)
    return STUBS + source[start:end] + "\n}\n"


class ReplaceTextTests(unittest.TestCase):
    def run_helper(self, scenario):
        with tempfile.TemporaryDirectory() as folder:
            script = pathlib.Path(folder) / "replace-text.swift"
            script.write_text(helper_source() + "\nextension Harness {\nstatic func scenario() {\n"
                              + scenario + "\n}\n}\nHarness.scenario()\n")
            result = subprocess.run([
                "env", "-u", "COPILOT_CONNECTION_TOKEN", "GIT_CONFIG_COUNT=1",
                "GIT_CONFIG_KEY_0=safe.bareRepository", "GIT_CONFIG_VALUE_0=all",
                "swift", str(script),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_replaces_existing_text_even_when_cursor_started_at_beginning(self):
        self.run_helper(r'''
let field = XCUIElement()
Harness().replaceText(XCUIApplication(), in: field, with: "phone-12345-renamed")
precondition(failures.isEmpty, "\(failures)")
precondition(field.text == "phone-12345-renamed", field.text)
precondition(field.typed.count == 2)
precondition(field.typed[0].allSatisfy { $0 == "\u{7f}" })
''')

    def test_failed_clear_reports_failure_and_never_types_replacement(self):
        self.run_helper(r'''
let field = XCUIElement()
field.ignoresDeletion = true
Harness().replaceText(XCUIApplication(), in: field, with: "must-not-be-typed")
precondition(failures.count == 1, "\(failures)")
precondition(failures[0].contains("must be empty"))
precondition(field.text == "phone-12345")
precondition(field.typed.count == 1)
precondition(!field.typed.contains("must-not-be-typed"))
''')

    def test_empty_field_reporting_placeholder_types_only_replacement(self):
        self.run_helper(r'''
let field = XCUIElement()
field.text = ""
precondition(field.value as? String == "Name")
Harness().replaceText(XCUIApplication(), in: field, with: "new-agent")
precondition(failures.isEmpty, "\(failures)")
precondition(field.text == "new-agent")
precondition(field.typed == ["new-agent"])
''')

    def test_placeholder_after_deletion_is_accepted_before_replacement(self):
        self.run_helper(r'''
let field = XCUIElement()
field.placeholderValue = "Agent name"
Harness().replaceText(XCUIApplication(), in: field, with: "renamed")
precondition(failures.isEmpty, "\(failures)")
precondition(field.text == "renamed")
precondition(field.typed == [String(repeating: "\u{7f}", count: "phone-12345".count), "renamed"])
''')


if __name__ == "__main__":
    unittest.main()
