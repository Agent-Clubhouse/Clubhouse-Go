import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Ordered record of socket closes and background-task ends, across the socket actor and the main actor.
final class BackgroundEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var entries: [String] { lock.withLock { values } }
}

/// UIKit's background-task assertion, modelled: ids, held/ended bookkeeping and a test-driven expiration.
@MainActor final class FakeBackgroundTasks: CompanionBackgroundTasking {
    var refuses = false
    let log: BackgroundEventLog?
    private var next = 1
    private(set) var begun: [Int] = []
    private(set) var ended: [Int] = []
    private var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
    init(log: BackgroundEventLog? = nil) { self.log = log }
    var held: Set<Int> { Set(begun).subtracting(ended) }
    var endedExactlyOnce: Bool { ended.count == Set(ended).count && Set(ended).isSubset(of: Set(begun)) }

    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        guard !refuses else { return nil }
        let id = next; next += 1
        begun.append(id); expirations[id] = expiration
        log?.append("begin:\(id)")
        return id
    }
    func end(_ id: Int) {
        ended.append(id); expirations[id] = nil
        log?.append("end:\(id)")
    }
    /// As UIKit: calls the handler, which must end the task before returning.
    func expire(_ id: Int) { expirations[id]?() }
}

private actor LifecycleSocket: AnnexWebSocket {
    let index: Int
    let log: BackgroundEventLog
    private var initial = true
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closeCount = 0
    private(set) var pings = 0
    init(index: Int, log: BackgroundEventLog) { self.index = index; self.log = log }
    func receive() async throws -> Data {
        if initial {
            initial = false
            return Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)
        }
        guard closeCount == 0 else { throw AnnexTransportError.disconnected }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) {}
    func ping() { pings += 1 }
    /// Production's close is `URLSessionWebSocketTask.cancel(with: .goingAway)`, a 1001 close frame.
    func close() {
        guard closeCount == 0 else { return }
        closeCount = 1
        log.append("close:\(index)")
        pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil
    }
}

private actor LifecycleIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let log: BackgroundEventLog
    private(set) var paths: [String] = []
    private(set) var sockets: [LifecycleSocket] = []
    init(log: BackgroundEventLog) { self.log = log }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url!.path
        paths.append(path)
        let value: AnnexJSON
        if path.hasSuffix("/identity") {
            value = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if path.hasSuffix("/capabilities") {
            value = .object(["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]),
                             "idempotency": .object(["scope": .string("s"), "maxEntries": .integer(1), "ttlMs": .integer(1)])])
        } else { value = .array([]) }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = LifecycleSocket(index: sockets.count, log: log); sockets.append(socket); return socket
    }
}

