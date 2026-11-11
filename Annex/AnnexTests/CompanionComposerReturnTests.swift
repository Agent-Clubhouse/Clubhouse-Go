import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionComposerReturnTests: XCTestCase {
    @MainActor private struct Hosted {
        let store: CompanionStore
        let service: ReturnServiceSpy
        let window: UIWindow
        let input: UITextView
        var target: CompanionTarget { CompanionPreviewService.target }
        func close() { service.release(); input.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil; store.shutdown() }
    }

    private func findInput(_ view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap(findInput).first
    }

    private func host(_ draft: String = "Hardware message", status: CompanionAgentStatus = .idle,
                      capabilities: CompanionCapabilities? = nil) async throws -> Hosted {
        let service = ReturnServiceSpy()
        let store = CompanionStore(service: service)
        var hosts = CompanionPreviewService.hosts(now: .now)
        let target = CompanionPreviewService.target
        var agent = try XCTUnwrap(hosts[0].agent(for: target))
        agent.status = status
        agent.capabilities = capabilities ?? [.chat, .steer, .queue, .cancel]
        agent.isSleepingOnDesktop = false
        agent.slashCommands = [.init(name: "review")]
        hosts[0].projects = [.init(id: target.projectID, name: "Synthetic composer", agents: [agent])]
        hosts[0].canStopAgents = true
        store.apply(.hosts(hosts))
        await store.load(target)
        store.drafts[target] = draft
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionConversationComposer(store: store, agent: agent,
            memory: CompanionComposerMemory(), focusRequests: 0, confirmCancel: .constant(false), dismissals: 0))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        let input = try XCTUnwrap(findInput(window))
        XCTAssertTrue(input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(100))
        input.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        return Hosted(store: store, service: service, window: window, input: input)
    }

    private func press(_ input: UITextView, modifiers: UIKeyModifierFlags = [], release: Bool = true) {
        let press = ReturnPress(modifiers: modifiers)
        input.pressesBegan([press], with: nil)
        if release { input.pressesEnded([press], with: nil) }
    }

    func testNativeReturnSendsOncePerPhysicalPressAndKeepsInputIdentityAndFocus() async throws {
        let hosted = try await host()
        defer { hosted.close() }
        press(hosted.input, release: false)
        press(hosted.input, release: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.service.requests.map(\.text), ["Hardware message"])
        XCTAssertEqual(hosted.store.drafts[hosted.target], "")
        hosted.input.insertText("Next draft")
        try await Task.sleep(for: .milliseconds(50))
        press(hosted.input, release: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(hosted.service.requests.count, 1, "Holding Return cannot send newly typed or restored text")
        hosted.input.pressesEnded([ReturnPress()], with: nil)
        XCTAssertNil(hosted.input.markedTextRange)
        XCTAssertTrue(hosted.input.isFirstResponder)
        XCTAssertEqual(hosted.store.drafts[hosted.target], hosted.input.text)
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.service.requests.map(\.text), ["Hardware message", "Next draft"])
        XCTAssertTrue(hosted.input.isFirstResponder)
        XCTAssertTrue(findInput(hosted.window) === hosted.input)
    }

    func testShiftReturnReplacesSelectionAndDoesNotCompleteSlashCommands() async throws {
        let hosted = try await host("/re")
        defer { hosted.close() }
        press(hosted.input, modifiers: .shift)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.store.drafts[hosted.target], "/re\n")
        XCTAssertEqual(hosted.input.text, "/re\n")
        XCTAssertEqual(hosted.input.selectedRange, NSRange(location: 4, length: 0))
        hosted.input.selectedRange = NSRange(location: 0, length: 3)
        press(hosted.input, modifiers: .shift)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.store.drafts[hosted.target], "\n\n")
        XCTAssertEqual(hosted.input.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertTrue(hosted.service.requests.isEmpty)
        XCTAssertTrue(hosted.input.isFirstResponder)
    }

    func testHardwareReturnCompletesSlashBeforeSendingButSoftwareReturnStillEdits() async throws {
        let hosted = try await host("/re")
        defer { hosted.close() }
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.store.drafts[hosted.target], "/review ")
        XCTAssertTrue(hosted.service.requests.isEmpty)
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.service.requests.map(\.text), ["/review"])
        hosted.input.insertText("Software\nreturn")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.store.drafts[hosted.target], "Software\nreturn")
        XCTAssertEqual(hosted.service.requests.count, 1)
        XCTAssertTrue(findInput(hosted.window) === hosted.input)
    }

    func testMarkedTextConfirmationAndItsRepeatsNeverSend() async throws {
        let hosted = try await host("")
        defer { hosted.close() }
        hosted.input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(hosted.input.markedTextRange)
        press(hosted.input, release: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hosted.service.requests.isEmpty)
        // XCUI cannot establish marked text. Commit through UITextInput, then deliver a repeat of the same key.
        hosted.input.unmarkText()
        hosted.input.delegate?.textViewDidChange?(hosted.input)
        press(hosted.input, release: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hosted.service.requests.isEmpty)
        XCTAssertTrue(hosted.input.text.contains("にほん"))
        hosted.input.pressesEnded([ReturnPress()], with: nil)
        XCTAssertNil(hosted.input.markedTextRange)
        XCTAssertEqual(hosted.store.drafts[hosted.target], hosted.input.text)
        // A synthesized press has no input-engine IME session; UIKit may end editing while forwarding it.
        XCTAssertTrue(hosted.input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(50))
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.service.requests.map(\.text), ["にほん"], "A new focused press may send committed text")
    }

    func testDisabledSendStatesKeepTheDraftAndDoNotInsertANewline() async throws {
        for state in ["empty", "offline", "unsupported", "pending", "loading", "resync", "sleep", "working"] {
            let hosted = try await host(state == "empty" ? " \n " : "Keep draft")
            defer { hosted.close() }
            var operation: Task<Void, Never>?
            switch state {
            case "offline": hosted.store.hosts[0].connection = .offline
            case "unsupported": hosted.store.hosts[0].projects[0].agents[0].capabilities = []
            case "pending":
                hosted.service.holds = true
                operation = Task { await hosted.store.cancel(hosted.target) }
            case "loading":
                hosted.service.holds = true
                operation = Task { await hosted.store.load(hosted.target, force: true) }
            case "resync": hosted.store.apply(.resyncRequired(hostID: hosted.target.hostID))
            case "sleep": await hosted.store.sleepAgent(hosted.target)
            case "working":
                hosted.store.hosts[0].projects[0].agents[0].status = .working
                hosted.store.hosts[0].projects[0].agents[0].capabilities = [.chat]
            default: break
            }
            try await Task.sleep(for: .milliseconds(50))
            if state != "empty" { XCTAssertFalse(hosted.store.canSend(hosted.target), state) }
            let before = hosted.store.drafts[hosted.target]
            press(hosted.input)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(hosted.service.requests.isEmpty, state)
            XCTAssertEqual(hosted.store.drafts[hosted.target], before, state)
            XCTAssertEqual(hosted.input.text, before, state)
            hosted.service.release()
            await operation?.value
        }
    }

    func testWorkingReturnUsesTheSameSteerAndQueueRulesAsSend() async throws {
        for steer in [true, false] {
            let hosted = try await host(status: .working, capabilities: steer ? [.steer] : [.queue])
            defer { hosted.close() }
            press(hosted.input)
            try await Task.sleep(for: .milliseconds(100))
            let request = try XCTUnwrap(hosted.service.requests.first)
            XCTAssertEqual(request.isSteering, steer)
            XCTAssertEqual(request.queueIfBusy, !steer)
        }
    }

    func testImageOnlyReturnKeepsTheAttachmentSendPath() async throws {
        let hosted = try await host("", capabilities: [.chat, .images])
        defer { hosted.close() }
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let image = CompanionImageAttachment(bytes: .init(data), mimeType: "image/png", width: 8, height: 8)
        hosted.store.addAttachments([image], to: hosted.target)
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        let request = try XCTUnwrap(hosted.service.requests.first)
        XCTAssertEqual(request.text, "")
        XCTAssertEqual(request.attachmentIDs, [image.id])
        XCTAssertTrue((hosted.store.attachmentDrafts[hosted.target] ?? []).isEmpty)
        XCTAssertTrue(hosted.input.isFirstResponder)
        XCTAssertTrue(findInput(hosted.window) === hosted.input)
    }

    func testCachedUnfocusedOrUneditableInputCannotSendAndRefocusResetsHeldKey() async throws {
        let hosted = try await host()
        defer { hosted.close() }
        hosted.input.resignFirstResponder()
        press(hosted.input)
        XCTAssertTrue(hosted.input.becomeFirstResponder())
        hosted.input.isEditable = false
        press(hosted.input)
        hosted.input.isEditable = true
        XCTAssertTrue(hosted.input.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hosted.service.requests.isEmpty)
        press(hosted.input, release: false)
        try await Task.sleep(for: .milliseconds(100))
        hosted.input.resignFirstResponder()
        XCTAssertTrue(hosted.input.becomeFirstResponder())
        hosted.input.insertText("After refocus")
        try await Task.sleep(for: .milliseconds(50))
        press(hosted.input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.service.requests.map(\.text), ["Hardware message", "After refocus"])
    }
}

@MainActor private final class ReturnKey: UIKey {
    private let modifiers: UIKeyModifierFlags
    init(modifiers: UIKeyModifierFlags) { self.modifiers = modifiers; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var keyCode: UIKeyboardHIDUsage { .keyboardReturnOrEnter }
    override var characters: String { "\r" }
    override var charactersIgnoringModifiers: String { "\r" }
    override var modifierFlags: UIKeyModifierFlags { modifiers }
}

private final class ReturnPress: UIPress {
    private let returnKey: UIKey
    @MainActor init(modifiers: UIKeyModifierFlags = []) { returnKey = ReturnKey(modifiers: modifiers); super.init() }
    override var key: UIKey? { returnKey }
}

@MainActor private final class ReturnServiceSpy: CompanionService {
    nonisolated deinit {}
    var requests: [CompanionSendRequest] = []
    var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private func waitIfHeld() async {
        if holds { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() {
        holds = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        await waitIfHeld()
        return .init(items: [], lastSequence: 0)
    }
    func reconnect(hostID: String) async {}
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        requests.append(request)
        return .init(clientCommandID: request.clientCommandID)
    }
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String { image.id }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { await waitIfHeld() }
    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Synthetic service") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
}
