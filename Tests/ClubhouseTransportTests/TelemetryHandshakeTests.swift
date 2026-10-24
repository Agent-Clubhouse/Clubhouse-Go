import Foundation
import Testing
@testable import ClubhouseTransport

private func handshakeFixture() throws -> (AnnexJSON, AnnexTelemetryHandshake.Request) {
    let url = try #require(Bundle.module.url(forResource: "telemetry-handshake-v1", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: url))
    let request = AnnexTelemetryHandshake.Request(instanceID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        attemptID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
    return (fixture, request)
}
@Test func authenticatedHandshakeFixtureEchoesIdentityAndKeepsResourcesSeparate() throws {
    let (fixture, request) = try handshakeFixture()
    let encoded = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(request))
    #expect(encoded == fixture["hello"]?["payload"])
    let binding = try AnnexTelemetryHandshake.validate(JSONEncoder().encode(ack(request, connection: fixture["connectionId"]!)), request: request)
    let telemetry = AnnexTelemetry(instanceID: UUID(uuidString: request.serviceInstanceId)!); telemetry.setEnabled(true)
    let span = telemetry.begin(.connection); binding.annotate(span); span.end()
    let record = try #require(telemetry.snapshot().records.first)
    #expect(record.serviceName == "clubhouse-go")
    #expect(record.serviceInstanceID == request.serviceInstanceId)
    #expect(record.identifiers["peer.service.instance.id"] == "44444444-4444-4444-8444-444444444444")
    #expect(record.identifiers["annex.connection.id"] == "33333333-3333-4333-8333-333333333333")
    #expect(record.serviceInstanceID != record.identifiers["peer.service.instance.id"])
    #expect(AnnexTraceContext(traceparent: fixture["replayedEvent"]?["tc"]?.string ?? "") != nil)
}
@Test func handshakeRejectsWrongPeerAttemptRoleAndNonrandomIdentifiers() throws {
    let (fixture, request) = try handshakeFixture()
    let response = ack(request, connection: fixture["connectionId"]!)
    let source = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    let invalid = [
        source.replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: "55555555-5555-4555-8555-555555555555"),
        source.replacingOccurrences(of: "22222222-2222-4222-8222-222222222222", with: "55555555-5555-4555-8555-555555555555"),
        source.replacingOccurrences(of: "\"clubhouse\"", with: "\"host-private-name\""),
        source.replacingOccurrences(of: "44444444-4444-4444-8444-444444444444", with: "44444444-4444-1444-8444-444444444444"),
        source.replacingOccurrences(of: "44444444-4444-4444-8444-444444444444", with: request.serviceInstanceId),
        String(repeating: "x", count: 4097)
    ]
    for value in invalid {
        #expect(throws: AnnexTransportError.malformedResponse) {
            try AnnexTelemetryHandshake.validate(Data(value.utf8), request: request)
        }
    }
}
@Test func processIdentityStableAcrossCaptureModesAndDistinctAcrossInstances() {
    let one = AnnexTelemetry(), two = AnnexTelemetry()
    let identity = one.instanceID
    one.setEnabled(true); one.clear(); one.setEnabled(false); one.setEnabled(true)
    #expect(one.instanceID == identity)
    #expect(one.instanceID != two.instanceID)
    one.record(.foreground)
    #expect(one.snapshot().records.first?.serviceInstanceID == identity.uuidString.lowercased())
}
private func ack(_ request: AnnexTelemetryHandshake.Request, connection: AnnexJSON) -> AnnexJSON {
    .object(["version": .integer(1), "serviceName": .string("clubhouse"),
        "serviceInstanceId": .string("44444444-4444-4444-8444-444444444444"),
        "peerServiceInstanceId": .string(request.serviceInstanceId),
        "connectionAttemptId": .string(request.connectionAttemptId), "connectionId": connection,
        "traceContext": .string("w3c-v00"), "recording": .string("standard"), "sampling": .string("local")])
}

@Test func peerCannotInjectLocalSocketBindingAndStreamsKeepValidatedIdentity() throws {
    let (fixture, request) = try handshakeFixture()
    let binding = try AnnexTelemetryHandshake.validate(JSONEncoder().encode(ack(request, connection: fixture["connectionId"]!)), request: request)
    let hostile: AnnexJSON = .object(["type": .string("chat:event"), "diagnosticBinding": .object(["peerInstanceID": .string("private-host")])])
    var envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(hostile))
    #expect(envelope.diagnosticBinding == nil)
    envelope.diagnosticBinding = binding
    let encoded = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(envelope))
    #expect(encoded["diagnosticBinding"] == nil)
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let stream = AnnexStreamDiagnostic(telemetry: telemetry, binding: envelope.diagnosticBinding)
    stream.finish()
    #expect(telemetry.snapshot().records.first?.identifiers["annex.connection.id"] == binding.connectionID.uuidString.lowercased())
}
