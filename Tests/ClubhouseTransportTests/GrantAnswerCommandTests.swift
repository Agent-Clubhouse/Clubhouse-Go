import Foundation
import Testing
@testable import ClubhouseTransport

/// `grant.answer` (grant requests v1): the command the phone sends to answer a Clubhouse grant request.
@Suite struct GrantAnswerCommandTests {
    @Test(arguments: AnnexCommand.GrantAnswer.allCases) func encodesTheRequestAndAnswerOnly(_ answer: AnnexCommand.GrantAnswer) throws {
        let command = AnnexCommand(commandID: "cmd_1", epoch: "e", kind: .answerGrant(requestID: "grant_1", answer: answer))
        #expect(command.type == "grant.answer" && command.agentReference == nil && command.diagnosticOperation == .grantRequest)
        let sent = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
        #expect(sent == .object(["version": .integer(1), "commandId": .string("cmd_1"), "epoch": .string("e"), "type": .string("grant.answer"),
                                 "requestId": .string("grant_1"), "answer": .string(answer.rawValue)]))
    }

    @Test func aRetryIsByteForByteTheSameCommand() throws {
        let first = AnnexCommand(commandID: "cmd_1", epoch: "e", kind: .answerGrant(requestID: "grant_1", answer: .allowOnce))
        let retry = AnnexCommand(commandID: "cmd_1", epoch: "e", kind: .answerGrant(requestID: "grant_1", answer: .allowOnce))
        #expect(try first.encoded() == retry.encoded())
    }

    @Test func refusesAnEmptyOrOversizedRequestID() {
        for id in ["", String(repeating: "g", count: 257)] {
            #expect(throws: AnnexTransportError.malformedResponse) {
                try AnnexCommand(commandID: "c", epoch: "e", kind: .answerGrant(requestID: id, answer: .decline)).encoded()
            }
        }
    }

    @Test func theCapabilityNeedsTheCommandAndVersionOne() throws {
        func caps(commands: [String], block: AnnexJSON?) throws -> AnnexCapabilities {
            var body: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("e"), "controlAuth": .string("mtls-pinned-client"),
                                             "commands": .array(commands.map(AnnexJSON.string)),
                                             "idempotency": .object(["scope": .string("peer-and-epoch"), "ttlMs": .integer(1), "maxEntries": .integer(1)])]
            if let block { body["grantRequests"] = block }
            return try AnnexJSON.object(body).decode(AnnexCapabilities.self)
        }
        let v1: AnnexJSON = .object(["version": .integer(1)])
        #expect(try caps(commands: ["grant.answer"], block: v1).supportsGrantRequests)
        #expect(try caps(commands: ["grant.answer"], block: v1).grantRequests?.snapshotField == "grantRequests")
        #expect(try !caps(commands: [], block: v1).supportsGrantRequests)
        #expect(try !caps(commands: ["grant.answer"], block: nil).supportsGrantRequests)
        #expect(try !caps(commands: ["grant.answer"], block: .object(["version": .string("1")])).supportsGrantRequests)
    }
}
