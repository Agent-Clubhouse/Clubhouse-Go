import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionUnicodeFocusTests: XCTestCase {
    private static let drafts = [
        "\u{1F642}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F1FA}\u{1F1F3}",
        "\u{1F44D}\u{1F3FD}", "\u{20000}"
    ]

    @MainActor @Observable final class FocusRequest {
        nonisolated deinit {}
        var value = 0
        var dismissals = 0
    }

    private struct Composer: View {
        let store: CompanionStore
        let agent: CompanionAgent
        let request: FocusRequest
        let memory = CompanionComposerMemory()
        var body: some View {
            CompanionConversationComposer(store: store, agent: agent, memory: memory,
                focusRequests: request.value, confirmCancel: .constant(false), dismissals: request.dismissals)
        }
    }

    private func findInput(_ view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap(findInput).first
    }

    func testAppComposerFocusRequestPreservesNonBMPDraftsDuringNativeInsertion() async throws {
        for draft in Self.drafts {
            let service = UnicodeService()
            let store = CompanionStore(service: service)
            let hosts = CompanionPreviewService.hosts(now: .now)
            let target = CompanionPreviewService.target
            store.apply(.hosts(hosts))
            await store.load(target)
            store.drafts[target] = draft
            let agent = try XCTUnwrap(hosts[0].agent(for: target))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let request = FocusRequest()
            let appeared = expectation(description: "The real composer appeared")
            let controller = UIHostingController(rootView: Composer(store: store, agent: agent, request: request)
                .onAppear { appeared.fulfill() })
            window.frame = scene.screen.bounds
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKey()
                store.shutdown()
            }
            await fulfillment(of: [appeared], timeout: 5)
            controller.view.layoutIfNeeded()
            let input = try XCTUnwrap(findInput(window))
            XCTAssertEqual(Array(input.text.utf8), Array(draft.utf8))
            request.value += 1
            let focused = expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: input)
            await fulfillment(of: [focused], timeout: 5)
            XCTAssertEqual(input.selectedRange, NSRange(location: draft.utf16.count, length: 0))
            input.insertText("q")
            let edited = expectation(for: NSPredicate { _, _ in store.drafts[target] == draft + "q" }, evaluatedWith: store)
            await fulfillment(of: [edited], timeout: 5)
            XCTAssertEqual(Array(input.text.utf8), Array((draft + "q").utf8))
            XCTAssertEqual(Array((store.drafts[target] ?? "").utf8), Array((draft + "q").utf8))
            await store.sendDraft(to: target)
            XCTAssertEqual(service.requests.count, 1)
            XCTAssertEqual(Array(try XCTUnwrap(service.requests.first).text.utf8), Array((draft + "q").utf8))
            let cleared = expectation(for: NSPredicate { _, _ in input.text.isEmpty }, evaluatedWith: input)
            await fulfillment(of: [cleared], timeout: 5)
            XCTAssertTrue(input.isFirstResponder, "Send retains the existing editing focus")
            input.insertText(draft)
            let nextDraft = expectation(for: NSPredicate { _, _ in store.drafts[target] == draft }, evaluatedWith: store)
            await fulfillment(of: [nextDraft], timeout: 5)
            XCTAssertEqual(Array(input.text.utf8), Array(draft.utf8))
            XCTAssertEqual(Array((store.drafts[target] ?? "").utf8), Array(draft.utf8))
            await store.sendDraft(to: target)
            XCTAssertEqual(service.requests.count, 2)
            XCTAssertEqual(Array(try XCTUnwrap(service.requests.last).text.utf8), Array(draft.utf8))
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in input.text.isEmpty }, evaluatedWith: input)], timeout: 5)
            let selectionDraft = "a" + draft + "b"
            input.insertText(selectionDraft)
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in store.drafts[target] == selectionDraft }, evaluatedWith: store)], timeout: 5)
            input.selectedRange = NSRange(location: 1, length: draft.utf16.count)
            input.delegate?.textViewDidChangeSelection?(input)
            request.dismissals += 1
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in !input.isFirstResponder }, evaluatedWith: input)], timeout: 5)
            request.value += 1
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: input)], timeout: 5)
            XCTAssertEqual(input.selectedRange, NSRange(location: 1, length: draft.utf16.count),
                "A user-placed grapheme selection survives programmatic refocus")
            input.insertText("q")
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in store.drafts[target] == "aqb" }, evaluatedWith: store)], timeout: 5)
            XCTAssertEqual(Array(input.text.utf8), Array("aqb".utf8))
            XCTAssertEqual(Array((store.drafts[target] ?? "").utf8), Array("aqb".utf8))
        }
    }
}

@MainActor private final class UnicodeService: CompanionService {
    nonisolated deinit {}
    var requests: [CompanionSendRequest] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: [], lastSequence: 0) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        requests.append(request)
        return .init(clientCommandID: request.clientCommandID)
    }
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String { image.id }
    func reconnect(hostID: String) async {}
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        throw CompanionServiceError.unavailable("Synthetic Unicode service does not spawn agents.")
    }
}
