import Testing
import Foundation
@testable import ClubhouseGo
import ClubhouseTransport
import Framebriar
import FramebriarUI

/// Framebriar telemetry with mocks only: nothing reaches the live service.
@MainActor @Suite(.serialized) struct CompanionTelemetryTests {
    private let config = try! Configuration(gameID: "phone-ui-fixture")

    private func compose(_ network: TelemetryMockTransport) throws -> (Client, FeedbackModel, CompanionTelemetry, AnnexTelemetry) {
        let client = try Client(configuration: config, transport: network, enrollmentStore: TelemetryMemoryEnrollment(), feedbackStore: TelemetryMemoryQueue())
        let source = AnnexTelemetry()
        let parts = CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        return (client, parts.model, try #require(parts.telemetry), source)
    }

    @Test func oneSessionIDForFeedbackTelemetryAndIncidents() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        let id = source.instanceID.uuidString.lowercased()
        #expect(FramebriarSession.id == id)
        #expect(bridge.telemetry.sessionID == id)
        #expect(model.telemetry === bridge.telemetry)
        #expect(try ReviewedFeedback(configuration: config, notes: "fixture").sessionID == id)
        #expect(CompanionFeedback.snapshotIncident(telemetry: source)?.phoneInstanceId == id)
    }

    @Test func nothingIsRecordedOrSentBeforeEnrollmentOrAfterDisconnect() async throws {
        let network = TelemetryMockTransport()
        let (client, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        bridge.start(metricKit: false)
        await model.setActive(true)
        // Not enrolled: the diagnostics aren't even captured, and the emitter is a no-op.
        #expect(!source.isEnabled && !bridge.telemetry.isEnabled)
        source.record(.pairing)
        #expect(source.snapshot().records.isEmpty)
        #expect(await bridge.telemetry.flush() == false)
        #expect(await network.telemetryPaths.isEmpty)

        await model.connect(String(repeating: "i", count: 43))
        #expect(source.isEnabled && bridge.telemetry.isEnabled)
        let pairing = source.begin(.pairing)
        pairing.identifier(.peerInstanceID, UUID()); pairing.event(.found); pairing.end()
        await source.measureRoutine(.ping, slowMs: 1000) {}
        bridge.tick(force: true)
        #expect(await bridge.telemetry.flush())
        let traces = try #require(await network.bodies(for: "traces").first)
        let span = try #require(spans(traces).first { $0["name"] as? String == "app.flow" })
        #expect(span["spanId"] as? String == source.snapshot().records.first?.id)
        #expect((span["events"] as? [[String: Any]])?.first?["name"] as? String == "found")
        #expect(attributes(span)["app.flow.name"] as? String == "pair")
        #expect(attributes(span)["app.telemetry.schema_version"] as? String == "1")
        #expect(attributes(span)["app.platform"] as? String == "ios")
        #expect(!spans(traces).contains { $0["name"] as? String == "ping" }) // counted, not a span
        let logs = try #require(await network.bodies(for: "logs").first)
        #expect(logBodies(logs).contains("app.session.start") && logBodies(logs).contains("app.performance.summary"))

        // Disconnect: capture stops, the buffer is forgotten and nothing more is sent.
        await model.disconnect()
        try await waitUntil { !source.isEnabled }
        #expect(!bridge.telemetry.isEnabled && source.snapshot().records.isEmpty)
        let sent = await network.telemetryPaths.count
        source.record(.reconnect)
        bridge.telemetry.log(.info, "app.lifecycle")
        #expect(await bridge.telemetry.flush() == false)
        #expect(await network.telemetryPaths.count == sent)
        #expect(await client.telemetryToken() == nil)
    }

    @Test func submittedFeedbackEmitsAMarkerWithTheReportID() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, _) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let reviewed = try ReviewedFeedback(configuration: config, notes: "Reviewed fixture note")
        #expect(await model.submit(reviewed, includeDiagnostics: false))
        try await waitUntil { await network.bodies(for: "logs").contains { logBodies($0).contains("feedback.submitted") } }
        let marker = try #require(await network.bodies(for: "logs").flatMap(logRecords).first { ($0["body"] as? [String: Any])?["stringValue"] as? String == "feedback.submitted" })
        #expect(attributes(marker)["feedback.report.id"] as? String == reviewed.id.uuidString.lowercased())
        // The notes are the report's, never telemetry's.
        for body in await network.bodies(for: "logs") + network.bodies(for: "traces") {
            #expect(!String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains("Reviewed fixture note"))
        }
    }

    @Test func settingsDiscloseTelemetryNextToEnrollment() {
        let text = CompanionFeedbackSettings.telemetryDisclosure
        #expect(text.contains("Enrolling in developer feedback also sends usage and diagnostic telemetry to the developer"))
        #expect(text.contains("never includes prompts"))
    }

    @Test func buildSHAReachesTheConfiguration() throws {
        // The key is always in the built Info.plist; local and CI builds expand it to empty, so no buildSha.
        let raw = try #require(Bundle.main.object(forInfoDictionaryKey: CompanionBuildInfo.buildSHAKey) as? String)
        #expect(CompanionBuildInfo.buildSHA(raw) == (raw.isEmpty ? nil : raw.lowercased()))
        #expect(!raw.contains("$("))
        let sha = "4905102899ee20db0c436716f4783f6ba9827c5d"
        #expect(try Configuration(gameID: "clubhouse-annex", buildSHA: CompanionBuildInfo.buildSHA(sha)).buildSHA == sha)
        #expect(try Configuration(gameID: "clubhouse-annex", buildSHA: CompanionBuildInfo.buildSHA("")).buildSHA == nil)
    }
}

