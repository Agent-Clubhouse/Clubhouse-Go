import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct AnnexContractTerminalReattachTests {
    @Test func recordedReattachRequestsAndRepliesMatchThePhoneWireFormat() throws {
        let cases = try AnnexContract.cases("pty-reattach.json")
        #expect(cases.count == 7)
        let request = try #require(cases.first { $0["name"]?.string == "reattach" }?["request"])
        let payload = try #require(request["payload"])
        let frame = AnnexTerminalFrame.reattachShell(
            sessionID: try #require(payload["sessionId"]?.string),
            cols: Int(try #require(payload["cols"]?.integer)),
            rows: Int(try #require(payload["rows"]?.integer)))
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: frame.encoded()) == request)

        var acknowledgements = 0
        var errors: Set<String> = []
        for item in cases {
            let replies = item["replies"].list
            #expect(replies.count == 1, "\(item["name"]?.string ?? "")")
            for raw in replies {
                let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(raw))
                #expect(AnnexTransport.isTerminalFrame(envelope))
                #expect(envelope.payload == raw["payload"])
                #expect(AnnexTerminalFrame.id(of: envelope) == raw["payload"]?["sessionId"]?.string)
                switch envelope.type {
                case "pty:reattach-shell:ack":
                    acknowledgements += 1
                    let buffer = try #require(envelope.payload?["buffer"]?.string)
                    let sequence = try #require(envelope.payload?["outputSeq"]?.integer)
                    #expect(buffer == "\u{001B}[1mready\u{001B}[0m\r\n$ " && sequence == 42)
                    #expect(envelope.payload?["cwd"]?.string == "/work/app")
                    #expect(envelope.payload?["cols"]?.integer == 120 && envelope.payload?["rows"]?.integer == 40)
                    #expect(AnnexTerminalOutput.unseen(buffer, outputSeq: sequence, snapshotSeq: sequence) == nil)
                    #expect(AnnexTerminalOutput.unseen("!", outputSeq: sequence + 1, snapshotSeq: sequence) == "!")
                case "error":
                    let code = try #require(envelope.payload?["code"]?.string)
                    #expect(envelope.payload?["op"]?.string == "pty:reattach-shell")
                    #expect(envelope.payload?["message"]?.string == code)
                    if code == "session_exited" { #expect(envelope.payload?["exitCode"]?.integer == 130) }
                    errors.insert(code)
                default:
                    Issue.record("Unexpected recorded reattach reply: \(envelope.type)")
                }
            }
        }
        #expect(acknowledgements == 2)
        #expect(errors == Set(["session_in_use", "session_not_found", "invalid_session_id", "session_exited", "session_expired"]))
    }
}
