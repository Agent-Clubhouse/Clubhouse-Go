import Foundation
@preconcurrency import OpenTelemetryApi
@preconcurrency import OpenTelemetrySdk

/// Closed vocabulary: no API accepts URLs, identities, paths, prompts or error descriptions.
nonisolated public enum AnnexDiagnosticOperation: String, Codable, CaseIterable, Sendable {
    case appLaunch, foreground, background, navigation, settings, discovery, resolve, manualAddress
    case handshake, trustInspection, pairing, restore, revoke, forget, connection, disconnect, reconnect, backoff
    case identity, status, projects, agents, capabilities, history, archive, media, command
    case start, send, steer, queued, interrupt, permission, question, spawn, removeQueued, wake, upload
    case createAgent, agentOptions, agentSettings, updateAgent, helperRequest, changes, updateProject, finishedQuick
    case http, httpTiming, response, tls, websocket, ping, replay, stream, legacyDiagnostic
}
nonisolated public enum AnnexDiagnosticEvent: String, Codable, Sendable {
    case found, resolved, snapshot, duplicate, gap, replayRequested, firstToken, chunk, completed
    case authenticated, rejected, queued, delivered, cancelled, background, overflow, connected, unsupported
}
nonisolated public enum AnnexDiagnosticIdentifier: String, CaseIterable, Sendable {
    case peerInstanceID = "peer.service.instance.id"
    case connectionAttemptID = "annex.connection.attempt.id"
    case connectionID = "annex.connection.id"
}
nonisolated public enum AnnexDiagnosticNumber: String, Codable, Sendable {
    case statusCode, requestBytes, responseBytes, firstTokenMs, interChunkMs, maxInterChunkMs
    case chunks, bytes, attempt, backoffMs, discoveredCount, dnsMs, connectMs, tlsMs, firstByteMs
}
nonisolated public enum AnnexDiagnosticFailure: String, Codable, Sendable {
    case none, cancelled, timeout, offline, dns, connection, tls, trust, identity, authentication
    case forbidden, invalidInput, malformed, tooLarge, overflow, unsupported, busy, conflict
    case outcomeUnknown, storage, server, rejected, unknown, abandoned
    public static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? AnnexTransportError {
            switch error {
            case .invalidEndpoint, .invalidPin: return .invalidInput
            case .trustRequired: return .trust
            case .identityMismatch: return .identity
            case .credentialMissing, .unauthorized: return .authentication
            case .forbidden: return .forbidden
            case .unsupportedCapability: return .unsupported
            case .malformedResponse: return .malformed
            case .responseTooLarge: return .tooLarge
            case .queueOverflow: return .overflow
            case .disconnected: return .connection
            case .commandOutcomeUnknown, .pairingRevocationOutcomeUnknown: return .outcomeUnknown
            case .commandInFlight: return .busy
            case .duplicateCommandConflict: return .conflict
            case .persistenceFailed: return .storage
            case .rejected(let status, _): return status >= 500 ? .server : .rejected
            case .rateLimited: return .busy
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost: return .offline
            case .cannotFindHost, .dnsLookupFailed: return .dns
            case .cannotConnectToHost: return .connection
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired, .userCancelledAuthentication: return .tls
            default: return .unknown
            }
        }
        return .unknown
    }
}

nonisolated public struct AnnexDiagnosticRecord: Codable, Sendable, Identifiable {
    public let serviceName: String
    public let serviceInstanceID: String
    public let identifiers: [String: String]
    public let traceID: String
    public let id: String
    public let parentID: String?
    public let operation: AnnexDiagnosticOperation
    public let startedAt: Date
    public let durationMs: Double
    public let spanKind: Int
    public let failure: AnnexDiagnosticFailure
    public let measurements: [String: Double]
    public let events: [String]
    /// When each of `events` happened, in milliseconds after `startedAt`. Nil in snapshots from older builds.
    public let eventOffsetsMs: [Double]?
}
/// Routine work counted instead of recorded span by span; see `AnnexTelemetry.measureRoutine`.
nonisolated public struct AnnexDiagnosticSummary: Sendable, Equatable {
    public let operation: AnnexDiagnosticOperation
    /// Completed operations, including slow and failed ones.
    public let count: Int
    /// At or over the slow threshold; each of these, and each failure, is also a span.
    public let slow: Int
    public let failed: Int
    public let totalMs: Double
    public let maxMs: Double
    public var meanMs: Double { count == 0 ? 0 : totalMs / Double(count) }
}
nonisolated public struct AnnexDiagnosticSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let enabled: Bool
    public let remoteExportEnabled: Bool
    public let dropped: Int
    public let records: [AnnexDiagnosticRecord]
}

