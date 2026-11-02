import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Uses UIKit input directly to distinguish composer/binding loss from synthesized keyboard delivery.
@MainActor final class CompanionComposerLoadTests: XCTestCase {
    func testTypedCharactersSurviveStreamingAndComposerLayoutChanges() async throws {
        try await Task.sleep(for: .seconds(2))
        let service = CompanionPreviewService(showsLongReply: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts)); await store.load(target)
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let controller = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first }
        let input = try XCTUnwrap(find(window))
        XCTAssertTrue(input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(400))
        let text = "Still here\nStreaming characters remain in the draft."
        var expected = ""
        for (index, character) in text.enumerated() {
            store.apply(.upsert(target, .message(.init(id: "typing-stream", role: .assistant,
                text: String(repeating: "Stream **chunk**. ", count: index + 1), isStreaming: true)), sequence: 100 + index))
            input.insertText(String(character)); expected.append(character)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(17))
            XCTAssertTrue(input.isFirstResponder, "Input focus must survive each streamed update")
            XCTAssertEqual(input.text, expected, "UIKit retains every delivered character")
            XCTAssertEqual(store.drafts[target], expected, "The binding retains every delivered character")
        }
        XCTAssertTrue(find(window) === input, "Streaming must retain the actual text input instance")
        for batch in 0..<10 {
            store.drafts[target] = ""
            try await Task.sleep(for: .milliseconds(20))
            for (index, character) in "Still here".enumerated() {
                store.apply(.upsert(target, .message(.init(id: "typing-stream", role: .assistant,
                    text: "Batch \(batch) chunk \(index)", isStreaming: true)), sequence: 1_000 + batch * 10 + index))
                input.insertText(String(character))
                window.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(input.isFirstResponder)
            XCTAssertTrue(find(window) === input)
            XCTAssertEqual(input.text, "Still here", "Rapid keyboard input must survive pending view updates")
            XCTAssertEqual(store.drafts[target], "Still here")
        }
        input.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.drafts[target], "Still here")
        print("COMPOSER_LOAD paced=\(text.utf16.count) rapidBatches=10 rapidCharacters=100 focusLosses=0 retainedAll=true")
    }
}
