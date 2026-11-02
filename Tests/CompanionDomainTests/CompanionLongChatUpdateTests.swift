import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionLongChatUpdateTests {
    @Test func twoHundredChunksPublishOnlyTwoHundredItemsAndMatchHistory() {
        var projector = CompanionChatProjector()
        for i in 1...5_000 { projector.upsert(.message(.init(id: "old-\(i)", role: .user, text: "History \(i)"))) }
        // Establish a session without replacing the seeded fixture.
        projector.sessionID = "long-dispatcher"
        let target = CompanionPreviewService.dispatcherTarget
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.timeline(target, items: projector.items, sequence: 0, reset: true, sessionID: projector.sessionID))
        var publishedItems = 0
        for i in 1...200 {
            let event = CompanionLongChatPerformanceTests.event("agent_message_chunk", i, ["messageId": .string("reply"), "text": .string("chunk ")])
            projector.apply(event)
            let update = projector.liveUpdate(for: event, target: target, previousSessionID: projector.sessionID)
            if case .upsert = update { publishedItems += 1 } else { Issue.record("A same-session text chunk must publish one row") }
            store.apply(update)
        }
        #expect(publishedItems == 200)
        #expect(store.conversation(for: target).items == projector.items)
        #expect(store.conversation(for: target).items.count == 5_001)
        let final = CompanionLongChatPerformanceTests.event("agent_message", 201, ["messageId": .string("reply"), "text": .string("Final replacement")])
        projector.apply(final)
        store.apply(projector.liveUpdate(for: final, target: target, previousSessionID: projector.sessionID))
        #expect(store.conversation(for: target).items == projector.items)
        #expect(projector.items.last?.id == "message:reply")
    }
    @Test func queueRemovalRebuildsIndicesAndSessionResetPublishesHistory() {
        var projector = CompanionChatProjector()
        for i in 1...3 {
            projector.apply(CompanionLongChatPerformanceTests.event("user_message", i, ["messageId": .string("q\(i)"), "delivery": .string("queued"), "content": .array([])]))
        }
        projector.apply(CompanionLongChatPerformanceTests.event("queue_removed", 4, ["messageIds": .array([.string("q2")])]))
        _ = projector.reconcile(messageID: "q3", commandID: "phone")
        guard case .message(let last) = projector.items.last else { Issue.record("Missing q3"); return }
        #expect(last.id == "q3" && last.clientCommandID == "phone")
        let event = CompanionLongChatPerformanceTests.event("agent_message", 5, ["messageId": .string("reply"), "text": .string("Hello")])
        projector.apply(event)
        if case .timeline(_, _, _, let reset, _) = projector.liveUpdate(for: event, target: CompanionPreviewService.dispatcherTarget, previousSessionID: "different") {
            #expect(reset)
        } else { Issue.record("A new session must reset the timeline") }
    }
    @Test func duplicateChunksDoNotPublishCatalogOrHistoryAgain() async throws {
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        try await harness.loadSession(LiveServiceHarness.chatSnapshot())
        let stream = harness.service.events()
        var timelines = 0, upserts = 0, catalogs = 0
        let watcher = Task { @MainActor in
            for await event in stream {
                switch event {
                case .timeline: timelines += 1
                case .upsert: upserts += 1
                case .hosts: catalogs += 1
                default: break
                }
            }
        }
        defer { watcher.cancel() }
        for i in 2...20 {
            let event = LiveServiceHarness.chatEvent("s1", sequence: Int64(i), type: "agent_message_chunk", data: ["messageId": .string("reply"), "text": .string("chunk ")])
            for _ in 0..<2 {
                await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]))))
            }
        }
        try await harness.waitUntil { harness.store.conversation(for: harness.target).lastSequence == 20 && upserts == 19 }
        #expect(timelines == 0)
        #expect(catalogs == 1, "Only the subscription's initial catalog; unchanged agent metadata must not fan out per chunk")
    }
}
