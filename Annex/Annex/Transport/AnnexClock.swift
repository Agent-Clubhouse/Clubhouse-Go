import Foundation

/// Wall time and waiting for the transport and the companion store. `.live` is the system clock;
/// tests inject `AnnexManualClock` so timeouts and retry waits run without real sleeps.
public struct AnnexClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static let live = AnnexClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// A clock that only moves when `advance(by:)` is called. Sleepers wake in deadline order once time
/// passes their deadline; a cancelled sleeper throws `CancellationError` like `Task.sleep`.
public final class AnnexManualClock: @unchecked Sendable {
    private struct Sleeper { let deadline: Duration; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private let origin: Date
    private var elapsed: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init(origin: Date = Date()) { self.origin = origin }

    public var clock: AnnexClock { AnnexClock(now: { [self] in now }, sleep: { [self] in try await sleep(for: $0) }) }

    public var now: Date {
        lock.withLock { origin.addingTimeInterval(Self.seconds(elapsed)) }
    }
    /// Sleeps not yet woken or cancelled.
    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Returns once at least `count` sleepers are waiting, so a test advances only after the code under test has started its wait.
    public func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if sleepers.count >= count { return true }
                waiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    public func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            elapsed += duration
            let due = sleepers.filter { $0.value.deadline <= elapsed }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case wait, wake, cancel }
                let (outcome, ready): (Outcome, [CheckedContinuation<Void, Never>]) = lock.withLock {
                    if cancelled.remove(id) != nil { return (.cancel, []) }
                    if duration <= .zero { return (.wake, []) }
                    sleepers[id] = Sleeper(deadline: elapsed + duration, continuation: continuation)
                    let ready = waiters.filter { $0.count <= sleepers.count }.map(\.continuation)
                    waiters.removeAll { $0.count <= sleepers.count }
                    return (.wait, ready)
                }
                for waiter in ready { waiter.resume() }
                switch outcome {
                case .wait: break
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let sleeper = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return nil }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
