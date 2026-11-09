import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor struct CompanionFullEventTests {
    private typealias Harness = LiveServiceHarness
    private let digest = "sha256:" + String(repeating: "a", count: 64)
    private func preview(sequence: Int64 = 7, title: String = "Write x") -> AnnexJSON {
        Harness.chatEvent("s1", sequence: sequence, type: "permission_request", data: [
            "requestId": .string("big"), "title": .string(title), "toolName": .string("Write"),
            "truncated": .object(["originalBytes": .integer(400_000)]),
            "options": .array([.object(["optionId": .string("ok"), "label": .string("Allow"), "kind": .string("allow_once")]),
                               .object(["optionId": .string("no"), "label": .string("Deny"), "kind": .string("reject_once")])])
        ])
    }
    private func full(_ preview: AnnexJSON) throws -> AnnexJSON {
        guard case .object(var event) = preview, case .object(var data)? = event["data"] else { throw AnnexTransportError.malformedResponse }
        data["truncated"] = nil
        data["rawInput"] = .object(["content": .string(String(repeating: "y", count: 400_000))])
        event["data"] = .object(data); event["agentId"] = .string("agent")
        return .object(["version": .integer(1), "agentId": .string("agent"), "sessionId": .string("s1"), "seq": preview["seq"] ?? .integer(7), "digest": .string(digest), "event": .object(event)])
    }
    private func start() async throws -> Harness {
        let capability = try #require(ContractFixtures.json("capabilities.json")["response"]?["body"])
        let feature: AnnexJSON = .object(["version": .integer(1), "path": .string("/api/v1/mobile/agents/{agentId}/chat/events/{seq}?sessionId={sessionId}"),
            "maximumBytes": .integer(33_554_432), "approvalField": .string("reviewedDigest")])
        let harness = try await Harness.start { transport in
            await transport.setCapability("fullEvents", feature)
            await transport.setCapability("controlAuth", capability["controlAuth"] ?? .string("mtls-pinned-client"))
        }
        await harness.transport.setRead("chat", Harness.chatSnapshot(events: [preview()]))
        await harness.transport.setRead("fullEvent", try full(preview()))
        await harness.store.load(harness.target)
        return harness
    }
    private func approval(_ harness: Harness) throws -> CompanionApproval {
        try #require(harness.store.conversation(for: harness.target).items.compactMap { if case .approval(let value) = $0 { value } else { nil } }.first)
    }

    @Test func aSmallRequestCanStillBeAllowedAfterOneRejectedAllow() async throws {
        let harness = try await start(); defer { harness.stop() }
        guard case .object(var event) = preview(sequence: 9), case .object(var data)? = event["data"] else { throw AnnexTransportError.malformedResponse }
        data["requestId"] = .string("small"); data["truncated"] = nil; event["data"] = .object(data)
        await harness.transport.setRead("chat", Harness.chatSnapshot(events: [.object(event)]))
        await harness.store.load(harness.target, force: true)
        let request = try approval(harness)
        #expect(request.id == "small" && !request.isIncomplete)
        #expect(harness.store.canApprove(request, target: harness.target))
        await harness.transport.enqueue(.rejected(code: "command_busy", message: "Try again"))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        let pending = try approval(harness)
        #expect(pending.resolution == .pending)
        #expect(harness.store.canApprove(pending, target: harness.target))
        #expect(harness.store.fullReviewReason(pending, target: harness.target) == nil)
        await harness.store.respond(pending, option: pending.options[0], target: harness.target)
        #expect(await harness.transport.executed.count == 2)
    }

    @Test func incompleteRepresentationAloneRequiresReviewAndClearsWithConnectionInvalidation() async throws {
        let harness = try await start(); defer { harness.stop() }
        guard case .object(var event) = preview(sequence: 9), case .object(var data)? = event["data"] else { throw AnnexTransportError.malformedResponse }
        data["requestId"] = .string("small"); data["truncated"] = nil; event["data"] = .object(data)
        await harness.transport.setRead("chat", Harness.chatSnapshot(events: [.object(event)]))
        await harness.store.load(harness.target, force: true)
        var request = try approval(harness)
        await harness.transport.enqueue(.rejected(code: "incomplete_representation", message: "Review again"))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        request = try approval(harness)
        #expect(request.resolution == .pending)
        #expect(!harness.store.canApprove(request, target: harness.target))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        #expect(await harness.transport.executed.count == 1)
        await harness.transport.setRead("fullEvent", try full(.object(event)))
        let reference = try #require(request.eventReference)
        let fetched = try await harness.store.fetchFullEvent(reference, target: harness.target)
        #expect(!harness.store.canApprove(request, target: harness.target))
        #expect(harness.store.acknowledgeFullReview(fetched, reference: reference, target: harness.target))
        #expect(harness.store.canApprove(request, target: harness.target))
        await harness.transport.enqueue(.rejected(code: "incomplete_representation", message: "Changed again"))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        #expect(harness.store.fullReviewFailures[harness.target]?["small"] != nil)
        harness.store.apply(.resyncRequired(hostID: Harness.hostID))
        #expect(harness.store.fullReviewFailures[harness.target] == nil)
        await harness.store.load(harness.target, force: true)
        await harness.transport.enqueue(.rejected(code: "incomplete_representation", message: "Changed again"))
        request = try approval(harness)
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        #expect(harness.store.fullReviewFailures[harness.target]?["small"] != nil)
        await harness.transport.emit(.connection(.disconnected))
        try await harness.waitUntil { harness.host?.connection == .offline }
        #expect(harness.store.fullReviewFailures[harness.target] == nil)
    }

    @Test func transportIncompleteRefusalRetainsItsMachineCodeInTheService() async throws {
        let harness = try await start(); defer { harness.stop() }
        try await harness.loadSession()
        await harness.transport.enqueue(.thrown(.rejected(status: 409, code: "incomplete_representation", message: "Review this request again")))
        do {
            try await harness.service.respond(to: "small", optionID: "allow", target: harness.target, clientCommandID: "refused")
            Issue.record("Expected a review-required refusal")
        } catch CompanionServiceError.incompleteRepresentation(let message) {
            #expect(message == "Review this request again")
        }
    }

    @Test func canonicalCutPayloadsRetainSequenceSessionTruncationAndReplacementSemantics() throws {
        for name in ["chat-event-tool-call-preview.json", "chat-event-tool-output-preview.json"] {
            let event = try #require(ContractFixtures.json(name)["frame"]?["payload"]?["event"])
            var projector = CompanionChatProjector()
            projector.apply(event)
            guard case .tool(let tool)? = projector.items.first else { Issue.record("Missing tool"); continue }
            let reference = try #require(tool.cutEvents.first)
            #expect(reference.sequence == event["seq"]?.integer)
            #expect(reference.sessionID == event["sessionId"]?.string)
            #expect(reference.truncation == event["data"]?["truncated"])
            #expect(reference.event == event)
        }
        let event = try #require(ContractFixtures.json("chat-permission-incomplete.json")["pendingPermission"])
        var projector = CompanionChatProjector(); projector.apply(event, allowOlderPending: true)
        guard case .approval(let request)? = projector.items.first else { Issue.record("Missing permission"); return }
        #expect(request.isIncomplete)
        #expect(request.eventReference?.event == event)
    }

    @Test func fullFetchRequiresAcknowledgmentThenAllowsExactlyTheFetchedPendingRequest() async throws {
        let harness = try await start(); defer { harness.stop() }
        let request = try approval(harness)
        let reference = try #require(request.eventReference)
        #expect(!harness.store.canApprove(request, target: harness.target))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        #expect(await harness.transport.executed.isEmpty)
        let full = try await harness.store.fetchFullEvent(reference, target: harness.target)
        #expect(!harness.store.canApprove(request, target: harness.target), "Fetching alone isn't review acknowledgment")
        harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target)
        #expect(harness.store.canApprove(request, target: harness.target))
        await harness.store.respond(request, option: request.options[0], target: harness.target)
        let command = try #require(await harness.transport.executed.last)
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())["reviewedDigest"] == .string(digest))
    }

    @Test func changedRequestSessionAndDisconnectedDeviceInvalidateReview() async throws {
        let harness = try await start(); defer { harness.stop() }
        let request = try approval(harness)
        let reference = try #require(request.eventReference)
        let full = try await harness.store.fetchFullEvent(reference, target: harness.target)
        harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target)
        let changed = preview(sequence: 8, title: "Changed action")
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": changed]))))
        try await harness.waitUntil { harness.store.conversation(for: harness.target).lastSequence == 8 }
        let current = try approval(harness)
        #expect(!harness.store.canApprove(current, target: harness.target))
        #expect(await serviceErrorKind { try await harness.service.respond(to: "big", optionID: "ok", reviewedDigest: digest, target: harness.target, clientCommandID: "changed") } == .rejected)
        await harness.transport.emit(.connection(.disconnected))
        try await harness.waitUntil { harness.host?.connection == .offline }
        #expect(!harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target))
        #expect(!harness.store.canApprove(request, target: harness.target))
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func desktopRestartInvalidatesAnOpenReviewEvenWhenTheSamePendingPreviewReturns() async throws {
        let harness = try await start(); defer { harness.stop() }
        let request = try approval(harness)
        let reference = try #require(request.eventReference)
        let full = try await harness.store.fetchFullEvent(reference, target: harness.target)
        harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target)
        #expect(harness.store.canApprove(request, target: harness.target))
        await harness.transport.setEpoch("restarted")
        try await harness.refreshCatalog()
        await harness.store.load(harness.target, force: true)
        #expect(!harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target))
        #expect(!harness.store.canApprove(try approval(harness), target: harness.target))
        #expect(await serviceErrorKind { try await harness.service.respond(to: "big", optionID: "ok", reviewedDigest: digest, target: harness.target, clientCommandID: "restarted") } == .rejected)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func aNewSessionCannotReuseThePreviousSessionsFetchedRequest() async throws {
        let harness = try await start(); defer { harness.stop() }
        let request = try approval(harness)
        let reference = try #require(request.eventReference)
        let full = try await harness.store.fetchFullEvent(reference, target: harness.target)
        let restarted = Harness.chatEvent("s2", sequence: 1, type: "session_started", data: [:])
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": restarted]))))
        try await harness.waitUntil { harness.store.conversation(for: harness.target).sessionID == "s2" }
        #expect(!harness.store.acknowledgeFullReview(full, reference: reference, target: harness.target))
        #expect(!harness.store.canApprove(request, target: harness.target))
        #expect(await serviceErrorKind { try await harness.service.respond(to: "big", optionID: "ok", reviewedDigest: digest, target: harness.target, clientCommandID: "session-changed") } == .rejected)
    }

    @Test func overCapCannotBeAcknowledgedAndDenyStillOmitsDigest() async throws {
        let harness = try await start(); defer { harness.stop() }
        let request = try approval(harness)
        await harness.transport.failRead("fullEvent", .rejected(status: 413, code: "event_too_large"))
        await #expect(throws: AnnexTransportError.self) { try await harness.store.fetchFullEvent(#require(request.eventReference), target: harness.target) }
        #expect(!harness.store.canApprove(request, target: harness.target))
        await harness.store.respond(request, option: request.options[1], target: harness.target)
        let command = try #require(await harness.transport.executed.last)
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())["reviewedDigest"] == nil)
    }
}
