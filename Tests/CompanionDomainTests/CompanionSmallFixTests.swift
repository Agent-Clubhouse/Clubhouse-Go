import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionSmallFixTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6])
    func onlyCompleteReadableQuestionsSendCommands(shape: Int) async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        let readable: AnnexJSON = .object(["id": .string("color"), "prompt": .string("Which color?"),
            "options": .array([.object(["id": .string("red"), "label": .string("Red")])])])
        let missing: AnnexJSON = .object(["id": .string("missing")])
        let blank: AnnexJSON = .object(["id": .string("blank"), "prompt": .string(" \n "), "allowFreeText": .bool(true)])
        let prompts: [AnnexJSON] = switch shape {
        case 0: []
        case 1: [missing]
        case 2: [readable, missing]
        case 3: [readable]
        case 4: [blank]
        case 5: [.object(["id": .string("empty"), "prompt": .string(""), "allowFreeText": .bool(true)])]
        default: [readable, readable]
        }
        let event = LiveServiceHarness.chatEvent("s1", sequence: 2, type: "question", data: [
            "requestId": .string("q"), "questions": .array(prompts)])
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(events: [event], fields: ["capabilities": .object(["chat": .bool(true), "questions": .bool(true)])]))
        await harness.store.load(harness.target)
        let question = try #require(harness.store.conversation(for: harness.target).items.compactMap { item -> CompanionQuestion? in
            if case .question(let value) = item { value } else { nil }
        }.first)
        let answers: [String: CompanionAnswer] = shape >= 2 ? ["color": .text("red")] : [:]
        #expect((question.desktopAnswerMessage == nil) == (shape == 3))
        #expect(CompanionStore.validAnswers(answers, for: question) == (shape == 3))
        await harness.store.answer(question, answers: answers, target: harness.target)
        #expect(await harness.transport.executed.count == (shape == 3 ? 1 : 0))
        if shape == 3 {
            #expect(await harness.transport.executed.first?.kind == .question(agentID: "agent", sessionID: "s1", requestID: "q", answers: ["color": .string("red")]))
        }
        // Empty/whitespace prompt text is just as unreadable as a missing field.
        var projector = CompanionChatProjector()
        projector.apply(LiveServiceHarness.chatEvent("s1", sequence: 3, type: "question", data: [
            "requestId": .string("blank"), "questions": .array([blank])]))
        if case .question(let value)? = projector.items.first {
            #expect(!CompanionStore.validAnswers(["blank": .text("red")], for: value))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func rejectedReadPreservesCachedOrColdChatAndExplainsDesktopAction(cached: Bool, withMessage: Bool) async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        if cached {
            await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
            await harness.store.load(harness.target)
        }
        let before = harness.store.conversation(for: harness.target).items
        let body = withMessage
            ? #"{"error":"pending_overflow","message":"Review the pending requests on your desktop, then refresh this conversation.","pendingCount":1000}"#
            : #"{"error":"pending_overflow","pendingCount":1000}"#
        let error = AnnexHTTPValidation.error(.init(status: 503, data: Data(body.utf8)))
        await harness.transport.failRead("chat", error)
        await harness.store.load(harness.target, force: true)
        let conversation = harness.store.conversation(for: harness.target)
        let expected = withMessage ? "Review the pending requests on your desktop, then refresh this conversation."
            : "There are too many pending requests to show on your phone. Review them on the desktop, then refresh this conversation."
        #expect(conversation.error == expected)
        #expect(conversation.items == before)
        #expect(conversation.isLoaded == cached)
        #expect(!conversation.isLoading && conversation.requiresResync)
        let count = await harness.transport.readRoutes.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.transport.readRoutes.count == count, "A failed read is not automatically retried")
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await harness.store.load(harness.target, force: true)
        #expect(harness.store.conversation(for: harness.target).error == nil)
        #expect(harness.store.canOperate(harness.target))
    }

    @Test func desktopRejectionMessageWinsOverKnownReadCodeFallbacks() {
        let message = "Review this request on the desktop."
        let error = AnnexHTTPValidation.error(.init(status: 404, data: Data(#"{"error":"agent_not_found","message":"Review this request on the desktop."}"#.utf8)))
        #expect(CompanionLiveService.sessionsReadError(error) == message)
        #expect(CompanionLiveService.agentReadError(error) == message)
        #expect(CompanionLiveService.changesReadError(error) == message)
        #expect(CompanionLiveService.contentErrorMessage(error, reference: .file("a.txt"), hostName: "Studio") == message)
    }

    @Test func repeatedCodeUsesReadableFallbackAndPairingGuidanceWinsOverDesktopMessage() {
        let repeated = AnnexHTTPValidation.error(.init(status: 503, data: Data(#"{"error":"pending_overflow","message":"pending_overflow"}"#.utf8)))
        #expect(CompanionLiveService.readableError(repeated) == "There are too many pending requests to show on your phone. Review them on the desktop, then refresh this conversation.")
        let pairing = AnnexHTTPValidation.error(.init(status: 409, data: Data(#"{"error":"persistent_pairing_requires_desktop","message":"Use desktop settings."}"#.utf8)))
        #expect(CompanionLiveService.readableError(pairing) == "Remove this remembered pairing in the desktop's Annex settings. You can also forget its local access on this device.")
    }

    @Test func questionPreviewShowsDesktopOnlyCardsAndRefusesCommands() async throws {
        let service = CompanionPreviewService(showsQuestions: true)
        let history = try await service.history(for: CompanionPreviewService.target)
        let questions = history.items.compactMap { item -> CompanionQuestion? in
            if case .question(let value) = item { value } else { nil }
        }
        #expect(questions.map(\.canAnswerOnPhone) == [false, false, true])
        #expect(await serviceErrorText {
            try await service.answer("complete", answers: ["color": .text("red")], target: CompanionPreviewService.target, clientCommandID: "preview")
        } == "Preview only. This action does not contact a desktop.")
    }

    @Test func oversizedHTTPReadDoesNotPromiseAnAutomaticRetry() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        await harness.transport.failRead("chat", .responseTooLarge)
        await harness.store.load(harness.target)
        #expect(harness.store.conversation(for: harness.target).error == "The desktop sent more data than your phone can accept.")
        #expect(CompanionLiveService.readableError(AnnexTransportError.rejected(status: 503, code: "unknown")) == "Desktop request failed (503): unknown.")
    }
}
