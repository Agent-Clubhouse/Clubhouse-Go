import Foundation

/// Review's filters, as the desktop's (`ReviewFilters` in `reviewModel.ts`). Needs you only is on when Review opens.
struct CompanionReviewFilters: Equatable, Sendable {
    var needsYouOnly = true
    var includeSleeping = true
    /// The desktop's Remote filter hides agents on other machines. The phone reaches every desktop remotely,
    /// so here it hides agents on desktops that aren't connected: their state is from the last snapshot.
    var includeRemote = false
}

/// One card in Review: an agent, where it runs and what it waits on.
struct CompanionReviewEntry: Identifiable, Equatable, Sendable {
    var agent: CompanionAgent
    var hostName: String
    var projectName: String
    /// The agent's desktop is offline or failed to connect.
    var isRemote = false
    /// What it waits on, when it's in Needs you.
    var attention: CompanionAttentionItem.Kind?
    var id: CompanionTarget { agent.id }
    var needsYou: Bool { attention != nil || agent.status.needsYou }
    var isSleeping: Bool { agent.status.dot == .sleeping }
}

/// Why Review has no cards, so the empty state can say so and offer the fix (`EmptyCause`).
enum CompanionReviewEmptyCause: Equatable, Sendable {
    /// No agents on any paired desktop.
    case noAgents
    /// Every agent is asleep and Sleeping is off.
    case nothingRunning(sleepers: [CompanionReviewEntry])
    /// Needs you only is on and nobody is waiting.
    case nobodyNeedsYou(others: [CompanionReviewEntry])
    /// The Sleeping and Remote filters hide everyone. Each count is how many turning that filter on would show.
    case filtered(total: Int, hiddenBySleeping: Int, hiddenByRemote: Int)

    var title: String {
        switch self {
        case .noAgents: "No agents yet"
        case .nothingRunning: "Nothing is running"
        case .nobodyNeedsYou: "Nobody needs you"
        case .filtered(let total, _, _): total == 1 ? "Your filters hide the only agent" : "Your filters hide all \(CompanionReviewModel.agentCount(total))"
        }
    }

    var message: String {
        switch self {
        case .noAgents:
            "Agents you start show up here, one at a time."
        case .nothingRunning(let sleepers):
            "\(sleepers.count == 1 ? "1 agent is" : "\(sleepers.count) agents are") asleep. Turn on Sleeping to step through them, or wake one here."
        case .nobodyNeedsYou(let others):
            "\(CompanionReviewModel.describe(others)). One shows up here when it asks for permission or hits an error."
        case .filtered(_, let sleeping, let remote):
            sleeping + remote > 0 ? "Turn one of these on, or clear the filters." : "Clear the filters to see them."
        }
    }
}

