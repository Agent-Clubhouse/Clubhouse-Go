import Foundation
import CryptoKit
import Testing
@testable import ClubhouseTransport

private func fullFixture(_ name: String) throws -> AnnexJSON {
    let path = AnnexContract.directory.deletingLastPathComponent().appendingPathComponent("AnnexFullEvents").appendingPathComponent(name)
    return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: path))
}
private let reviewDigest = "sha256:" + String(repeating: "a", count: 64)
private func fullBody(sequence: Int64 = 7, request: String = "big", digest: String = reviewDigest, isPermission: Bool = true, payloadSize: Int = 400 * 1024) -> AnnexJSON {
    .object(["version": .integer(1), "agentId": .string("a"), "sessionId": .string("s"), "seq": .integer(sequence), "digest": .string(digest),
        "event": .object(["v": .integer(1), "agentId": .string("a"), "sessionId": .string("s"), "seq": .integer(sequence), "type": .string(isPermission ? "permission_request" : "tool_call"),
            "data": .object(["requestId": .string(request), "rawInput": .object(["content": .string(String(repeating: "y", count: payloadSize))])])])])
}
private func capabilitiesResponse() throws -> AnnexHTTPResponse {
    try AnnexContract.response(fullFixture("capabilities.json")["response"])
}
private func permission(_ id: String = "approve", agent: String = "a", session: String = "s", request: String = "big", digest: String = reviewDigest) throws -> AnnexCommand {
    let caps = try fullFixture("capabilities.json")["response"]?["body"]
    return .init(commandID: id, epoch: caps?["epoch"]?.string ?? "", kind: .permission(agentID: agent, sessionID: session, requestID: request, optionID: "ok", reviewedDigest: digest))
}

