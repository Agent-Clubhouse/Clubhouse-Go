import Foundation

/// Inactive is transient (Control Center, permission sheets, foregrounding).
/// Only background suspends; the next active phase resumes, in arrival order.
@MainActor final class CompanionLifecycle {
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
        let previous = pending
        let transition = transition
        pending = Task {
            await previous?.value
            await transition(active)
        }
    }

    func settle() async { await pending?.value }
}
