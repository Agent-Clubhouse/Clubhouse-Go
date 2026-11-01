import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

// Hand-built from desktop RoutedMessagePart (events.ts). Move to contract fixtures once desktop #2617 lands.
@Suite struct CompanionRoutedMessageTests {
    private let raw = "[TASK:t] [FROM:Wrong sender] Raw delivery\n\n---\nReply instructions stay in Copy."

    private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }
    private func event(_ routed: AnnexJSON? = nil, sequence: Int64 = 2) -> AnnexJSON {
        var data: [String: AnnexJSON] = ["messageId": .string("routed"), "source": .string("mcp"), "delivery": .string("steer"),
                                       "content": .array([.object(["type": .string("text"), "text": .string(raw)])])]
        data["routed"] = routed
        return LiveServiceHarness.chatEvent("s1", sequence: sequence, type: "user_message", data: data)
    }
    private func message(_ event: AnnexJSON) throws -> CompanionMessage {
        var projector = CompanionChatProjector()
        projector.apply(event)
        return try #require(projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }.first)
    }

    @Test func onePartKeepsIdentityAndCleanTextWhileCopyKeepsTheWholeDelivery() throws {
        let projected = try message(event(json(#"[{"sender":{"agentId":"dispatcher","name":"Dispatcher","future":42},"text":"Clean delivery","future":true}]"#)))
        let part = try #require(projected.routed.first)
        #expect(part.sender == .init(agentID: "dispatcher", name: "Dispatcher"))
        #expect(part.displayText == "Clean delivery")
        #expect(part.caption(source: projected.source, isSteered: projected.isSteered) == "Dispatcher · Steered into the running turn")
        #expect(projected.routed.count == 1)
        #expect(projected.text == raw, "Copy uses the original content, including instructions")
    }

    @Test func burstPreservesSeparatePartsSendersAndOrder() throws {
        let projected = try message(event(json(#"[{"sender":{"name":"Builder"},"text":"Fix ready"},{"sender":{"name":"Reviewer"},"text":"Tests pass"},{"fromClubhouse":true,"text":"Helper finished"},{"text":"Unnamed update"}]"#)))
        #expect(projected.routed.map(\.displayText) == ["Fix ready", "Tests pass", "Helper finished", "Unnamed update"])
        #expect(projected.routed.map { $0.caption(source: "mcp") } == ["Builder", "Reviewer", "Clubhouse", "Another agent"])
        #expect(projected.routed.last?.caption(source: "group_project") == "Group project")
        #expect(projected.routed.first?.caption(source: "mission") == "Builder · Mission")
        #expect(projected.routed.first?.caption(source: "shoulder_tap") == "Builder · Shoulder tap")
        #expect(projected.routed.first?.caption(source: "annex") == "Builder · From Annex")
    }

    @Test func structuredTextIsNeverReparsedAsRouting() throws {
        let projected = try message(event(json(#"[{"sender":{"name":"Real sender"},"fromClubhouse":true,"text":"[FROM:Not the sender] quoted text"}]"#)))
        #expect(projected.routed.first?.caption(source: "mcp") == "Real sender")
        #expect(projected.routed.first?.displayText == "[FROM:Not the sender] quoted text")
    }

    @Test func replyMarkersMatchTheDesktopWithoutChangingRawText() throws {
        for text in ["TASK_RESULT:t: Ready", "TASK_ACK:t Ready"] {
            let projected = try message(event(.array([.object(["text": .string(text)])])))
            #expect(projected.routed.first?.displayText == "Ready")
            #expect(projected.text == raw)
        }
    }

    @Test func malformedPartsAreSkippedWithoutDroppingTheirValidNeighbours() throws {
        let projected = try message(event(json(#"[null,42,"bad",{}, {"text":true}, {"text":"Bad sender","sender":{"agentId":"a"}}, {"text":"Bad name","sender":{"name":false}}, {"text":"Blank name","sender":{"name":"  "}}, {"text":"Bad id","sender":{"name":"A","agentId":1}}, {"text":"Bad flag","fromClubhouse":"yes"}, {"text":"Good","sender":{"name":"Atlas"}}, {"text":"Notice","fromClubhouse":true}, {"text":"No sender","sender":null,"fromClubhouse":null}]"#)))
        #expect(projected.routed.map(\.displayText) == ["Good", "Notice", "No sender"])
    }

    @Test func absentEmptyAndUnusableRoutedPreserveLegacyBehavior() throws {
        for routed in [nil, try json("[]"), try json("[null,{}, {\"text\":false}]"), try json("{}"), try json("null")] as [AnnexJSON?] {
            let projected = try message(event(routed))
            #expect(projected.routed.isEmpty)
            #expect(projected.relay?.sender == "Wrong sender")
            #expect(projected.displayText == "Raw delivery\n\n---\nReply instructions stay in Copy.")
            #expect(projected.sourceLabel == "From Wrong sender · Steered into the running turn")
            #expect(projected.text == raw)
        }
    }

    @Test func legacyTagsAreOnlyParsedOnMCPUserMessages() {
        for source in ["user", "annex", "mission", "system", "group_project", "shoulder_tap"] {
            let old = CompanionMessage(id: source, role: .user, text: raw, source: source)
            #expect(old.relay == nil && old.displayText == raw)
        }
        let old = CompanionMessage(id: "m", role: .user, text: "[FROM: Atlas@Project ]\nBody", source: "mcp")
        #expect(old.sourceLabel == "From Atlas@Project" && old.displayText == "Body")
        let untagged = CompanionMessage(id: "m", role: .user, text: "Plain", source: "mcp")
        #expect(untagged.sourceLabel == "From another agent" && untagged.displayText == "Plain")
    }

    @MainActor @Test func liveEventsAndChatSnapshotsUseTheSameRoutedProjection() async throws {
        let routed = try json(#"[{"sender":{"name":"Builder"},"text":"First"},{"fromClubhouse":true,"text":"Second"}]"#)
        let expected = try message(event(routed))
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event(routed)]))))
        try await harness.waitUntil { harness.store.conversation(for: harness.target).items.contains(.message(expected)) }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(events: [event(routed)]))
        let history = try await harness.service.history(for: harness.target)
        #expect(history.items.contains(.message(expected)))
    }

    @MainActor @Test func historyPagesRebuildRoutedBurstsWithoutMergingOrDuplicates() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        let reader = CompanionArchiveReader(transport: harness.transport, target: harness.target, sessionID: "s1")
        let routed = try json(#"[{"sender":{"name":"Builder"},"text":"First"},{"sender":{"name":"Reviewer"},"text":"Second"}]"#)
        let expected = try message(event(routed))
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array([event(routed)]), "nextBeforeSeq": .integer(2)]))
        let latest = try await reader.load(before: nil)
        #expect(latest.items == [.message(expected)] && latest.nextBeforeSequence == 2)
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array([event(sequence: 1), event(routed)])]))
        let earlier = try await reader.load(before: 2)
        #expect(earlier.items == [.message(expected)], "The duplicate event replaces the older copy by sequence/message ID")
        #expect(earlier.nextBeforeSequence == nil)
    }
}
