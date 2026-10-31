import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Supplies the enrollment access token. `Client` conforms; tests may inject another provider.
public protocol TelemetryAccess: Sendable {
    var enrollmentSignal: EnrollmentSignal { get }
    func telemetryToken(refresh: Bool) async -> String?
}
extension Client: TelemetryAccess {}

public enum TelemetrySeverity: Int, Sendable {
    case trace = 1, debug = 5, info = 9, warn = 13, error = 17, fatal = 21
    var text: String { switch self { case .trace: "TRACE"; case .debug: "DEBUG"; case .info: "INFO"; case .warn: "WARN"; case .error: "ERROR"; case .fatal: "FATAL" } }
}
public enum TelemetrySpanKind: Int, Sendable { case internalKind = 1, server, client, producer, consumer }
public enum TelemetrySpanStatus: Sendable, Equatable { case unset, ok, error }

public struct TelemetrySpanContext: Sendable, Equatable {
    public let traceID: String
    public let spanID: String
    public init(traceID: String, spanID: String) throws {
        guard matches(traceID, "^[0-9a-f]{32}$"), matches(spanID, "^[0-9a-f]{16}$"),
              traceID != String(repeating: "0", count: 32), spanID != String(repeating: "0", count: 16) else { throw FramebriarError.invalidInput }
        self.traceID = traceID; self.spanID = spanID
    }
    init(unchecked traceID: String, _ spanID: String) { self.traceID = traceID; self.spanID = spanID }
}

/// A span already recorded elsewhere, e.g. a host's local incident ring buffer. Exported with its
/// events (at most 32, 16 attributes each) through the same queue, ring and status handling.
public struct RecordedSpan: Sendable {
    public struct Event: Sendable {
        public let name: String, time: Date, attributes: TelemetryAttributes
        public init(name: String, time: Date, attributes: TelemetryAttributes = [:]) { self.name = name; self.time = time; self.attributes = attributes }
    }
    public let context: TelemetrySpanContext
    public let parentSpanID: String?
    public let name: String
    public let kind: TelemetrySpanKind
    public let start: Date, end: Date
    public let attributes: TelemetryAttributes
    public let events: [Event]
    public let status: TelemetrySpanStatus
    public init(context: TelemetrySpanContext, parentSpanID: String? = nil, name: String, kind: TelemetrySpanKind = .internalKind,
                start: Date, end: Date, attributes: TelemetryAttributes = [:], events: [Event] = [], status: TelemetrySpanStatus = .unset) throws {
        guard end >= start, parentSpanID.map({ matches($0, "^[0-9a-f]{16}$") && $0 != String(repeating: "0", count: 16) }) ?? true else { throw FramebriarError.invalidInput }
        self.context = context; self.parentSpanID = parentSpanID; self.name = name; self.kind = kind
        self.start = start; self.end = end; self.attributes = attributes; self.events = events; self.status = status
    }
}

/// Enrolled-user telemetry (traces, logs, delta metrics) for Swift apps, sent as standard OTLP/HTTP
/// JSON to the enrollment route `{endpoint}/v1/otlp/v1/{traces,logs,metrics}` with the current
/// enrollment access token (docs/telemetry.md). Memory only: nothing is written to disk and nothing
/// survives a relaunch. Not enrolled, disconnected, revoked or a 403 => every call is a no-op.
public final class Telemetry: @unchecked Sendable {
    public enum Mode: Sendable { case continuous, excerptOnly }
    public struct Stats: Sendable {
        public let sent: Int, dropped: Int, requests: Int, buffered: Int, bufferedBytes: Int, series: Int
        public let forbidden: Bool, blockedUntil: Date, nextFlushAt: Date?, ringLogs: Int, ringSpans: Int
    }
    public static let sdkVersion = "0.1.0"
    @TaskLocal static var activeSpan: TelemetrySpanContext?

    public let sessionID: String
    public let mode: Mode
    public let serviceVersion: String?
    private let access: any TelemetryAccess
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let random: @Sendable () -> Double
    private let base: URL
    private let common: TelemetryAttributes
    private let resource: [KeyValue]
    private let scope = ["name": "framebriar.swift", "version": Telemetry.sdkVersion]
    private var observer: UUID?
    private var lifecycle: [NSObjectProtocol] = []

