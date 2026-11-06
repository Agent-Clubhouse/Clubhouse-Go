import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Synthetic UIKit responder actions on the real hosted composer. These verify the registered input hook and
/// store integration, not hardware-event delivery by iPhone Mirroring, an IME, or XCUITest's keyboard synthesizer.
@MainActor final class CompanionComposerReturnTests: XCTestCase {
    @MainActor private final class Service: CompanionService {
        var sent: [CompanionSendRequest] = []
        var sendGate: CheckedContinuation<Void, Never>?
        func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
        func history(for target: CompanionTarget) async throws -> CompanionHistory {
            .init(items: [], sessionID: "return-fixture")
        }
        func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
            sent.append(request)
            await withCheckedContinuation { sendGate = $0 }
            return .init(clientCommandID: request.clientCommandID)
        }
        func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
        func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
        func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
            throw CompanionServiceError.rejected("Synthetic composer fixture")
        }
        func reconnect(hostID: String) async {}
        func finishSend() { sendGate?.resume(); sendGate = nil }
    }

    @MainActor private struct Fixture {
        let service: Service
        let store: CompanionStore
        let target: CompanionTarget
        let window: UIWindow
        let input: UITextView
        func close() {
            service.finishSend()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func findInput(in view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap { self.findInput(in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

    private func fixture(_ draft: String = "Draft", capabilities: CompanionCapabilities? = nil) async throws -> Fixture {
        let service = Service(), target = CompanionPreviewService.target
        let store = CompanionStore(service: service)
        var hosts = CompanionPreviewService.hosts(now: .now)
        if let capabilities {
            let project = try XCTUnwrap(hosts[0].projects.firstIndex { $0.id == target.projectID })
            let agent = try XCTUnwrap(hosts[0].projects[project].agents.firstIndex { $0.id == target })
            hosts[0].projects[project].agents[agent].capabilities = capabilities
        }
        store.apply(.hosts(hosts)); await store.load(target)
        store.drafts[target] = draft
        let agent = try XCTUnwrap(store.agent(for: target))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionConversationComposer(store: store, agent: agent,
            memory: CompanionComposerMemory(), focusRequests: 0, confirmCancel: .constant(false), dismissals: 0))
        window.makeKeyAndVisible()
        try await settle()
        window.layoutIfNeeded()
        let input = try XCTUnwrap(findInput(in: window))
        XCTAssertTrue(input.becomeFirstResponder())
        try await settle()
        // Programmatic focus can place the caret inside prefilled text. Hardware commands use the real native
        // selection, so make this fixture's insertion point explicit rather than assuming focus moves it to end.
        let insertionPoint = NSRange(location: draft.utf16.count, length: 0)
        input.selectedRange = insertionPoint
        try await settle()
        XCTAssertEqual(input.selectedRange, insertionPoint)
        XCTAssertTrue(input.pasteDelegate is CompanionComposerPasteHook.Coordinator)
        return Fixture(service: service, store: store, target: target, window: window, input: input)
    }

    private func command(_ input: UITextView, modifiers: UIKeyModifierFlags = []) throws -> UIKeyCommand {
        let commands = (input.keyCommands ?? []).filter { $0.input == "\r" && $0.modifierFlags == modifiers }
        XCTAssertEqual(commands.count, 1, "The registered native input advertises one command for this Return chord")
        let command = try XCTUnwrap(commands.first)
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior, "Return must precede the text view's default newline")
        return command
    }

    private func invoke(_ command: UIKeyCommand, on input: UITextView) throws {
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(input.canPerformAction(action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: input, from: command, for: nil),
                      "Invoke the actual registered UIKit command action")
    }

    func testReturnSendsOnceAndPendingReturnKeepsNewerTypingAndInputIdentity() async throws {
        let f = try await fixture("Send once")
        defer { f.close() }
        let enter = try command(f.input)
        try invoke(enter, on: f.input)
        try invoke(enter, on: f.input)
        try await settle()
        XCTAssertEqual(f.service.sent.map(\.text), ["Send once"])
        XCTAssertEqual(f.service.sent.first?.target, f.target)
        XCTAssertEqual(f.store.drafts[f.target], "")
        XCTAssertEqual(f.input.text, "")
        XCTAssertTrue(f.store.pendingCommands.contains(f.target))
        f.input.insertText("Next draft")
        try await settle()
        try invoke(enter, on: f.input)
        try await settle()
        XCTAssertEqual(f.service.sent.count, 1)
        XCTAssertEqual(f.store.drafts[f.target], "Next draft")
        XCTAssertEqual(f.input.text, "Next draft")
        XCTAssertTrue(f.input.isFirstResponder)
        XCTAssertTrue(findInput(in: f.window) === f.input)
    }

    func testReturnPicksNamedSlashCompletionBeforeSendingButBareAndCompleteCommandsSend() async throws {
        let partial = try await fixture("/rev")
        defer { partial.close() }
        try invoke(command(partial.input), on: partial.input)
        try await settle()
        XCTAssertEqual(partial.store.drafts[partial.target], "/review ")
        XCTAssertEqual(partial.input.text, "/review ")
        XCTAssertEqual(partial.input.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertTrue(partial.service.sent.isEmpty)
        partial.close()
        for text in ["/", "/review"] {
            let f = try await fixture(text)
            defer { f.close() }
            try invoke(command(f.input), on: f.input)
            try await settle()
            XCTAssertEqual(f.service.sent.map(\.text), [text], "Existing returnPicks only completes a started partial name")
        }
    }

    func testShiftReturnInsertsNativeNewlineAtSelectionAndBypassesSlashPick() async throws {
        let f = try await fixture("/rev")
        defer { f.close() }
        let newline = try command(f.input, modifiers: .shift)
        try invoke(newline, on: f.input)
        try await settle()
        XCTAssertEqual(f.store.drafts[f.target], "/rev\n", "Shift Return must bypass the binding's slash-return completion")
        XCTAssertEqual(f.input.text, "/rev\n")
        XCTAssertEqual(f.input.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertTrue(f.service.sent.isEmpty)

        f.store.drafts[f.target] = "🙂 select me"
        try await settle()
        f.input.selectedRange = NSRange(location: 3, length: 7)
        try invoke(newline, on: f.input)
        try await settle()
        XCTAssertEqual(f.store.drafts[f.target], "🙂 \nme")
        XCTAssertEqual(f.input.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertTrue(findInput(in: f.window) === f.input)
        XCTAssertTrue(f.service.sent.isEmpty)
    }

    func testNativeTextAndSoftwareReturnKeepMultilineAndSlashBehavior() async throws {
        let f = try await fixture("")
        defer { f.close() }
        f.input.insertText("First\nSecond\n/rev")
        try await settle()
        XCTAssertEqual(f.store.drafts[f.target], "First\nSecond\n/rev")
        f.input.insertText("\n")
        try await settle()
        XCTAssertEqual(f.store.drafts[f.target], "First\nSecond\n/review ", "Software Return keeps existing slash completion")
        f.input.insertText("\nMultiline\npaste")
        try await settle()
        XCTAssertEqual(f.store.drafts[f.target], "First\nSecond\n/review \nMultiline\npaste")
        XCTAssertTrue(f.service.sent.isEmpty, "insertText and pasted multiline are never hardware-send evidence")
    }

    func testReturnUsesStoreGuardsForEmptyOfflineUnsupportedAndResyncDrafts() async throws {
        for condition in ["empty", "offline", "unsupported", "resync"] {
            let draft = condition == "empty" ? " \n " : "Keep this draft"
            let f = try await fixture(draft, capabilities: condition == "unsupported" ? [] : nil)
            defer { f.close() }
            let enter = try command(f.input)
            if condition == "offline" {
                var hosts = f.store.hosts
                hosts[0].connection = .offline
                f.store.apply(.hosts(hosts))
            } else if condition == "resync" {
                f.store.apply(.resyncRequired(hostID: f.target.hostID))
            }
            if condition == "empty" { XCTAssertTrue(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            else { XCTAssertFalse(f.store.canSend(f.target), "Fixture must actually disable sending: \(condition)") }
            // Use the cached native command: safety must be checked at dispatch, even before a view update.
            try invoke(enter, on: f.input)
            try await settle()
            XCTAssertTrue(f.service.sent.isEmpty, condition)
            XCTAssertEqual(f.store.drafts[f.target], draft, condition)
            XCTAssertEqual(f.input.text, draft, condition)
        }
    }

    func testMarkedTextAndStaleUnfocusedOrUneditableCommandsDoNotConsumeInput() async throws {
        let f = try await fixture("Keep ")
        defer { f.close() }
        let enter = try command(f.input), newline = try command(f.input, modifiers: .shift)
        f.input.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(f.input.markedTextRange, "Exercise UIKit's real marked-text state")
        let markedDraft = f.input.text
        for command in [enter, newline] {
            let action = try XCTUnwrap(command.action)
            XCTAssertFalse(f.input.canPerformAction(action, withSender: command))
            XCTAssertFalse((f.input.keyCommands ?? []).contains { $0.action == command.action })
            _ = UIApplication.shared.sendAction(action, to: f.input, from: command, for: nil)
            XCTAssertNotNil(f.input.markedTextRange, "A cached action must not confirm composition")
            XCTAssertEqual(f.input.text, markedDraft)
        }
        try await settle()
        XCTAssertTrue(f.service.sent.isEmpty)
        f.input.unmarkText()
        try await settle()
        for editable in [false, true] {
            f.input.isEditable = editable
            if editable { f.input.resignFirstResponder() }
            let before = f.input.text
            for command in [enter, newline] {
                let action = try XCTUnwrap(command.action)
                XCTAssertFalse(f.input.canPerformAction(action, withSender: command))
                _ = UIApplication.shared.sendAction(action, to: f.input, from: command, for: nil)
                XCTAssertEqual(f.input.text, before)
            }
        }
        try await settle()
        XCTAssertTrue(f.service.sent.isEmpty)
    }

    func testReturnHookDoesNotAddCommandsToOtherSwiftUIFieldsOrTakeCommandReturn() async throws {
        let f = try await fixture()
        defer { f.close() }
        let enter = try command(f.input), newline = try command(f.input, modifiers: .shift)
        XCTAssertFalse((f.input.keyCommands ?? []).contains {
            ($0.action == enter.action || $0.action == newline.action) && $0.modifierFlags == .command
        }, "Command Return stays with the existing SwiftUI Send shortcut")
        let other = UIHostingController(rootView: TextField("Other field", text: .constant("Other"), axis: .vertical))
        f.window.rootViewController = other
        try await settle()
        let input = try XCTUnwrap(findInput(in: f.window))
        XCTAssertTrue(input.becomeFirstResponder())
        XCTAssertFalse((input.keyCommands ?? []).contains { $0.action == enter.action || $0.action == newline.action })
        XCTAssertFalse(input.canPerformAction(try XCTUnwrap(enter.action), withSender: enter))
        XCTAssertFalse(input.canPerformAction(try XCTUnwrap(newline.action), withSender: newline))
    }
}
