import Foundation
import Testing
@testable import ClubhouseTransport

private actor MockOTLP: AnnexOTLPTransport {
    var result: AnnexOTLPResponse
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, rejected: Int = 0) { result = .init(status: status, rejectedSpans: rejected) }
    func send(_ request: URLRequest) -> AnnexOTLPResponse { requests.append(request); return result }
}
private final class ExportClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    func now() -> Double { lock.withLock { value } }
    func advance(_ value: Double) { lock.withLock { self.value += value } }
}
private func exportConfiguration() throws -> AnnexOTLPConfiguration {
    try .init(address: "https://collector.example.invalid/v1/traces")
}
@Test func OTLPConfigurationRefusesSecretsPlaintextAndWrongRoute() throws {
    for address in ["http://collector.invalid/v1/traces", "https://user:secret@collector.invalid/v1/traces", "https://collector.invalid/v1/traces?token=x", "https://collector.invalid/v1/traces#secret", "https://collector.invalid/reports", "InstrumentationKey=secret"] {
        #expect(throws: AnnexTransportError.invalidEndpoint) { try AnnexOTLPConfiguration(address: address) }
    }
    let config = try exportConfiguration()
    #expect(try JSONDecoder().decode(AnnexOTLPConfiguration.self, from: JSONEncoder().encode(config)) == config)
}
@Test func OTLPEncodingKeepsProcessAndTraceIdentityWithNoUnapprovedResources() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let root = telemetry.begin(.send), child = telemetry.begin(.http)
    root.end(); child.end()
    let data = try AnnexOTLPJSON.encode(telemetry.snapshot().records)
    let object = try JSONDecoder().decode(AnnexJSON.self, from: data)
    guard case .array(let resources) = object["resourceSpans"],
          case .array(let attrs) = resources[0]["resource"]?["attributes"],
          case .array(let scopes) = resources[0]["scopeSpans"],
          case .array(let spans) = scopes[0]["spans"] else { Issue.record("Invalid OTLP shape"); return }
    #expect(attrs.contains(.object(["key": .string("service.instance.id"), "value": .object(["stringValue": .string(telemetry.instanceID.uuidString.lowercased())])])))
    #expect(spans[0]["traceId"]?.string == telemetry.snapshot().records[0].traceID)
    #expect(spans[0]["startTimeUnixNano"]?.string != nil)
    #expect(attrs.count == 2)
}
@Test func OTLPRequiresConsentAndExcludesPreConsentRecords() async throws {
    let transport = MockOTLP(), telemetry = AnnexTelemetry()
    let exporter = AnnexOTLPExporter(transport: transport)
    telemetry.setEnabled(true); telemetry.record(.pairing)
    let config = try exportConfiguration()
    await exporter.flush(configuration: config, enabled: false, records: telemetry.snapshot().records)
    #expect(await transport.requests.isEmpty)
    await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
    #expect(await transport.requests.isEmpty)
    telemetry.record(.wake)
    await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
    #expect(await transport.requests.count == 1)
    #expect(await exporter.health().delivered == 1)
    await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
    #expect(await transport.requests.count == 1)
    let sent = try #require(await transport.requests.first)
    #expect(sent.url == config.endpoint)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(sent.value(forHTTPHeaderField: "traceparent") == nil)
    #expect(!String(decoding: sent.httpBody!, as: UTF8.self).contains("pairing"))
}
@Test func OTLPFailuresRetryBoundedlyAndPartialSuccessDoesNotRetry() async throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let clock = ExportClock(), transport = MockOTLP(status: 503)
    let exporter = AnnexOTLPExporter(transport: transport, now: { clock.now() })
    let config = try exportConfiguration()
    await exporter.flush(configuration: config, enabled: true, records: [])
    telemetry.record(.http)
    for _ in 0..<5 {
        await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
        clock.advance(301)
    }
    #expect(await transport.requests.count == 3)
    #expect(await exporter.health().dropped == 1)
    let partial = MockOTLP(rejected: 1)
    let receiver = AnnexOTLPExporter(transport: partial)
    await receiver.flush(configuration: config, enabled: true, records: [])
    await receiver.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
    await receiver.flush(configuration: config, enabled: true, records: telemetry.snapshot().records)
    #expect(await partial.requests.count == 1)
    #expect(await receiver.health().dropped == 1)
}
@MainActor @Test func destinationChangesNeedFreshConsentAndStayIndependentOfCapture() throws {
    let suite = "otlp-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let telemetry = AnnexTelemetry()
    let settings = AnnexDiagnosticSettings(defaults: defaults, telemetry: telemetry)
    #expect(settings.destination == nil); #expect(!settings.remoteEnabled)
    settings.setRemoteEnabled(true); #expect(!settings.remoteEnabled)
    try settings.configureDestination(address: "https://collector.example.invalid/v1/traces")
    settings.setRemoteEnabled(true); #expect(settings.remoteEnabled)
    #expect(settings.mode == .off)
    try settings.configureDestination(address: "https://other.example.invalid/v1/traces")
    #expect(!settings.remoteEnabled)
    settings.removeDestination(); #expect(settings.destination == nil)
    #expect(!telemetry.snapshot().remoteExportEnabled)
}

