import Foundation

/// The system's finite background-task assertion (`UIApplication.beginBackgroundTask`), behind a protocol so
/// lifecycle code is unit-testable. It only asks for a few seconds to finish work already started; it keeps
/// nothing alive in the background and needs no entitlement or background mode.
@MainActor protocol CompanionBackgroundTasking {
    /// Returns nil when the system grants no background time. The system calls `expiration` on the main
    /// thread when that time runs out; the task must be ended before it returns.
    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int?
    func end(_ id: Int)
}

/// One background task, ended exactly once: when its work completes or when the system expires it,
/// whichever is first. A later `end()` is a no-op, so completion and expiration can both call it.
@MainActor final class CompanionBackgroundLease {
    // ARC-only teardown; stored fields and captures are reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    private let tasks: any CompanionBackgroundTasking
    private var id: Int?
    private(set) var isEnded = false

    private init(tasks: any CompanionBackgroundTasking) { self.tasks = tasks }

    /// Begins synchronously, so it must be called before the caller yields: once a background transition
    /// returns to the system, the process may be suspended before any queued task runs.
    /// The expiration handler retains the lease, so expiry can end the task even if its owner is gone.
    static func begin(_ name: String, on tasks: any CompanionBackgroundTasking) -> CompanionBackgroundLease {
        let lease = CompanionBackgroundLease(tasks: tasks)
        let id = tasks.begin(name: name) { lease.end() }
        if lease.isEnded { if let id { tasks.end(id) } }
        else { lease.id = id; if id == nil { lease.isEnded = true } }
        return lease
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        guard let id else { return }
        self.id = nil
        tasks.end(id)
    }

    /// Runs `work` inside its own background task and always ends that task afterwards.
    static func during<T>(_ name: String, on tasks: (any CompanionBackgroundTasking)?,
                          _ work: @MainActor () async -> T) async -> T {
        let lease = tasks.map { begin(name, on: $0) }
        defer { lease?.end() }
        return await work()
    }
}