    private enum EntryState { case local, queued, inflight, sent, rejected }
    private enum Payload { case span(SpanRecord), log(LogRecordData), metric(Instrument, MetricPoint) }
    private enum MetricPoint { case number(NumberPoint), exponential(ExponentialPoint) }
    private final class Entry { let payload: Payload; let at: Date; var state = EntryState.local; init(_ p: Payload, _ at: Date) { payload = p; self.at = at } }
    private struct Item { var payload: Payload; let size: Int; let entry: Entry? }
    fileprivate enum InstrumentKind { case counter, gauge, histogram }
    fileprivate final class Series { let attributes: [KeyValue]; var value = 0.0; var histogram: ExponentialHistogram?
        init(_ a: [KeyValue], histogram: Bool) { attributes = a; self.histogram = histogram ? ExponentialHistogram() : nil } }
    fileprivate final class Instrument { let kind: InstrumentKind, name: String, unit: String?, summary: String?; var series: [String: Series] = [:]
        init(_ k: InstrumentKind, _ n: String, _ u: String?, _ d: String?) { kind = k; name = n; unit = u; summary = d } }

    private let lock = NSLock()
    private var queue: [Item] = []
    private var queuedBytes = 0
    private var ring: [Entry] = []
    private var instruments: [String: Instrument] = [:]
    private var seriesTotal = 0
    private var windowStart: Date
    private var epoch = 0
    private var forbidden = false
    private var disposed = false
    private var lastToken: String?
    private var blockedUntil = Date.distantPast
    private var blockedForToken = false // only a missing token; a background pass may still use its cached one
    private var failures = 0
    private var splitting = false
    private var batchLimit = TelemetryLimits.batchBytes
    private var urgent = false
    private var soon = false
    private var timer: Task<Void, Never>?
    private var timerAt: Date?
    private var inflight: Task<Bool, Never>?
    private var sent = 0, dropped = 0, requests = 0

    /// - Parameters:
    ///   - appVersion: human version (e.g. CFBundleShortVersionString); with `appBuild` it becomes
    ///     `service.version = "<version>+<build>"`. Without it, the configuration's build SHA is used.
    ///   - commonAttributes: added to every log and span, e.g. `app.telemetry.schema_version`.
    ///   - observeAppLifecycle: on iOS, flush when the app enters the background or terminates.
    public init(client access: any TelemetryAccess, configuration: Configuration, mode: Mode = .continuous,
                appVersion: String? = nil, appBuild: String? = nil, environment: String? = nil,
                commonAttributes: TelemetryAttributes = [:], sessionID: String = FramebriarSession.id,
                transport: any HTTPTransport = URLSessionTransport(), observeAppLifecycle: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) throws {
        let token = "^[A-Za-z0-9._-]{1,32}$"
        guard matches(sessionID, "^[A-Za-z0-9_-]{1,64}$"), appVersion.map({ matches($0, token) }) ?? true,
              appBuild.map({ matches($0, token) }) ?? true, environment.map({ matches($0, "^[a-z0-9-]{1,32}$") }) ?? true else { throw FramebriarError.invalidConfiguration }
        self.access = access; self.transport = transport; self.now = now; self.sleep = sleep; self.random = random
        self.sessionID = sessionID; self.mode = mode
        let version = appVersion.map { v in appBuild.map { "\(v)+\($0)" } ?? v } ?? configuration.buildSHA
        serviceVersion = version.flatMap { matches($0, "^[A-Za-z0-9._+-]{1,40}$") ? $0 : nil }
        base = configuration.endpoint.appendingPathComponent("v1/otlp/v1")
        common = commonAttributes
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        var r: TelemetryAttributes = ["service.name": .string(configuration.gameID), "session.id": .string(sessionID),
            "telemetry.sdk.name": "framebriar", "telemetry.sdk.language": "swift", "telemetry.sdk.version": .string(Telemetry.sdkVersion),
            "os.type": "darwin", "host.arch": .string(arch)]
        if let serviceVersion { r["service.version"] = .string(serviceVersion) }
        if let environment { r["deployment.environment.name"] = .string(environment) }
        resource = r.keys.sorted().map { KeyValue($0, r[$0]!) }
        windowStart = now()
        observer = access.enrollmentSignal.observe { [weak self] enrolled in
            guard let self else { return }
            // Re-enrollment lifts a 403 stop; losing enrollment forgets everything immediately.
            self.lock.withLock { self.forbidden = false; if !enrolled { self.clearAllLocked() } }
        }
        if observeAppLifecycle { installLifecycleObservers() }
    }
    deinit {
        if let observer { access.enrollmentSignal.removeObserver(observer) }
        for token in lifecycle { NotificationCenter.default.removeObserver(token) }
        timer?.cancel(); inflight?.cancel()
    }

    /// True while recording: enrolled, not disposed and not stopped by a 403.
    public var isEnabled: Bool { lock.withLock { enabledLocked() } }
    private func enabledLocked() -> Bool { !disposed && !forbidden && access.enrollmentSignal.isEnrolled(at: now()) }

    // MARK: traces

