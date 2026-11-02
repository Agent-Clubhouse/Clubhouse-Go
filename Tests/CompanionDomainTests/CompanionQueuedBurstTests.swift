import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Queue joins are reduced before dispatch: the runtime need not echo a delivered user_message.
@Suite struct CompanionQueuedBurstTests {
    private func event(_ type: String, _ seq: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["v": .integer(2), "sessionId": .string("s1"), "seq": .integer(seq), "ts": .integer(1_700_000_000_000),
                 "type": .string(type), "data": .object(data)])
    }
    private func user(_ id: String, _ seq: Int64, _ text: String, joined: String? = nil,
                      delivery: String = "queued", source: String = "mcp", routed: AnnexJSON? = nil,
                      content: [AnnexJSON]? = nil) -> AnnexJSON {
        var data: [String: AnnexJSON] = ["messageId": .string(id), "delivery": .string(delivery), "source": .string(source),
            "content": .array(content ?? [.object(["type": .string("text"), "text": .string(text)])])]
        data["queuedWith"] = joined.map(AnnexJSON.string); data["routed"] = routed
        return event("user_message", seq, data)
    }
    private func routed(_ name: String, _ text: String) -> AnnexJSON {
        .array([.object(["sender": .object(["name": .string(name)]), "text": .string(text)])])
    }
    private func queue(_ seq: Int64, _ state: String, ids: [String] = []) -> AnnexJSON {
        event("queue_state", seq, ["queuedMessageIds": .array(ids.map(AnnexJSON.string)),
            "transition": .object(["messageIds": .array([.string("item")]), "status": .string(state)])])
    }
    private func messages(_ projector: CompanionChatProjector) -> [CompanionMessage] {
        projector.items.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }
    private func combined(_ texts: [String]) -> String {
        (["\(texts.count) updates, oldest first:"] + texts.enumerated().map { "--- \($0.offset + 1) of \(texts.count) ---\n\($0.element)" }).joined(separator: "\n\n")
    }

    @Test func oneJoinBuildsOneRowAndDeliveryNeedsOnlyQueueState() throws {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "[FROM:Docs] First")); p.apply(queue(2, "queued", ids: ["item"]))
        p.apply(user("join", 3, "[FROM:Reviewer] Second", joined: "item"))
        #expect(messages(p).count == 1)
        let row = try #require(messages(p).first)
        #expect(row.id == "item" && row.queueState == .queued)
        #expect(row.text == combined(["[FROM:Docs] First", "[FROM:Reviewer] Second"]))
        #expect(row.display == .others([.init(sender: .init(name: "Docs"), text: "First"), .init(sender: .init(name: "Reviewer"), text: "Second")]))
        p.apply(queue(4, "dispatching")); p.apply(event("turn_started", 5, [:]))
        #expect(messages(p).first?.queueState == .dispatching)
        p.apply(queue(6, "delivered"))
        #expect(messages(p).count == 1 && messages(p).first?.queueState == .delivered)
        #expect(messages(p).first?.text == row.text)
    }

    @MainActor @Test func severalJoinsAppendPartsWithoutShiftingFoldStateAndKeepRawCopy() throws {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "raw one", routed: routed("Docs", "First")))
        let expansion = CompanionTranscriptExpansion()
        let first = expansion.part(messageID: "item", index: 0); first.open = true
        p.apply(user("join-1", 2, "[FROM:Reviewer] Second", joined: "item"))
        p.apply(user("join-2", 3, "raw three", joined: "item", routed: routed("Helper", "TASK_RESULT:t: Third")))
        let row = try #require(messages(p).first)
        #expect(messages(p).count == 1)
        #expect(row.text == combined(["raw one", "[FROM:Reviewer] Second", "raw three"]))
        #expect(row.routed.map(\.text) == ["First", "Second", "TASK_RESULT:t: Third"])
        #expect(row.display == .others([.init(sender: .init(name: "Docs"), text: "First"), .init(sender: .init(name: "Reviewer"), text: "Second"), .init(sender: .init(name: "Helper"), text: "Third")]))
        #expect(expansion.part(messageID: row.id, index: 0) === first && first.open == true)
        #expect(expansion.part(messageID: row.id, index: 2) !== first)
    }

    @Test func textOnlyTargetAndMultipleStructuredPartsKeepTheirOrder() throws {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "[FROM:Legacy] First"))
        p.apply(user("join", 2, "raw burst", joined: "item", routed: .array([
            .object(["text": .string("Second")]), .object(["text": .string("Third"), "fromClubhouse": .bool(true)])])))
        let row = try #require(messages(p).first)
        #expect(messages(p).count == 1)
        #expect(row.routed.map(\.text) == ["First", "Second", "Third"])
        #expect(row.routed.first?.sender?.name == "Legacy" && row.routed.last?.fromClubhouse == true)
    }

    @Test func cutOffTargetTakesItemIDForLaterJoinsAndDelivery() throws {
        var p = CompanionChatProjector()
        p.apply(user("join-1", 2, "Second", joined: "item"))
        p.apply(user("join-2", 3, "Third", joined: "item"))
        #expect(messages(p).map(\.id) == ["item"])
        #expect(messages(p).first?.text == combined(["Second", "Third"]))
        p.apply(user("item", 4, "Complete delivery", delivery: "prompt"))
        #expect(messages(p).map(\.id) == ["item"] && messages(p).first?.text == "Complete delivery")
        #expect(messages(p).first?.queueState == nil)
    }

    @Test func deliveredUserMessageSupersedesByIDBeforeText() {
        var p = CompanionChatProjector()
        p.apply(user("same-text", 1, "combined"))
        p.apply(user("item", 2, "First")); p.apply(user("join", 3, "Second", joined: "item"))
        p.apply(user("item", 4, "combined", delivery: "prompt", routed: routed("Final", "Delivered")))
        #expect(messages(p).map(\.id) == ["same-text", "item"])
        #expect(messages(p).last?.display == .others([.init(sender: .init(name: "Final"), text: "Delivered")]))
        p.apply(user("new-id", 5, "combined", delivery: "steer"))
        #expect(messages(p).map(\.id) == ["new-id", "item"])
        #expect(messages(p).first?.queueState == nil)
    }

    @Test func bothRemovalEventsApplyToTheWholeMergedRow() {
        for removal in [queue(4, "removed"), event("queue_removed", 4, ["messageIds": .array([.string("item")])])] {
            var p = CompanionChatProjector()
            p.apply(user("item", 1, "First")); p.apply(queue(2, "queued", ids: ["item"]))
            p.apply(user("join", 3, "Second", joined: "item")); p.apply(removal)
            #expect(messages(p).map(\.id) == ["item"] && messages(p).first?.queueState == .removed)
            #expect(messages(p).first?.routed.map(\.text) == ["First", "Second"])
            #expect(p.queuedMessageIDs.isEmpty)
        }
    }

    @Test func ownQueuedMessagesNeverJoinImplicitlyAndSteerIgnoresQueuedWith() throws {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "First")); p.apply(user("own", 2, "First", source: "user"))
        p.apply(user("phone", 3, "From phone", source: "annex"))
        #expect(messages(p).map(\.id) == ["item", "own", "phone"])
        let fixture = try ContractFixtures.chatEvent("msg_10")
        var fixtureProjection = CompanionChatProjector(); fixtureProjection.apply(fixture)
        #expect(messages(fixtureProjection).map(\.id) == ["msg_10"])
        #expect(messages(fixtureProjection).first?.isSteered == true)
        #expect(messages(fixtureProjection).first?.queueState == nil)
    }

    @Test func mixedContentUsesDesktopBlockCoalescing() {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "", content: [.object(["type": .string("text"), "text": .string("First")]),
            .object(["type": .string("file"), "path": .string("note.md")])]))
        p.apply(user("join", 2, "Second", joined: "item"))
        #expect(messages(p).first?.text == "2 updates, oldest first:\n--- 1 of 2 ---\nFirst\nFile: note.md\n--- 2 of 2 ---\nSecond")
    }

    @MainActor @Test func liveSnapshotAndPaginatedHistoryProduceTheSameMergedRow() async throws {
        let events = [user("item", 10, "[FROM:Docs] First"), queue(11, "queued", ids: ["item"]),
                      user("join-1", 12, "raw second", joined: "item", routed: routed("Reviewer", "Second")),
                      user("join-2", 13, "[Clubhouse] Third", joined: "item"), queue(14, "delivered")]
        var expected = CompanionChatProjector(); events.forEach { expected.apply($0) }
        #expect(messages(expected).count == 1)
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        try await harness.loadSession()
        for event in events {
            await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]))))
        }
        try await harness.waitUntil { harness.store.conversation(for: harness.target).items == expected.items }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(events: events))
        #expect(try await harness.service.history(for: harness.target).items == expected.items)
        let reader = CompanionArchiveReader(transport: harness.transport, target: harness.target, sessionID: "s1")
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array(Array(events.suffix(3))), "nextBeforeSeq": .integer(12)]))
        let tail = try await reader.load(before: nil)
        #expect(tail.items.count == 1 && tail.items.first?.id == "message:item")
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array(Array(events.prefix(3)))]))
        #expect(try await reader.load(before: 12).items == expected.items)
    }
}
