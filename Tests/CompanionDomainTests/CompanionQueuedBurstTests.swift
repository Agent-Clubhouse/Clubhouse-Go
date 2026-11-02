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

    @MainActor @Test(arguments: ["TASK_RESULT:t:", "TASK_ACK:t:"])
    func severalJoinsAppendPartsWithoutShiftingFoldStateAndKeepRawCopy(marker: String) throws {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "raw one", routed: routed("Docs", "First")))
        let expansion = CompanionTranscriptExpansion()
        let first = expansion.part(messageID: "item", index: 0); first.open = true
        p.apply(user("join-1", 2, "[FROM:Reviewer] Second", joined: "item"))
        p.apply(user("join-2", 3, "raw three", joined: "item", routed: routed("Helper", marker + " Third")))
        let row = try #require(messages(p).first)
        #expect(messages(p).count == 1)
        #expect(row.text == combined(["raw one", "[FROM:Reviewer] Second", "raw three"]))
        #expect(row.routed.map(\.text) == ["First", "Second", marker + " Third"])
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

    @Test func deliveredUserMessageSupersedesOnlyByID() {
        var p = CompanionChatProjector()
        p.apply(user("same-text", 1, "combined"))
        p.apply(user("item", 2, "First")); p.apply(user("join", 3, "Second", joined: "item"))
        p.apply(user("item", 4, "combined", delivery: "prompt", routed: routed("Final", "Delivered")))
        #expect(messages(p).map(\.id) == ["same-text", "item"])
        #expect(messages(p).last?.display == .others([.init(sender: .init(name: "Final"), text: "Delivered")]))
        p.apply(user("new-id", 5, "combined", delivery: "steer"))
        #expect(messages(p).map(\.id) == ["same-text", "item", "new-id"])
        #expect(messages(p).first?.queueState == .submitted, "Matching text must not consume a different queued item")
    }

    @Test func bothRemovalEventsApplyToTheWholeMergedRow() {
        for removal in [queue(4, "removed"), event("queue_removed", 4, ["messageIds": .array([.string("item")])])] {
            var p = CompanionChatProjector()
            p.apply(user("item", 1, "First")); p.apply(queue(2, "queued", ids: ["item"]))
            p.apply(user("join", 3, "Second", joined: "item")); p.apply(removal)
            #expect(messages(p).isEmpty, "Removal drops every part of the merged item")
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
        try await harness.loadSession(LiveServiceHarness.chatSnapshot(fields: ["events": .array([])]))
        for event in events {
            await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]))))
        }
        try await harness.waitUntil { harness.store.conversation(for: harness.target).items == expected.items }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["events": .array(events)]))
        #expect(try await harness.service.history(for: harness.target).items == expected.items)
        let reader = CompanionArchiveReader(transport: harness.transport, target: harness.target, sessionID: "s1")
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array(Array(events.suffix(3))), "nextBeforeSeq": .integer(12)]))
        let tail = try await reader.load(before: nil)
        #expect(tail.items.count == 1 && tail.items.first?.id == "message:item")
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array(Array(events.prefix(3)))]))
        #expect(try await reader.load(before: 12).items == expected.items)
    }
    @Test func dispatchingBeforeOrAfterTurnStartedKeepsExactlyOneMergedRow() {
        for dispatchFirst in [false, true] {
            var p = CompanionChatProjector()
            p.apply(event("session_started", 1, ["capabilities": .object(["queue": .string("client")])]))
            p.apply(user("item", 2, "First")); p.apply(user("join", 3, "Second", joined: "item"))
            if dispatchFirst { p.apply(queue(4, "dispatching")); p.apply(event("turn_started", 5, [:])) }
            else { p.apply(event("turn_started", 4, [:])); p.apply(queue(5, "dispatching")) }
            #expect(messages(p).count == 1 && messages(p).first?.queueState == .dispatching)
            #expect(messages(p).first?.text == combined(["First", "Second"]))
        }
    }

    @Test func failedDispatchIsNeverConsumedOrRetriedByTheNextTurn() {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "First")); p.apply(user("join", 2, "Second", joined: "item"))
        p.apply(queue(3, "dispatching")); p.apply(queue(4, "failed")); p.apply(event("turn_started", 5, [:]))
        #expect(messages(p).count == 1 && messages(p).first?.queueState == .failed)
        #expect(p.queuedMessageIDs.isEmpty)
        #expect(messages(p).first?.text == combined(["First", "Second"]))
    }

    @Test func fullMembershipListRecoversMissedDispatchWithoutClaimingDelivery() {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "First")); p.apply(queue(2, "queued", ids: ["item"]))
        p.apply(user("join", 3, "Second", joined: "item"))
        // The item's dispatching/delivered transitions were missed; this event concerns another item.
        p.apply(event("queue_state", 6, ["queuedMessageIds": .array([.string("other")]),
            "transition": .object(["messageIds": .array([.string("other")]), "status": .string("queued")])]))
        #expect(messages(p).count == 1 && messages(p).first?.queueState == nil)
        #expect(messages(p).first?.text == combined(["First", "Second"]))
        p.apply(event("turn_started", 7, [:]))
        #expect(messages(p).first?.queueState == nil)
    }

    @Test func nativeAndLegacyTurnFallbackConsumesOnlyTheOldestNeverMentionedRow() {
        for native in [false, true] {
            var p = CompanionChatProjector()
            if native { p.apply(event("session_started", 1, ["capabilities": .object(["queue": .string("native")])])) }
            p.apply(user("first", 2, "First")); p.apply(user("second", 3, "Second"))
            p.apply(event("turn_started", 4, [:]))
            #expect(messages(p).first?.queueState == nil)
            #expect(messages(p).last?.queueState == .submitted)
        }
    }

    @Test func runtimeOwnedRowsNeverUseTurnFallbackEvenBeforeTheirFirstQueueState() {
        var p = CompanionChatProjector()
        p.apply(event("session_started", 1, ["capabilities": .object(["queue": .string("client")])]))
        p.apply(user("item", 2, "First")); p.apply(event("turn_started", 3, [:]))
        #expect(messages(p).first?.queueState == .submitted)
        p.apply(queue(4, "queued", ids: ["item"]))
        p.updateCapabilities(.object(["queue": .string("native")]))
        p.apply(event("turn_started", 5, [:]))
        #expect(messages(p).first?.queueState == .queued)
    }

    @Test func snapshotOwnershipPreventsTurnFallbackAndReconcilesMissedTransitions() {
        var p = CompanionChatProjector()
        p.apply(user("item", 1, "First"))
        p.applyQueueSnapshot(.object(["queueStateSeq": .integer(2), "queuedMessageIds": .array([.string("item")])]))
        p.apply(event("turn_started", 3, [:]))
        #expect(messages(p).first?.queueState == .queued)
        p.applyQueueSnapshot(.object(["queueStateSeq": .integer(4), "queuedMessageIds": .array([])]))
        #expect(messages(p).first?.queueState == nil)
    }

    @MainActor @Test func latestHostQueueCapabilityAndSnapshotKindGateNativeFallback() async throws {
        let harness = try await LiveServiceHarness.start { transport in
            await transport.setCapability("events", .object(["queueState": .string("queue_state")]))
        }
        defer { harness.stop() }
        let queued = user("native", 2, "Native submission")
        let turn = event("turn_started", 3, [:])
        for kind in ["native", "client", "unknown"] {
            await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["events": .array([queued, turn]),
                "capabilities": .object(kind == "unknown" ? [:] : ["queue": .string(kind)])]))
            let history = try await harness.service.history(for: harness.target)
            guard case .message(let row) = history.items.first else { Issue.record("Expected queued message"); return }
            #expect(row.queueState == (kind == "native" ? nil : .submitted))
        }
    }

    @MainActor @Test func removingFromThePhoneAddressesTheItemAndDropsEveryJoinedPart() async throws {
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        let events = [user("item", 1, "First"), queue(2, "queued", ids: ["item"]), user("join", 3, "Second", joined: "item")]
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["events": .array(events),
            "capabilities": .object(["queue": .string("client")]), "queueStateSeq": .integer(2),
            "queuedMessageIds": .array([.string("item")]), "queueRemovalSupported": .bool(true)]))
        await harness.store.load(harness.target, force: true)
        await harness.transport.enqueue(.completed(.object(["removed": .array([.string("item")])])))
        await harness.store.removeQueuedMessage("item", target: harness.target)
        #expect(await harness.transport.executed.map(\.kind) == [.removeQueued(agentID: "agent", sessionID: "s1", messageIDs: ["item"])])
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": queue(4, "removed")]))))
        try await harness.waitUntil { harness.store.conversation(for: harness.target).items.isEmpty }
    }

}
