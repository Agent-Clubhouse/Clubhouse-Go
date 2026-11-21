import XCTest
import SwiftUI
import UIKit
import Vision
@testable import ClubhouseGo

/// The state and rendering half of `CompanionDispatcherUITests/testSenderMessagesStartExpandedAndExplicitFoldsSurvive…`,
/// in process: an explicit fold is Store state keyed by conversation, session and part, so it survives a forced refresh,
/// a new view (leaving and reopening the chat) and the row leaving the window; a collapsed part builds no body.
/// The native test keeps the real chat navigation, VoiceOver label/value and Copy menu.
@MainActor final class CompanionRoutedFoldPersistenceTests: XCTestCase {
    private let target = CompanionTarget(hostID: "fold-host", projectID: "fold-project", agentID: "river")
    private static let marker = "Body line seven is the fold marker"
    private static let longText = "## Helper report\n" + (1...16).map { $0 == 7 ? marker : "Body line \($0) of the helper report." }.joined(separator: "\n")

    private func message(id: String = "sender-fold") -> CompanionMessage {
        CompanionMessage(id: id, role: .user, text: Self.longText, source: "mcp", routed: [
            .init(sender: .init(agentID: "cedar", name: "Cedar"), text: Self.longText),
            .init(sender: .init(agentID: "maple", name: "Maple"), text: Self.longText),
        ])
    }

    func testAnExplicitFoldSurvivesAForcedRefreshAndReopeningTheChat() async throws {
        let service = FoldHistoryService(history: CompanionHistory(items: [.message(message())], sessionID: "session-1"))
        let store = CompanionStore(service: service)
        await store.load(target)
        let expansion = store.transcriptExpansion(for: target)
        XCTAssertTrue(expansion.part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText), "Long replies start readable")
        expansion.part(messageID: "sender-fold", index: 0).open = false

        await store.load(target, force: true) // Refresh conversation
        XCTAssertEqual(service.reads, 2, "The refresh actually read history again")
        let afterRefresh = store.transcriptExpansion(for: target)
        XCTAssertTrue(afterRefresh === expansion, "A refreshed snapshot keeps the same fold state")
        XCTAssertFalse(afterRefresh.part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText))
        XCTAssertTrue(afterRefresh.part(messageID: "sender-fold", index: 1).isOpen(for: Self.longText), "Each part folds independently")

        // Leaving and reopening the chat builds new views over the same Store state.
        XCTAssertFalse(store.transcriptExpansion(for: target).part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText))
        let other = CompanionTarget(hostID: "fold-host", projectID: "fold-project", agentID: "maple")
        XCTAssertTrue(store.transcriptExpansion(for: other).part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText),
                      "Another conversation's fold is separate")
        XCTAssertTrue(store.transcriptExpansion(for: target, sessionID: "archived").part(messageID: "sender-fold", index: 0)
                        .isOpen(for: Self.longText), "An archived session's fold is separate")
        store.shutdown()
    }

    func testACollapsedPartBuildsOnlyItsCaptionAndReopenedViewsShowTheSameFold() throws {
        let expansion = CompanionTranscriptExpansion()
        let part = message().routed[0]
        let open = try renderedText(part: part, expansion: expansion.part(messageID: "sender-fold", index: 0), name: "open part")
        XCTAssertTrue(open.contains("Body line seven"), "An open long part shows its body: \(open)")

        expansion.part(messageID: "sender-fold", index: 0).open = false
        // A new view instance for the same part, as after scrolling away or reopening the chat.
        let collapsed = try renderedText(part: part, expansion: expansion.part(messageID: "sender-fold", index: 0), name: "collapsed part")
        XCTAssertTrue(collapsed.contains("Cedar sent a long message"), "A collapsed part keeps its caption: \(collapsed)")
        XCTAssertFalse(collapsed.contains("Body line seven"), "A collapsed part builds no body: \(collapsed)")
    }

    private func renderedText(part: CompanionRoutedMessagePart, expansion: CompanionPartExpansion, name: String) throws -> String {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "Requires a foreground-active hosted test scene")
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let identity = CompanionSenderIdentity(id: "cedar", name: "Cedar")
        window.rootViewController = UIHostingController(rootView:
            CompanionSentPartView(part: part, message: message(), index: 0, identity: identity, expansion: expansion)
                .padding(16).frame(width: 390, height: 844, alignment: .topLeading)
                .companionTheme(.clubhouse).environment(\.colorScheme, .light))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKey()
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
    }
}

/// Serves one fixed history and counts reads; nothing else is reachable.
@MainActor private final class FoldHistoryService: CompanionService {
    let history: CompanionHistory
    var reads = 0
    init(history: CompanionHistory) { self.history = history }
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { reads += 1; return history }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
}
