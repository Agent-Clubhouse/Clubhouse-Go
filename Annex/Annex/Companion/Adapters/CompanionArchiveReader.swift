import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Archive reads never replace the live projection or its command session.
@MainActor final class CompanionArchiveReader: CompanionArchiveReading {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    private let transport: any AnnexTransporting
    private let target: CompanionTarget
    private let sessionID: String
    private let windows: Bool
    private var eventsBySequence: [Int64: AnnexJSON] = [:]
    private var readOnly = false

    init(transport: any AnnexTransporting, target: CompanionTarget, sessionID: String, windows: Bool = false) {
        self.transport = transport; self.target = target; self.sessionID = sessionID; self.windows = windows
    }

    func load(before: Int64?) async throws -> CompanionArchivePage {
        let snapshot = try await transport.read(.chatHistory(agentID: target.agentID, sessionID: sessionID, beforeSeq: before, limit: 300))
        guard snapshot["sessionId"]?.string == sessionID else {
            throw CompanionServiceError.unavailable("This saved session is no longer available.")
        }
        var accumulated = before == nil ? [:] : eventsBySequence
        for event in snapshot["events"].arrayValue {
            guard event["sessionId"]?.string == sessionID, let sequence = event["seq"]?.integer, sequence > 0 else { continue }
            accumulated[sequence] = event
        }
        var projection = CompanionChatProjector()
        for sequence in accumulated.keys.sorted() {
            if let event = accumulated[sequence] { projection.apply(event) }
        }
        // Keep the latest page's dead-session signal when an older page omits it. Settle after replay, so
        // turn boundaries and late delivery acknowledgments can still clear a row before it is marked unknown.
        let dead: Bool
        if case .bool(let value)? = snapshot["readOnly"] { dead = value }
        else { dead = before == nil ? false : readOnly }
        if dead { projection.settleQueuedMessages() }
        readOnly = dead
        eventsBySequence = accumulated
        let next = snapshot["nextBeforeSeq"]?.integer
        // A non-advancing cursor must never trap the user in an endless load loop.
        let cursor = next.flatMap { value in value > 0 && (before == nil || value < before!) ? value : nil }
        return .init(items: projection.items, nextBeforeSequence: cursor,
                     contentRoots: CompanionLiveService.contentRoots(from: snapshot, windows: windows))
    }
}