/// Synchronous, bounded, memory-only SDK exporter. No URLSession, timer, disk or queue.
/// Defense in depth also rejects arbitrary SDK span names/attributes at this boundary.
nonisolated final class AnnexLocalSpanExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AnnexDiagnosticRecord] = []
    private var enabled = false
    private var remoteEnabled = false
    private var generation = 0
    private var dropped = 0
    private let capacity: Int
    private let instanceID: UUID
    private var sink: (@Sendable (AnnexDiagnosticRecord) -> Void)?
    init(capacity: Int, instanceID: UUID = UUID()) { self.capacity = min(512, max(1, capacity)); self.instanceID = instanceID }
    func setSink(_ sink: (@Sendable (AnnexDiagnosticRecord) -> Void)?) { lock.withLock { self.sink = sink } }
    func configure(enabled: Bool) -> Int {
        lock.withLock { self.enabled = enabled; generation += 1; records.removeAll(); dropped = 0; return generation }
    }
    func setRemoteEnabled(_ value: Bool) { lock.withLock { remoteEnabled = value } }
    func captureGeneration() -> Int? { lock.withLock { enabled ? generation : nil } }
    func snapshot() -> AnnexDiagnosticSnapshot {
        lock.withLock { .init(schemaVersion: 1, enabled: enabled, remoteExportEnabled: enabled && remoteEnabled, dropped: dropped, records: records) }
    }
    func drop() { lock.withLock { if enabled { dropped = min(Int.max - 1, dropped + 1) } } }
    private func receive(_ spans: [SpanData]) -> SpanExporterResultCode {
        let (accepted, recipient) = lock.withLock { () -> ([AnnexDiagnosticRecord], (@Sendable (AnnexDiagnosticRecord) -> Void)?) in
            guard enabled else { return ([], nil) }
            var accepted: [AnnexDiagnosticRecord] = []
            for span in spans.prefix(512) {
                guard span.attributes["capture.generation"] == .int(generation),
                      let operation = AnnexDiagnosticOperation(rawValue: span.name) else { continue }
                var numbers: [String: Double] = [:]
                for key in AnnexDiagnosticNumber.allKeys {
                    let value: Double?
                    switch span.attributes[key.rawValue] {
                    case .double(let number): value = number
                    case .int(let number): value = Double(number)
                    default: value = nil
                    }
                    if let value, value.isFinite { numbers[key.rawValue] = min(1_000_000_000, max(0, value)) }
                }
                var identifiers: [String: String] = [:]
                for key in AnnexDiagnosticIdentifier.allCases {
                    if case .string(let value) = span.attributes[key.rawValue], AnnexTelemetryHandshake.canonicalUUID(value) != nil {
                        identifiers[key.rawValue] = value
                    }
                }
                let failure: AnnexDiagnosticFailure
                if case .string(let value) = span.attributes["failure"] { failure = AnnexDiagnosticFailure(rawValue: value) ?? .unknown }
                else { failure = .none }
                let durationMs = min(600_000, max(0, span.endTime.timeIntervalSince(span.startTime) * 1000))
                let events = span.events.prefix(32).compactMap { event in
                    AnnexDiagnosticEvent(rawValue: event.name).map { ($0.rawValue, min(durationMs, max(0, event.timestamp.timeIntervalSince(span.startTime) * 1000))) }
                }
                if records.count == capacity { records.removeFirst(); dropped = min(Int.max - 1, dropped + 1) }
                let record = AnnexDiagnosticRecord(serviceName: "clubhouse-go", serviceInstanceID: instanceID.uuidString.lowercased(), identifiers: identifiers,
                    traceID: span.traceId.hexString, id: span.spanId.hexString,
                    parentID: span.parentSpanId?.hexString, operation: operation, startedAt: span.startTime,
                    durationMs: durationMs,
                    spanKind: span.kind == .client ? 3 : span.kind == .consumer ? 5 : 1,
                    failure: failure, measurements: numbers, events: events.map(\.0), eventOffsetsMs: events.map(\.1))
                records.append(record); accepted.append(record)
            }
            return (accepted, self.sink)
        }
        // Outside the lock: the sink may record into other telemetry.
        if let recipient { accepted.forEach(recipient) }
        return .success
    }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode { receive(spans) }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { receive(spans) }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) { _ = configure(enabled: false) }
    func shutdown(explicitTimeout: TimeInterval?) async { _ = configure(enabled: false) }
}
nonisolated private extension AnnexDiagnosticNumber {
    static let allKeys: [Self] = [.statusCode, .requestBytes, .responseBytes, .firstTokenMs, .interChunkMs,
        .maxInterChunkMs, .chunks, .bytes, .attempt, .backoffMs, .discoveredCount, .dnsMs, .connectMs, .tlsMs, .firstByteMs]
}
/// Avoid SimpleSpanProcessor's unbounded asynchronous queue: this exporter only copies bounded data.
nonisolated private struct AnnexLocalSpanProcessor: SpanProcessor {
    let exporter: AnnexLocalSpanExporter
    let isStartRequired = false
    let isEndRequired = true
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {}
    mutating func onEnd(span: ReadableSpan) { _ = exporter.export(spans: [span.toSpanData()], explicitTimeout: nil) }
    mutating func shutdown(explicitTimeout: TimeInterval?) { exporter.shutdown(explicitTimeout: explicitTimeout) }
    func forceFlush(timeout: TimeInterval?) {}
}

