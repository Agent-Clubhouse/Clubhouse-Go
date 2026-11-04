import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionComposerIsolationTests: XCTestCase {
    func testNativeEditsDoNotRebuildTheTranscriptButStreamingStillDoes() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        let items: [CompanionTimelineItem] = (0..<128).map {
            .message(.init(id: "history-\($0)", role: .assistant, text: "A **formatted** fixture message."))
        }
        store.apply(.timeline(target, items: items, sequence: 5_000, reset: true, sessionID: "fixture"))
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack {
            CompanionConversationView(store: store, agent: agent)
        }.environment(\.scenePhase, .active))
        window.frame = scene.screen.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        let previousProbe = CompanionConversationBuildProbe.record
        defer {
            CompanionConversationBuildProbe.record = previousProbe
            window.isHidden = true; window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(300))
        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let input = try XCTUnwrap(find(window))
        XCTAssertTrue(input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(300))
        var bodies = 0, timelines = 0
        CompanionConversationBuildProbe.record = { kind, current in
            guard current == target else { return }
            switch kind { case .body: bodies += 1; case .timeline: timelines += 1 }
        }
        for _ in 0..<10 { input.insertText("x"); try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(bodies, 0, "Draft and selection observation belong to the composer subtree")
        XCTAssertEqual(timelines, 0, "A native edit must not rebuild any transcript entries")
        XCTAssertEqual(store.drafts[target]?.utf16.count, 10)
        XCTAssertEqual(input.text.utf16.count, 10)
        store.apply(.upsert(target, .message(.init(id: "reply", role: .assistant, text: "Streaming **reply**.", isStreaming: true)), sequence: 5_001))
        for _ in 0..<100 where timelines == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(timelines, 0, "Live updates must still rebuild the transcript")
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertTrue(find(window) === input)
        XCTAssertEqual(store.drafts[target]?.utf16.count, 10)
    }
    func testRemountDoesNotReuseSelectionAfterDraftChangesWhileUnmounted() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let memory = CompanionComposerMemory()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AnyView(EmptyView()))
        window.frame = scene.screen.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func mount() {
            controller.rootView = AnyView(CompanionConversationComposer(store: store, agent: agent,
                memory: memory, focusRequests: 0, confirmCancel: .constant(false), dismissals: 0))
        }
        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        for replacement in ["z", ""] {
            store.drafts[target] = "abcdef"
            memory.selection = .init(lowerUTF16: 4, upperUTF16: 6)
            mount()
            try await Task.sleep(for: .milliseconds(200))
            let original = try XCTUnwrap(find(window))
            XCTAssertEqual(original.text, "abcdef")
            XCTAssertTrue(original.becomeFirstResponder())
            original.selectedRange = NSRange(location: 4, length: 2)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(original.selectedRange, NSRange(location: 4, length: 2))
            controller.rootView = AnyView(EmptyView())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(memory.selection, .init(lowerUTF16: 4, upperUTF16: 6))
            XCTAssertEqual(memory.selectionDraft, "abcdef")
            // A send, restore or external clear can replace the draft while its tab is unmounted.
            store.drafts[target] = replacement
            mount()
            try await Task.sleep(for: .milliseconds(200))
            let remounted = try XCTUnwrap(find(window))
            XCTAssertEqual(remounted.text, replacement)
            XCTAssertEqual(remounted.selectedRange, NSRange(location: replacement.utf16.count, length: 0))
            XCTAssertTrue(remounted.becomeFirstResponder())
            remounted.insertText("q")
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(store.drafts[target], replacement + "q")
            controller.rootView = AnyView(EmptyView())
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testRealComposerAccessibilityDismissalPreservesDraftSelectionAndFieldIdentity() async throws {
        let service = CompanionPreviewService(showsDispatcher: true, showsEmptyConversation: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        store.drafts[target] = "Keep this selected draft"
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionConversationComposer(store: store, agent: agent,
            memory: CompanionComposerMemory(), focusRequests: 0, confirmCancel: .constant(false), dismissals: 0))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        try await Task.sleep(for: .milliseconds(200))
        let input = try XCTUnwrap(find(window))
        let selection = NSRange(location: 5, length: 4)
        for escape in [false, true] {
            XCTAssertTrue(input.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(200))
            input.selectedRange = selection
            try await Task.sleep(for: .milliseconds(100))
            let action = try XCTUnwrap(input.accessibilityCustomActions?.first { $0.name == "Dismiss Keyboard" })
            if escape { XCTAssertTrue(input.accessibilityPerformEscape()) }
            else { XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action)) }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(input.isFirstResponder)
            XCTAssertEqual(store.drafts[target], "Keep this selected draft")
            XCTAssertEqual(input.text, "Keep this selected draft")
            XCTAssertEqual(input.selectedRange, selection)
            XCTAssertTrue(find(window) === input, "Focus changes must not recreate the native input")
            XCTAssertFalse((input.accessibilityCustomActions ?? []).contains { $0.name == "Dismiss Keyboard" })
        }
    }

}
