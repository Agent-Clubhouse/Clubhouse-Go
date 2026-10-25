import Foundation
import Observation

/// Holds a swiped approval decision for a short undo window before sending it.
/// Taps on Allow or Deny send straight away; only swipes go through here.
@MainActor @Observable final class CompanionDecisionQueue {
    struct Pending: Identifiable, Sendable, Equatable {
        var approval: CompanionApproval
        var option: CompanionApprovalOption
        var target: CompanionTarget
        var agentName: String
        var id: String { approval.id }
        var allows: Bool { option.kind == .allowOnce }
    }

    private(set) var pending: [Pending] = []
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let commit: @MainActor (Pending) async -> Void
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    init(delay: Duration = .seconds(3), commit: @escaping @MainActor (Pending) async -> Void) {
        self.delay = delay
        self.commit = commit
    }

    func isPending(_ approvalID: String) -> Bool { pending.contains { $0.id == approvalID } }

    func schedule(_ decision: Pending) {
        guard !isPending(decision.id) else { return }
        pending.append(decision)
        let delay = delay
        timers[decision.id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.send(decision.id)
        }
    }

    func undo(_ approvalID: String) {
        timers.removeValue(forKey: approvalID)?.cancel()
        pending.removeAll { $0.id == approvalID }
    }

    /// Sends now instead of waiting out the undo window.
    func send(_ approvalID: String) async {
        timers.removeValue(forKey: approvalID)?.cancel()
        guard let index = pending.firstIndex(where: { $0.id == approvalID }) else { return }
        let decision = pending.remove(at: index)
        await commit(decision)
    }
}
