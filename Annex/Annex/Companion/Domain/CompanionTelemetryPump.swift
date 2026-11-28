import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// The tracing-collector pump around the existing `AnnexOTLPExporter`: one exporter session at a time, flushing
/// about every 30 seconds while the app is active. Inactive (Control Center, a permission sheet, the way to the
/// background) pauses flushing without ending the session.
///
/// On entering the background, and only while export consent is on, it begins a finite background task at that
/// phase change and flushes the session once more: the same exporter, endpoint, consent check, eligibility, encode
/// allowlist and limits (one batch, at most 64 spans and 256 KiB, the 10 s request and 15 s resource timeouts, the
/// existing backoff). A request already in flight is that one flush. Then the session ends as before, and anything
/// unsent is dropped. It is best effort: the system may refuse or expire the task, and expiry cancels the request,
/// whose late result the exporter's generation fence ignores. Any consent change (disable, destination, mode, clear)
/// cancels every session at once. A foreground starts a new session only after a finishing one has ended, and a new
/// session never sends records captured before it began.
@MainActor final class CompanionTelemetryPump {
    // ARC-only teardown; stored fields and captures are reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}

    enum Phase: Equatable, Sendable { case active, inactive, background }
    struct Consent: Equatable, Sendable {
        var destination: AnnexOTLPConfiguration?
        /// Collector export confirmed and collection on.
        var enabled: Bool
        /// Changes when captured diagnostics are cleared.
        var revision: UUID
        var exports: Bool { enabled && destination != nil }
    }
    struct Inputs: Equatable, Sendable {
        var phase: Phase
        var consent: Consent
    }
    private struct Run {
        let task: Task<Void, Never>
        var finishing = false
        var nap: Task<Void, Never>?
        var lease: CompanionBackgroundLease?
    }

    private let exporter: AnnexOTLPExporter
    private let backgroundTasks: (any CompanionBackgroundTasking)?
    private let records: @Sendable () -> [AnnexDiagnosticRecord]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var inputs: Inputs?
    private var runs: [UUID: Run] = [:]
    private var current: UUID?
    private var latest: Task<Void, Never>?

    init(exporter: AnnexOTLPExporter, backgroundTasks: (any CompanionBackgroundTasking)?,
         records: @escaping @Sendable () -> [AnnexDiagnosticRecord] = { AnnexTelemetry.shared.snapshot().records },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.exporter = exporter; self.backgroundTasks = backgroundTasks; self.records = records; self.sleep = sleep
    }

    /// Call synchronously on every phase or consent change, before yielding: a background task begun later
    /// may never run.
    func update(_ new: Inputs) {
        let old = inputs
        guard old != new else { return }
        inputs = new
        if old?.consent != new.consent {
            for id in runs.keys { stop(id) }
        }
        switch new.phase {
        case .active:
            if current == nil { start() }
        case .inactive:
            break
        case .background:
            guard let id = current else { return }
            current = nil
            guard new.consent.exports, let backgroundTasks else { stop(id); return }
            runs[id]?.finishing = true
            runs[id]?.lease = CompanionBackgroundLease.begin("companion.telemetry", on: backgroundTasks) { [weak self] in
                self?.stop(id)
            }
            runs[id]?.nap?.cancel()
        }
    }

    private func start() {
        let id = UUID(), previous = latest
        let exporter = exporter, records = records, sleep = sleep
        let task = Task { [weak self] in
            await previous?.value
            if let session = await exporter.beginSession() {
                while !Task.isCancelled, let self, let run = self.runs[id] {
                    if run.finishing || (self.current == id && self.inputs?.phase == .active) {
                        let consent = self.inputs?.consent
                        await exporter.flush(configuration: consent?.destination, enabled: consent?.enabled ?? false,
                                             records: records(), session: session)
                        // The flush begun while finishing, or the one in flight when finishing began, is the last.
                        if run.finishing || self.runs[id]?.finishing == true { break }
                    }
                    guard !Task.isCancelled, self.runs[id]?.finishing == false else { continue }
                    let nap = Task { _ = try? await sleep(.seconds(30)) }
                    self.runs[id]?.nap = nap
                    await nap.value
                }
                await exporter.endSession(session)
            }
            self?.finish(id)
        }
        runs[id] = Run(task: task)
        current = id
        latest = task
    }

    /// Cancels the session's request in flight, if any; the exporter resets and fences its late result.
    private func stop(_ id: UUID) {
        runs[id]?.task.cancel()
        runs[id]?.nap?.cancel()
        if current == id { current = nil }
    }

    private func finish(_ id: UUID) {
        runs.removeValue(forKey: id)?.lease?.end()
        if current == id { current = nil }
    }
}