private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(4)) }
    Issue.record("condition not met")
}
private func attributes(_ item: [String: Any]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: ((item["attributes"] as? [[String: Any]]) ?? []).compactMap { entry in
        (entry["key"] as? String).flatMap { key in (entry["value"] as? [String: Any])?.values.first.map { (key, $0) } }
    })
}
private func spans(_ body: [String: Any]) -> [[String: Any]] {
    ((body["resourceSpans"] as? [[String: Any]]) ?? []).flatMap { ($0["scopeSpans"] as? [[String: Any]]) ?? [] }.flatMap { ($0["spans"] as? [[String: Any]]) ?? [] }
}
private func logRecords(_ body: [String: Any]) -> [[String: Any]] {
    ((body["resourceLogs"] as? [[String: Any]]) ?? []).flatMap { ($0["scopeLogs"] as? [[String: Any]]) ?? [] }.flatMap { ($0["logRecords"] as? [[String: Any]]) ?? [] }
}
private func logBodies(_ body: [String: Any]) -> [String] {
    logRecords(body).compactMap { ($0["body"] as? [String: Any])?["stringValue"] as? String }
}

nonisolated private final class TelemetryMemoryEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord()
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
nonisolated private final class TelemetryMemoryQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [QueuedFeedback] = []
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { reports } }
    func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { reports = items } }
}
/// Answers the access, report and OTLP routes the way the service does; records what was sent.
private actor TelemetryMockTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var telemetryPaths: [String] { requests.map { $0.url!.path }.filter { $0.contains("/v1/otlp/") } }
    func bodies(for signal: String) -> [[String: Any]] {
        requests.filter { $0.url!.path.hasSuffix("/v1/otlp/v1/\(signal)") }
            .compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        let path = request.url!.path
        let object: [String: Any]
        if path.hasSuffix("access/redeem") {
            object = ["v": 1, "scopeVersion": 2, "gameId": "phone-ui-fixture", "token": String(repeating: "b", count: 43),
                      "refreshToken": String(repeating: "r", count: 43), "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(),
                      "refreshExpiresAt": Date().addingTimeInterval(86400).ISO8601Format()]
        } else if path.hasSuffix("/reports") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            object = ["id": body["id"]!, "status": "ready", "gameId": "phone-ui-fixture"]
        } else if path.hasSuffix("access/disconnect") {
            object = ["v": 1, "disconnected": true]
        } else if path.contains("/v1/otlp/v1/") {
            object = [:]
        } else { throw FramebriarError.network }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}
