import Foundation
import Testing
@testable import ClubhouseTransport
import OpenTelemetryApi
import OpenTelemetrySdk

private final class DiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

@Test func diagnosticsDefaultOffAndNoRemoteExport() throws {
    let telemetry = AnnexTelemetry()
    telemetry.record(.pairing)
    #expect(!telemetry.snapshot().enabled)
    #expect(!telemetry.snapshot().remoteExportEnabled)
    #expect(telemetry.snapshot().records.isEmpty)
    #expect(telemetry.snapshot().dropped == 0)
}
@Test func diagnosticsCorrelateSDKSpansAndFenceOldGeneration() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let parent = telemetry.begin(.pairing)
    let child = telemetry.begin(.http, parent: parent); child.end(); parent.end()
    let records = telemetry.snapshot().records
    #expect(records.count == 2)
    #expect(records[0].traceID == records[1].traceID)
    #expect(records[0].parentID == records[1].id)
    let late = telemetry.begin(.http)
    telemetry.clear(); late.event(.connected); late.end()
    #expect(telemetry.snapshot().records.isEmpty)
    let disabled = telemetry.begin(.http)
    telemetry.setEnabled(false); disabled.end()
    #expect(telemetry.snapshot().records.isEmpty)
    telemetry.setEnabled(true); telemetry.record(.wake)
    #expect(telemetry.snapshot().records.count == 1)
}
@Test func diagnosticCapacityAndExportFailureStayBounded() throws {
    let telemetry = AnnexTelemetry(capacity: 3); telemetry.setEnabled(true)
    for _ in 0..<100 { telemetry.record(.http) }
    #expect(telemetry.snapshot().records.count == 3)
    #expect(telemetry.snapshot().dropped == 97)
    #expect(throws: AnnexTransportError.responseTooLarge) { try telemetry.exportJSON(maximumBytes: 1) }
    #expect(telemetry.snapshot().records.count == 3)
    #expect(try telemetry.exportJSON().count < 512 * 1024)
}
@Test func activeDiagnosticCapacityAndTimeout() {
    let clock = DiagnosticClock()
    let telemetry = AnnexTelemetry(clock: { clock.now() }); telemetry.setEnabled(true)
    let spans = (0..<200).map { _ in telemetry.begin(.connection) }
    #expect(telemetry.snapshot().dropped == 72)
    clock.advance(601)
    #expect(telemetry.snapshot().records.count == 128)
    #expect(telemetry.snapshot().records.allSatisfy { $0.failure == .timeout })
    spans.forEach { $0.end() }
    #expect(telemetry.snapshot().records.count == 128)
}
@Test func diagnosticsSanitizeErrorsAndDoNotStorePayloads() throws {
    let secret = "https://private-host:443/users/mason?token=secret prompt screenshot"
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let span = telemetry.begin(.http)
    span.fail(NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret]))
    span.number(.bytes, .infinity); span.number(.statusCode, -1); span.number(.responseBytes, 1e100)
    span.end()
    let record = try #require(telemetry.snapshot().records.first)
    #expect(record.failure == .unknown)
    #expect(record.measurements["bytes"] == nil)
    #expect(record.measurements["statusCode"] == 0)
    #expect(record.measurements["responseBytes"] == 1_000_000_000)
    let json = String(decoding: try telemetry.exportJSON(), as: UTF8.self)
    #expect(!json.contains(secret)); #expect(!json.contains("private-host"))
    #expect(AnnexLegacyDiagnostic.category(secret) == "Other")
    #expect(AnnexDiagnosticFailure.classify(AnnexTransportError.rejected(status: 503, code: secret)) == .server)
    #expect(AnnexDiagnosticFailure.classify(URLError(.timedOut)) == .timeout)
    #expect(AnnexDiagnosticFailure.classify(URLError(.serverCertificateUntrusted)) == .tls)
    #expect(AnnexDiagnosticFailure.classify(AnnexTransportError.trustRequired) == .trust)
}
@Test func diagnosticAsyncCancellationEndsScope() async {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    do { try await telemetry.measure(.media) { throw CancellationError() } }
    catch { #expect(error is CancellationError) }
    #expect(telemetry.snapshot().records.count == 1)
    #expect(telemetry.snapshot().records.first?.failure == .cancelled)
}
@Test func diagnosticTaskLocalParentIsScoped() async throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    await telemetry.measure(.wake) {
        await telemetry.measure(.http) {}
    }
    #expect(AnnexTelemetry.current == nil)
    let records = telemetry.snapshot().records
    #expect(records.count == 2)
    #expect(records[0].parentID == records[1].id)
}
@Test func streamDiagnosticsMeasureOnlyCountsAndLatency() throws {
    let clock = DiagnosticClock()
    let telemetry = AnnexTelemetry(clock: { clock.now() }); telemetry.setEnabled(true)
    let stream = AnnexStreamDiagnostic(telemetry: telemetry)
    clock.advance(0.25); stream.chunk(byteCount: 4)
    clock.advance(0.5); stream.chunk(byteCount: 6)
    clock.advance(0.1); stream.chunk(byteCount: 0)
    stream.finish(); stream.chunk(byteCount: 100); stream.finish(.server)
    let record = try #require(telemetry.snapshot().records.first)
    #expect(record.measurements["firstTokenMs"] == 250)
    #expect(record.measurements["maxInterChunkMs"] == 500)
    #expect(record.measurements["chunks"] == 2)
    #expect(record.measurements["bytes"] == 10)
    #expect(record.failure == .none)
    #expect(telemetry.snapshot().records.count == 1)
}
@Test func streamDiagnosticsStopOnCancellationAndOptOut() {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let stream = AnnexStreamDiagnostic(telemetry: telemetry)
    stream.finish(.cancelled)
    #expect(telemetry.snapshot().records.first?.failure == .cancelled)
    let pending = AnnexStreamDiagnostic(telemetry: telemetry)
    telemetry.setEnabled(false); pending.chunk(byteCount: 100); pending.finish()
    #expect(telemetry.snapshot().records.isEmpty)
}
@Test func exporterRejectsArbitrarySDKData() {
    let exporter = AnnexLocalSpanExporter(capacity: 2)
    let generation = exporter.configure(enabled: true)
    let provider = TracerProviderBuilder().build()
    let tracer = provider.get(instrumentationName: "malicious")
    let span = tracer.spanBuilder(spanName: "http").setAttribute(key: "capture.generation", value: generation).startSpan()
    span.setAttribute(key: "url.full", value: "https://private-host/secret")
    span.setAttribute(key: "failure", value: "raw secret")
    span.addEvent(name: "response body secret")
    span.end()
    if let readable = span as? ReadableSpan { _ = exporter.export(spans: [readable.toSpanData()], explicitTimeout: nil) }
    #expect(exporter.snapshot().records.count == 1)
    #expect(exporter.snapshot().records.first?.failure == .unknown)
    #expect(exporter.snapshot().records.first?.measurements.isEmpty == true)
    #expect(exporter.snapshot().records.first?.events.isEmpty == true)
    exporter.shutdown(explicitTimeout: nil)
    #expect(exporter.snapshot().records.isEmpty)
}