/// A suspension point that ignores cancellation, like an already-dispatched I/O callback.
private actor TransitionGate {
    private var released = false
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; waiting = false; continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.serialized) struct CompanionBackgroundLifecycleTests {
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out", sourceLocation: sourceLocation); throw AnnexTransportError.disconnected
    }

    // MARK: The lease

    @Test func aLeaseEndsOnceOnCompletion() {
        let tasks = FakeBackgroundTasks()
        let lease = CompanionBackgroundLease.begin("t", on: tasks)
        #expect(tasks.held == [1])
        lease.end(); lease.end()
        #expect(tasks.ended == [1] && tasks.held.isEmpty)
    }

    @Test func expirationEndsTheLeaseAndCompletionThenDoesNothing() {
        let tasks = FakeBackgroundTasks()
        let lease = CompanionBackgroundLease.begin("t", on: tasks)
        tasks.expire(1)
        #expect(tasks.ended == [1] && lease.isEnded)
        lease.end()
        #expect(tasks.ended == [1])
    }

    @Test func expirationStillEndsTheTaskWhenNothingElseHoldsTheLease() {
        let tasks = FakeBackgroundTasks()
        _ = CompanionBackgroundLease.begin("t", on: tasks)
        tasks.expire(1)
        #expect(tasks.ended == [1] && tasks.held.isEmpty)
    }

    @Test func aRefusedTaskIsNeverEnded() {
        let tasks = FakeBackgroundTasks(); tasks.refuses = true
        let lease = CompanionBackgroundLease.begin("t", on: tasks)
        lease.end()
        #expect(tasks.begun.isEmpty && tasks.ended.isEmpty && lease.isEnded)
    }

    // MARK: Lifecycle with the real service and transport

    @MainActor private struct Fixture {
        let log = BackgroundEventLog()
        let tasks: FakeBackgroundTasks
        let io: LifecycleIO
        let clock = AnnexManualClock()
        let service: CompanionLiveService
        let store: CompanionStore
        let hostID: String
        let lifecycle: CompanionLifecycle

        @MainActor init(gate: TransitionGate? = nil) async throws {
            tasks = FakeBackgroundTasks(log: log)
            io = LifecycleIO(log: log)
            hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
            let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                           verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
            let credentials = MemoryAnnexCredentialStore()
            await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
            let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry(), clock: clock.clock)
            let service = CompanionLiveService()
            self.service = service
            store = CompanionStore(service: service); store.start()
            lifecycle = CompanionLifecycle(backgroundTasks: tasks) { active in
                if active { await service.resume() }
                else { await gate?.hold(); await service.suspend() }
            }
            await service.register(.init(host: host, alias: "Fixture", transport: transport))
        }
        var connection: CompanionConnection? { store.hosts.first?.connection }
        func stop() async { store.stop(); await service.suspend(); service.remove(hostID: hostID) }
    }

    @Test func backgroundClosesTheSocketInsideOneBackgroundTaskThatThenEnds() async throws {
        let f = try await Fixture()
        try await wait { f.connection == .connected }
        f.lifecycle.update(.inactive)
        #expect(f.tasks.begun.isEmpty, "Inactive is transient and takes no background time")
        f.lifecycle.update(.background)
        // Begun before update returned: before any queued work can run, and before iOS may suspend.
        #expect(f.tasks.held == [1])
        await f.lifecycle.settle()
        let socket = try #require(await f.io.sockets.first)
        #expect(await socket.closeCount == 1, "The close (1001 in production) was requested inside the task")
        try await wait { f.connection == .offline }
        #expect(f.tasks.held.isEmpty && f.tasks.ended == [1])
        #expect(f.log.entries == ["begin:1", "close:0", "end:1"], "The task ends only after the close")
        await f.stop()
    }

    @Test func expirationEndsTheTaskWhileSuspensionIsStillRunning() async throws {
        let gate = TransitionGate()
        let f = try await Fixture(gate: gate)
        try await wait { f.connection == .connected }
        f.lifecycle.update(.background)
        try await wait { await gate.waiting }
        f.tasks.expire(1)
        #expect(f.tasks.ended == [1] && f.tasks.held.isEmpty, "Expiration ends the task at once")
        await gate.release()
        await f.lifecycle.settle()
        #expect(f.tasks.ended == [1], "Completion after expiry ends nothing twice")
        #expect(await f.io.sockets.first?.closeCount == 1, "The suspension still finishes its clean close")
        await f.stop()
    }

    /// The system expires the task while suspend is still running, and the app foregrounds before that suspend finishes.
    /// The foreground waits for it, then reconnects; a second full cycle still takes and ends its own task.
    @Test func expiryMidSuspendThenForegroundReconnectsAndASecondCycleStillWorks() async throws {
        let gate = TransitionGate()
        let f = try await Fixture(gate: gate)
        try await wait { f.connection == .connected }
        f.lifecycle.update(.background)
        try await wait { await gate.waiting }
        f.tasks.expire(1)
        #expect(f.tasks.ended == [1] && f.tasks.held.isEmpty)
        f.lifecycle.update(.inactive)
        f.lifecycle.update(.active)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await f.io.sockets.count == 1, "Foreground cannot overtake the pending suspension")
        await gate.release()
        await f.lifecycle.settle()
        try await wait { f.connection == .connected }
        var sockets = await f.io.sockets
        #expect(sockets.count == 2)
        #expect(await sockets[0].closeCount == 1)
        #expect(await sockets[1].closeCount == 0)
        #expect(f.tasks.begun == [1] && f.tasks.ended == [1] && f.tasks.held.isEmpty)

        f.lifecycle.update(.background)
        #expect(f.tasks.held == [2])
        await f.lifecycle.settle()
        try await wait { f.connection == .offline }
        #expect(await sockets[1].closeCount == 1)
        f.lifecycle.update(.active)
        await f.lifecycle.settle()
        try await wait { f.connection == .connected }
        sockets = await f.io.sockets
        #expect(sockets.count == 3)
        #expect(await sockets[2].closeCount == 0)
        #expect(f.tasks.begun == [1, 2] && f.tasks.ended == [1, 2] && f.tasks.endedExactlyOnce && f.tasks.held.isEmpty)
        await f.stop()
    }

    @Test func rapidFlipsEndEveryTaskExactlyOnceAndNeverHoldOneInTheForeground() async throws {
        let gate = TransitionGate()
        let f = try await Fixture(gate: gate)
        try await wait { f.connection == .connected }
        for phase in [CompanionLifecycle.Phase.background, .inactive, .active, .background, .background, .inactive, .active, .background] {
            f.lifecycle.update(phase)
        }
        #expect(f.tasks.begun == [1, 2, 3], "One task per queued suspension, none for foregrounds or repeats")
        // The first suspension is inside its transition; the other two await the one before them.
        try await wait { await gate.waiting }
        #expect(f.tasks.held == [1, 2, 3], "Each queued suspension holds its task while it waits")
        await gate.release()
        await f.lifecycle.settle()
        #expect(f.tasks.held.isEmpty && f.tasks.endedExactlyOnce && f.tasks.ended.count == 3)
        try await wait { f.connection == .offline }
        f.lifecycle.update(.active)
        await f.lifecycle.settle()
        #expect(f.tasks.begun.count == 3, "Foreground takes no background time")
        try await wait { f.connection == .connected }
        #expect(f.tasks.held.isEmpty)
        await f.stop()
    }

    @Test func aRefusedBackgroundTaskStillSuspends() async throws {
        let f = try await Fixture()
        f.tasks.refuses = true
        try await wait { f.connection == .connected }
        f.lifecycle.update(.background)
        await f.lifecycle.settle()
        #expect(await f.io.sockets.first?.closeCount == 1)
        #expect(f.tasks.begun.isEmpty && f.tasks.ended.isEmpty)
        await f.stop()
    }

    /// Back in the foreground the closed socket is replaced at once: no ping interval, pong deadline or
    /// request timeout has to pass first. The manual clock never moves in this test.
    @Test func foregroundReconnectsImmediatelyWithoutWaitingOnAnyDeadline() async throws {
        let f = try await Fixture()
        try await wait { f.connection == .connected }
        f.lifecycle.update(.background)
        await f.lifecycle.settle()
        let start = f.clock.now
        f.lifecycle.update(.active)
        await f.lifecycle.settle()
        try await wait { f.connection == .connected }
        let sockets = await f.io.sockets
        #expect(sockets.count == 2)
        #expect(await sockets[1].closeCount == 0)
        #expect(await sockets[0].pings == 0, "No heartbeat was needed to find the closed socket")
        #expect(await sockets[1].pings == 0, "No heartbeat was needed to replace it")
        // Nothing in this test advances the clock: the reconnect needed no ping interval (20 s), pong deadline (10 s)
        // or request timeout (30 s) to pass.
        #expect(f.clock.now == start)
        #expect(f.tasks.held.isEmpty)
        await f.stop()
    }
}