    /// Starts a span. Parent defaults to the span active in `withSpan`; pass `parent: nil` explicitly via `root: true`.
    public func startSpan(_ name: String, attributes: TelemetryAttributes = [:], parent: TelemetrySpanContext? = nil,
                          root: Bool = false, kind: TelemetrySpanKind = .internalKind, start: Date? = nil) -> TelemetrySpan {
        guard isEnabled else { return TelemetrySpan(noop: ()) }
        let parent = root ? nil : parent ?? Telemetry.activeSpan
        let context = TelemetrySpanContext(unchecked: parent?.traceID ?? randomHex(bytes: 16), randomHex(bytes: 8))
        let record = SpanRecord(traceId: context.traceID, spanId: context.spanID, parentSpanId: parent?.spanID,
                                name: telemetryName(name, fallback: "span"), kind: kind.rawValue, startTimeUnixNano: nanos(start ?? now()),
                                endTimeUnixNano: "", attributes: telemetryAttributes(common.merging(attributes) { $1 }), events: [],
                                status: SpanStatusRecord(code: 0))
        return TelemetrySpan(telemetry: self, record: record, context: context, epoch: lock.withLock { epoch }, start: start ?? now())
    }
    /// Runs `operation` inside a span that is the default parent for nested spans and logs in this task.
    /// A thrown error marks the span as an error with only the Swift error type recorded.
    public func withSpan<T: Sendable>(_ name: String, attributes: TelemetryAttributes = [:], kind: TelemetrySpanKind = .internalKind,
                                      operation: (TelemetrySpan) async throws -> T) async rethrows -> T {
        let span = startSpan(name, attributes: attributes, kind: kind)
        do {
            let value = try await Telemetry.$activeSpan.withValue(span.isRecording ? span.context : Telemetry.activeSpan) { try await operation(span) }
            span.end(); return value
        } catch { span.recordError(error); span.setStatus(.error); span.end(); throw error }
    }
    /// Exports a span recorded by the host (for example its incident ring), keeping its events.
    public func record(_ span: RecordedSpan) {
        let events = span.events.prefix(TelemetryLimits.events).map {
            SpanEventRecord(timeUnixNano: nanos($0.time), name: telemetryName($0.name, fallback: "event"),
                            attributes: telemetryAttributes($0.attributes, max: TelemetryLimits.eventAttributes))
        }
        let record = SpanRecord(traceId: span.context.traceID, spanId: span.context.spanID, parentSpanId: span.parentSpanID,
                                name: telemetryName(span.name, fallback: "span"), kind: span.kind.rawValue, startTimeUnixNano: nanos(span.start),
                                endTimeUnixNano: nanos(span.end), attributes: telemetryAttributes(common.merging(span.attributes) { $1 }),
                                events: events.isEmpty ? nil : Array(events), status: SpanStatusRecord(code: span.status.code))
        lock.withLock { if enabledLocked() { emitLocked(.span(record)) } }
    }
    fileprivate func finish(_ record: SpanRecord, epoch born: Int) {
        lock.withLock { if born == epoch, enabledLocked() { emitLocked(.span(record)) } }
    }
    fileprivate var clock: Date { now() }

    // MARK: logs

    /// `event` is a constant event name (`app.session.start`, `app.error`); it becomes the log body.
    public func log(_ severity: TelemetrySeverity = .info, _ event: String, _ attributes: TelemetryAttributes = [:],
                    parent: TelemetrySpanContext? = nil) {
        lock.withLock {
            guard enabledLocked() else { return }
            emitLocked(.log(logRecord(severity, event, common.merging(attributes) { $1 }, parent: parent ?? Telemetry.activeSpan)))
        }
    }
    /// `app.error` with a closed `app.error.class`. Swift errors contribute only their type name, never a message.
    public func recordError(class errorClass: String, _ error: (any Error)? = nil, attributes: TelemetryAttributes = [:], severity: TelemetrySeverity = .error) {
        var attrs = attributes; attrs["app.error.class"] = .string(errorClass)
        if let error { attrs["exception.type"] = .string(String(describing: type(of: error))) }
        log(severity, "app.error", attrs)
    }
    private func logRecord(_ severity: TelemetrySeverity, _ body: String, _ attributes: TelemetryAttributes, parent: TelemetrySpanContext?) -> LogRecordData {
        let t = nanos(now())
        return LogRecordData(timeUnixNano: t, observedTimeUnixNano: t, severityNumber: severity.rawValue, severityText: severity.text,
                             body: LogBody(stringValue: scrubTelemetryText(body, max: TelemetryLimits.bodyChars)),
                             attributes: telemetryAttributes(attributes), traceId: parent?.traceID, spanId: parent?.spanID)
    }

    // MARK: metrics (delta temporality; off in excerpt-only mode)

