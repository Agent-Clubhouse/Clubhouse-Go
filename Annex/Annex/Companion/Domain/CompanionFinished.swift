import Foundation

/// A quick agent that has exited, kept until it's dismissed: one row of the desktop's "Finished, waiting on you"
/// (Clubhouse `ProjectStartPage.tsx`, `quickAgentStore.ts`).
///
/// The desktop keeps its list in its own window, not on the Annex surface, and forgets a quick agent a minute after
/// it exits. So the phone keeps its own list of the quick agents it saw exit, under the desktop's rules.
struct CompanionFinishedRun: Codable, Identifiable, Sendable, Equatable {
    var target: CompanionTarget
    var name: String
    var mission: String
    /// The process exit code, when the desktop's `agent:completed` reached the phone.
    var exitCode: Int?
    var status: CompanionAgentStatus
    var completedAt: Date
    var id: CompanionTarget { target }

    /// The desktop shows the mission, or the name when there is none.
    var title: String { mission.isEmpty ? name : mission }
    /// The desktop's second line is "Exited with code N" for a non-zero exit, else the agent's summary or its file
    /// count. Neither of those reaches the phone, so a clean exit just says it finished.
    var detail: String {
        if let exitCode, exitCode != 0 { return "Exited with code \(exitCode)" }
        switch status {
        case .failed: return "Stopped with an error"
        case .stopped: return "Cancelled"
        default: return "Finished"
        }
    }
    var failed: Bool { (exitCode ?? 0) != 0 || status == .failed }

    /// The desktop's `ago`: "just now", then minutes, hours and days, each rounded.
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded()))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "\(hours)h ago" }
        return "\(Int((Double(hours) / 24).rounded()))d ago"
    }
}

/// Every project's finished quick agents, newest first, as the desktop keeps them.
struct CompanionFinishedRuns: Codable, Sendable, Equatable {
    /// The desktop's `MAX_COMPLETED_AGENTS`, per project.
    static let maximumPerProject = 50
    /// Dismissed agents still in a desktop's catalog must not come back, so their ids are kept for a while.
    static let maximumDismissed = 500

    private(set) var runs: [CompanionFinishedRun] = []
    private(set) var dismissed: [CompanionTarget] = []

    /// A quick agent whose process has exited, however it ended.
    static func hasFinished(_ agent: CompanionAgent) -> Bool { agent.isQuick && agent.hasExited }

    func runs(in project: CompanionProjectTarget) -> [CompanionFinishedRun] {
        runs.filter { $0.target.hostID == project.hostID && $0.target.projectID == project.projectID }
    }

    /// Adds each finished quick agent not already listed or dismissed. Returns whether anything changed.
    @discardableResult mutating func observe(_ hosts: [CompanionHost], now: Date) -> Bool {
        var changed = false
        for host in hosts {
            for project in host.projects {
                for agent in project.agents where Self.hasFinished(agent) {
                    if record(agent, now: now) { changed = true }
                }
            }
        }
        return changed
    }

    @discardableResult mutating func record(_ agent: CompanionAgent, now: Date) -> Bool {
        guard Self.hasFinished(agent), !dismissed.contains(agent.id) else { return false }
        if let index = runs.firstIndex(where: { $0.target == agent.id }) {
            // A later report can bring the exit code.
            guard runs[index].exitCode == nil, let code = agent.exitCode else { return false }
            runs[index].exitCode = code
            runs[index].status = agent.status
            return true
        }
        // The desktop stamps the run when it exits; its last activity is that moment.
        let completedAt = min(agent.lastActivity ?? now, now)
        let run = CompanionFinishedRun(target: agent.id, name: agent.name, mission: agent.subtitle, exitCode: agent.exitCode,
                                       status: agent.status, completedAt: completedAt)
        runs.insert(run, at: runs.firstIndex { $0.completedAt <= completedAt } ?? runs.endIndex)
        let project = CompanionProjectTarget(hostID: agent.id.hostID, projectID: agent.id.projectID)
        let extra = runs(in: project).dropFirst(Self.maximumPerProject).map(\.target)
        runs.removeAll { extra.contains($0.target) }
        return true
    }

    mutating func dismiss(_ target: CompanionTarget) {
        runs.removeAll { $0.target == target }
        remember(dismissed: [target])
    }

    /// The desktop's "Clear all", for one project.
    mutating func clear(_ project: CompanionProjectTarget) {
        let cleared = runs(in: project).map(\.target)
        runs.removeAll { cleared.contains($0.target) }
        remember(dismissed: cleared)
    }

    private mutating func remember(dismissed targets: [CompanionTarget]) {
        dismissed.removeAll { targets.contains($0) }
        dismissed.append(contentsOf: targets)
        if dismissed.count > Self.maximumDismissed { dismissed.removeFirst(dismissed.count - Self.maximumDismissed) }
    }
}

@MainActor protocol CompanionFinishedPersistence: AnyObject {
    func load() -> CompanionFinishedRuns?
    func save(_ runs: CompanionFinishedRuns)
}
