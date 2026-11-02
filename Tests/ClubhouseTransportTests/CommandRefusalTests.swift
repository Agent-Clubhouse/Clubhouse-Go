import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct CommandRefusalTests {
    @Test func committedOversizeBytesAreDefiniteAcrossEpochsOnlyAt413AndNeverResent() async throws {
        let fixture = try AnnexContract.json("command-too-large.json")
        #expect(fixture["request"]?["requestBytes"]?.integer == 1_048_577)
        let response = try #require(fixture["response"])
        let status = Int(try #require(response["status"]?.integer))
        // Do not re-encode response.body: these are the desktop's exact recorded wire bytes.
        let bytes = Data(try #require(response["bodyBytes"]?.string).utf8)
        #expect(response["headers"]?["Content-Length"]?.string == String(bytes.count))
        let expected = try JSONDecoder().decode(AnnexCommandReceipt.self, from: bytes)
        #expect(status == 413 && expected.version == 1 && expected.status == .rejected)
        #expect(expected.commandId == nil && expected.error?.code == "too_large")

        let requestEpoch = "request-epoch-before-desktop-restart"
        #expect(expected.epoch != requestEpoch, "Exercise the narrow cross-epoch exception")
        var capabilities = try #require(try AnnexContract.json("capabilities.json")["response"]?["body"])
            .decode([String: AnnexJSON].self)
        capabilities["epoch"] = .string(requestEpoch)
        let caps = AnnexHTTPResponse(status: 200, data: try AnnexContract.encode(.object(capabilities)))
        for httpStatus in [status, 400] {
            let io = AnnexContractIO([caps, AnnexHTTPResponse(status: httpStatus, data: bytes)])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            // Only the response is oversized-fixture compatibility; Go preflights outgoing command bytes.
            let command = AnnexCommand(commandID: "fixture-too-large", epoch: requestEpoch, kind: .stop(agentID: "fixture"))
            for _ in 0..<2 {
                if httpStatus == status {
                    #expect(try await transport.execute(command) == expected)
                } else {
                    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)) {
                        try await transport.execute(command)
                    }
                }
            }
            #expect(await io.requests.count == 2, "Neither a definite refusal nor an unknown outcome resends")
        }
    }

    private func refusal(epoch: String, commandID: String? = nil) -> AnnexJSON {
        var body: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string(epoch), "status": .string("rejected"),
                                       "error": .object(["code": .string("too_large"), "message": .string("too_large")])]
        if let commandID { body["commandId"] = .string(commandID) }
        return .object(body)
    }

    @Test(arguments: [false, true])
    func idlessOversizeRefusalIsDefiniteAcrossEpochsAndCached(changedEpoch: Bool) async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let epoch = try #require(caps?["body"]?["epoch"]?.string)
        let body = refusal(epoch: changedEpoch ? "a-new-desktop-epoch" : epoch)
        let io = AnnexContractIO([try AnnexContract.response(caps),
                                  AnnexHTTPResponse(status: 413, data: try AnnexContract.encode(body))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let command = AnnexCommand(commandID: "too-large", epoch: epoch, kind: .interrupt(agentID: "a", sessionID: "s"))
        let receipt = try await transport.execute(command)
        #expect(receipt.status == .rejected && receipt.commandId == nil && receipt.error?.code == "too_large")
        #expect(receipt.epoch == body["epoch"]?.string)
        #expect(try await transport.execute(command) == receipt)
        #expect(await io.requests.count == 2, "The cached refusal cannot resend the same command")
    }

    @Test func crossEpochExceptionRequiresEveryFieldAndNeverResendsUnknownOutcomes() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let epoch = try #require(caps?["body"]?["epoch"]?.string)
        let base = refusal(epoch: "a-new-desktop-epoch")
        guard case .object(let fields) = base else { return }
        var cases: [(String, Int, AnnexJSON)] = [
            ("wrong HTTP status", 400, base), ("server failure", 500, base),
            ("mismatched command ID", 413, refusal(epoch: "a-new-desktop-epoch", commandID: "other")),
            ("matching ID does not get the new epoch exception", 413, refusal(epoch: "a-new-desktop-epoch", commandID: "test")),
        ]
        for (key, value) in [("version", AnnexJSON.integer(2)), ("status", .string("failed")), ("status", .string("completed")),
                             ("error", .object(["code": .string("busy"), "message": .string("busy")])), ("error", .null)] {
            var changed = fields; changed[key] = value
            cases.append(("wrong \(key): \(value)", 413, .object(changed)))
        }
        var noEpoch = fields; noEpoch.removeValue(forKey: "epoch")
        cases.append(("missing epoch remains malformed", 413, .object(noEpoch)))
        for (name, status, body) in cases {
            let io = AnnexContractIO([try AnnexContract.response(caps),
                                      AnnexHTTPResponse(status: status, data: try AnnexContract.encode(body))])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            let command = AnnexCommand(commandID: "test", epoch: epoch, kind: .interrupt(agentID: "a", sessionID: "s"))
            for _ in 0..<2 {
                await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "test"), "\(name)") {
                    try await transport.execute(command)
                }
            }
            #expect(await io.requests.count == 2, "\(name) must not resend")
        }
    }
}