    public func counter(_ name: String, unit: String? = nil, description: String? = nil) -> TelemetryInstrument { instrument(.counter, name, unit, description) }
    public func gauge(_ name: String, unit: String? = nil, description: String? = nil) -> TelemetryInstrument { instrument(.gauge, name, unit, description) }
    public func histogram(_ name: String, unit: String? = nil, description: String? = nil) -> TelemetryInstrument { instrument(.histogram, name, unit, description) }
    private func instrument(_ kind: InstrumentKind, _ name: String, _ unit: String?, _ description: String?) -> TelemetryInstrument {
        guard mode == .continuous, matches(name, "^[A-Za-z][A-Za-z0-9_./-]{0,127}$") else { return TelemetryInstrument(telemetry: nil, name: name) }
        return lock.withLock {
            if let existing = instruments[name] { return TelemetryInstrument(telemetry: existing.kind == kind ? self : nil, name: name) }
            guard instruments.count < TelemetryLimits.instruments else { return TelemetryInstrument(telemetry: nil, name: name) }
            instruments[name] = Instrument(kind, name, unit.map { String($0.prefix(63)) }, description.map { scrubTelemetryText($0) })
            return TelemetryInstrument(telemetry: self, name: name)
        }
    }
    fileprivate func measure(_ name: String, _ value: Double, _ attributes: TelemetryAttributes) {
        guard value.isFinite else { return }
        lock.withLock {
            guard enabledLocked(), let inst = instruments[name], inst.kind != .counter || value >= 0 else { return }
            var list = telemetryAttributes(attributes)
            var key = seriesKey(list)
            if inst.series[key] == nil, inst.series.count >= TelemetryLimits.series - 1 || seriesTotal >= TelemetryLimits.totalSeries {
                list = [KeyValue("otel.metric.overflow", true)]; key = seriesKey(list)
            }
            let series: Series
            if let existing = inst.series[key] { series = existing } else {
                if queue.isEmpty && seriesTotal == 0 { windowStart = now() }
                series = Series(list, histogram: inst.kind == .histogram); inst.series[key] = series; seriesTotal += 1
                pressureLocked()
            }
            switch inst.kind {
            case .counter: series.value += value
            case .gauge: series.value = value
            case .histogram: series.histogram?.record(value)
            }
        }
    }
    private func seriesKey(_ list: [KeyValue]) -> String {
        list.map { "\($0.key)=\($0.value.value)" }.sorted().joined(separator: "\u{1}")
    }
    private func collectMetricsLocked() {
        let start = nanos(windowStart), end = now(), time = nanos(end)
        windowStart = end
        for (_, inst) in instruments.sorted(by: { $0.key < $1.key }) {
            for (_, series) in inst.series.sorted(by: { $0.key < $1.key }) {
                let point: MetricPoint
                if let h = series.histogram {
                    guard h.count > 0 else { continue }
                    point = .exponential(h.point(attributes: series.attributes, start: start, time: time))
                } else { point = .number(NumberPoint(attributes: series.attributes, startTimeUnixNano: start, timeUnixNano: time, asDouble: series.value)) }
                enqueueLocked(.metric(inst, point), entry: nil)
            }
            inst.series.removeAll()
        }
        seriesTotal = 0
    }

    // MARK: feedback correlation (docs/correlation.md)

    /// Call after `Client.enqueue` commits the report. Emits the `feedback.submitted` marker (with the
    /// incident trace when known), sends the consented diagnostics excerpt and flushes now.
    @discardableResult
    public func feedbackSubmitted(reportID: UUID, trace: FeedbackIncident.Trace? = nil, includeDiagnostics: Bool = true) async -> Bool {
        let id = reportID.uuidString.lowercased()
        let ok: Bool = lock.withLock {
            guard enabledLocked() else { return false }
            if includeDiagnostics {
                pruneLocked()
                let picked = ring.filter { $0.state == .local || $0.state == .queued }
                let ids = Set(picked.map(ObjectIdentifier.init))
                // A still-queued original is replaced by its tagged copy, so nothing goes out twice.
                queue.removeAll { item in
                    guard let e = item.entry, ids.contains(ObjectIdentifier(e)) else { return false }
                    queuedBytes -= item.size; return true
                }
                for entry in picked { enqueueLocked(tag(entry.payload, id), entry: entry) }
            }
            let parent = trace.map { TelemetrySpanContext(unchecked: $0.traceId, $0.spanId) }
            let marker = Payload.log(logRecord(.info, "feedback.submitted", common.merging(["feedback.report.id": .string(id)]) { $1 }, parent: parent))
            let entry = Entry(marker, now()); ring.append(entry); pruneLocked()
            enqueueLocked(marker, entry: entry)
            urgent = true
            return true
        }
        guard ok else { return false }
        await flush()
        return true
    }
    private func tag(_ payload: Payload, _ id: String) -> Payload {
        func tagged(_ list: [KeyValue]) -> [KeyValue] {
            Array(list.filter { $0.key != "feedback.report.id" && $0.key != "feedback.excerpt" }.prefix(TelemetryLimits.attributes - 2))
                + [KeyValue("feedback.report.id", .string(id)), KeyValue("feedback.excerpt", true)]
        }
        switch payload {
        case .span(var s): s.attributes = tagged(s.attributes); return .span(s)
        case .log(var l): l.attributes = tagged(l.attributes); return .log(l)
        case .metric: return payload
        }
    }
    /// Recent distinct traces (newest first) from the local ring, for a `FeedbackIncident` snapshot.
    public func recentTraces(window: TimeInterval = TelemetryLimits.ringWindow, limit: Int = 8) -> [FeedbackIncident.Trace] {
        lock.withLock {
            let cutoff = now().addingTimeInterval(-window)
            var seen = Set<String>(), out: [FeedbackIncident.Trace] = []
            for entry in ring.reversed() where entry.at >= cutoff && out.count < limit {
                guard case .span(let s) = entry.payload, !seen.contains(s.traceId),
                      let trace = try? FeedbackIncident.Trace(traceId: s.traceId, spanId: s.spanId) else { continue }
                seen.insert(s.traceId); out.append(trace)
            }
            return out
        }
    }

