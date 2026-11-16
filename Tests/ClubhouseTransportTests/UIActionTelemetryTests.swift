import Foundation
import Testing
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import ClubhouseTransport

@Test func uiActionsUseTheExistingCaptureGateAndBoundedRing() throws {
    let telemetry = AnnexTelemetry(capacity: 2)
    telemetry.recordAction(screen: .project, control: .newAgent)
    #expect(telemetry.snapshot().records.isEmpty)
    telemetry.setEnabled(true)
    for _ in 0..<3 { telemetry.recordAction(screen: .project, control: .newAgent) }
    #expect(telemetry.snapshot().records.count == 2)
    #expect(telemetry.snapshot().dropped == 1)
    let record = try #require(telemetry.snapshot().records.last)
    #expect(record.operation == .uiAction)
    #expect(record.uiAction == .init(screen: .project, control: .newAgent))
    #expect(record.identifiers.isEmpty && record.events.isEmpty && record.measurements.isEmpty)
    telemetry.setEnabled(false)
    telemetry.recordAction(screen: .agentSettings, control: .done)
    #expect(telemetry.snapshot().records.isEmpty)
}

@Test func enrolledUIActionsStopWhenEnrollmentEnds() {
    let telemetry = AnnexTelemetry()
    telemetry.setEnrolledCapture(true)
    telemetry.recordAction(screen: .agentSettings, control: .selectModel)
    #expect(telemetry.snapshot().records.count == 1)
    telemetry.setEnrolledCapture(false)
    telemetry.recordAction(screen: .agentSettings, control: .selectModel)
    #expect(!telemetry.isEnabled && telemetry.snapshot().records.isEmpty)
}

@Test func uiActionSignalsHaveClosedScreenAndControlAndNoIncidentSpan() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    telemetry.recordAction(screen: .agentSettings, control: .selectAccess)
    let record = try #require(telemetry.snapshot().records.last)
    let signals = AnnexAppTelemetry.signals(for: record)
    #expect(signals.count == 1)
    guard case let .log(event, severity, attributes, traceID, spanID) = try #require(signals.first) else {
        Issue.record("UI intent must map to one action log"); return
    }
    #expect(event == "app.action" && severity == .info)
    #expect(attributes == ["app.action.name": .string("uiAction"), "app.action.result": .string("accepted"),
                           "screen": .string("agentSettings"), "control": .string("selectAccess")])
    #expect(traceID == nil && spanID == nil)
    #expect(!AnnexAppTelemetry.exportsSpan(for: .uiAction))
}

@Test func uiActionRecordsRoundTripAndOldRecordsRemainReadable() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    telemetry.recordAction(screen: .project, control: .openTerminal)
    let record = try #require(telemetry.snapshot().records.last)
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(AnnexDiagnosticRecord.self, from: encoded).uiAction == record.uiAction)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "uiAction")
    legacy["operation"] = "navigation"
    let decoded = try JSONDecoder().decode(AnnexDiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.operation == .navigation && decoded.uiAction == nil)
    #expect(AnnexAppTelemetry.signals(for: decoded).count == 1)
}

@Test func uiActionVocabularyContainsOnlyStaticSemanticNames() throws {
    let names = AnnexUIAction.Screen.allCases.map(\.rawValue) + AnnexUIAction.Control.allCases.map(\.rawValue)
    let pattern = try NSRegularExpression(pattern: "^[a-z][a-zA-Z]*$")
    for name in names {
        #expect(name.count <= 64)
        #expect(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil)
    }
    #expect(AnnexUIAction.Screen(rawValue: "project/private-id") == nil)
    #expect(AnnexUIAction.Control(rawValue: "model:gpt-private") == nil)
}

@Test func dashboardCanCountTheSameControlSeparatelyByScreen() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    telemetry.recordAction(screen: .project, control: .openAgentSettings)
    telemetry.recordAction(screen: .project, control: .openAgentSettings)
    telemetry.recordAction(screen: .conversation, control: .openAgentSettings)
    var counts: [String: Int] = [:]
    for record in telemetry.snapshot().records {
        guard case let .log(event, _, attributes, _, _) = try #require(AnnexAppTelemetry.signals(for: record).first),
              event == "app.action", case let .string(screen) = attributes["screen"],
              case let .string(control) = attributes["control"] else {
            Issue.record("Every typed intent needs dashboard dimensions"); continue
        }
        counts[screen + "." + control, default: 0] += 1
    }
    #expect(counts == ["project.openAgentSettings": 2, "conversation.openAgentSettings": 1])
}

@Test func uiActionExporterRejectsUnknownAndPartialSDKAttributes() throws {
    let exporter = AnnexLocalSpanExporter(capacity: 8)
    let generation = exporter.configure(enabled: true)
    let provider = TracerProviderBuilder().build()
    let tracer = provider.get(instrumentationName: "untrusted")
    for (screen, control) in [("project", "newAgent"), ("secret/project", "newAgent"), ("project", "private-control"), ("project", "")] {
        let span = tracer.spanBuilder(spanName: "uiAction").setAttribute(key: "capture.generation", value: generation).startSpan()
        span.setAttribute(key: "ui.screen", value: screen)
        span.setAttribute(key: "ui.control", value: control)
        span.setAttribute(key: "project.id", value: "secret-project-id")
        span.end()
        if let readable = span as? ReadableSpan { _ = exporter.export(spans: [readable.toSpanData()], explicitTimeout: nil) }
    }
    let records = exporter.snapshot().records
    #expect(records.count == 4)
    #expect(records.first?.uiAction == .init(screen: .project, control: .newAgent))
    #expect(records.dropFirst().allSatisfy { $0.uiAction == nil && AnnexAppTelemetry.signals(for: $0).isEmpty })
    let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    #expect(!json.contains("secret") && !json.contains("private-control") && !json.contains("project.id"))
}
