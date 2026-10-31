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
    telemetry.begin(.httpTiming, parent: late).end()
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

@MainActor @Test func diagnosticSettingsPersistOnlyAlwaysAndNeverEnableRemote() throws {
    let suite = "diagnostics-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let telemetry = AnnexTelemetry()
    let settings = AnnexDiagnosticSettings(defaults: defaults, telemetry: telemetry)
    #expect(settings.mode == .off)
    settings.select(.session)
    #expect(telemetry.snapshot().enabled)
    #expect(AnnexDiagnosticSettings(defaults: defaults, telemetry: AnnexTelemetry()).mode == .off)
    settings.select(.always)
    #expect(AnnexDiagnosticSettings(defaults: defaults, telemetry: AnnexTelemetry()).mode == .always)
    #expect(!telemetry.snapshot().remoteExportEnabled)
    settings.select(.off)
    #expect(!telemetry.snapshot().enabled)
    #expect(telemetry.snapshot().records.isEmpty)
    #expect(AnnexDiagnosticSettings(defaults: defaults, telemetry: AnnexTelemetry()).mode == .off)
    defaults.set("unknown-future-mode", forKey: AnnexDiagnosticSettings.preferenceKey)
    #expect(AnnexDiagnosticSettings(defaults: defaults, telemetry: AnnexTelemetry()).mode == .off)
}

@Test func traceContextStrictValidationAndVendorStatePrivacy() throws {
    let good = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
    #expect(AnnexTraceContext(traceparent: good) != nil)
    let context = try #require(AnnexTraceContext(traceparent: good, tracestate: "az=opaque-vendor-data"))
    #expect(context.tracestate == nil)
    for bad in ["", "zz" + good.dropFirst(2), good.uppercased(), good + "-extra", good + "\r\nsecret", String(repeating: "x", count: 10000),
                "00-00000000000000000000000000000000-0123456789abcdef-01", "00-0123456789abcdef0123456789abcdef-0000000000000000-01"] {
        #expect(AnnexTraceContext(traceparent: bad) == nil)
    }
    for bad in ["az=one,az=two", "bad=value\r\nsecret", "az=", "=value", "az=" + String(repeating: "x", count: 513), "a=b=c", "a@=value"] {
        #expect(AnnexTraceContext(traceparent: good, tracestate: bad) == nil)
    }
}
@Test func traceHeadersRespectOptOutAndGenerationWithoutBaggage() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let span = telemetry.begin(.send)
    var request = URLRequest(url: URL(string: "https://example.invalid")!)
    request.setValue("secret", forHTTPHeaderField: "baggage")
    request.setValue("az=secret", forHTTPHeaderField: "tracestate")
    telemetry.inject(into: &request, span: span)
    let header = try #require(request.value(forHTTPHeaderField: "traceparent"))
    #expect(AnnexTraceContext(traceparent: header) != nil)
    #expect(request.value(forHTTPHeaderField: "baggage") == nil)
    #expect(request.value(forHTTPHeaderField: "tracestate") == nil)
    telemetry.clear()
    telemetry.inject(into: &request, span: span)
    #expect(request.value(forHTTPHeaderField: "traceparent") == nil)
    telemetry.setEnabled(false)
    request.setValue(header, forHTTPHeaderField: "traceparent")
    telemetry.inject(into: &request, span: span)
    #expect(request.value(forHTTPHeaderField: "traceparent") == nil)
}
@Test func remoteTurnContextCorrelatesWithoutLeakingStateOrLinkingUnrelatedTurns() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let remote = try #require(AnnexTraceContext(traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-00", tracestate: "az=secret"))
    AnnexStreamDiagnostic(telemetry: telemetry, remoteParent: remote).finish()
    AnnexStreamDiagnostic(telemetry: telemetry).finish()
    let records = telemetry.snapshot().records
    #expect(records.count == 2)
    #expect(records[0].traceID == "0123456789abcdef0123456789abcdef")
    #expect(records[0].parentID == "0123456789abcdef")
    #expect(records[1].traceID != records[0].traceID)
    #expect(!String(decoding: try telemetry.exportJSON(), as: UTF8.self).contains("secret"))
}

