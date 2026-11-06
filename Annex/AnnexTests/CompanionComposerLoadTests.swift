import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Uses UIKit input directly to distinguish composer/binding loss from synthesized keyboard delivery.
@MainActor final class CompanionComposerLoadTests: XCTestCase {
    /// Scoped to this test: observes lifecycle/ownership without refocusing or replacing the native editor.
    @MainActor private final class FocusDiagnostics: NSObject {
        weak var window: UIWindow?
        weak var input: UITextView?
        private let started = ContinuousClock.now
        private var reportedLoss = false
        private var reportedEndEditing = false
        var focusLosses = 0

        init(window: UIWindow) {
            self.window = window
            super.init()
            for name in [UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification,
                         UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                         UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                         UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(notified(_:)), name: name, object: nil)
            }
        }

        func stop() { NotificationCenter.default.removeObserver(self) }

        @objc private func notified(_ note: Notification) {
            if let textView = note.object as? UITextView, textView !== input { return }
            if let scene = note.object as? UIWindowScene, scene !== window?.windowScene { return }
            snapshot("native-\(note.name.rawValue)", eventIsFixtureWindow: (note.object as? UIWindow) === window)
            if note.name == UITextView.textDidEndEditingNotification, !reportedEndEditing {
                reportedEndEditing = true
                // This is the synchronous notification delivery stack, not necessarily the resign call site.
                print("COMPOSER_FOCUS endEditingNotificationStack=\(Thread.callStackSymbols.prefix(24).joined(separator: " | "))")
            }
        }

        func snapshot(_ event: String, eventIsFixtureWindow: Bool = false) {
            guard let window else { return }
            let scene = window.windowScene
            func responder(in view: UIView) -> UIView? {
                view.isFirstResponder ? view : view.subviews.lazy.compactMap { responder(in: $0) }.first
            }
            let current = scene?.windows.lazy.compactMap { responder(in: $0) }.first
            let elapsed = started.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            print("COMPOSER_FOCUS event=\(event) elapsedMs=\(milliseconds) nativeFocused=\(input?.isFirstResponder ?? false) inputInFixture=\(input?.window === window) inputHasSuperview=\(input?.superview != nil) fixtureKey=\(window.isKeyWindow) fixtureHidden=\(window.isHidden) rootMounted=\(window.rootViewController?.viewIfLoaded?.window === window) sceneState=\(scene?.activationState.rawValue ?? -1) applicationState=\(UIApplication.shared.applicationState.rawValue) visibleWindows=\(scene?.windows.filter { !$0.isHidden }.count ?? 0) keyWindows=\(scene?.windows.filter(\.isKeyWindow).count ?? 0) responderIsInput=\(input != nil && current === input) responderClass=\(current.map { String(describing: type(of: $0)) } ?? "none") eventIsFixtureWindow=\(eventIsFixtureWindow)")
        }

        func observeFocus(_ focused: Bool, stage: String) {
            guard !focused else { return }
            focusLosses += 1
            if !reportedLoss {
                reportedLoss = true
                snapshot("first-observed-loss-\(stage)")
                print("COMPOSER_FOCUS firstObservedLossStack=\(Thread.callStackSymbols.prefix(16).joined(separator: " | "))")
            }
        }
    }

    func testTypedCharactersSurviveStreamingAndComposerLayoutChanges() async throws {
        try await Task.sleep(for: .seconds(2))
        let service = CompanionPreviewService(showsLongReply: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts)); await store.load(target)
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let diagnostics = FocusDiagnostics(window: window)
        let previousFocusProbe = CompanionComposerFocusProbe.record
        CompanionComposerFocusProbe.record = { event, current, focused in
            guard current == target else { return }
            diagnostics.snapshot("swiftui-\(event.rawValue)-\(focused)")
        }
        defer {
            diagnostics.snapshot("teardown")
            diagnostics.stop()
            CompanionComposerFocusProbe.record = previousFocusProbe
            window.isHidden = true; window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        window.frame = scene.screen.bounds
        let controller = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        window.rootViewController = controller; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(400))
        func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first }
        let input = try XCTUnwrap(find(window))
        diagnostics.input = input
        diagnostics.snapshot("before-native-focus")
        XCTAssertTrue(input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(400))
        diagnostics.snapshot("after-native-focus-settle")
        let text = "Still here\nStreaming characters remain in the draft."
        var expected = ""
        var retainedAll = true
        for (index, character) in text.enumerated() {
            store.apply(.upsert(target, .message(.init(id: "typing-stream", role: .assistant,
                text: String(repeating: "Stream **chunk**. ", count: index + 1), isStreaming: true)), sequence: 100 + index))
            input.insertText(String(character)); expected.append(character)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(17))
            let focused = input.isFirstResponder
            diagnostics.observeFocus(focused, stage: "paced-\(index)")
            retainedAll = retainedAll && input.text == expected && store.drafts[target] == expected
            XCTAssertTrue(focused, "Input focus must survive each streamed update")
            XCTAssertEqual(input.text, expected, "UIKit retains every delivered character")
            XCTAssertEqual(store.drafts[target], expected, "The binding retains every delivered character")
        }
        let retainedInput = find(window) === input
        XCTAssertTrue(retainedInput, "Streaming must retain the actual text input instance")
        var retainedIdentity = retainedInput
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
            let focused = input.isFirstResponder
            diagnostics.observeFocus(focused, stage: "rapid-\(batch)")
            retainedAll = retainedAll && input.text == "Still here" && store.drafts[target] == "Still here"
            retainedIdentity = retainedIdentity && find(window) === input
            XCTAssertTrue(focused)
            XCTAssertTrue(find(window) === input)
            XCTAssertEqual(input.text, "Still here", "Rapid keyboard input must survive pending view updates")
            XCTAssertEqual(store.drafts[target], "Still here")
        }
        diagnostics.snapshot("before-explicit-resign")
        input.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.drafts[target], "Still here")
        retainedAll = retainedAll && store.drafts[target] == "Still here"
        print("COMPOSER_LOAD paced=\(text.utf16.count) rapidBatches=10 rapidCharacters=100 focusLosses=\(diagnostics.focusLosses) focusLossMetric=failedSamples retainedAll=\(retainedAll) retainedIdentity=\(retainedIdentity)")
    }
}
