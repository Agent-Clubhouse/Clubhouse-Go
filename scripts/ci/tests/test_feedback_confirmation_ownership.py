"""Run the actual Swift ownership helpers against synthetic native-tree shapes.

This is a Foundation-only host regression, not an XCTest, app or simulator run.
The first fixture models the original iPad hierarchy's two inactive backdrops and
the current popover's sibling backdrop. No private native payload is embedded.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


def actual_helper(source, name):
    start = source.index("    @MainActor private func " + name + "(")
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                     "The pure Foundation query-model probe needs the macOS Swift compiler")
class FeedbackConfirmationOwnershipTests(unittest.TestCase):
    def test_actual_helpers_reject_inactive_or_ambiguous_dismissal_hosts(self):
        source = (ROOT / "Annex/AnnexUITests/FeedbackTriggersUITests.swift").read_text()
        helpers = "\n\n".join(actual_helper(source, name) for name in
                                ("uniqueHeldConfirmation", "heldPopoverDismissal"))
        model = r'''
import Foundation

enum Kind { case application, other, popover, sheet, staticText, any }
final class Node {
    let kind: Kind
    let identifier: String
    let label: String
    let nodes: [Node]
    init(_ kind: Kind, id: String = "", label: String = "", _ nodes: [Node] = []) {
        self.kind = kind; self.identifier = id; self.label = label; self.nodes = nodes
    }
    var descendants: [Node] { nodes.flatMap { [$0] + $0.descendants } }
    func descendants(matching kind: Kind) -> Query {
        Query(descendants.filter { kind == .any || $0.kind == kind })
    }
    func children(matching kind: Kind) -> Query { Query(nodes.filter { $0.kind == kind }) }
    var popovers: Query { descendants(matching: .popover) }
    var sheets: Query { descendants(matching: .sheet) }
    var otherElements: Query { descendants(matching: .other) }
}
struct Query {
    let nodes: [Node]
    init(_ nodes: [Node]) { self.nodes = nodes }
    var count: Int { nodes.count }
    var allElementsBoundByIndex: [Node] { nodes }
    func containing(_ kind: Kind, identifier: String?) -> Query {
        Query(nodes.filter { node in node.descendants.contains {
            $0.kind == kind && (identifier == nil || $0.identifier == identifier || $0.label == identifier)
        } })
    }
    func matching(_ predicate: NSPredicate) -> Query {
        Query(nodes.filter { predicate.evaluate(with: ["identifier": $0.identifier, "label": $0.label]) })
    }
}
typealias XCUIApplication = Node
typealias XCUIElement = Node
enum Rejected: Error { case missingOrAmbiguous }
func XCTUnwrap<T>(_ value: T?, _ message: String = "") throws -> T {
    guard let value else { throw Rejected.missingOrAmbiguous }; return value
}
'''
        controls = r'''
@main struct Probe {
    @MainActor static func main() throws {
        let title = "Send 2 reports saved under a previous enrollment with this one?"
        func backdrop(id: String = "PopoverDismissRegion", label: String = "dismiss popup") -> Node {
            Node(.other, id: id, label: label)
        }
        func popover(_ label: String) -> Node {
            Node(.popover, [Node(.sheet, [Node(.staticText, label: label)])])
        }
        var checked: [String] = []
        func same(_ actual: Node, _ expected: Node) { precondition(actual === expected) }
        func expectRejected(_ name: String, _ body: () throws -> Node) {
            do { _ = try body(); fatalError("Accepted " + name) }
            catch { checked.append(name) }
        }
        let inactiveRoot = backdrop(), inactiveSettings = backdrop(), active = backdrop()
        let current = popover(title)
        let host = Node(.other, [active, current])
        // Ancestor wrappers contain the popover but do not directly own it.
        let app = Node(.application, [Node(.other, [inactiveRoot]),
                                     Node(.other, [inactiveSettings]), Node(.other, [host])])
        let oldGlobal = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label ==[c] %@", "PopoverDismissRegion", "dismiss popup"))
        precondition(oldGlobal.count == 3 && oldGlobal.allElementsBoundByIndex.first === inactiveRoot)
        try same(uniqueHeldConfirmation(app, titled: title), current)
        try same(heldPopoverDismissal(app, titled: title), active)
        checked.append("original-three-backdrops-rejects-global-first")

        let unrelated = Node(.other, [backdrop(), popover("Unrelated confirmation")])
        try same(heldPopoverDismissal(Node(.application, [unrelated, host]), titled: title), active)
        checked.append("unrelated-title-does-not-own-current-dismissal")

        expectRejected("duplicate-current-backdrops") {
            try heldPopoverDismissal(Node(.application, [Node(.other, [backdrop(), backdrop(), current])]), titled: title)
        }
        let duplicateOwners = Node(.application, [host, Node(.other, [backdrop(), popover(title)])])
        expectRejected("duplicate-titled-confirmations") { try uniqueHeldConfirmation(duplicateOwners, titled: title) }
        expectRejected("duplicate-titled-hosts") { try heldPopoverDismissal(duplicateOwners, titled: title) }
        expectRejected("two-titled-popovers-in-one-host") {
            try heldPopoverDismissal(Node(.application, [Node(.other, [backdrop(), current, popover(title)])]), titled: title)
        }
        expectRejected("missing-owned-backdrop-no-global-fallback") {
            try heldPopoverDismissal(Node(.application, [Node(.other, [backdrop()]), Node(.other, [current])]), titled: title)
        }
        expectRejected("missing-title") { try uniqueHeldConfirmation(Node(.application, [unrelated]), titled: title) }

        let sheet = Node(.sheet, [Node(.staticText, label: title)])
        try same(uniqueHeldConfirmation(Node(.application, [sheet]), titled: title), sheet)
        expectRejected("sheet-does-not-invent-popover-owner") {
            try heldPopoverDismissal(Node(.application, [sheet]), titled: title)
        }
        let labelOnly = backdrop(id: "", label: "DISMISS POPUP")
        try same(heldPopoverDismissal(Node(.application, [Node(.other, [labelOnly, popover(title)])]), titled: title), labelOnly)
        checked.append("native-dismissal-label-alternative")
        print(String(data: try JSONSerialization.data(withJSONObject: checked), encoding: .utf8)!)
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="feedback-confirmation-model-") as temp:
            swift = Path(temp) / "probe.swift"
            executable = Path(temp) / "probe"
            swift.write_text(model + helpers + controls)
            compiled = subprocess.run([shutil.which("swiftc"), "-parse-as-library", str(swift), "-o", str(executable)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stderr)
            observed = json.loads(run.stdout)
            self.assertEqual(len(observed), 10, observed)
            self.assertEqual(len(set(observed)), 10)


if __name__ == "__main__":
    unittest.main()
