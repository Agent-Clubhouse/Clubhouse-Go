"""Exercise the actual snapshot walker and geometry body without XCTest or a simulator."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'Annex/AnnexUITests/CompanionHeaderReflowUITests.swift'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                     'Extracted CoreGraphics controls run on a Mac; Linux Plan retains source/inventory controls')
class HeaderSamplerControls(unittest.TestCase):
    def test_same_tree_scope_and_transient_geometry(self):
        source = SOURCE.read_text()
        frames = source[source.index('    private func frames(in root:'):source.index('    /// The real identity,')]
        scope = source[source.index('    private func scopeMatches(in root:'):source.index('    enum Disturbance')]
        geometry = source[source.index('            var problems: [String] = []'):source.index('            if !problems.isEmpty')]
        code = '''import Foundation
import CoreGraphics
// Stand-in snapshot values only. These controls exercise the exact source walker;
// no XCTest accessibility query, native discovery or query timing is simulated.
enum Kind { case application, navigationBar, button, other }
struct XCUIElementSnapshot {
    var identifier: String = ""
    var label: String = ""
    var elementType: Kind = .other
    var frame: CGRect = .zero
    var children: [XCUIElementSnapshot] = []
}
struct Frames { let identity: CGRect; let actions: CGRect; let leading: CGRect? }
'''
        code += frames.replace('private func', 'func') + scope.replace('private func', 'func')
        code += 'func problems(_ f: Frames, _ screen: CGRect) -> [String] {\n' + geometry + '\nreturn problems\n}\n'
        code += '''
let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
let title = XCUIElementSnapshot(identifier: "companion-chat-header", elementType: .button, frame: CGRect(x: 140, y: 60, width: 120, height: 44))
let actions = XCUIElementSnapshot(identifier: "companion-chat-header-actions", frame: CGRect(x: 304, y: 60, width: 88, height: 44))
let menu = XCUIElementSnapshot(identifier: "header-fixture-menu", elementType: .button, frame: CGRect(x: 8, y: 60, width: 44, height: 44))
let back = XCUIElementSnapshot(label: "Back", elementType: .button, frame: menu.frame)
func hierarchy(_ title: XCUIElementSnapshot, _ leading: XCUIElementSnapshot) -> XCUIElementSnapshot {
    let bar = XCUIElementSnapshot(elementType: .navigationBar, children: [leading, title, actions])
    return XCUIElementSnapshot(elementType: .application, children: [bar, XCUIElementSnapshot(label: "Long streaming transcript")])
}
for leading in [menu, back] {
    let id: String? = leading.identifier.isEmpty ? nil : leading.identifier
    let root = hierarchy(title, leading)
    precondition(scopeMatches(in: root, leadingID: id))
    let whole = frames(in: root, leadingID: id)!
    let scoped = frames(in: root.children[0], leadingID: id)!
    precondition(whole.identity == scoped.identity && whole.actions == scoped.actions && whole.leading == scoped.leading)
    precondition(problems(scoped, screen).isEmpty)
    var absent = root
    absent.children[0].children.remove(at: 1)
    precondition(frames(in: absent.children[0], leadingID: id) == nil)
    precondition(!scopeMatches(in: absent, leadingID: id))
    var ambiguous = root
    ambiguous.children.append(root.children[0])
    precondition(!scopeMatches(in: ambiguous, leadingID: id))
    var outside = root
    outside.children.append(title) // even equal geometry outside the bar fails scope
    precondition(!scopeMatches(in: outside, leadingID: id))
}
// No caching, averaging or stable-frame filter: exactly one displaced sample
// between 100 good snapshots still reaches the original off-centre assertion.
var violations = 0
for i in 0..<101 {
    var current = title
    if i == 50 { current.frame.origin.x += 2 }
    let root = hierarchy(current, menu)
    precondition(scopeMatches(in: root, leadingID: menu.identifier))
    let f = frames(in: root.children[0], leadingID: menu.identifier)!
    if !problems(f, screen).isEmpty { violations += 1 }
}
precondition(violations == 1)
for (identity, action, leading) in [
    (title.frame, CGRect(x: 360, y: 60, width: 88, height: 44), menu.frame),
    (CGRect(x: 200, y: 60, width: 120, height: 44), actions.frame, menu.frame),
    (title.frame, actions.frame, CGRect(x: 100, y: 60, width: 80, height: 44))
] {
    precondition(!problems(Frames(identity: identity, actions: action, leading: leading), screen).isEmpty)
}
print("same-tree menu/back scope, missing/ambiguous/outside guards, transient and all original geometry problems passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / 'controls.swift'
            swift.write_text(code)
            binary = Path(directory) / 'controls'
            compiled = subprocess.run(['swiftc', str(swift), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('all original geometry problems passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
