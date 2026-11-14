import CryptoKit
import Foundation
import Testing

@testable import ClubhouseTransport

@MainActor struct AnnexContractChatPagesWireTests {
    @Test func recordedFullEventFetchBindsTheReviewedPermissionDigest() async throws {
        let fixture = try AnnexContract.json("chat-full-event.json")
        let fetch = try #require(fixture["fetch"])
        let body = try #require(fetch["response"]?["body"])
        let agent = try #require(body["agentId"]?.string)
        let session = try #require(body["sessionId"]?.string)
        let sequence = try #require(body["seq"]?.integer)
        let capabilities = try AnnexContract.json("capabilities.json")["response"]?["body"]
        let request = try #require(fixture["approveWithDigest"]?["request"])
        let command = AnnexCommand(commandID: "fixture-review", epoch: try #require(capabilities?["epoch"]?.string),
                                   kind: .permission(agentID: agent, sessionID: session,
                                                     requestID: try #require(request["requestId"]?.string),
                                                     optionID: try #require(request["optionId"]?.string),
                                                     reviewedDigest: try #require(request["reviewedDigest"]?.string)))
        guard case .object(var receipt)? = fixture["approveWithDigest"]?["response"]?["body"] else {
            Issue.record("Missing recorded approval receipt")
            return
        }
        receipt["epoch"] = .string(command.epoch)
        receipt["commandId"] = .string(command.commandID)
        let io = AnnexContractIO([
            try AnnexContract.response(AnnexContract.json("capabilities.json")["response"]),
            try AnnexContract.response(fetch["response"]),
            .init(status: 200, data: try AnnexContract.encode(.object(receipt)))
        ])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let full = try await transport.fullEvent(agentID: agent, sessionID: session, sequence: sequence)
        #expect(full.event == body["event"] && full.digest == request["reviewedDigest"]?.string)
        #expect(try await transport.execute(command).status == .completed)
        let requests = await io.requests
        #expect(requests[1].url?.path == "/api/v1/mobile/agents/durable_chat/chat/events/8")
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: #require(requests[2].httpBody))["reviewedDigest"] == .string(full.digest))
    }

    @Test func completePageEventsDecodeLosslesslyAndDeduplicateThroughTheRealCursor() throws {
        let pages = try AnnexContract.json("chat-pages.json")
        let forms = try #require(pages["smallestForms"])
        let events = try [
            pages["omittedQuestion"]?["event"], pages["queuedRowShortened"]?["event"],
            forms["questionResolved"], forms["permissionResolved"], forms["userMessage"],
        ].map { try #require($0) }
        for event in events {
            let wire: AnnexJSON = .object([
                "type": .string("chat:event"), "seq": .integer(1),
                "payload": .object(["agentId": .string("durable_chat"), "event": event]),
            ])
            let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(wire))
            #expect(envelope.payload?["event"] == event)
            var cursor = AnnexReplayCursor()
            #expect(cursor.accept(.init(type: "snapshot", lastSeq: 0)) == .deliver)
            #expect(cursor.accept(envelope) == .deliver)
            #expect(cursor.accept(envelope) == .duplicate)
            #expect(cursor.lastSequence == 1)
        }
    }

    @Test func pageOverflowIsAnExplicitHTTPFailureWithTheDesktopSentence() async throws {
        let overflow = try #require(AnnexContract.json("chat-pages.json")["overflow"])
        let io = AnnexContractIO([try AnnexContract.response(overflow)])
        let transport = try await annexContractTransport(io)
        do {
            _ = try await transport.read(.chat(agentID: "durable_chat"))
            Issue.record("Overflow must not decode as an empty successful page")
        } catch let error as AnnexTransportError {
            #expect(error == .rejected(status: 503, code: "pending_overflow", message: overflow["body"]?["message"]?.string))
        }
    }

    @Test func syncedIconFixturesPreserveTheIndependentlyPinnedIconContract() throws {
        let root = AnnexContract.directory.deletingLastPathComponent().appendingPathComponent("IconRefs")
        let source = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent("SOURCE.json")))
        let syncedSource = try AnnexContract.json("SOURCE.json")
        #expect(source["commit"]?.string == "8bd00f0cf2f40d75af153c49b8e4485726eaeee9")
        #expect(syncedSource["commit"]?.string == "7b9425f1f1b6f028541d99ee2908c2a945e49edd")
        guard case .object(let hashes)? = source["files"] else {
            Issue.record("Missing icon fixture hashes")
            return
        }
        #expect(hashes.count == 6)
        for (file, hash) in hashes {
            let pinned = try Data(contentsOf: root.appendingPathComponent(file))
            let synced = try AnnexContract.data(file)
            #expect(SHA256.hash(data: pinned).map { String(format: "%02x", $0) }.joined() == hash.string)
            if file == "capabilities.json" {
                let old = try JSONDecoder().decode(AnnexJSON.self, from: pinned)
                let current = try JSONDecoder().decode(AnnexJSON.self, from: synced)
                let icons = try #require(old["response"]?["body"]?["iconRefs"])
                #expect(current["response"]?["body"]?["iconRefs"] == icons)
            } else {
                #expect(synced == pinned, "\(file) changed from the pinned icon contract")
            }
        }
    }
}