@Test func concurrentSpanCompletionKeepsRingBoundedAndEndsOnce() async {
    let telemetry = AnnexTelemetry(capacity: 20); telemetry.setEnabled(true)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 {
            group.addTask {
                let span = telemetry.begin(.http)
                span.number(.responseBytes, 123); span.end(); span.end()
            }
        }
    }
    #expect(telemetry.snapshot().records.count == 20)
    #expect(telemetry.snapshot().dropped == 80)
}

@Test func responseTraceMustMatchRequestTraceAndMalformedEnvelopeContextIsOptional() throws {
    let request = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
    let response = try #require(AnnexTraceContext(traceparent: "00-0123456789abcdef0123456789abcdef-aaaaaaaaaaaaaaaa-01"))
    #expect(response.belongsToRequest(request))
    #expect(!response.belongsToRequest("00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-0123456789abcdef-01"))
    #expect(!response.belongsToRequest(nil))
    let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: Data(#"{"type":"chat:event","payload":{},"tc":{"bad":"secret"}}"#.utf8))
    #expect(envelope.type == "chat:event")
    #expect(envelope.tc?.string == nil)
}

private struct RoutineFailure: Error {}

@Test func routinePingsAreCountedSoUsefulSpansSurviveTheRing() async throws {
    let clock = DiagnosticClock()
    let telemetry = AnnexTelemetry(capacity: 8, clock: { clock.now() }); telemetry.setEnabled(true)
    telemetry.record(.pairing)
    // A day of pings from one desktop (one every 20 s) would have filled the ring 500 times over.
    for _ in 0..<4320 { await telemetry.measureRoutine(.ping, slowMs: 1000) { clock.advance(0.05) } }
    let records = telemetry.snapshot().records
    #expect(records.map(\.operation) == [.pairing])
    #expect(telemetry.snapshot().dropped == 0)
    let summary = try #require(telemetry.drainSummaries().first)
    #expect(summary.operation == .ping && summary.count == 4320 && summary.slow == 0 && summary.failed == 0)
    #expect(abs(summary.meanMs - 50) < 0.001 && abs(summary.maxMs - 50) < 0.001)
    #expect(telemetry.drainSummaries().isEmpty) // drained
}
@Test func slowAndFailedRoutineRunsStillBecomeSpans() async throws {
    let clock = DiagnosticClock()
    let telemetry = AnnexTelemetry(clock: { clock.now() }); telemetry.setEnabled(true)
    let parent = telemetry.begin(.connection)
    await AnnexTelemetry.$current.withValue(parent) {
        await telemetry.measureRoutine(.ping, slowMs: 1000) { clock.advance(1.5) }
        await #expect(throws: URLError(.timedOut)) {
            try await telemetry.measureRoutine(.ping, slowMs: 1000) { clock.advance(0.01); throw URLError(.timedOut) }
        }
        await #expect(throws: RoutineFailure.self) {
            try await telemetry.measureRoutine(.ping, slowMs: 1000) { throw RoutineFailure() }
        }
    }
    parent.end()
    let pings = telemetry.snapshot().records.filter { $0.operation == .ping }
    #expect(pings.map(\.failure) == [.none, .timeout, .unknown])
    #expect(pings.allSatisfy { $0.parentID == telemetry.snapshot().records.last?.id })
    let summary = try #require(telemetry.drainSummaries().first)
    #expect(summary.count == 3 && summary.slow == 1 && summary.failed == 2 && abs(summary.maxMs - 1500) < 0.001)
}
@Test func routineSummariesNeedCaptureAndResetWithIt() async throws {
    let telemetry = AnnexTelemetry()
    await telemetry.measureRoutine(.ping, slowMs: 0) {}
    #expect(telemetry.drainSummaries().isEmpty && telemetry.snapshot().records.isEmpty)
    telemetry.setEnabled(true)
    await telemetry.measureRoutine(.ping, slowMs: 1000) {}
    telemetry.clear()
    #expect(telemetry.drainSummaries().isEmpty)
}