@Test func staleForegroundCleanupCannotCancelNewExporterSession() async throws {
    let transport = MockOTLP(), telemetry = AnnexTelemetry()
    telemetry.setEnabled(true)
    let exporter = AnnexOTLPExporter(transport: transport)
    let old = try #require(await exporter.beginSession())
    let new = try #require(await exporter.beginSession())
    await exporter.endSession(old)
    let config = try exportConfiguration()
    await exporter.flush(configuration: config, enabled: true, records: [], session: new)
    telemetry.record(.http)
    await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records, session: old)
    #expect(await transport.requests.isEmpty)
    await exporter.flush(configuration: config, enabled: true, records: telemetry.snapshot().records, session: new)
    #expect(await transport.requests.count == 1)
}

@Test func malformedOTLPAcknowledgementsNeverClaimDelivery() throws {
    let replies: [AnnexJSON] = [.null, .array([]), .object(["partialSuccess": .string("secret")]),
        .object(["partialSuccess": .object(["rejectedSpans": .string("not-a-number")])]),
        .object(["partialSuccess": .object(["rejectedSpans": .integer(-1)])])]
    for reply in replies {
        #expect(throws: AnnexTransportError.malformedResponse) { try AnnexOTLPHTTP.parseResponse(reply, status: 200) }
    }
    #expect(try AnnexOTLPHTTP.parseResponse(.object(["partialSuccess": .object(["rejectedSpans": .string("2"), "errorMessage": .string("private backend error")])]), status: 200).rejectedSpans == 2)
}
private actor HeldOTLP: AnnexOTLPTransport {
    private var continuation: CheckedContinuation<AnnexOTLPResponse, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    func wait() async { if continuation == nil { await withCheckedContinuation { arrived = $0 } } }
    func send(_ request: URLRequest) async -> AnnexOTLPResponse {
        await withCheckedContinuation { continuation = $0; arrived?.resume(); arrived = nil }
    }
    func release() { continuation?.resume(returning: .init(status: 200)); continuation = nil }
}
@Test func revokedExporterGenerationIgnoresLateSuccess() async throws {
    let transport = HeldOTLP(), exporter = AnnexOTLPExporter(transport: transport)
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let config = try exportConfiguration()
    await exporter.flush(configuration: config, enabled: true, records: [])
    telemetry.record(.wake)
    let records = telemetry.snapshot().records
    let pending = Task { await exporter.flush(configuration: config, enabled: true, records: records) }
    await transport.wait()
    await exporter.reset()
    await transport.release()
    await pending.value
    #expect(await exporter.health().delivered == 0)
}
