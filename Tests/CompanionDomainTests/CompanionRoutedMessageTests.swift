import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

// Valid deliveries come from the desktop's real chat-events.json. Damage and inline-tag cases extend those shapes.
@Suite struct CompanionRoutedMessageTests {
    private let raw = "[TASK:t] [FROM:Wrong sender] Raw delivery\n\n---\nReply instructions stay in Copy."

    private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }
    private func event(_ routed: AnnexJSON? = nil, sequence: Int64 = 2, messageID: String = "routed", source: String = "mcp") throws -> AnnexJSON {
        guard case .object(var fixture) = try ContractFixtures.chatEvent("msg_routed_one"),
              case .object(var data)? = fixture["data"] else { throw AnnexTransportError.malformedResponse }
        data["messageId"] = .string(messageID); data["source"] = .string(source); data["delivery"] = .string("steer")
        data["content"] = .array([.object(["type": .string("text"), "text": .string(raw)])])
        data["routed"] = routed
        fixture["sessionId"] = .string("s1"); fixture["seq"] = .integer(sequence); fixture["data"] = .object(data)
        return .object(fixture)
    }
    private func message(_ event: AnnexJSON) throws -> CompanionMessage {
        var projector = CompanionChatProjector()
        projector.apply(event)
        return try #require(projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }.first)
    }

    @Test func onePartKeepsIdentityAndCleanTextWhileCopyKeepsTheWholeDelivery() throws {
        let projected = try message(ContractFixtures.chatEvent("msg_routed_one"))
        let part = try #require(projected.routed.first)
        #expect(part.sender == .init(agentID: "durable_docs", name: "Docs"))
        #expect(part.displayText == "The docs are up to date.")
        #expect(part.caption(source: projected.source, isSteered: projected.isSteered) == "Docs")
        #expect(projected.routed.count == 1)
        #expect(projected.text == "[FROM:Docs@App] The docs are up to date.", "Copy keeps the original delivery")
    }

    @Test func burstPreservesSeparatePartsSendersAndOrder() throws {
        let projected = try message(ContractFixtures.chatEvent("msg_routed_burst"))
        #expect(projected.routed.map(\.displayText) == ["Started on the guide.", "The tests pass."])
        #expect(projected.routed.map { $0.caption(source: "mcp") } == ["Docs", "reviewer"])
        let notice = try message(ContractFixtures.chatEvent("msg_routed_clubhouse"))
        let unnamed = try message(ContractFixtures.chatEvent("msg_routed_no_sender"))
        #expect(notice.routed.first?.caption(source: "mcp") == "Clubhouse")
        #expect(unnamed.routed.first?.caption(source: "mcp") == "Another agent")
        #expect(unnamed.routed.first?.caption(source: "group_project") == "Group project")
        #expect(projected.routed.first?.caption(source: "mission") == "Docs · Mission")
        #expect(projected.routed.first?.caption(source: "shoulder_tap") == "Docs · Shoulder tap")
    }

    @Test func ownMessagesIgnoreRoutedPartsAndKeepTheNormalUserBubble() throws {
        let base = try ContractFixtures.chatEvent("msg_routed_burst")
        let original = try message(base)
        for source in ["user", "annex"] {
            guard case .object(var event) = base, case .object(var data)? = event["data"] else { return }
            data["source"] = .string(source); event["data"] = .object(data)
            let projected = try message(.object(event))
            #expect(projected.display == .you(original.text))
            #expect(projected.text == original.text)
            #expect(projected.metaLabels == (source == "annex" ? ["From Annex"] : []))
        }
        #expect(original.display == .others(original.routed))
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

    @Test func malformedAttributionKeepsTheTextAndOnlyPartsWithoutStringTextAreSkipped() throws {
        let projected = try message(event(json(#"[null,42,"bad",{}, {"text":true}, {"text":"Bad sender","sender":{"agentId":"a"}}, {"text":"Bad name","sender":{"name":false}}, {"text":"Blank name","sender":{"name":"  "}}, {"text":"Bad id","sender":{"name":"A","agentId":1}}, {"text":"Bad flag","fromClubhouse":"yes"}, {"text":"Good","sender":{"name":"Atlas"}}, {"text":"Notice","fromClubhouse":true}, {"text":"No sender","sender":null,"fromClubhouse":null}]"#)))
        #expect(projected.routed.map(\.displayText) == ["Bad sender", "Bad name", "Blank name", "Bad id", "Bad flag", "Good", "Notice", "No sender"])
        #expect(projected.routed.map { $0.caption(source: "mcp") } == ["Another agent", "Another agent", "Another agent", "Another agent", "Another agent", "Atlas", "Clubhouse", "Another agent"])
    }

    @Test func absentEmptyAndUnusableRoutedUseDesktopTextFallback() throws {
        for routed in [nil, try json("[]"), try json("[null,{}, {\"text\":false}]"), try json("{}"), try json("null")] as [AnnexJSON?] {
            let projected = try message(event(routed))
            #expect(projected.routed.isEmpty)
            #expect(projected.display == .others([.init(sender: .init(name: "Wrong sender"), text: "Raw delivery\n\n---\nReply instructions stay in Copy.")]))
            #expect(projected.text == raw)
        }
    }

    @MainActor @Test func liveEventsAndChatSnapshotsUseTheSameRoutedProjection() async throws {
        let recorded = try ContractFixtures.chatEvent("msg_routed_burst")
        let expected = try message(recorded)
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": recorded]))))
        try await harness.waitUntil { harness.store.conversation(for: harness.target).items.contains(.message(expected)) }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(events: [recorded]))
        let history = try await harness.service.history(for: harness.target)
        #expect(history.items.contains(.message(expected)))
    }

    @MainActor @Test func historyPagesRebuildRoutedBurstsWithoutMergingOrDuplicates() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        let reader = CompanionArchiveReader(transport: harness.transport, target: harness.target, sessionID: "sess_live")
        let recorded = try ContractFixtures.chatEvent("msg_routed_burst")
        let expected = try message(recorded)
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("sess_live"), "events": .array([recorded]), "nextBeforeSeq": .integer(132)]))
        let latest = try await reader.load(before: nil)
        #expect(latest.items == [.message(expected)] && latest.nextBeforeSequence == 132)
        let legacy = try ContractFixtures.chatEvent("msg_10")
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("sess_live"), "events": .array([legacy, recorded])]))
        let earlier = try await reader.load(before: 132)
        #expect(earlier.items == [.message(try message(legacy)), .message(expected)], "Earlier legacy messages and deduplicated routed bursts both survive pagination")
        #expect(earlier.nextBeforeSequence == nil)
    }
}
