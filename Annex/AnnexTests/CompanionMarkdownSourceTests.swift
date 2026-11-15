import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionMarkdownSourceTests: XCTestCase {
    func testSourceIsReadOnlyAndKeepsExactText() {
        let source = "# Caf\u{00e9}\r\n\r\n**Keep**  \r\n\u{1f680} \t \r\n"
        let host = UIHostingController(rootView: CompanionMarkdownSourceView(source: source))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.layoutIfNeeded()
        func findTextView(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        guard let text = findTextView(host.view) else { return XCTFail("Native source view must exist") }
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(Array(text.text.utf8), Array(source.utf8))
    }
}
