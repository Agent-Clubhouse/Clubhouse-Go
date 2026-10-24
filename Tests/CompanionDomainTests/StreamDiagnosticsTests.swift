import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@MainActor @Test func liveDiagnosticsDeduplicateReplayAndCloseOnDisconnect() {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let observer = CompanionStreamDiagnostics(telemetry: telemetry)
    let target = CompanionTarget(hostID: "private-host", projectID: "private-path", agentID: "agent")
    func event(_ sequence: Int64, _ type: String, text: String = "secret text") -> AnnexJSON {
        .object(["sessionId": .string("private-session"), "seq": .integer(sequence), "type": .string(type), "data": .object(["text": .string(text)])])
    }
    observer.receive(event(1, "turn_started"), target: target)
    observer.receive(event(2, "agent_message_chunk"), target: target)
    observer.receive(event(2, "agent_message_chunk"), target: target)
    observer.disconnect(hostID: target.hostID)
    observer.receive(event(1, "turn_started"), target: target)
    observer.receive(event(2, "agent_message_chunk"), target: target)
    observer.receive(event(3, "turn_ended"), target: target)
    #expect(telemetry.snapshot().records.count == 1)
    #expect(telemetry.snapshot().records.first?.measurements["chunks"] == 1)
    #expect(telemetry.snapshot().records.first?.failure == .connection)
    observer.receive(event(4, "turn_started"), target: target)
    observer.receive(event(5, "turn_ended"), target: target)
    #expect(telemetry.snapshot().records.count == 2)
    let json = String(decoding: try! telemetry.exportJSON(), as: UTF8.self)
    #expect(!json.contains("private-")); #expect(!json.contains("secret text"))
}

@MainActor @Test func liveTurnUsesOuterValidatedHostContextAndDoesNotLinkNextUnrelatedTurn() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let observer = CompanionStreamDiagnostics(telemetry: telemetry)
    let target = CompanionTarget(hostID: "host", projectID: "project", agentID: "agent")
    let context = try #require(AnnexTraceContext(traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"))
    func event(_ seq: Int64, _ type: String) -> AnnexJSON {
        .object(["sessionId": .string("session"), "seq": .integer(seq), "type": .string(type), "data": .object([:])])
    }
    observer.receive(event(1, "turn_started"), target: target, context: context)
    observer.receive(event(2, "turn_ended"), target: target)
    observer.receive(event(3, "turn_started"), target: target)
    observer.receive(event(4, "turn_ended"), target: target)
    let records = telemetry.snapshot().records
    #expect(records.count == 2)
    #expect(records[0].traceID == "0123456789abcdef0123456789abcdef")
    #expect(records[0].parentID == "0123456789abcdef")
    #expect(records[1].traceID != records[0].traceID)
}
