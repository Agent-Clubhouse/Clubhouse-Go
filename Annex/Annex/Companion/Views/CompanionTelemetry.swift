import Foundation
import Framebriar
import ClubhouseTransport

/// Framebriar telemetry for users enrolled in developer feedback (framebriar adapters/swift README,
/// "Clubhouse Go integration recipe"). Enrolling turns it on; nothing is recorded or sent before that,
/// and clearing enrollment stops it and forgets everything queued.
///
/// The app's closed-enum diagnostics (`AnnexTelemetry`) are captured while enrolled and forwarded as they
/// complete, mapped onto `app.*` by `AnnexAppTelemetry`, with their span IDs and events kept, so a feedback
/// report's incident trace references point at exported spans. The user's own OTLP collector is separate
/// and unchanged: it still needs Connection diagnostics on and its own consent.
@MainActor final class CompanionTelemetry {
    let telemetry: Telemetry
    private let source: AnnexTelemetry
    private let enrollment: EnrollmentSignal
    private var observer: UUID?
    private var lastSummary: Date
    private let now: @Sendable () -> Date
    #if canImport(MetricKit) && os(iOS)
    private var metricKit: MetricKitDiagnostics?
    #endif

    init(client: Client, configuration: Configuration, source: AnnexTelemetry = .shared, transport: any HTTPTransport = URLSessionTransport(),
         observeAppLifecycle: Bool = true, bundle: Bundle = .main, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let version = CompanionBuildInfo.version(bundle: bundle)
        // Background flush (didEnterBackground/willTerminate) is the SDK's own lifecycle observer.
        telemetry = try Telemetry(client: client, configuration: configuration, appVersion: version.version, appBuild: version.build,
                                  commonAttributes: CompanionTelemetryForwarder.attributes(AnnexAppTelemetry.commonAttributes),
                                  transport: transport, observeAppLifecycle: observeAppLifecycle, now: now)
        self.source = source; self.enrollment = client.enrollmentSignal; self.now = now; lastSummary = now()
        source.setRecordSink { [telemetry] record in
            CompanionTelemetryForwarder.forward(AnnexAppTelemetry.signals(for: record), to: telemetry)
        }
        source.setEnrolledCapture(enrollment.isEnrolled(at: now()))
        observer = enrollment.observe { [source, telemetry] enrolled in
            source.setEnrolledCapture(enrolled)
            if enrolled { telemetry.log(.info, "app.session.start") }
        }
    }

    /// Once at launch: the session start (a no-op unless enrolled) and, as the recipe recommends for Go,
    /// MetricKit crash and hang diagnostics, which iOS delivers on a later launch and the SDK drops unless enrolled.
    func start(metricKit: Bool = true) {
        telemetry.log(.info, "app.session.start")
        #if canImport(MetricKit) && os(iOS)
        if metricKit, self.metricKit == nil {
            let diagnostics = MetricKitDiagnostics(telemetry: telemetry)
            diagnostics.start(); self.metricKit = diagnostics
        }
        #endif
    }

    /// From the foreground pump: routine summaries (pings) at most once a minute, or now when `force`.
    func tick(force: Bool = false) {
        guard force || now().timeIntervalSince(lastSummary) >= AnnexAppTelemetry.summaryInterval else { return }
        lastSummary = now()
        for summary in source.drainSummaries() {
            CompanionTelemetryForwarder.forward(AnnexAppTelemetry.signals(for: summary), to: telemetry)
        }
    }

    /// Tests only: the app keeps one instance for its lifetime.
    func stop() {
        if let observer { enrollment.removeObserver(observer) }
        observer = nil
        source.setRecordSink(nil); source.setEnrolledCapture(false)
        #if canImport(MetricKit) && os(iOS)
        metricKit?.stop(); metricKit = nil
        #endif
        telemetry.dispose()
    }
}

/// Converts mapped signals to SDK calls; runs on whichever thread completed the span.
nonisolated enum CompanionTelemetryForwarder {
    static func attributes(_ values: [String: AnnexAppTelemetry.Value]) -> TelemetryAttributes {
        values.mapValues { value in
            switch value {
            case .string(let text): .string(text)
            case .int(let number): .int(number)
            case .double(let number): .double(number)
            case .bool(let flag): .bool(flag)
            }
        }
    }
    static func forward(_ signals: [AnnexAppTelemetry.Signal], to telemetry: Telemetry) {
        for signal in signals {
            switch signal {
            case .span(let span):
                guard let context = try? TelemetrySpanContext(traceID: span.traceID, spanID: span.spanID),
                      let recorded = try? RecordedSpan(context: context, parentSpanID: span.parentID, name: span.name,
                                                       kind: TelemetrySpanKind(rawValue: span.kind) ?? .internalKind,
                                                       start: span.start, end: span.end, attributes: attributes(span.attributes),
                                                       events: span.events.map { RecordedSpan.Event(name: $0.name, time: $0.time) },
                                                       status: span.failed ? .error : .ok) else { continue }
                telemetry.record(recorded)
            case .log(let event, let severity, let values, let traceID, let spanID):
                let parent = traceID.flatMap { trace in spanID.flatMap { try? TelemetrySpanContext(traceID: trace, spanID: $0) } }
                let level: TelemetrySeverity = switch severity { case .info: .info; case .warn: .warn; case .error: .error }
                telemetry.log(level, event, attributes(values), parent: parent)
            case .counter(let name, let unit, let value, let values):
                telemetry.counter(name, unit: unit).add(value, attributes(values))
            case .histogram(let name, let unit, let value, let values):
                telemetry.histogram(name, unit: unit).record(value, attributes(values))
            }
        }
    }
}
