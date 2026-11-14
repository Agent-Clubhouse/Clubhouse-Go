import Foundation

/// Requests recovered outside the transcript tail still precede newer requests; submitting stays until settled.
enum CompanionPendingDecision: Equatable, Identifiable {
    case approval(CompanionApproval)
    case question(CompanionQuestion)

    var id: String {
        switch self {
        case .approval(let value): "approval:\(value.id)"
        case .question(let value): "question:\(value.id)"
        }
    }
    var summary: String {
        switch self {
        case .approval(let value): value.title ?? value.toolName
        case .question(let value): value.prompts.first?.text ?? "The agent has a question"
        }
    }
    var isSubmitting: Bool {
        switch self {
        case .approval(let value): value.resolution == .submitting
        case .question(let value): value.resolution == .submitting
        }
    }
    private var requestedAt: Date? {
        switch self {
        case .approval(let value): value.requestedAt
        case .question(let value): value.requestedAt
        }
    }
    static func pending(in items: [CompanionTimelineItem], at date: Date = .now) -> [Self] {
        let pending: [Self] = items.compactMap { item in
            switch item {
            case .approval(let value) where value.resolution == .submitting
                || (value.resolution == .pending && !value.isExpired(at: date)): .approval(value)
            case .question(let value) where value.resolution == .pending || value.resolution == .submitting: .question(value)
            default: nil
            }
        }
        // Undated legacy requests retain transcript order ahead of dated requests; equal dates retain transcript ties.
        return pending.enumerated().sorted {
            let left = $0.element.requestedAt ?? .distantPast
            let right = $1.element.requestedAt ?? .distantPast
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    static func selected(in queue: [Self], id: String?) -> Self? {
        queue.first { $0.id == id } ?? queue.first
    }
}

/// A presented callback cannot answer a same-ID replacement, a new session, or a restarted desktop.
struct CompanionDecisionPresentation: Equatable {
    let target: CompanionTarget
    let epoch: String?
    let sessionID: String?
    let decision: CompanionPendingDecision
}

extension CompanionStore {
    func decisionPresentation(_ decision: CompanionPendingDecision, target: CompanionTarget) -> CompanionDecisionPresentation {
        .init(target: target, epoch: host(for: target)?.controlEpoch,
              sessionID: conversation(for: target).sessionID, decision: decision)
    }

    func currentDecision(for presentation: CompanionDecisionPresentation) -> CompanionPendingDecision? {
        guard host(for: presentation.target)?.controlEpoch == presentation.epoch,
              conversation(for: presentation.target).sessionID == presentation.sessionID else { return nil }
        return CompanionPendingDecision.pending(in: conversation(for: presentation.target).items)
            .first { $0 == presentation.decision }
    }

    func respond(_ presentation: CompanionDecisionPresentation, option: CompanionApprovalOption) async {
        guard case .approval(let approval) = currentDecision(for: presentation) else { return }
        await respond(approval, option: option, target: presentation.target)
    }

    func answer(_ presentation: CompanionDecisionPresentation, answers: [String: CompanionAnswer]) async {
        guard case .question(let question) = currentDecision(for: presentation) else { return }
        await answer(question, answers: answers, target: presentation.target)
    }
}
