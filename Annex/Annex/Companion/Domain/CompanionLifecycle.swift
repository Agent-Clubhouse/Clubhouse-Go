import Foundation
#if DEBUG && canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Inactive is transient (Control Center, permission sheets, foregrounding).
/// Background pre-empts a pending resume. A new foreground still waits for suspension to finish.
/// Each suspension runs inside its own finite background task, begun before `update` returns, so the suspend
/// path, including each socket's 1001 close request, is likely to run before iOS suspends the process. That is
/// best effort: the system may refuse or expire the task, and delivery of the close frame is not guaranteed.
/// The task ends when the suspension finishes or when the system expires it, whichever comes first; nothing
/// stays connected.
@MainActor final class CompanionLifecycle {
    // ARC-only teardown; transition captures are reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    enum Phase { case active, inactive, background }
    private var wantsActive = true
    private var pending: Task<Void, Never>?
    private var resume: Task<Void, Never>?
    private var suspension: Task<Void, Never>?
    private let transition: @MainActor (Bool) async -> Void
    private let backgroundTasks: (any CompanionBackgroundTasking)?

    init(backgroundTasks: (any CompanionBackgroundTasking)? = nil, transition: @escaping @MainActor (Bool) async -> Void) {
        self.backgroundTasks = backgroundTasks
        self.transition = transition
    }

    func update(_ phase: Phase) {
        guard phase != .inactive else { return }
        let active = phase == .active
        guard active != wantsActive else { return }
        wantsActive = active
        #if DEBUG
        let operation: AnnexDiagnosticOperation = active ? .foreground : .background
        AnnexTelemetry.shared.record(operation, event: .transitionQueued)
        #endif
        // Preparation may be awaiting slow network/Keychain work. Never put disconnect behind
        // it; cancellation plus the service's generation fences retire its late results.
        if !active { resume?.cancel(); resume = nil }
        let previous = suspension
        let transition = transition
        // Synchronously, before this phase change returns to the system. Only suspensions hold one.
        let lease = active ? nil : backgroundTasks.map { CompanionBackgroundLease.begin("companion.suspend", on: $0) }
        pending = Task {
            defer { lease?.end() }
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionWaiting)
            #endif
            await previous?.value
            guard !active || !Task.isCancelled else { return }
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionStarted)
            #endif
            await transition(active)
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionCompleted)
            #endif
        }
        if active { resume = pending }
        else { suspension = pending }
    }

    /// Wait for the latest requested phase, not a cancelled resume's uncooperative preparation.
    func settle() async { await pending?.value }
}