nonisolated public final class AnnexDiagnosticSpan: @unchecked Sendable {
    fileprivate let span: (any Span)?
    fileprivate let started: TimeInterval
    fileprivate let generation: Int?
    private let lock = NSLock()
    private var ended = false
    private let clock: @Sendable () -> TimeInterval
    init(span: (any Span)?, generation: Int?, clock: @escaping @Sendable () -> TimeInterval) {
        self.span = span; self.generation = generation; self.clock = clock; started = clock()
    }
    public func number(_ key: AnnexDiagnosticNumber, _ value: Double) {
        guard value.isFinite else { return }
        lock.withLock { if !ended { span?.setAttribute(key: key.rawValue, value: .double(min(1_000_000_000, max(0, value)))) } }
    }
    public func identifier(_ key: AnnexDiagnosticIdentifier, _ value: UUID) {
        lock.withLock { if !ended { span?.setAttribute(key: key.rawValue, value: .string(value.uuidString.lowercased())) } }
    }
    public func event(_ event: AnnexDiagnosticEvent) { lock.withLock { if !ended { span?.addEvent(name: event.rawValue) } } }
    public func fail(_ error: Error) { fail(AnnexDiagnosticFailure.classify(error)) }
    public func fail(_ failure: AnnexDiagnosticFailure) {
        lock.withLock {
            guard !ended else { return }
            span?.setAttribute(key: "failure", value: .string(failure.rawValue))
            if failure != .none { span?.status = .error(description: failure.rawValue) }
        }
    }
    public var elapsedMs: Double { max(0, (clock() - started) * 1000) }
    public func end() { lock.withLock { guard !ended else { return }; ended = true; span?.end() } }
    deinit { end() }
}

