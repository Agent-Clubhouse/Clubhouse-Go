import Foundation

/// Maps the closed-enum diagnostics (`AnnexDiagnosticRecord`, `AnnexDiagnosticSummary`) onto Framebriar's
/// `app.*` conventions (framebriar docs/app-telemetry-v1.md) without depending on the Framebriar SDK, so the
/// mapping is tested here and the app only forwards the result.
///
/// Every value comes from a closed enum, a number or a random UUID already in the record. There is no input
/// for prompts, names, paths, hosts, URLs or error messages.
nonisolated public enum AnnexAppTelemetry {
    public static let schemaVersion = 1
    public static let platform = "ios"
    /// Added to every log and span (`Telemetry(commonAttributes:)`).
    public static let commonAttributes: [String: Value] = ["app.telemetry.schema_version": .int(schemaVersion), "app.platform": .string(platform)]
    /// At most one `app.performance.summary` per kind per minute.
    public static let summaryInterval: TimeInterval = 60

    public enum Value: Sendable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool)
    }
    public enum Severity: Sendable, Equatable { case info, warn, error }
    public struct Span: Sendable, Equatable {
        public struct Event: Sendable, Equatable { public let name: String; public let time: Date }
        public let traceID: String
        public let spanID: String
        public let parentID: String?
        public let name: String
        /// OTLP span kind: 1 internal, 3 client, 5 consumer.
        public let kind: Int
        public let start: Date
        public let end: Date
        public let attributes: [String: Value]
        public let events: [Event]
        public let failed: Bool
    }
    public enum Signal: Sendable, Equatable {
        case span(Span)
        /// A log whose body is a constant event name, parented to a span when `traceID`/`spanID` are set.
        case log(event: String, severity: Severity, attributes: [String: Value], traceID: String?, spanID: String?)
        case counter(name: String, unit: String, value: Double, attributes: [String: Value])
        case histogram(name: String, unit: String, value: Double, attributes: [String: Value])
    }

    /// `app.flow.name` for operations that are one user-meaningful unit of work.
    public static func flowName(_ operation: AnnexDiagnosticOperation) -> String? {
        switch operation {
        case .pairing: "pair"
        case .connection: "connect"
        case .reconnect: "reconnect"
        case .restore: "restore"
        case .send, .steer, .queued: "chat_turn"
        case .spawn, .createAgent: "spawn_agent"
        default: nil
        }
    }
    /// Operations the user asked for, reported as `app.action` with `app.action.result`.
    public static func isAction(_ operation: AnnexDiagnosticOperation) -> Bool {
        switch operation {
        case .start, .send, .steer, .queued, .interrupt, .permission, .question, .spawn, .removeQueued, .wake, .upload,
             .createAgent, .updateAgent, .command, .helperRequest, .updateProject, .finishedQuick, .revoke, .forget: true
        default: false
        }
    }
    public static func outcome(_ failure: AnnexDiagnosticFailure) -> String {
        switch failure {
        case .none: "ok"
        case .cancelled, .abandoned: "cancelled"
        case .timeout: "timeout"
        default: "error"
        }
    }
    public static func actionResult(_ failure: AnnexDiagnosticFailure) -> String {
        switch failure {
        case .none: "accepted"
        case .outcomeUnknown: "outcome_unknown"
        default: "rejected"
        }
    }

    public static func signals(for record: AnnexDiagnosticRecord) -> [Signal] {
        switch record.operation {
        case .appLaunch:
            // The bridge logs app.session.start itself, once enrolled telemetry exists.
            return []
        case .foreground, .background:
            // Zero-work spans locally; a lifecycle log for telemetry.
            return [.log(event: "app.lifecycle", severity: .info, attributes: ["app.lifecycle.state": .string(record.operation.rawValue)],
                         traceID: nil, spanID: nil)]
        case .navigation, .settings:
            return [.log(event: "app.action", severity: .info,
                         attributes: ["app.action.name": .string(record.operation.rawValue), "app.action.result": .string("accepted")],
                         traceID: nil, spanID: nil)]
        default: break
        }
        var signals: [Signal] = [.span(span(for: record))]
        let failure = record.failure
        if isAction(record.operation) {
            signals.append(.log(event: "app.action", severity: failure == .none ? .info : .warn,
                                attributes: ["app.action.name": .string(record.operation.rawValue), "app.action.result": .string(actionResult(failure))],
                                traceID: record.traceID, spanID: record.id))
        }
        if failure != .none && failure != .cancelled {
            signals.append(.log(event: "app.error", severity: .error,
                                attributes: ["app.error.class": .string(failure.rawValue), "annex.operation": .string(record.operation.rawValue)],
                                traceID: record.traceID, spanID: record.id))
        }
        // Metric labels come only from small closed sets, never identifiers.
        switch record.operation {
        case .connection:
            signals.append(.histogram(name: "app.connect.duration", unit: "ms", value: record.durationMs, attributes: ["app.outcome": .string(outcome(failure))]))
        case .reconnect:
            signals.append(.counter(name: "app.reconnects", unit: "{reconnect}", value: 1, attributes: ["app.outcome": .string(outcome(failure))]))
        case .stream:
            if let firstToken = record.measurements[AnnexDiagnosticNumber.firstTokenMs.rawValue] {
                signals.append(.histogram(name: "app.first_token.duration", unit: "ms", value: firstToken, attributes: [:]))
            }
        default: break
        }
        return signals
    }

    /// The span as recorded, with its events and their times, standard names where OTel has one
    /// (`http.response.status_code`, `error.type`) and the rest under `annex.*`. Flow operations are named
    /// `app.flow` with `app.flow.name`, `app.flow.id`, `app.outcome` and `app.duration.ms`.
    public static func span(for record: AnnexDiagnosticRecord, flowID: UUID = UUID()) -> Span {
        var attributes: [String: Value] = [:]
        for (key, value) in record.measurements {
            guard let number = AnnexDiagnosticNumber(rawValue: key), value.isFinite else { continue }
            switch number {
            case .statusCode: attributes["http.response.status_code"] = .int(Int(value))
            case .requestBytes, .responseBytes, .chunks, .bytes, .attempt, .discoveredCount: attributes["annex.\(key)"] = .int(Int(value))
            default: attributes["annex.\(key)"] = .double(value)
            }
        }
        for key in AnnexDiagnosticIdentifier.allCases {
            if let value = record.identifiers[key.rawValue], AnnexTelemetryHandshake.canonicalUUID(value) != nil { attributes[key.rawValue] = .string(value) }
        }
        if record.failure != .none { attributes["error.type"] = .string(record.failure.rawValue) }
        var name = record.operation.rawValue
        if let flow = flowName(record.operation) {
            name = "app.flow"
            attributes["app.flow.name"] = .string(flow)
            attributes["app.flow.id"] = .string(flowID.uuidString.lowercased())
            attributes["app.outcome"] = .string(outcome(record.failure))
            attributes["app.duration.ms"] = .int(Int(record.durationMs.rounded()))
            attributes["annex.operation"] = .string(record.operation.rawValue)
        }
        let end = record.startedAt.addingTimeInterval(record.durationMs / 1000)
        // Older snapshots have no event times; never invent them.
        let events = zip(record.events, record.eventOffsetsMs ?? []).map { name, offset in
            Span.Event(name: name, time: record.startedAt.addingTimeInterval(min(record.durationMs, max(0, offset)) / 1000))
        }
        return Span(traceID: record.traceID, spanID: record.id, parentID: record.parentID, name: name,
                    kind: [1, 3, 5].contains(record.spanKind) ? record.spanKind : 1, start: record.startedAt, end: end,
                    attributes: attributes, events: events, failed: record.failure != .none)
    }

    /// Routine work counted rather than recorded (the WebSocket ping): an `app.performance.summary` log and an
    /// `app.pings` counter split by outcome.
    public static func signals(for summary: AnnexDiagnosticSummary) -> [Signal] {
        guard summary.count > 0 else { return [] }
        let kind = summary.operation.rawValue
        var signals: [Signal] = [.log(event: "app.performance.summary", severity: .info, attributes: [
            "app.performance.kind": .string(kind), "count": .int(summary.count), "mean_ms": .double(summary.meanMs),
            "max_ms": .double(summary.maxMs), "over_threshold": .int(summary.slow), "annex.failed": .int(summary.failed)
        ], traceID: nil, spanID: nil)]
        if summary.operation == .ping {
            let ok = summary.count - summary.failed
            if ok > 0 { signals.append(.counter(name: "app.pings", unit: "{ping}", value: Double(ok), attributes: ["app.outcome": .string("ok")])) }
            if summary.failed > 0 { signals.append(.counter(name: "app.pings", unit: "{ping}", value: Double(summary.failed), attributes: ["app.outcome": .string("error")])) }
        }
        return signals
    }
}
