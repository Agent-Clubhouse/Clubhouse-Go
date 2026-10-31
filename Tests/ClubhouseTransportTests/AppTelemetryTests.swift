import Foundation
import Testing
@testable import ClubhouseTransport

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AnnexDiagnosticRecord] = []
    func add(_ record: AnnexDiagnosticRecord) { lock.withLock { values.append(record) } }
    var records: [AnnexDiagnosticRecord] { lock.withLock { values } }
}
private let peer = UUID().uuidString.lowercased()

private func record(_ operation: AnnexDiagnosticOperation, failure: AnnexDiagnosticFailure = .none, numbers: [AnnexDiagnosticNumber: Double] = [:],
                    events: [AnnexDiagnosticEvent] = [], telemetry: AnnexTelemetry = { let t = AnnexTelemetry(); t.setEnabled(true); return t }()) throws -> AnnexDiagnosticRecord {
    let span = telemetry.begin(operation)
    for (key, value) in numbers { span.number(key, value) }
    span.identifier(.peerInstanceID, UUID(uuidString: peer)!)
    for event in events { span.event(event) }
    if failure != .none { span.fail(failure) }
    span.end()
    return try #require(telemetry.snapshot().records.last)
}
private func spans(_ signals: [AnnexAppTelemetry.Signal]) -> [AnnexAppTelemetry.Span] {
    signals.compactMap { if case .span(let span) = $0 { span } else { nil } }
}
private func logs(_ signals: [AnnexAppTelemetry.Signal]) -> [(String, [String: AnnexAppTelemetry.Value])] {
    signals.compactMap { if case .log(let event, _, let attributes, _, _) = $0 { (event, attributes) } else { nil } }
}
/// Every string that would leave the device: names, keys and string values.
private func strings(_ signals: [AnnexAppTelemetry.Signal]) -> [String] {
    func values(_ attributes: [String: AnnexAppTelemetry.Value]) -> [String] {
        attributes.flatMap { key, value -> [String] in if case .string(let text) = value { [key, text] } else { [key] } }
    }
    return signals.flatMap { signal -> [String] in
        switch signal {
        case .span(let span): [span.name] + values(span.attributes) + span.events.map(\.name)
        case .log(let event, _, let attributes, _, _): [event] + values(attributes)
        case .counter(let name, let unit, _, let attributes), .histogram(let name, let unit, _, let attributes): [name, unit] + values(attributes)
        }
    }
}

@Test func recordsKeepEventTimesAndReachTheSinkOnlyWhileCapturing() throws {
    let telemetry = AnnexTelemetry()
    let collected = Collected()
    telemetry.setRecordSink { collected.add($0) }
    telemetry.record(.pairing)
    #expect(collected.records.isEmpty) // capture off: nothing recorded, nothing forwarded
    telemetry.setEnabled(true)
    let span = telemetry.begin(.stream)
    span.event(.firstToken); span.event(.gap); span.end()
    let forwarded = try #require(collected.records.first)
    #expect(forwarded.events == ["firstToken", "gap"])
    let offsets = try #require(forwarded.eventOffsetsMs)
    #expect(offsets.count == 2 && offsets.allSatisfy { $0 >= 0 && $0 <= forwarded.durationMs })
    telemetry.setRecordSink(nil)
    telemetry.record(.wake)
    #expect(collected.records.count == 1)
}

@Test func enrollmentCaptureIsSeparateFromTheUsersChoice() {
    let telemetry = AnnexTelemetry()
    telemetry.setEnrolledCapture(true)
    #expect(telemetry.isEnabled && telemetry.capturesForEnrollment)
    telemetry.record(.pairing)
    // Turning Connection diagnostics off keeps capturing for enrolled telemetry, without the old records.
    telemetry.setEnabled(false)
    #expect(telemetry.isEnabled && telemetry.snapshot().records.isEmpty)
    telemetry.record(.pairing)
    telemetry.clear()
    #expect(telemetry.isEnabled && telemetry.snapshot().records.isEmpty) // clear does not switch capture on or off
    // Disconnecting stops capture and forgets everything.
    telemetry.record(.pairing)
    telemetry.setEnrolledCapture(false)
    #expect(!telemetry.isEnabled && telemetry.snapshot().records.isEmpty && !telemetry.capturesForEnrollment)
    // With the user's own capture on, enrollment changes neither capture nor the retained records.
    telemetry.setEnabled(true); telemetry.record(.pairing)
    telemetry.setEnrolledCapture(true); telemetry.setEnrolledCapture(false)
    #expect(telemetry.isEnabled && telemetry.snapshot().records.count == 1)
}