/// Pure rules behind Review: which agents it steps through, in what order, and where it goes after each one.
enum CompanionReviewModel {
    /// Needs you first, in its order, then every other agent in the order given.
    static func ordered(_ entries: [CompanionReviewEntry], attentionOrder: [CompanionTarget]) -> [CompanionReviewEntry] {
        let rank = Dictionary(attentionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                if lhs.element.needsYou != rhs.element.needsYou { return lhs.element.needsYou }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The cards the filters let through, keeping their order (`filterAgents`, `filterRemoteAgents`, `filterNeedsAttention`).
    static func visible(_ entries: [CompanionReviewEntry], filters: CompanionReviewFilters) -> [CompanionReviewEntry] {
        entries.filter { entry in
            (filters.includeSleeping || !entry.isSleeping) && (filters.includeRemote || !entry.isRemote) && (!filters.needsYouOnly || entry.needsYou)
        }
    }

    /// Why nothing is shown (`emptyCause`). Only meaningful when `visible` is empty.
    static func emptyCause(_ all: [CompanionReviewEntry], filters: CompanionReviewFilters) -> CompanionReviewEmptyCause {
        if all.isEmpty { return .noAgents }
        let passSleeping = { (entry: CompanionReviewEntry) in filters.includeSleeping || !entry.isSleeping }
        let passRemote = { (entry: CompanionReviewEntry) in filters.includeRemote || !entry.isRemote }
        let shown = all.filter { passSleeping($0) && passRemote($0) }
        if filters.needsYouOnly && !shown.isEmpty { return .nobodyNeedsYou(others: shown) }
        if !filters.includeSleeping && all.allSatisfy(\.isSleeping) {
            let reachable = all.filter(passRemote)
            return .nothingRunning(sleepers: reachable.isEmpty ? all : reachable)
        }
        return .filtered(total: all.count,
                         hiddenBySleeping: filters.includeSleeping ? 0 : all.filter { $0.isSleeping && passRemote($0) }.count,
                         hiddenByRemote: filters.includeRemote ? 0 : all.filter { $0.isRemote && passSleeping($0) }.count)
    }

    /// The card after `id`, wrapping to the first. Nil when there's no other card to go to.
    static func next(after id: CompanionTarget, in ids: [CompanionTarget]) -> CompanionTarget? {
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        guard ids.count > 1 else { return nil }
        return ids[(index + 1) % ids.count]
    }

    /// Where to go when the card on screen leaves the list (answered, or filtered out): the next card that's
    /// still there, else the one before it. Keeps `current` when it's still listed.
    static func successor(of current: CompanionTarget?, previous: [CompanionTarget], in ids: [CompanionTarget]) -> CompanionTarget? {
        guard let current, !ids.contains(current) else { return current ?? ids.first }
        let remaining = Set(ids)
        guard let index = previous.firstIndex(of: current) else { return ids.first }
        return previous[(index + 1)...].first(where: remaining.contains) ?? previous[..<index].last(where: remaining.contains) ?? ids.first
    }

    /// "2 of 5".
    static func position(of id: CompanionTarget?, in ids: [CompanionTarget]) -> String? {
        guard let id, let index = ids.firstIndex(of: id) else { return nil }
        return "\(index + 1) of \(ids.count)"
    }

    /// "1 agent", "3 agents".
    static func agentCount(_ n: Int) -> String { "\(n) agent\(n == 1 ? "" : "s")" }

    /// "3 agents are running", "2 agents are running and 1 is asleep", "1 agent is asleep" (`describeAgents`).
    static func describe(_ entries: [CompanionReviewEntry]) -> String {
        let asleep = entries.filter(\.isSleeping).count
        let running = entries.count - asleep
        func verb(_ n: Int) -> String { n == 1 ? "is" : "are" }
        if running > 0 && asleep > 0 { return "\(agentCount(running)) \(verb(running)) running and \(asleep) \(verb(asleep)) asleep" }
        if asleep > 0 { return "\(agentCount(asleep)) \(verb(asleep)) asleep" }
        return "\(agentCount(running)) \(verb(running)) running"
    }

    /// "on Studio Mac" for one desktop, "on 2 desktops" for more (`useRemoteWhere`).
    static func remoteWhere(_ entries: [CompanionReviewEntry]) -> String {
        let hosts = Set(entries.filter(\.isRemote).map(\.agent.id.hostID))
        if hosts.count == 1, let name = entries.first(where: { $0.isRemote })?.hostName { return "on \(name)" }
        return "on \(hosts.count) desktops"
    }

    /// The latest thing the agent said, for the card's preview.
    static func latestReply(in items: [CompanionTimelineItem]) -> CompanionMessage? {
        for item in items.reversed() {
            if case .message(let message) = item, message.role == .assistant, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        return nil
    }
}

extension CompanionStore {
    /// Every agent as a Review card: Needs you first in its order, then the rest by latest activity.
    func reviewEntries(now: Date = Date()) -> [CompanionReviewEntry] {
        let attention = attentionItems(now: now)
        let kinds = Dictionary(attention.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let entries = agentsNeedsYouFirst().compactMap { agent -> CompanionReviewEntry? in
            guard let host = host(for: agent.id), let project = host.projects.first(where: { $0.id == agent.id.projectID }) else { return nil }
            let remote = switch host.connection { case .offline, .failed: true; default: false }
            return .init(agent: agent, hostName: host.name, projectName: project.name, isRemote: remote, attention: kinds[agent.id])
        }
        return CompanionReviewModel.ordered(entries, attentionOrder: attention.map(\.id))
    }
}
