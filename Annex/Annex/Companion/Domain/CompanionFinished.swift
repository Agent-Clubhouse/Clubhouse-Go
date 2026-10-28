import Foundation
import Markdown

/// A quick agent that has exited, kept until it's dismissed: one row of the desktop's "Finished, waiting on you"
/// (Clubhouse `ProjectStartPage.tsx`, `quickAgentStore.ts`).
///
/// A desktop that offers `finishedQuickAgents` (Clubhouse #2468) sends its own list in the snapshot, and the phone
/// shows that. Older desktops keep the list in their window and forget a quick agent a minute after it exits, so
/// there the phone keeps its own list of the quick agents it saw exit, under the desktop's rules.
struct CompanionFinishedRun: Codable, Identifiable, Sendable, Equatable {
    var target: CompanionTarget
    var name: String
    var mission: String
    /// The process exit code, when the desktop's `agent:completed` reached the phone.
    var exitCode: Int?
    var status: CompanionAgentStatus
    var completedAt: Date
    /// The agent's own summary, in Markdown. Only the desktop's list has it.
    var summary: String?
    var id: CompanionTarget { target }

    /// The desktop shows the mission, or the name when there is none.
    var title: String { mission.isEmpty ? name : mission }
    /// The desktop's second line is "Exited with code N" for a non-zero exit, else the agent's summary as plain text.
    /// The desktop falls back to a file count, which doesn't reach the phone, so a run without a summary says it finished.
    var detail: String {
        if status == .stopped { return "Cancelled" }
        if let exitCode, exitCode != 0 { return "Exited with code \(exitCode)" }
        if status == .failed { return "Stopped with an error" }
        return summary.map(Self.plainText).flatMap { $0.isEmpty ? nil : $0 } ?? "Finished"
    }
    /// A non-zero exit, unless the user stopped it.
    var failed: Bool { status != .stopped && ((exitCode ?? 0) != 0 || status == .failed) }

    /// Markdown as one line of text, as the desktop's `markdownToPlainText`: formatting, links and code fences dropped.
    static func plainText(_ markdown: String) -> String {
        var words: [String] = []
        func walk(_ markup: any Markup) {
            switch markup {
            case let text as Text: words.append(text.string)
            case let code as InlineCode: words.append(code.code)
            case let block as CodeBlock: words.append(block.code)
            case is SoftBreak, is LineBreak: words.append(" ")
            default:
                for child in markup.children { walk(child) }
                if markup is BlockMarkup { words.append(" ") }
            }
        }
        walk(Document(parsing: markdown))
        return words.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

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

    /// A project's list when its desktop shares one: the desktop's entries in its order, then any quick agent the phone
    /// has seen exit that the desktop hasn't listed yet (its snapshot follows the exit). For an agent in both, the desktop's
    /// entry wins. Agents dismissed on this phone stay out.
    static func merged(desktop: [CompanionFinishedRun], exited agents: [CompanionAgent], dismissed: [CompanionTarget], now: Date) -> [CompanionFinishedRun] {
        let listed = Set(desktop.map(\.target))
        var extra = CompanionFinishedRuns()
        for agent in agents where !listed.contains(agent.id) && !dismissed.contains(agent.id) { extra.record(agent, now: now) }
        var runs = desktop
        for run in extra.runs { runs.insert(run, at: runs.firstIndex { $0.completedAt <= run.completedAt } ?? runs.endIndex) }
        return runs
    }

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
