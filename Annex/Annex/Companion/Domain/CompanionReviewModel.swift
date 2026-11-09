import Foundation

/// Review's filters, from the desktop's (`ReviewFilters` in `reviewModel.ts`). The desktop's Remote filter isn't here:
/// every agent the phone sees is on another machine.
struct CompanionReviewFilters: Equatable, Sendable {
    /// On when Review opens from Needs you, off from Home, as the desktop's Needs you > Review applies it for the visit.
    var needsYouOnly = false
    var includeSleeping = false
}

/// One page in Review: an agent and where it runs.
struct CompanionReviewEntry: Identifiable, Equatable, Sendable {
    var agent: CompanionAgent
    var hostName: String
    var projectName: String
    var id: CompanionTarget { agent.id }
    /// The desktop's `filterNeedsAttention`: a permission request, a question, or an error.
    var needsYou: Bool { agent.status.needsYou }
    var isSleeping: Bool { agent.status.dot == .sleeping }
}

/// Why Review has no pages, so the empty state can say so and offer the fix (`EmptyCause`).
enum CompanionReviewEmptyCause: Equatable, Sendable {
    /// No agents on any connected desktop.
    case noAgents
    /// Every agent is asleep and Sleeping is off.
    case nothingRunning(sleepers: [CompanionReviewEntry])
    /// Needs you only is on and nobody is waiting.
    case nobodyNeedsYou(others: [CompanionReviewEntry])

    var title: String {
        switch self {
        case .noAgents: "No agents yet"
        case .nothingRunning: "Nothing is running"
        case .nobodyNeedsYou: "Nobody needs you"
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
        }
    }
}

/// Pure rules behind Review: which agents it steps through, in what order, and where it goes when one leaves.
enum CompanionReviewModel {
    /// The pages the filters let through, in desktop order (`filterAgents`, then `filterNeedsAttention`).
    static func visible(_ entries: [CompanionReviewEntry], filters: CompanionReviewFilters) -> [CompanionReviewEntry] {
        entries.filter { (filters.includeSleeping || !$0.isSleeping) && (!filters.needsYouOnly || $0.needsYou) }
    }

    /// Why nothing is shown (`emptyCause`). Only meaningful when `visible` is empty.
    static func emptyCause(_ all: [CompanionReviewEntry], filters: CompanionReviewFilters) -> CompanionReviewEmptyCause {
        if all.isEmpty { return .noAgents }
        let shown = all.filter { filters.includeSleeping || !$0.isSleeping }
        if filters.needsYouOnly && !shown.isEmpty { return .nobodyNeedsYou(others: shown) }
        return .nothingRunning(sleepers: all.filter(\.isSleeping))
    }

    /// Where to go when the page on screen leaves the list (answered with Needs you only on, or filtered out):
    /// the next page that's still there, else the one before it, as the desktop keeps the index and clamps it.
    /// Keeps `current` when it's still listed.
    static func successor(of current: CompanionTarget?, previous: [CompanionTarget], in ids: [CompanionTarget]) -> CompanionTarget? {
        guard let current, !ids.contains(current) else { return current ?? ids.first }
        let remaining = Set(ids)
        guard let index = previous.firstIndex(of: current) else { return ids.first }
        return previous[(index + 1)...].first(where: remaining.contains) ?? previous[..<index].last(where: remaining.contains) ?? ids.first
    }

    /// "3 of 7".
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
}

extension CompanionStore {
    /// Every agent on a connected desktop, in desktop order, as the desktop's Review steps through them.
    /// An offline desktop's agents are left out, as Home leaves them out: their state is stale. So are finished quick
    /// agents: the desktop moves an exited quick agent out of its agent list (`removeAgent` in `app-event-bridge.ts`),
    /// so its Review never shows one, though the phone keeps it in the catalog for the project page's Finished list.
    var reviewEntries: [CompanionReviewEntry] {
        hosts.filter { host in
            switch host.connection { case .offline, .failed: false; default: true }
        }.flatMap { host in
            // The Dispatcher comes first, as its row sits above the projects.
            (host.dispatcher?.liveAgent.map { [CompanionReviewEntry(agent: $0, hostName: host.name, projectName: CompanionDispatcher.name)] } ?? [])
            + host.projects.flatMap { project in
                project.agents.filter { !CompanionFinishedRuns.hasFinished($0) }
                    .map { CompanionReviewEntry(agent: $0, hostName: host.name, projectName: project.name) }
            }
        }
    }
}