nonisolated public final class AnnexTelemetry: @unchecked Sendable {
    public static let shared = AnnexTelemetry()
    public let instanceID: UUID
    public var isEnabled: Bool { exporter.captureGeneration() != nil }
    /// Capture the user chose in Connection diagnostics.
    private var localCapture = false
    /// Capture because the user enrolled in developer feedback, whose telemetry exports these records.
    private var enrolledCapture = false
    public var capturesForEnrollment: Bool { lock.withLock { enrolledCapture } }
    @TaskLocal public static var current: AnnexDiagnosticSpan?
    private let lock = NSLock()
    private let exporter: AnnexLocalSpanExporter
    private let provider: TracerProviderSdk
    private let tracer: any Tracer
    private var active: [AnnexDiagnosticSpan] = []
    private var summaries: [AnnexDiagnosticOperation: AnnexDiagnosticSummary] = [:]
    private let clock: @Sendable () -> TimeInterval
    public init(capacity: Int = 256, instanceID: UUID = UUID(), clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let instanceID = AnnexTelemetryHandshake.canonicalUUID(instanceID.uuidString.lowercased()) == nil ? UUID() : instanceID
        self.clock = clock; self.instanceID = instanceID
        let exporter = AnnexLocalSpanExporter(capacity: capacity, instanceID: instanceID); self.exporter = exporter
        provider = TracerProviderBuilder()
            .with(sampler: Samplers.alwaysOn)
            .with(resource: Resource(attributes: ["service.name": .string("clubhouse-go"), "service.instance.id": .string(instanceID.uuidString.lowercased())]))
            .with(spanLimits: SpanLimits().settingAttributeCountLimit(24).settingEventCountLimit(32)
                .settingLinkCountLimit(0).settingAttributeValueLengthLimit(64))
            .add(spanProcessor: AnnexLocalSpanProcessor(exporter: exporter)).build()
        tracer = provider.get(instrumentationName: "clubhouse.annex", instrumentationVersion: "1")
    }
    public func setRemoteExportEnabled(_ enabled: Bool) { exporter.setRemoteEnabled(enabled) }
    /// The user's Connection diagnostics choice. Capture stays on while enrolled (`setEnrolledCapture`).
    public func setEnabled(_ enabled: Bool) { lock.withLock { localCapture = enabled; reconfigureLocked() } }
    /// On while the user is enrolled in developer feedback, so its telemetry has spans to export; off
    /// (clearing everything, unless the user also chose capture) the moment enrollment ends.
    public func setEnrolledCapture(_ enabled: Bool) {
        lock.withLock {
            guard enrolledCapture != enabled else { return }
            let wasOn = localCapture || enrolledCapture
            enrolledCapture = enabled
            if wasOn != (localCapture || enrolledCapture) { reconfigureLocked() }
        }
    }
    /// Receives each record as it is captured, outside any lock. One sink; nil removes it.
    public func setRecordSink(_ sink: (@Sendable (AnnexDiagnosticRecord) -> Void)?) { exporter.setSink(sink) }
    public func clear() { lock.withLock { reconfigureLocked() } }
    private func reconfigureLocked() {
        _ = exporter.configure(enabled: localCapture || enrolledCapture) // Fence late completion before ending old scopes.
        active.forEach { $0.end() }; active.removeAll(); summaries.removeAll()
    }
    public func snapshot() -> AnnexDiagnosticSnapshot { expire(); return exporter.snapshot() }
    public func exportJSON(maximumBytes: Int = 512 * 1024) throws -> Data {
        let data = try JSONEncoder().encode(snapshot())
        guard data.count <= min(512 * 1024, max(0, maximumBytes)) else { throw AnnexTransportError.responseTooLarge }
        return data
    }
    private func expire() {
        lock.withLock {
            active.removeAll { scope in
                if scope.elapsedMs >= 600_000 { scope.fail(.timeout); scope.end(); return true }
                return scope.span?.isRecording != true
            }
        }
    }
    public func begin(_ operation: AnnexDiagnosticOperation, parent: AnnexDiagnosticSpan? = AnnexTelemetry.current, remoteParent: AnnexTraceContext? = nil,
                      startedAt: Date? = nil) -> AnnexDiagnosticSpan {
        expire()
        return lock.withLock {
            guard let generation = exporter.captureGeneration(), active.count < 128 else {
                exporter.drop(); return AnnexDiagnosticSpan(span: nil, generation: nil, clock: clock)
            }
            // An explicit child of pre-clear/disabled work must not reappear in a new capture.
            if let parent, parent.generation != generation {
                return AnnexDiagnosticSpan(span: nil, generation: nil, clock: clock)
            }
            let builder = tracer.spanBuilder(spanName: operation.rawValue).setAttribute(key: "capture.generation", value: generation)
            if operation == .http || operation == .websocket { builder.setSpanKind(spanKind: .client) }
            if operation == .stream { builder.setSpanKind(spanKind: .consumer) }
            if let startedAt { builder.setStartTime(time: startedAt) }
            if let remoteParent { builder.setParent(remoteParent.context) }
            else if parent?.generation == generation, let span = parent?.span { builder.setParent(span) }
            else { builder.setNoParent() }
            let result = AnnexDiagnosticSpan(span: builder.startSpan(), generation: generation, clock: clock)
            active.append(result); return result
        }
    }
    /// Called only after the request's exact pinned endpoint has been validated.
    /// Capture off strips all trace headers; no baggage is ever propagated.
    public func inject(into request: inout URLRequest, span: AnnexDiagnosticSpan? = AnnexTelemetry.current) {
        request.setValue(nil, forHTTPHeaderField: "traceparent")
        request.setValue(nil, forHTTPHeaderField: "tracestate")
        request.setValue(nil, forHTTPHeaderField: "baggage")
        request.setValue(traceparent(for: span), forHTTPHeaderField: "traceparent")
    }
    public func traceparent(for span: AnnexDiagnosticSpan?) -> String? {
        guard let generation = exporter.captureGeneration(), span?.generation == generation,
              let context = span?.span?.context, context.isValid else { return nil }
        return "00-\(context.traceId.hexString)-\(context.spanId.hexString)-\(context.traceFlags.hexString)"
    }
    public func record(_ operation: AnnexDiagnosticOperation, event: AnnexDiagnosticEvent? = nil) {
        let span = begin(operation); if let event { span.event(event) }; span.end()
    }
    public func measure<T>(_ operation: AnnexDiagnosticOperation, isolation: isolated (any Actor)? = #isolation,
                           body: () async throws -> T) async rethrows -> T {
        let span = begin(operation)
        defer { span.end() }
        do { return try await Self.$current.withValue(span) { try await body() } }
        catch { span.fail(error); throw error }
    }
    /// For frequent routine work, such as the WebSocket ping every 20 s per desktop, which as one span
    /// each would push useful spans out of the ring (and the feedback incident window) within the hour.
    /// Every run is counted in a summary (`drainSummaries`); only failed runs and runs at or over
    /// `slowMs` become a span, backdated to when the work started.
    public func measureRoutine<T>(_ operation: AnnexDiagnosticOperation, slowMs: Double, isolation: isolated (any Actor)? = #isolation,
                                  body: () async throws -> T) async rethrows -> T {
        let parent = Self.current, startedAt = Date(), started = clock()
        func finish(_ failure: AnnexDiagnosticFailure) {
            let elapsed = max(0, (clock() - started) * 1000)
            let slow = elapsed >= slowMs
            guard summarize(operation, elapsed, slow: slow, failed: failure != .none), slow || failure != .none else { return }
            let span = begin(operation, parent: parent, startedAt: startedAt)
            if failure != .none { span.fail(failure) }
            span.end()
        }
        do { let value = try await body(); finish(.none); return value }
        catch { finish(AnnexDiagnosticFailure.classify(error)); throw error }
    }
    /// Returns and resets the routine summaries counted since the last call (or since capture changed).
    public func drainSummaries() -> [AnnexDiagnosticSummary] {
        lock.withLock {
            defer { summaries.removeAll() }
            return summaries.values.sorted { $0.operation.rawValue < $1.operation.rawValue }
        }
    }
    /// False, counting nothing, while capture is off.
    private func summarize(_ operation: AnnexDiagnosticOperation, _ ms: Double, slow: Bool, failed: Bool) -> Bool {
        lock.withLock {
            guard exporter.captureGeneration() != nil else { return false }
            let ms = min(600_000, ms), old = summaries[operation]
            summaries[operation] = AnnexDiagnosticSummary(operation: operation, count: min(1_000_000, (old?.count ?? 0) + 1),
                slow: min(1_000_000, (old?.slow ?? 0) + (slow ? 1 : 0)), failed: min(1_000_000, (old?.failed ?? 0) + (failed ? 1 : 0)),
                totalMs: min(1e12, (old?.totalMs ?? 0) + ms), maxMs: max(old?.maxMs ?? 0, ms))
            return true
        }
    }
}

