import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct CommandSizeTests {
    @Test func longQuestionKeysAreSentWithoutTrimmingOrTruncation() async throws {
        let answers: [String: AnnexJSON] = [
            "  Long question " + String(repeating: "x", count: 330) + "?  ": .string("main"),
            // Desktop's new ceiling counts UTF-16 units, not Swift Characters or UTF-8 bytes.
            String(repeating: "🦊", count: 32_768): .array([.string("main"), .string("dev")]),
        ]
        #expect(answers.keys.map(\.utf16.count).max() == 65_536)
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let epoch = try #require(caps?["body"]?["epoch"]?.string)
        let receipt: AnnexJSON = .object(["version": .integer(1), "commandId": .string("long-keys"),
                                          "epoch": .string(epoch), "status": .string("completed")])
        let io = AnnexContractIO([try AnnexContract.response(caps),
                                  AnnexHTTPResponse(status: 200, data: try AnnexContract.encode(receipt))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        _ = try await transport.execute(AnnexCommand(commandID: "long-keys", epoch: epoch,
            kind: .question(agentID: "a", sessionID: "s", requestID: "q", answers: answers)))
        let sent = try JSONDecoder().decode(AnnexJSON.self, from: #require(await io.requests.last?.httpBody))
        #expect(sent["answers"] == .object(answers))
        #expect(Set(sent["answers"].keys.map { Data($0.utf8) }) == Set(answers.keys.map { Data($0.utf8) }))
    }

    @Test(arguments: ["chat.send", "chat.question"])
    func encodedBodyLimitIncludesMultibyteTextAndJSONEscaping(type: String) async throws {
        let limit = 1_048_576
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let epoch = try #require(caps?["body"]?["epoch"]?.string)
        let receipt: AnnexJSON = .object(["version": .integer(1), "commandId": .string("boundary"),
                                          "epoch": .string(epoch), "status": .string("completed")])
        let io = AnnexContractIO([try AnnexContract.response(caps),
                                  AnnexHTTPResponse(status: 200, data: try AnnexContract.encode(receipt))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        func command(_ text: String) -> AnnexCommand {
            let kind: AnnexCommand.Kind = type == "chat.send"
                ? .send(agentID: "a", sessionID: "s", text: text)
                : .question(agentID: "a", sessionID: "s", requestID: "q", answers: ["é🦊\"\\\n": .string(text)])
            return AnnexCommand(commandID: "boundary", epoch: epoch, kind: kind)
        }
        // Non-ASCII characters and quotes, slashes, newlines and controls all affect encoded size.
        let prefix = String(repeating: "é🦊\"\\\n\u{0001}", count: 4096)
        let overhead = try command(prefix).encoded().count
        let text = prefix + String(repeating: "a", count: limit - overhead)
        let exact = command(text), over = command(text + "a")
        #expect(try exact.encoded().count == limit)
        #expect(try over.encoded().count == limit + 1)
        #expect((text + "a").utf8.count < limit, "A raw text estimate would miss the oversized encoded body")
        for _ in 0..<2 {
            await #expect(throws: AnnexTransportError.commandTooLarge) { try await transport.execute(over) }
        }
        #expect(await io.requests.count == 1, "Only the explicit capabilities read may use IO")
        #expect(AnnexDiagnosticFailure.classify(AnnexTransportError.commandTooLarge) == .tooLarge)

        // A local refusal neither poisons the idempotency record nor prevents an explicitly edited send.
        #expect(try await transport.execute(exact).status == .completed)
        let requests = await io.requests
        #expect(requests.count == 2)
        #expect(requests.last?.httpBody == (try exact.encoded()))
        #expect(requests.last?.httpMethod == "POST")
    }
}
