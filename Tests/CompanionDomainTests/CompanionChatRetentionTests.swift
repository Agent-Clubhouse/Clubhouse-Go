import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionChatRetentionTests {
    private func count(_ property: String, in projector: CompanionChatProjector) -> Int {
        let value = Mirror(reflecting: projector).children.first { $0.label == property }!.value
        return Mirror(reflecting: value).children.count
    }
    @Test func deliveredQueueDropsSubmissionCopies() {
        var projector = CompanionChatProjector()
        for i in 0..<100 {
            let id = "queued-\(i)"
            projector.apply(CompanionLongChatPerformanceTests.event("user_message", 3 * i + 1,
                ["messageId": .string(id), "delivery": .string("queued"), "content": .array([.object(["type": .string("text"), "text": .string(String(repeating: "queued", count: 200))])])]))
            projector.apply(CompanionLongChatPerformanceTests.event("queue_state", 3 * i + 2,
                ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string(id)]), "status": .string("delivered")])]))
        }
        #expect(projector.items.count == 100, "Delivery history and Copy message stay intact")
        #expect(count("queuedContentParts", in: projector) == 0, "Only pending submissions need the raw coalescing copies")
    }
    @Test func sessionChangeDropsCommandMappings() {
        var projector = CompanionChatProjector()
        projector.apply(CompanionLongChatPerformanceTests.event("agent_message", 1, ["messageId": .string("old"), "text": .string("old")]))
        for i in 0..<100 { _ = projector.reconcile(messageID: "old-\(i)", commandID: "command-\(i)") }
        projector.apply(.object(["sessionId": .string("new"), "seq": .integer(1), "type": .string("session_started"), "data": .object([:])]))
        #expect(projector.commandIDsByMessage.isEmpty)
    }
    @Test func dispatchingKeepsSubmissionBoundariesForALateJoin() {
        var projector = CompanionChatProjector()
        for i in 1...2 {
            var data: [String: AnnexJSON] = ["messageId": .string(i == 1 ? "q" : "join-2"), "delivery": .string("queued"),
                "content": .array([.object(["type": .string("text"), "text": .string("Part \(i)")])])]
            if i > 1 { data["queuedWith"] = .string("q") }
            projector.apply(CompanionLongChatPerformanceTests.event("user_message", i, data))
        }
        projector.apply(CompanionLongChatPerformanceTests.event("queue_state", 3,
            ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string("q")]), "status": .string("dispatching")])]))
        #expect(count("queuedContentParts", in: projector) == 1)
        projector.apply(CompanionLongChatPerformanceTests.event("user_message", 4,
            ["messageId": .string("join-3"), "queuedWith": .string("q"), "delivery": .string("queued"),
             "content": .array([.object(["type": .string("text"), "text": .string("Part 3")])])]))
        guard case .message(let message) = projector.items.first else { Issue.record("Missing queued row"); return }
        #expect(message.text == "3 updates, oldest first:\n\n--- 1 of 3 ---\nPart 1\n\n--- 2 of 3 ---\nPart 2\n\n--- 3 of 3 ---\nPart 3")
    }

    @Test func wakeReceiptBeforeTheNewSessionUserMessageStillReconcilesThePhoneSend() throws {
        var projector = CompanionChatProjector()
        projector.apply(CompanionLongChatPerformanceTests.event("agent_message", 100,
            ["messageId": .string("old"), "text": .string("Previous session")]))
        let previousSession = projector.sessionID
        let target = CompanionPreviewService.dispatcherTarget
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.timeline(target, items: projector.items, sequence: 100, reset: true, sessionID: previousSession))
        store.apply(.upsert(target, .message(.init(id: "local-phone", role: .user, text: "Wake and do work",
            delivery: .accepted, clientCommandID: "wake-command")), sequence: nil))
        #expect(projector.reconcile(messageID: "wake-server", commandID: "wake-command") == nil)
        #expect(projector.commandIDsByMessage["wake-server"] == "wake-command")
        let first: AnnexJSON = .object(["sessionId": .string("new-session"), "seq": .integer(1), "type": .string("user_message"),
            "data": .object(["messageId": .string("wake-server"), "clientCommandId": .string("wake-command"),
                "content": .array([.object(["type": .string("text"), "text": .string("Wake and do work")])])])])
        projector.apply(first)
        store.apply(projector.liveUpdate(for: first, target: target, previousSessionID: previousSession))
        #expect(projector.commandIDsByMessage.isEmpty, "Receipt maps from the prior session are released")
        let items = store.conversation(for: target).items
        #expect(items.count == 1, "The new session's wire command id replaces the optimistic phone row")
        guard case .message(let message) = try #require(items.first) else { Issue.record("Missing wake echo"); return }
        #expect(message.id == "wake-server" && message.clientCommandID == "wake-command" && message.delivery == .confirmed)
    }

}
