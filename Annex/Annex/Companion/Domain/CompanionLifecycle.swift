import Foundation
#if DEBUG && canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Inactive is transient (Control Center, permission sheets, foregrounding).
/// Only background suspends; the next active phase resumes, in arrival order.
@MainActor final class CompanionLifecycle {
    // ARC-only teardown; transition captures are reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    enum Phase { case active, inactive, background }
    private var wantsActive = true
    private var pending: Task<Void, Never>?
    private let transition: @MainActor (Bool) async -> Void

    init(transition: @escaping @MainActor (Bool) async -> Void) {
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
        let previous = pending
        let transition = transition
        pending = Task {
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionWaiting)
            #endif
            await previous?.value
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionStarted)
            #endif
            await transition(active)
            #if DEBUG
            AnnexTelemetry.shared.record(operation, event: .transitionCompleted)
            #endif
        }
    }

    func settle() async { await pending?.value }
}
