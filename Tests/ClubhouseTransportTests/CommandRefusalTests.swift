import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct CommandRefusalTests {
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
