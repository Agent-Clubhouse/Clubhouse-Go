import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// A tracing collector, modelled: records each request body, can hold the next sends until released or
/// cancelled, and answers with a settable status.
private actor PumpCollector: AnnexOTLPTransport {
    let log: BackgroundEventLog
    var status = 200
    private(set) var bodies: [String] = []
    private(set) var cancelled = 0
    private var holds = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<UUID> = []
    init(log: BackgroundEventLog) { self.log = log }
    var waiting: Int { waiters.count }
    func holdNext() { holds += 1 }
    func setStatus(_ value: Int) { status = value }
    func release() { for waiter in waiters.values { waiter.resume() }; waiters.removeAll() }

    func send(_ request: URLRequest) async throws -> AnnexOTLPResponse {
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        log.append("send")
        if holds > 0 {
            holds -= 1
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if cancelledEarly.remove(id) != nil { continuation.resume(throwing: CancellationError()) }
                    else { waiters[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        return .init(status: status)
    }
    private func cancel(_ id: UUID) {
        cancelled += 1
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(throwing: CancellationError()) }
        else { cancelledEarly.insert(id) }
    }
}

/// The pump's 30-second wait, under test control: it ends only when woken or cancelled.
private final class PumpNaps: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<UUID> = []
    private(set) var started = 0
    var napping: Int { lock.withLock { waiters.count } }
    var count: Int { lock.withLock { started } }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = lock.withLock {
                    started += 1
                    if cancelledEarly.remove(id) != nil { return true }
                    waiters[id] = continuation; return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock {
                if let waiter = waiters.removeValue(forKey: id) { return waiter as CheckedContinuation<Void, Error>? }
                cancelledEarly.insert(id); return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
    func wake() {
        let woken = lock.withLock { let all = Array(waiters.values); waiters.removeAll(); return all }
        for waiter in woken { waiter.resume() }
    }
}

@MainActor @Suite(.serialized) struct CompanionTelemetryPumpTests {
    @MainActor private struct Fixture {
        let log = BackgroundEventLog()
        let tasks: FakeBackgroundTasks
        let collector: PumpCollector
        let telemetry = AnnexTelemetry()
        let naps = PumpNaps()
        let exporter: AnnexOTLPExporter
        let pump: CompanionTelemetryPump
        let on: CompanionTelemetryPump.Consent
        var off: CompanionTelemetryPump.Consent { var value = on; value.enabled = false; return value }

        @MainActor init() throws {
            tasks = FakeBackgroundTasks(log: log)
            collector = PumpCollector(log: log)
            telemetry.setEnabled(true)
            exporter = AnnexOTLPExporter(transport: collector)
            let telemetry = telemetry, naps = naps
            pump = CompanionTelemetryPump(exporter: exporter, backgroundTasks: tasks,
                                          records: { telemetry.snapshot().records }, sleep: { try await naps.sleep($0) })
            on = .init(destination: try AnnexOTLPConfiguration(address: "https://collector.example.invalid/v1/traces"),
                       enabled: true, revision: UUID())
        }
        func set(_ phase: CompanionTelemetryPump.Phase, _ consent: CompanionTelemetryPump.Consent? = nil) {
            pump.update(.init(phase: phase, consent: consent ?? on))
        }
        /// A record captured now, after the session's first flush made the session's records eligible.
        func capture() -> String {
            telemetry.record(.wake)
            return telemetry.snapshot().records.last!.id
        }
    }

    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out", sourceLocation: sourceLocation); throw AnnexTransportError.disconnected
    }

    /// Active until the session's first flush has run (it only fixes eligibility) and the pump is waiting.
    private func activeAndIdle(_ f: Fixture, _ consent: CompanionTelemetryPump.Consent? = nil) async throws {
        f.set(.active, consent)
        try await wait { f.naps.napping == 1 }
        #expect(await f.collector.bodies.isEmpty)
    }

    @Test func backgroundSendsThePendingBatchOnceInsideItsBackgroundTask() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        let record = f.capture()
        f.set(.inactive)
        #expect(f.tasks.begun.isEmpty, "Inactive pauses; it takes no background time")
        f.set(.background)
        #expect(f.tasks.held == [1], "Begun synchronously at the phase change")
        try await wait { f.tasks.held.isEmpty }
        let bodies = await f.collector.bodies
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains(record) == true)
        #expect(f.log.entries == ["begin:1", "send", "end:1"], "The task ends after the send completes")
        #expect(f.tasks.ended == [1])
        #expect(await f.exporter.health().delivered == 1)
    }

    /// A request in flight when the app backgrounds is the one background flush: it completes under the task, and no
    /// second request follows it, even though a newer record became eligible meanwhile.
    @Test func aRequestInFlightAtBackgroundIsTheOnlyFlush() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        let first = f.capture()
        await f.collector.holdNext()
        f.naps.wake()
        try await wait { await f.collector.waiting == 1 }
        let later = f.capture()
        f.set(.inactive); f.set(.background)
        #expect(f.tasks.held == [1])
        await f.collector.release()
        try await wait { f.tasks.held.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let bodies = await f.collector.bodies
        #expect(bodies.count == 1, "No second request under the background task")
        #expect(bodies.first?.contains(first) == true)
        #expect(bodies.first?.contains(later) == false)
        #expect(f.log.entries == ["send", "begin:1", "end:1"])
        #expect(f.tasks.ended == [1] && f.tasks.endedExactlyOnce)
        #expect(await f.exporter.health().delivered == 1)
    }

    /// Inactive pauses: a nap ending while inactive sends nothing and takes no background time. Back to active, the
    /// same session sends what it captured meanwhile, once.
    @Test func inactivePausesFlushingAndActiveResumesTheSameSessionOnce() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        f.set(.inactive)
        let record = f.capture()
        f.naps.wake()
        try await wait { f.naps.napping == 1 && f.naps.count == 2 }
        f.naps.wake()
        try await wait { f.naps.napping == 1 && f.naps.count == 3 }
        #expect(await f.collector.bodies.isEmpty, "Nothing is sent while inactive")
        #expect(f.tasks.begun.isEmpty, "Inactive takes no background time")
        f.set(.active)
        f.naps.wake()
        try await wait { await f.collector.bodies.count == 1 }
        f.naps.wake()
        try await wait { f.naps.napping == 1 && f.naps.count == 5 }
        let bodies = await f.collector.bodies
        #expect(bodies.count == 1, "Exactly one send, no duplicate")
        // A new session would have excluded this record, captured before it began: this is the same session.
        #expect(bodies.first?.contains(record) == true)
        #expect(f.tasks.begun.isEmpty)
    }

    @Test func expiryCancelsTheRequestEndsTheTaskOnceAndCountsNothing() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        _ = f.capture()
        await f.collector.holdNext()
        f.set(.inactive); f.set(.background)
        try await wait { await f.collector.waiting == 1 }
        f.tasks.expire(1)
        #expect(f.tasks.ended == [1] && f.tasks.held.isEmpty)
        try await wait { await f.collector.cancelled == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.tasks.ended == [1], "Completion after expiry ends nothing twice")
        #expect(await f.collector.bodies.count == 1)
        #expect(await f.exporter.health().delivered == 0, "The cancelled request is fenced, not counted")
    }

    @Test func nothingIsSentOrHeldInTheBackgroundWithoutExportConsent() async throws {
        for variant in 0..<2 {
            let f = try Fixture()
            var consent = f.off
            if variant == 1 { consent = f.on; consent.destination = nil }
            try await activeAndIdle(f, consent)
            _ = f.capture()
            f.set(.inactive, consent); f.set(.background, consent)
            try await Task.sleep(for: .milliseconds(100))
            #expect(f.tasks.begun.isEmpty, "No background time without consent")
            #expect(await f.collector.bodies.isEmpty)
        }
    }

    @Test func revokingConsentMidExportCancelsItAndSendsNothingMore() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        _ = f.capture()
        await f.collector.holdNext()
        f.set(.inactive); f.set(.background)
        try await wait { await f.collector.waiting == 1 }
        f.set(.background, f.off)
        try await wait { await f.collector.cancelled == 1 }
        try await wait { f.tasks.held.isEmpty }
        #expect(f.tasks.ended == [1] && f.tasks.endedExactlyOnce)
        _ = f.capture()
        f.set(.active, f.off)
        try await wait { f.naps.napping == 1 }
        f.naps.wake()
        try await wait { f.naps.count >= 3 }
        #expect(await f.collector.bodies.count == 1, "Only the request begun before revocation")
        #expect(await f.exporter.health().delivered == 0)
    }

    @Test func aQuickForegroundNeitherCancelsNorRepeatsTheBackgroundExport() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        let first = f.capture()
        await f.collector.holdNext()
        f.set(.inactive); f.set(.background)
        try await wait { await f.collector.waiting == 1 }
        f.set(.inactive); f.set(.active)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.naps.count == 1, "The new session waits for the finishing one")
        await f.collector.release()
        try await wait { f.tasks.held.isEmpty }
        #expect(await f.exporter.health().delivered == 1, "The background export completed, not cancelled")
        try await wait { f.naps.napping == 1 && f.naps.count == 2 }
        let second = f.capture()
        f.naps.wake()
        try await wait { await f.collector.bodies.count == 2 }
        let bodies = await f.collector.bodies
        #expect(bodies[0].contains(first))
        #expect(bodies[1].contains(second))
        #expect(!bodies[1].contains(first), "The new session never resends the earlier session's records")
        #expect(f.tasks.begun == [1] && f.tasks.endedExactlyOnce)
    }

    @Test func aNewSessionNeverReusesTheEndedSessionsUnsentBatch() async throws {
        let f = try Fixture()
        try await activeAndIdle(f)
        let stale = f.capture()
        await f.collector.setStatus(503)
        f.naps.wake()
        try await wait { await f.collector.bodies.count == 1 }
        try await wait { f.naps.napping == 1 }
        await f.collector.setStatus(200)
        // The retained batch is in backoff, so the background flush sends nothing; the session ends and drops it.
        f.set(.inactive); f.set(.background)
        try await wait { f.tasks.held.isEmpty }
        #expect(await f.collector.bodies.count == 1)
        f.set(.active)
        try await wait { f.naps.napping == 1 && f.naps.count == 3 }
        let fresh = f.capture()
        f.naps.wake()
        try await wait { await f.collector.bodies.count == 2 }
        let body = await f.collector.bodies[1]
        #expect(body.contains(fresh))
        #expect(!body.contains(stale))
    }
}
