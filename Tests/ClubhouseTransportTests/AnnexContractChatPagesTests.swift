import CryptoKit
import Foundation
import Testing

@testable import ClubhouseTransport

@MainActor struct AnnexContractChatPagesWireTests {
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

    @Test func syncedIconFixturesMatchEveryPinnedByteAndSourceCommit() throws {
        let root = AnnexContract.directory.deletingLastPathComponent().appendingPathComponent("IconRefs")
        let source = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent("SOURCE.json")))
        let syncedSource = try AnnexContract.json("SOURCE.json")
        #expect(source["commit"] == syncedSource["commit"])
        #expect(syncedSource["commit"]?.string == "7a00c822f45da68c2e1e634c727aef3156aeb961")
        guard case .object(let hashes)? = source["files"] else {
            Issue.record("Missing icon fixture hashes")
            return
        }
        #expect(hashes.count == 6)
        for (file, hash) in hashes {
            let pinned = try Data(contentsOf: root.appendingPathComponent(file))
            let synced = try AnnexContract.data(file)
            #expect(synced == pinned, "\(file) changed from the pinned icon contract")
            #expect(SHA256.hash(data: synced).map { String(format: "%02x", $0) }.joined() == hash.string)
        }
    }
}
