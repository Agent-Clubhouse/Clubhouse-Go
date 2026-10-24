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
    #expect(encoded == fixture["request"])
    let binding = try AnnexTelemetryHandshake.validate(JSONEncoder().encode(fixture["response"]!), request: request)
    let telemetry = AnnexTelemetry(instanceID: UUID(uuidString: request.service.instanceId)!); telemetry.setEnabled(true)
    let span = telemetry.begin(.connection); binding.annotate(span); span.end()
    let record = try #require(telemetry.snapshot().records.first)
    #expect(record.serviceName == "clubhouse-go")
    #expect(record.serviceInstanceID == request.service.instanceId)
    #expect(record.identifiers["peer.service.instance.id"] == "33333333-3333-4333-8333-333333333333")
    #expect(record.identifiers["annex.connection.id"] == "44444444-4444-4444-8444-444444444444")
    #expect(record.serviceInstanceID != record.identifiers["peer.service.instance.id"])
    #expect(AnnexTraceContext(traceparent: fixture["turnEnvelope"]?["tc"]?.string ?? "") != nil)
}
@Test func handshakeRejectsWrongPeerAttemptRoleAndNonrandomIdentifiers() throws {
    let (fixture, request) = try handshakeFixture()
    let response = try #require(fixture["response"])
    let source = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    let invalid = [
        source.replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: "55555555-5555-4555-8555-555555555555"),
        source.replacingOccurrences(of: "22222222-2222-4222-8222-222222222222", with: "55555555-5555-4555-8555-555555555555"),
        source.replacingOccurrences(of: "\"clubhouse\"", with: "\"host-private-name\""),
        source.replacingOccurrences(of: "33333333-3333-4333-8333-333333333333", with: "33333333-3333-1333-8333-333333333333"),
        source.replacingOccurrences(of: "33333333-3333-4333-8333-333333333333", with: request.service.instanceId),
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
@Test func absentOrMalformedOptionalTelemetryKeepsLegacyCapabilitiesDecodable() throws {
    let base = #"{"version":1,"epoch":"test","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"idempotency":{"scope":"peer","maxEntries":10,"ttlMs":1000}}"#
    for suffix in ["", #","telemetry":false"#] {
        let json = String(base.dropLast()) + suffix + "}"
        let caps = try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8))
        #expect(caps.controlAvailable == true)
        #expect(caps.telemetry == nil)
    }
}