    // MARK: queue and ring

    private func emitLocked(_ payload: Payload) {
        let entry = Entry(payload, now())
        guard size(payload) <= TelemetryLimits.itemBytes else { dropped += 1; return }
        ring.append(entry); pruneLocked()
        if mode == .continuous { enqueueLocked(payload, entry: entry) }
    }
    private func size(_ payload: Payload) -> Int {
        let encoder = JSONEncoder()
        switch payload {
        case .span(let s): return (try? encoder.encode(s).count) ?? .max
        case .log(let l): return (try? encoder.encode(l).count) ?? .max
        case .metric(_, .number(let p)): return (try? encoder.encode(p).count) ?? .max
        case .metric(_, .exponential(let p)): return (try? encoder.encode(p).count) ?? .max
        }
    }
    private func enqueueLocked(_ payload: Payload, entry: Entry?) {
        let bytes = size(payload)
        guard bytes <= TelemetryLimits.itemBytes else { dropped += 1; return }
        if case .metric = payload {} else if queue.isEmpty && seriesTotal == 0 { windowStart = now() }
        entry?.state = .queued
        queue.append(Item(payload: payload, size: bytes, entry: entry)); queuedBytes += bytes
        evictLocked(); pressureLocked()
    }
    private func evictLocked() {
        while queuedBytes > TelemetryLimits.bufferBytes, !queue.isEmpty {
            let old = queue.removeFirst(); queuedBytes -= old.size; dropped += 1; old.entry?.state = .local
        }
    }
    private func pruneLocked() {
        let cutoff = now().addingTimeInterval(-TelemetryLimits.ringWindow)
        var logs = ring.filter { if case .log = $0.payload { return true }; return false }.count
        var spans = ring.count - logs
        ring.removeAll { entry in
            let isLog: Bool; if case .log = entry.payload { isLog = true } else { isLog = false }
            if entry.at >= cutoff && (isLog ? logs <= TelemetryLimits.ringLogs : spans <= TelemetryLimits.ringSpans) { return false }
            if isLog { logs -= 1 } else { spans -= 1 }
            return true
        }
    }
    private func clearAllLocked() {
        epoch += 1
        inflight?.cancel()
        queue = []; queuedBytes = 0; ring = []; urgent = false; lastToken = nil
        for inst in instruments.values { inst.series.removeAll() }
        seriesTotal = 0; blockedUntil = .distantPast; blockedForToken = false; failures = 0; splitting = false; batchLimit = TelemetryLimits.batchBytes
        windowStart = now(); timer?.cancel(); timer = nil; timerAt = nil
    }
    private func pressureLocked() {
        armLocked(max(blockedUntil, windowStart.addingTimeInterval(TelemetryLimits.flushInterval)))
        guard now() >= blockedUntil, !soon,
              queue.count + seriesTotal >= TelemetryLimits.flushItems || queuedBytes >= TelemetryLimits.flushBytes else { return }
        soon = true
        Task { [weak self] in self?.lock.withLock { self?.soon = false }; await self?.flush() }
    }
    private func armLocked(_ at: Date) {
        guard !disposed, timerAt.map({ at < $0 }) ?? true else { return }
        timer?.cancel(); timerAt = at
        let delay = at.timeIntervalSince(now()), sleep = self.sleep
        timer = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock { self.timer = nil; self.timerAt = nil }
            await self.flush()
        }
    }
    private func backoffLocked(_ seconds: TimeInterval, token: Bool = false) {
        blockedUntil = now().addingTimeInterval(seconds); blockedForToken = token; armLocked(blockedUntil)
    }
    private func exponentialDelay() -> TimeInterval {
        let base = min(TelemetryLimits.maxBackoff, 5 * pow(2, Double(min(failures, 7)))); failures += 1
        return min(TelemetryLimits.maxBackoff, (base * (1 + 0.2 * random())).rounded())
    }

    // MARK: export

    /// One bounded pass: at most one batch (≤248 KiB), one OTLP request per signal present.
    @discardableResult public func flush() async -> Bool { await flush(background: false) }

    /// Flush while the app is going to the background. The client is usually paused by then, so the
    /// last access token obtained in this process is reused (in memory only); a 401 keeps the batch.
    @discardableResult public func flushForBackground() async -> Bool {
        for _ in 0..<4 {
            guard await flush(background: true), lock.withLock({ !queue.isEmpty }) else { break }
        }
        return lock.withLock { queue.isEmpty }
    }

    private func flush(background: Bool) async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let inflight { return inflight }
            let task = Task { [weak self] in
                let result = await self?.pass(background: background) ?? false
                self?.lock.withLock { self?.inflight = nil }
                return result
            }
            inflight = task; return task
        }
        return await task.value
    }

    private enum Signal: String, CaseIterable { case traces, logs, metrics }
    private func pass(background: Bool) async -> Bool {
        enum Plan { case stop(Bool), send([Item], Int, String?) }
        let plan: Plan = lock.withLock {
            guard enabledLocked() else { if !disposed && !forbidden { clearAllLocked() }; return .stop(false) }
            guard now() >= blockedUntil || (background && blockedForToken && lastToken != nil) else { return .stop(false) }
            collectMetricsLocked()
            timer?.cancel(); timer = nil; timerAt = nil
            guard !queue.isEmpty else { return .stop(true) }
            var batch: [Item] = [], bytes = 0
            while let first = queue.first, batch.isEmpty || bytes + first.size <= batchLimit {
                queue.removeFirst(); queuedBytes -= first.size; bytes += first.size; batch.append(first)
            }
            for item in batch { item.entry?.state = .inflight }
            return .send(batch, epoch, background ? lastToken : nil)
        }
        guard case .send(let batch, let ticket, let cached) = plan else { if case .stop(let v) = plan { return v }; return false }
        var token = cached
        if token == nil { token = await access.telemetryToken(refresh: false) }
        let live: Bool = lock.withLock {
            guard ticket == epoch else { return false }
            if let token { lastToken = token }
            return true
        }
        guard live else { return false }
        guard var token else {
            lock.withLock { requeueLocked(batch); backoffLocked(exponentialDelay(), token: true) }
            return false
        }
        let groups = Signal.allCases.map { signal in (signal, batch.filter { self.signal(of: $0.payload) == signal }) }.filter { !$0.1.isEmpty }
        for (index, (signal, items)) in groups.enumerated() {
            let rest = groups[(index + 1)...].flatMap(\.1)
            var reply = await post(signal, items, token, ticket)
            var refreshFailed = false
            if reply?.status == 401 {
                if let fresh = await access.telemetryToken(refresh: true) {
                    token = fresh; lock.withLock { if ticket == epoch { lastToken = fresh } }
                    reply = await post(signal, items, token, ticket)
                } else { refreshFailed = true }
            }
            let outcome: Bool? = lock.withLock {
                guard ticket == epoch else { return false }
                let status = reply?.status ?? 0
                switch status {
                case 200..<300:
                    sent += items.count; failures = 0; blockedForToken = false; for item in items { item.entry?.state = .sent }
                    return nil
                case 401 where refreshFailed:
                    // No fresh token (paused, offline or revoked): keep the data for the next pass.
                    requeueLocked(items + rest); backoffLocked(exponentialDelay(), token: !background); return false
                case 401:
                    reject(items); requeueLocked(rest); backoffLocked(exponentialDelay()); return false
                case 403:
                    forbidden = true; dropped += items.count + rest.count; clearAllLocked(); return false
                case 413:
                    if items.count > 1 {
                        splitting = true; batchLimit = max(1, items.reduce(0) { $0 + $1.size } / 2)
                        requeueLocked(items + rest); armLocked(now())
                    } else { reject(items); requeueLocked(rest); armLocked(now()) }
                    return false
                case 429:
                    let header = reply?.headers["retry-after"].flatMap(Double.init)
                    requeueLocked(items + rest)
                    backoffLocked(min(TelemetryLimits.maxRetryAfter, header.map { max(0, $0) } ?? TelemetryLimits.flushInterval)); return false
                case 0, 408, 500...:
                    requeueLocked(items + rest)
                    let header = reply?.headers["retry-after"].flatMap(Double.init)
                    backoffLocked(min(TelemetryLimits.maxRetryAfter, max(exponentialDelay(), header ?? 0))); return false
                default:
                    reject(items); return nil // 400 and other 4xx: never retry
                }
            }
            if let outcome { return outcome }
        }
        lock.withLock {
            guard ticket == epoch else { return }
            if (urgent || splitting) && !queue.isEmpty { armLocked(now()); return }
            urgent = false; splitting = false; batchLimit = TelemetryLimits.batchBytes
            if queue.count >= TelemetryLimits.flushItems || queuedBytes >= TelemetryLimits.flushBytes { armLocked(now()) }
            else if !queue.isEmpty || seriesTotal > 0 { armLocked(max(blockedUntil, windowStart.addingTimeInterval(TelemetryLimits.flushInterval))) }
        }
        return true
    }
    private func signal(of payload: Payload) -> Signal {
        switch payload { case .span: .traces; case .log: .logs; case .metric: .metrics }
    }
    private func reject(_ items: [Item]) { dropped += items.count; for item in items { item.entry?.state = .rejected } }
    private func requeueLocked(_ items: [Item]) {
        queue = items + queue; queuedBytes += items.reduce(0) { $0 + $1.size }
        for item in items { item.entry?.state = .queued }
        evictLocked()
    }
    private func post(_ signal: Signal, _ items: [Item], _ token: String, _ ticket: Int) async -> HTTPResponse? {
        guard let body = try? encode(signal, items) else { return HTTPResponse(status: 400, body: Data()) }
        var request = URLRequest(url: base.appendingPathComponent(signal.rawValue), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard lock.withLock({ guard ticket == epoch else { return false }; requests += 1; return true }) else { return nil }
        return try? await transport.send(request)
    }

    private struct ScopeBlock<T: Encodable>: Encodable {
        let scope: [String: String]
        let items: [T]
        let key: String
        struct Key: CodingKey { var stringValue: String; init(_ s: String) { stringValue = s }; init?(stringValue s: String) { stringValue = s }; var intValue: Int? { nil }; init?(intValue: Int) { nil } }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(scope, forKey: Key("scope")); try c.encode(items, forKey: Key(key))
        }
    }
    private struct ResourceBlock<T: Encodable>: Encodable {
        let resource: [KeyValue]
        let scopeKey: String
        let block: T
        typealias Key = ScopeBlock<Int>.Key
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(["attributes": resource], forKey: Key("resource")); try c.encode([block], forKey: Key(scopeKey))
        }
    }
    private struct MetricOut: Encodable {
        struct Data<P: Encodable>: Encodable { let aggregationTemporality: Int?; let isMonotonic: Bool?; let dataPoints: [P] }
        let name: String, unit: String?, description: String?
        let sum: Data<NumberPoint>?, gauge: Data<NumberPoint>?, exponentialHistogram: Data<ExponentialPoint>?
    }
    private func encode(_ signal: Signal, _ items: [Item]) throws -> Data {
        let encoder = JSONEncoder()
        func wrap<T: Encodable>(_ resourceKey: String, _ scopeKey: String, _ itemKey: String, _ list: [T]) throws -> Data {
            try encoder.encode([resourceKey: [ResourceBlock(resource: resource, scopeKey: scopeKey, block: ScopeBlock(scope: scope, items: list, key: itemKey))]])
        }
        switch signal {
        case .traces:
            return try wrap("resourceSpans", "scopeSpans", "spans", items.compactMap { if case .span(let s) = $0.payload { s } else { nil } })
        case .logs:
            return try wrap("resourceLogs", "scopeLogs", "logRecords", items.compactMap { if case .log(let l) = $0.payload { l } else { nil } })
        case .metrics:
            var order: [String] = [], numbers: [String: [NumberPoint]] = [:], hists: [String: [ExponentialPoint]] = [:], meta: [String: Instrument] = [:]
            for item in items {
                guard case .metric(let inst, let point) = item.payload else { continue }
                if meta[inst.name] == nil { order.append(inst.name); meta[inst.name] = inst }
                switch point { case .number(let p): numbers[inst.name, default: []].append(p); case .exponential(let p): hists[inst.name, default: []].append(p) }
            }
            let metrics = order.map { name -> MetricOut in
                let inst = meta[name]!
                return MetricOut(name: name, unit: inst.unit, description: inst.summary,
                                 sum: inst.kind == .counter ? .init(aggregationTemporality: 1, isMonotonic: true, dataPoints: numbers[name] ?? []) : nil,
                                 gauge: inst.kind == .gauge ? .init(aggregationTemporality: nil, isMonotonic: nil, dataPoints: numbers[name] ?? []) : nil,
                                 exponentialHistogram: inst.kind == .histogram ? .init(aggregationTemporality: 1, isMonotonic: nil, dataPoints: hists[name] ?? []) : nil)
            }
            return try wrap("resourceMetrics", "scopeMetrics", "metrics", metrics)
        }
    }

    // MARK: lifecycle

    public func stats() -> Stats {
        lock.withLock {
            let logs = ring.filter { if case .log = $0.payload { return true }; return false }.count
            return Stats(sent: sent, dropped: dropped, requests: requests, buffered: queue.count, bufferedBytes: queuedBytes, series: seriesTotal,
                         forbidden: forbidden, blockedUntil: blockedUntil, nextFlushAt: timerAt, ringLogs: logs, ringSpans: ring.count - logs)
        }
    }
    /// Stops recording and forgets everything buffered. Irreversible for this instance.
    public func dispose() {
        lock.withLock { clearAllLocked(); disposed = true }
        if let observer { access.enrollmentSignal.removeObserver(observer) }
        for token in lifecycle { NotificationCenter.default.removeObserver(token) }
        lifecycle = []
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        let background: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBackgroundFlush() }
        }
        lifecycle = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: background),
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main, using: background),
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { if !self.queue.isEmpty || self.seriesTotal > 0 { self.armLocked(max(self.blockedUntil, self.now())) } }
            }
        ]
        #endif
    }
    #if canImport(UIKit) && !os(watchOS)
    private final class BackgroundTask: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
    @MainActor private func beginBackgroundFlush() {
        let task = BackgroundTask()
        let end: @MainActor @Sendable () -> Void = {
            if task.id != .invalid { UIApplication.shared.endBackgroundTask(task.id); task.id = .invalid }
        }
        task.id = UIApplication.shared.beginBackgroundTask(withName: "framebriar.telemetry") { MainActor.assumeIsolated { end() } }
        Task { await self.flushForBackground(); await MainActor.run { end() } }
    }
    #endif
}