@MainActor struct FullEventTests {
    @Test func canonicalCapabilityAndPreviewsRetainTheFullReviewContract() throws {
        let caps = try JSONDecoder().decode(AnnexCapabilities.self, from: capabilitiesResponse().data)
        #expect(caps.supportsFullEvents)
        #expect(caps.fullEvents?.maximumBytes == AnnexFullEvent.maximumBytes)
        for file in ["chat-event-tool-call-preview.json", "chat-event-tool-output-preview.json"] {
            let frame = try #require(fullFixture(file)["frame"])
            let decoded = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(frame))
            #expect(decoded.payload?["event"] == frame["payload"]?["event"])
            #expect(decoded.payload?["event"]?["data"]?["truncated"]?["originalBytes"]?.integer != nil)
        }
    }

    // Response shape and security cases from desktop annex-server.test.ts, #3035.
    @Test func fetchThenApproveSendsOnlyTheDigestFetchedByThisTransport() async throws {
        let command = try permission()
        let receipt: AnnexJSON = .object(["version": .integer(1), "commandId": .string(command.commandID), "epoch": .string(command.epoch), "status": .string("completed"), "result": .object(["answered": .bool(true)])])
        let io = AnnexContractIO([try capabilitiesResponse(), .init(status: 200, data: try AnnexContract.encode(fullBody())), .init(status: 200, data: try AnnexContract.encode(receipt))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let full = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7)
        #expect(full.event["data"]?["rawInput"]?["content"]?.string?.count == 400 * 1024)
        #expect(full.sequence == 7 && full.sessionID == "s")
        let result = try await transport.execute(command)
        #expect(result.status == .completed)
        let requests = await io.requests
        #expect(requests[1].url?.path == "/api/v1/mobile/agents/a/chat/events/7")
        #expect(URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "sessionId", value: "s")])
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: #require(requests[2].httpBody))["reviewedDigest"] == .string(full.digest))
    }

    @Test func digestCannotMoveBetweenDevicesSessionsRequestsOrAgents() async throws {
        let io = AnnexContractIO([try capabilitiesResponse(), .init(status: 200, data: try AnnexContract.encode(fullBody())), try capabilitiesResponse()])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        _ = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7)
        let other = try await annexContractTransport(AnnexContractIO([try capabilitiesResponse()]))
        _ = try await other.read(.capabilities)
        for (device, command) in [(other, try permission("other-device")), (transport, try permission("session", session: "other")),
                                  (transport, try permission("request", request: "other")), (transport, try permission("agent", agent: "other")),
                                  (transport, try permission("digest", digest: "sha256:" + String(repeating: "b", count: 64)))] {
            do { _ = try await device.execute(command); Issue.record("Unbound review must be refused") }
            catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
        }
        #expect(await io.requests.count == 2)
        await transport.disconnect()
        _ = try await transport.read(.capabilities)
        do { _ = try await transport.execute(permission("after-disconnect")); Issue.record("Disconnected review must be gone") }
        catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
        #expect(await io.requests.count == 3)
    }

    @Test func mismatchedOrStillCutFullResponsesCannotBeReviewed() throws {
        for (agent, session, seq) in [("other", "s", Int64(7)), ("a", "other", 7), ("a", "s", 8)] {
            #expect(throws: AnnexTransportError.malformedResponse) {
                try AnnexFullEvent(data: AnnexContract.encode(fullBody()), agentID: agent, sessionID: session, sequence: seq)
            }
        }
        guard case .object(var body) = fullBody() else { return }
        body["digest"] = .string("wrong")
        #expect(throws: AnnexTransportError.malformedResponse) {
            try AnnexFullEvent(data: AnnexContract.encode(.object(body)), agentID: "a", sessionID: "s", sequence: 7)
        }
    }

    @Test func reviewsExpireAfterDisconnectOrDesktopEpochChange() async throws {
        for disconnect in [true, false] {
            let first = try capabilitiesResponse()
            let epoch = try permission().epoch
            var refreshed = try JSONDecoder().decode(AnnexJSON.self, from: first.data)
            if !disconnect, case .object(var fields) = refreshed { fields["epoch"] = .string("new-epoch"); refreshed = .object(fields) }
            let io = AnnexContractIO([first, .init(status: 200, data: try AnnexContract.encode(fullBody())), .init(status: 200, data: try AnnexContract.encode(refreshed))])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            _ = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7)
            if disconnect { await transport.disconnect() }
            _ = try await transport.read(.capabilities)
            let command = AnnexCommand(epoch: disconnect ? epoch : "new-epoch", kind: .permission(agentID: "a", sessionID: "s", requestID: "big", optionID: "ok", reviewedDigest: reviewDigest))
            do { _ = try await transport.execute(command); Issue.record("Expired review must be refused") }
            catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
            #expect(await io.requests.count == 3)
        }
    }

    @Test func fullReviewHasNoOldDesktopFallbackAndStillCutResponsesFailClosed() async throws {
        guard case .object(var fields) = try JSONDecoder().decode(AnnexJSON.self, from: capabilitiesResponse().data) else { return }
        fields["fullEvents"] = nil
        let io = AnnexContractIO([.init(status: 200, data: try AnnexContract.encode(.object(fields)))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        await #expect(throws: AnnexTransportError.unsupportedCapability("fullEvents")) {
            try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7)
        }
        #expect(await io.requests.count == 1)
        guard case .object(var body) = fullBody(), case .object(var event)? = body["event"], case .object(var payload)? = event["data"] else { return }
        payload["truncated"] = .object(["originalBytes": .integer(500_000)])
        event["data"] = .object(payload); body["event"] = .object(event)
        #expect(throws: AnnexTransportError.malformedResponse) {
            try AnnexFullEvent(data: AnnexContract.encode(.object(body)), agentID: "a", sessionID: "s", sequence: 7)
        }
    }

    @Test func isolatedCanonicalFixturesMatchTheirRecordedSourceHashes() throws {
        let source = try fullFixture("SOURCE.json")
        guard case .object(let files)? = source["sha256"] else { Issue.record("Missing provenance"); return }
        let root = AnnexContract.directory.deletingLastPathComponent().appendingPathComponent("AnnexFullEvents")
        for (name, hash) in files {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash.string)
            #expect(source["commits"]?[name]?.string?.count == 40)
        }
    }

    @Test func nonPermissionEventsDoNotCreateApprovalReviews() async throws {
        let io = AnnexContractIO([try capabilitiesResponse(), .init(status: 200, data: try AnnexContract.encode(fullBody(isPermission: false, payloadSize: 0)))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let full = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7)
        #expect(full.event["type"] == .string("tool_call"))
        do { _ = try await transport.execute(permission()); Issue.record("Tool fetch must not authorize a permission") }
        catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
        #expect(await io.requests.count == 2)
    }

    @Test func reviewCapacityIsBoundedAt128AndNewestFetchCanBeApproved() async throws {
        let epoch = try permission().epoch
        func digest(_ index: Int) -> String {
            let hex = String(index, radix: 16); return "sha256:" + String(repeating: "0", count: 64 - hex.count) + hex
        }
        func receipt(_ id: String) throws -> AnnexHTTPResponse {
            .init(status: 200, data: try AnnexContract.encode(.object(["version": .integer(1), "epoch": .string(epoch), "commandId": .string(id), "status": .string("completed")])))
        }
        var responses = [try capabilitiesResponse()]
        for index in 1...128 {
            responses.append(.init(status: 200, data: try AnnexContract.encode(fullBody(sequence: Int64(index), request: "r\(index)", digest: digest(index), payloadSize: 0))))
        }
        responses.append(try receipt("before-cap"))
        responses.append(.init(status: 200, data: try AnnexContract.encode(fullBody(sequence: 129, request: "r129", digest: digest(129), payloadSize: 0))))
        responses.append(try receipt("newest"))
        let io = AnnexContractIO(responses), transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        for index in 1...128 { _ = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: Int64(index)) }
        #expect(try await transport.execute(permission("before-cap", request: "r1", digest: digest(1))).status == .completed)
        _ = try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 129)
        do { _ = try await transport.execute(permission("old", request: "r1", digest: digest(1))); Issue.record("Overflow must not retain old reviews") }
        catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
        #expect(try await transport.execute(permission("newest", request: "r129", digest: digest(129))).status == .completed)
        #expect(await io.requests.count == 132)
    }

    @Test func overCapAndRevocationAreRefusalsAndNeverGrantAReview() async throws {
        for response in [AnnexHTTPResponse(status: 413, data: Data(#"{"error":"event_too_large","bytes":33554433,"maximumBytes":33554432}"#.utf8)),
                         AnnexHTTPResponse(status: 403, data: Data(#"{"error":"authorization_revoked"}"#.utf8))] {
            let io = AnnexContractIO([try capabilitiesResponse(), response])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            await #expect(throws: AnnexTransportError.self) { try await transport.fullEvent(agentID: "a", sessionID: "s", sequence: 7) }
            do { _ = try await transport.execute(permission()); Issue.record("Failed fetch cannot grant a review") }
            catch AnnexTransportError.rejected(409, "incomplete_representation", _) { }
            #expect(await io.requests.count == 2)
        }
        #expect(throws: AnnexTransportError.responseTooLarge) {
            try AnnexFullEvent(data: Data(repeating: 32, count: AnnexFullEvent.maximumBytes + 1), agentID: "a", sessionID: "s", sequence: 7)
        }
        let plain = AnnexCommand(epoch: "e", kind: .permission(agentID: "a", sessionID: "s", requestID: "r", optionID: "no"))
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: plain.encoded())["reviewedDigest"] == nil)
    }
}
