import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionMarkdownSourceTests: XCTestCase {
    func testSourceIsReadOnlyAndKeepsExactText() async throws {
        let source = "# Caf\u{00e9}\r\n\r\n**Keep**  \r\n\u{1f680} \t \r\n"
        let range = CompanionMarkdownFilePreview(source: source).sourceRange(line: 4)
        let host = UIHostingController(rootView: CompanionMarkdownSourceView(source: source, range: range))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func findTextView(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            if findTextView(host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try XCTUnwrap(findTextView(host.view), "Native source view must exist")
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(Array(text.text.utf8), Array(source.utf8))
        XCTAssertEqual(text.selectedRange, range, "A line target selects the raw source's UTF-16 position")
    }

    func testOpeningSourceNeverInvokesPreviewParser() async throws {
        let calls = MarkdownParseCalls()
        let unexpectedParse = expectation(description: "Source must not start the Preview parser")
        unexpectedParse.isInverted = true
        let source = "# Source stays immediate\r\n\r\nkeep  \r\n"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: CompanionMarkdownFileView(text: source, line: 3, truncated: false, parse: { source in
            unexpectedParse.fulfill()
            await calls.record()
            return try await CompanionMarkdownFilePreview.load(source)
        }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func sourceView(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(sourceView).first
        }
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            if sourceView(host.view)?.window === window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try XCTUnwrap(sourceView(host.view))
        XCTAssertTrue(text.window === window)
        XCTAssertEqual(Array(text.text.utf8), Array(source.utf8))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // Observe late SwiftUI task startup for 100 ms; a single yield can finish before the task runs.
        await fulfillment(of: [unexpectedParse], timeout: 0.1)
        let count = await calls.count
        XCTAssertEqual(count, 0, "Mounting Source must never request a Preview parse")
    }
}

private actor MarkdownParseCalls {
    var count = 0
    func record() { count += 1 }
}