/// A live span. All methods are thread-safe no-ops after `end()` or when telemetry is off.
public final class TelemetrySpan: @unchecked Sendable {
    private weak var telemetry: Telemetry?
    private let lock = NSLock()
    private var record: SpanRecord?
    private let epoch: Int
    private let start: Date
    public let context: TelemetrySpanContext
    public var isRecording: Bool { lock.withLock { record != nil } }

    init(noop: Void) { telemetry = nil; record = nil; epoch = 0; start = .distantPast; context = TelemetrySpanContext(unchecked: "", "") }
    fileprivate init(telemetry: Telemetry, record: SpanRecord, context: TelemetrySpanContext, epoch: Int, start: Date) {
        self.telemetry = telemetry; self.record = record; self.context = context; self.epoch = epoch; self.start = start
    }
    @discardableResult public func setAttribute(_ key: String, _ value: TelemetryValue) -> Self {
        lock.withLock { if record != nil { setAttribute_(&record!.attributes, key, value) } }; return self
    }
    @discardableResult public func addEvent(_ name: String, _ attributes: TelemetryAttributes = [:], at time: Date? = nil) -> Self {
        let at = time ?? telemetry?.clock ?? Date()
        lock.withLock {
            guard record != nil, (record!.events?.count ?? 0) < TelemetryLimits.events else { return }
            record!.events?.append(SpanEventRecord(timeUnixNano: nanos(at), name: telemetryName(name, fallback: "event"),
                                                   attributes: telemetryAttributes(attributes, max: TelemetryLimits.eventAttributes)))
        }
        return self
    }
    /// Records an `exception` event with only the Swift error type (messages may hold user content).
    @discardableResult public func recordError(_ error: any Error, _ attributes: TelemetryAttributes = [:]) -> Self {
        addEvent("exception", attributes.merging(["exception.type": .string(String(describing: type(of: error)))]) { $1 })
    }
    @discardableResult public func setStatus(_ status: TelemetrySpanStatus) -> Self {
        lock.withLock { record?.status = SpanStatusRecord(code: status.code) }; return self
    }
    public func end(at time: Date? = nil) {
        let finished: SpanRecord? = lock.withLock {
            guard var r = record else { return nil }
            record = nil
            r.endTimeUnixNano = nanos(max(time ?? telemetry?.clock ?? Date(), start))
            if r.events?.isEmpty == true { r.events = nil }
            return r
        }
        if let finished { telemetry?.finish(finished, epoch: epoch) }
    }
}
private func setAttribute_(_ list: inout [KeyValue], _ key: String, _ value: TelemetryValue) { setAttribute(&list, key, value) }

/// Counter (`add`, monotonic delta sum), gauge or exponential histogram (`record`). No-op when telemetry is off.
public struct TelemetryInstrument: Sendable {
    let telemetry: Telemetry?
    let name: String
    public func add(_ value: Double, _ attributes: TelemetryAttributes = [:]) { telemetry?.measure(name, value, attributes) }
    public func record(_ value: Double, _ attributes: TelemetryAttributes = [:]) { telemetry?.measure(name, value, attributes) }
}

extension TelemetrySpanStatus { var code: Int { switch self { case .unset: 0; case .ok: 1; case .error: 2 } } }
