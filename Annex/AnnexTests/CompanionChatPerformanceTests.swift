import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionChatPerformanceTests: XCTestCase {
    func testOnlyTheCurrentChatCountsEditsBodiesAndViewportSamples() async {
        let source = AnnexTelemetry.shared
        source.setEnabled(true)
        let first = CompanionPreviewService.target
        let second = CompanionPreviewService.dispatcherTarget
        let staleLease = CompanionChatPerformance.start(target: first)
        let lease = CompanionChatPerformance.start(target: second)
        defer { CompanionChatPerformance.stop(lease); source.setEnabled(false) }
        CompanionChatPerformance.stop(staleLease)
        CompanionChatPerformance.edit(target: first, messageCount: 999)
        CompanionChatPerformance.edit(target: second, messageCount: 128)
        let a = CompanionChatPerformance.measureBody(target: first, messageCount: 999) { 7 }
        let b = CompanionChatPerformance.measureBody(target: second, messageCount: 128) { 8 }
        XCTAssertEqual(a + b, 15)
        let frames: [String: ClosedRange<Double>] = ["a": 0...50, "b": 50...100, "c": 100...150, "d": 150...200]
        CompanionChatPerformance.viewport(target: first, messageCount: 999, frames: frames, offset: 0, height: 200)
        CompanionChatPerformance.viewport(target: second, messageCount: 128, frames: frames, offset: 25, height: 100)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let afterInactive = CompanionChatPerformance.measureBody(target: second, messageCount: 128) { 9 }
        XCTAssertEqual(afterInactive, 9)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let summaries = source.drainSummaries()
        let edit = summaries.first { $0.operation == .composerEditTurnDelay }
        XCTAssertEqual(edit?.count, 1)
        XCTAssertEqual(edit?.messageCount, 128)
        XCTAssertEqual(summaries.first { $0.operation == .typingConversationBody }?.count, 1)
        let viewport = summaries.first { $0.operation == .chatViewport }
        XCTAssertEqual(viewport?.count, 1)
        XCTAssertEqual(viewport?.messageCount, 128)
        XCTAssertEqual(viewport?.visibleRows, 3)
        XCTAssertEqual(viewport?.laidOutRows, 4)
        XCTAssertTrue(source.snapshot().records.isEmpty, "Input and geometry must not allocate per-event spans")
    }

    func testOneNativeEditCountsOnceEvenWhenSwiftUIRepeatsTheBindingSetter() async throws {
        let source = AnnexTelemetry.shared
        let service = CompanionPreviewService(showsDispatcher: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        window.frame = scene.screen.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; source.setEnabled(false) }
        try await Task.sleep(for: .milliseconds(300))
        func input(in view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        let editor = try XCTUnwrap(input(in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(300))
        source.setEnabled(true)
        for _ in 0..<10 { editor.insertText("x"); try await Task.sleep(for: .milliseconds(20)) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let edits = source.drainSummaries().first { $0.operation == .composerEditTurnDelay }
        XCTAssertEqual(edits?.count, 10, "Count changed input edits, not duplicate SwiftUI setter callbacks")
        XCTAssertEqual(store.drafts[target]?.utf16.count, 10)
        XCTAssertEqual(editor.text.utf16.count, 10)
    }

}