@Test func flowsUseAppConventionsAndStandardNames() throws {
    let pairing = try record(.pairing, failure: .timeout)
    let signals = AnnexAppTelemetry.signals(for: pairing)
    let span = try #require(spans(signals).first)
    #expect(span.name == "app.flow" && span.spanID == pairing.id && span.traceID == pairing.traceID && span.failed)
    #expect(span.attributes["app.flow.name"] == .string("pair"))
    #expect(span.attributes["app.outcome"] == .string("timeout"))
    #expect(span.attributes["annex.operation"] == .string("pairing"))
    #expect(span.attributes["error.type"] == .string("timeout"))
    #expect(span.attributes[AnnexDiagnosticIdentifier.peerInstanceID.rawValue] == .string(peer))
    if case .string(let id) = span.attributes["app.flow.id"] { #expect(AnnexTelemetryHandshake.canonicalUUID(id) != nil) } else { Issue.record("no flow id") }
    let error = try #require(logs(signals).first { $0.0 == "app.error" })
    #expect(error.1["app.error.class"] == .string("timeout"))
    for (operation, flow) in [(AnnexDiagnosticOperation.connection, "connect"), (.reconnect, "reconnect"), (.restore, "restore"),
                              (.send, "chat_turn"), (.steer, "chat_turn"), (.queued, "chat_turn"), (.spawn, "spawn_agent"), (.createAgent, "spawn_agent")] {
        #expect(AnnexAppTelemetry.flowName(operation) == flow)
    }
    #expect(AnnexAppTelemetry.flowName(.http) == nil)
}

@Test func httpSpansMapStatusCodesAndKeepEvents() throws {
    let http = try record(.http, numbers: [.statusCode: 503, .responseBytes: 120, .firstByteMs: 41.5], events: [.authenticated])
    let span = try #require(spans(AnnexAppTelemetry.signals(for: http)).first)
    #expect(span.name == "http" && span.kind == 3)
    #expect(span.attributes["http.response.status_code"] == .int(503))
    #expect(span.attributes["annex.responseBytes"] == .int(120))
    #expect(span.attributes["annex.firstByteMs"] == .double(41.5))
    #expect(span.attributes["statusCode"] == nil)
    #expect(span.events.map(\.name) == ["authenticated"])
    #expect(span.events.allSatisfy { $0.time >= span.start && $0.time <= span.end })
}

@Test func actionsLifecycleAndMetrics() throws {
    let interrupt = AnnexAppTelemetry.signals(for: try record(.interrupt, failure: .outcomeUnknown))
    let action = try #require(logs(interrupt).first { $0.0 == "app.action" })
    #expect(action.1["app.action.name"] == .string("interrupt") && action.1["app.action.result"] == .string("outcome_unknown"))
    // Cancelling is not an error.
    #expect(!logs(AnnexAppTelemetry.signals(for: try record(.send, failure: .cancelled))).contains { $0.0 == "app.error" })

    let background = AnnexAppTelemetry.signals(for: try record(.background))
    #expect(spans(background).isEmpty)
    #expect(logs(background).first?.0 == "app.lifecycle" && logs(background).first?.1["app.lifecycle.state"] == .string("background"))
    #expect(AnnexAppTelemetry.signals(for: try record(.appLaunch)).isEmpty)
    #expect(logs(AnnexAppTelemetry.signals(for: try record(.settings))).first?.0 == "app.action")

    let stream = AnnexAppTelemetry.signals(for: try record(.stream, numbers: [.firstTokenMs: 820], events: [.firstToken]))
    #expect(stream.contains(.histogram(name: "app.first_token.duration", unit: "ms", value: 820, attributes: [:])))
    let reconnect = AnnexAppTelemetry.signals(for: try record(.reconnect))
    #expect(reconnect.contains(.counter(name: "app.reconnects", unit: "{reconnect}", value: 1, attributes: ["app.outcome": .string("ok")])))
}

@Test func pingSummaryBecomesAPerformanceSummaryAndCounter() {
    let summary = AnnexDiagnosticSummary(operation: .ping, count: 180, slow: 2, failed: 1, totalMs: 9000, maxMs: 1400)
    let signals = AnnexAppTelemetry.signals(for: summary)
    let log = logs(signals).first
    #expect(log?.0 == "app.performance.summary")
    #expect(log?.1["app.performance.kind"] == .string("ping") && log?.1["count"] == .int(180) && log?.1["mean_ms"] == .double(50))
    #expect(log?.1["over_threshold"] == .int(2) && log?.1["max_ms"] == .double(1400))
    #expect(signals.contains(.counter(name: "app.pings", unit: "{ping}", value: 179, attributes: ["app.outcome": .string("ok")])))
    #expect(signals.contains(.counter(name: "app.pings", unit: "{ping}", value: 1, attributes: ["app.outcome": .string("error")])))
    #expect(AnnexAppTelemetry.signals(for: AnnexDiagnosticSummary(operation: .ping, count: 0, slow: 0, failed: 0, totalMs: 0, maxMs: 0)).isEmpty)
}

@Test func noUserContentCanLeaveThroughTheMapping() throws {
    // Every operation, failure and event: every string is a fixed name, an enum raw value or a UUID.
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    var all: [AnnexAppTelemetry.Signal] = []
    for operation in AnnexDiagnosticOperation.allCases {
        all += AnnexAppTelemetry.signals(for: try record(operation, failure: .server, numbers: [.statusCode: 500, .firstTokenMs: 10],
                                                          events: [.found, .gap], telemetry: telemetry))
    }
    all += AnnexAppTelemetry.signals(for: AnnexDiagnosticSummary(operation: .ping, count: 1, slow: 0, failed: 0, totalMs: 1, maxMs: 1))
    let allowed = try NSRegularExpression(pattern: "^([a-z][a-zA-Z0-9_.]*|\\{[a-z]+\\}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
    for text in strings(all) {
        #expect(allowed.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil, "\(text)")
        #expect(!text.contains("/") && !text.contains("@") && !text.contains(":") && text.count <= 64, "\(text)")
    }
    #expect(AnnexAppTelemetry.commonAttributes == ["app.telemetry.schema_version": .int(1), "app.platform": .string("ios")])
}
