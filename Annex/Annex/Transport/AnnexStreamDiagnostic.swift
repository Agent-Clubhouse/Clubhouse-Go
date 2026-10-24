import Foundation

/// Observed live turn timing, not provider token accounting or prompt-to-response latency.
/// It accepts byte counts only; it never receives or retains response text.
nonisolated public final class AnnexStreamDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private let span: AnnexDiagnosticSpan
    private var lastMs: Double?
    private var maximumGap = 0.0
    private var chunks = 0
    private var bytes = 0
    private var ended = false
    public init(telemetry: AnnexTelemetry = .shared, parent: AnnexDiagnosticSpan? = AnnexTelemetry.current) {
        span = telemetry.begin(.stream, parent: parent)
    }
    public func chunk(byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.withLock {
            guard !ended else { return }
            let elapsed = span.elapsedMs
            if let lastMs {
                let gap = max(0, elapsed - lastMs)
                maximumGap = max(maximumGap, gap)
                span.number(.interChunkMs, gap)
            } else {
                span.number(.firstTokenMs, elapsed); span.event(.firstToken)
            }
            lastMs = elapsed
            chunks = min(1_000_000, chunks + 1)
            bytes = min(1_000_000_000, bytes + min(byteCount, 1_000_000_000))
            span.number(.chunks, Double(chunks)); span.number(.bytes, Double(bytes))
            span.number(.maxInterChunkMs, maximumGap)
            // Avoid one SDK event per delta: totals and last/max gap remain bounded.
        }
    }
    public func finish(_ failure: AnnexDiagnosticFailure = .none) {
        lock.withLock {
            guard !ended else { return }; ended = true
            if failure != .none { span.fail(failure) }
            span.event(failure == .cancelled ? .cancelled : .completed); span.end()
        }
    }
    deinit { finish(.abandoned) }
}

/// Legacy text is deliberately discarded, not regex-redacted after retaining it.
nonisolated public enum AnnexLegacyDiagnostic {
    public static func category(_ value: String) -> String {
        switch value {
        case "API", "WS", "TLS", "Pairing", "Discovery", "Store", "Session", "Auth": value
        default: "Other"
        }
    }
}