nonisolated extension AnnexReadRoute {
    var diagnosticOperation: AnnexDiagnosticOperation {
        switch self {
        case .identity: .identity
        case .status: .status
        case .projects: .projects
        case .capabilities: .capabilities
        case .agents, .agentState: .agents
        case .chat, .chatHistory: .history
        case .chatSessions, .sessions, .transcript: .archive
        case .chatContent: .media
        case .createOptions: .agentOptions
        case .agentSettings: .agentSettings
        case .gitStatus, .gitDiff: .changes
        }
    }
}
nonisolated extension AnnexCommand {
    var diagnosticOperation: AnnexDiagnosticOperation {
        switch kind {
        case .send(_, _, _, let delivery, _): delivery == .steer ? .steer : delivery == .queued ? .queued : .send
        case .start: .start
        case .stop, .interrupt: .interrupt
        case .removeQueued: .removeQueued
        case .permission: .permission
        case .question: .question
        case .spawn: .spawn
        case .create: .createAgent
        case .update: .updateAgent
        case .setModel, .setLevel: .command
        case .helperApprove, .helperDecline: .helperRequest
        case .setProjectPinned, .setProjectInactive: .updateProject
        case .dismissFinishedQuick, .clearFinishedQuick: .finishedQuick
        }
    }
}
