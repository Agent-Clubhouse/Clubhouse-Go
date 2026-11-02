import Foundation
import Testing

@testable import ClubhouseTransport
@testable import CompanionDomain

/// Complete events come unchanged from the desktop's real-server fixtures. `queuedRow` is an
/// abbreviated example: only its missing session routing and numeric paging envelope are supplied.
@MainActor struct AnnexContractChatPagesTests {
    private func fixture() throws -> AnnexJSON { try ContractFixtures.json("chat-pages.json") }

    private func page(_ events: [AnnexJSON], queue: [AnnexJSON] = [], next: Int64? = nil) -> AnnexJSON {
        .object([
            "sessionId": .string("sess_live"), "state": .string("waiting_input"), "readOnly": .bool(false),
            "events": .array(events), "queuedMessageIds": .array(queue), "queueStateSeq": .integer(215),
            "queueRemovalSupported": .bool(true), "nextBeforeSeq": next.map(AnnexJSON.integer) ?? .null,
            "truncated": .bool(next != nil), "capabilities": .object(["chat": .bool(true), "queue": .string("client")]),
        ])
    }

    @Test func omittedHistoricalQuestionIsANoticeWithoutAnAnswerableCard() throws {
        let event = try #require(fixture()["omittedQuestion"]?["event"])
        var projection = CompanionChatProjector()
        projection.apply(event)
        projection.apply(event)
        #expect(projection.lastSequence == 300)
        #expect(
            projection.items == [.notice(id: "event-sess_live-300", text: "A question here is too large to show. It's on the desktop.")])
        #expect(!projection.items.contains { if case .question = $0 { true } else { false } })
    }

    @Test func oldQueuedRowKeepsItsPositionAndRepeatingPagesDoNotDuplicateIt() async throws {
        let example = try #require(fixture()["queuedRow"])
        let events = try example["firstEvents"].arrayValue.map { event -> AnnexJSON in
            guard case .object(var fields) = event else { throw AnnexTransportError.malformedResponse }
            fields["sessionId"] = .string("sess_live")
            return .object(fields)
        }
        let next = try #require(events.last?["seq"]?.integer)
        #expect(next == 215 && events.first?["seq"]?.integer == 4)
        let queue = example["queuedMessageIds"].arrayValue
        let h = try await LiveServiceHarness.start { transport in
            await transport.setRead("chat", page(events, queue: queue, next: next))
        }
        defer { h.stop() }
        await h.store.load(h.target, force: true)
        let conversation = h.store.conversation(for: h.target)
        #expect(conversation.lastSequence == 215 && conversation.hasEarlierMessages)
        guard case .message(let queued)? = conversation.items.first else {
            Issue.record("Missing queued row")
            return
        }
        #expect(queued.id == "msg_q" && queued.text == "Then run the tests." && queued.queueState == .queued)

        let reader = try h.service.archive(for: h.target, sessionID: "sess_live")
        let transcript = CompanionArchiveTranscript(reader: reader)
        await h.transport.setRead("chatHistory", page(events, queue: queue, next: next))
        await transcript.loadEarlier()
        #expect(transcript.nextBeforeSequence == 215)
        await h.transport.setRead("chatHistory", page([events[0]], queue: queue))
        await transcript.loadEarlier()
        #expect(transcript.error == nil && transcript.nextBeforeSequence == nil)
        #expect(transcript.items.map(\.id) == ["message:msg_q"])
    }

    @Test func shortenedQueuedEventRetainsIdentityAndDisplaysItsRecordedText() async throws {
        let event = try #require(fixture()["queuedRowShortened"]?["event"])
        let h = try await LiveServiceHarness.start { transport in
            await transport.setRead("chat", page([event], queue: [.string("msg_q")]))
        }
        defer { h.stop() }
        await h.store.load(h.target, force: true)
        let conversation = h.store.conversation(for: h.target)
        guard case .message(let message)? = conversation.items.first else {
            Issue.record("Missing shortened queued row")
            return
        }
        #expect(message.id == "msg_q" && message.queueState == .queued && message.source == "user")
        // The fixture itself abbreviates ten blocks to one; do not invent the omitted text or note.
        #expect(message.text == event["data"]?["content"].arrayValue.first?["text"]?.string)
        #expect(conversation.items.count == 1 && conversation.error == nil)
    }

    @Test func compactResolutionsSettleExistingCardsAndIgnoreOrphans() throws {
        let forms = try #require(fixture()["smallestForms"])
        for (key, type, id) in [("questionResolved", "question", "q_old"), ("permissionResolved", "permission_request", "perm_old")] {
            let resolution = try #require(forms[key])
            var orphan = CompanionChatProjector()
            orphan.apply(resolution)
            #expect(orphan.lastSequence == 40 && orphan.items.isEmpty)

            var projection = CompanionChatProjector()
            let data: [String: AnnexJSON] =
                type == "question"
                ? [
                    "requestId": .string(id),
                    "questions": .array([
                        .object(["id": .string("which"), "prompt": .string("Which branch?"), "allowFreeText": .bool(true)])
                    ]),
                ]
                : ["requestId": .string(id), "title": .string("Write file"), "options": .array([])]
            projection.apply(LiveServiceHarness.chatEvent("sess_live", sequence: 1, type: type, data: data))
            projection.apply(resolution)
            projection.apply(resolution)
            #expect(projection.lastSequence == 40 && projection.items.count == 1)
            switch projection.items.first {
            case .question(let question):
                #expect(question.id == id && question.resolution == .answered)
                #expect(question.prompts.first?.text == "Which branch?")
            case .approval(let approval): #expect(approval.id == id && approval.resolution == .denied)
            default: Issue.record("Compact resolution lost its card")
            }
        }
    }

    @Test func smallestDeliveredMessageReplacesQueuedContentAndKeepsTheNotice() throws {
        let event = try #require(fixture()["smallestForms"]?["userMessage"])
        var projection = CompanionChatProjector()
        projection.updateCapabilities(.object(["queue": .string("client")]))
        projection.apply(
            LiveServiceHarness.chatEvent(
                "sess_live", sequence: 1, type: "user_message",
                data: [
                    "messageId": .string("msg_old"), "delivery": .string("queued"),
                    "content": .array([.object(["type": .string("text"), "text": .string("Earlier queued content")])]),
                ]))
        projection.applyQueueSnapshot(.object(["queuedMessageIds": .array([.string("msg_old")]), "queueStateSeq": .integer(1)]))
        projection.apply(event)
        projection.apply(event)
        guard case .message(let message)? = projection.items.first else {
            Issue.record("Missing delivered message")
            return
        }
        #expect(projection.items.count == 1 && projection.lastSequence == 40)
        #expect(message.id == "msg_old" && message.queueState == nil && message.source == "user")
        #expect(message.text.contains("409357 bytes of this output are omitted here"))
        #expect(!message.text.contains("Earlier queued content"))
    }
}
