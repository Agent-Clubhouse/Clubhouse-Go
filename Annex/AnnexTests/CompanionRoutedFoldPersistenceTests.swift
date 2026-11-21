import XCTest
@testable import ClubhouseGo

/// Store state behind routed-message folds: an explicit fold is keyed by conversation, session, message and part, and
/// a forced history refresh keeps it. The real transcript round trip (collapse, reopen, refresh, expand) stays native in
/// CompanionDispatcherUITests/testSenderMessagesStartExpandedAndExplicitFoldsSurviveRefreshAndNavigation.
@MainActor final class CompanionRoutedFoldPersistenceTests: XCTestCase {
    private let target = CompanionTarget(hostID: "fold-host", projectID: "fold-project", agentID: "river")
    private static let longText = "## Helper report\n" + (1...16).map { "Body line \($0) of the helper report." }.joined(separator: "\n")

    func testAnExplicitFoldSurvivesAForcedRefreshAndStaysScopedToItsPart() async throws {
        let message = CompanionMessage(id: "sender-fold", role: .user, text: Self.longText, source: "mcp", routed: [
            .init(sender: .init(agentID: "cedar", name: "Cedar"), text: Self.longText),
            .init(sender: .init(agentID: "maple", name: "Maple"), text: Self.longText),
        ])
        let service = FoldHistoryService(history: CompanionHistory(items: [.message(message)], sessionID: "session-1"))
        let store = CompanionStore(service: service)
        defer { store.shutdown() }
        await store.load(target)
        let expansion = store.transcriptExpansion(for: target)
        XCTAssertTrue(expansion.part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText), "Long replies start readable")
        expansion.part(messageID: "sender-fold", index: 0).open = false

        await store.load(target, force: true) // what Refresh conversation calls
        XCTAssertEqual(service.reads, 2, "The refresh read history again")
        let afterRefresh = store.transcriptExpansion(for: target)
        XCTAssertTrue(afterRefresh === expansion, "A refreshed snapshot keeps the conversation's fold state")
        XCTAssertFalse(afterRefresh.part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText))
        XCTAssertTrue(afterRefresh.part(messageID: "sender-fold", index: 1).isOpen(for: Self.longText), "Each part folds independently")
        XCTAssertTrue(afterRefresh.part(messageID: "other-message", index: 0).isOpen(for: Self.longText), "Another message is unaffected")

        let other = CompanionTarget(hostID: "fold-host", projectID: "fold-project", agentID: "maple")
        XCTAssertTrue(store.transcriptExpansion(for: other).part(messageID: "sender-fold", index: 0).isOpen(for: Self.longText),
                      "Another conversation's fold is separate")
        XCTAssertTrue(store.transcriptExpansion(for: target, sessionID: "archived").part(messageID: "sender-fold", index: 0)
                        .isOpen(for: Self.longText), "An archived session's fold is separate")
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
