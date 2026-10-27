import Foundation

// Agent details (#157): the desktop's agent hover card (`AgentHoverCard.tsx`) and its Details pane
// (`features/agents/details`: SettingsCard, McpCard, ChangesCard). Every field is optional: what a desktop
// doesn't send is left out rather than guessed.

/// An MCP server, as the desktop's MCP servers card lists it.
nonisolated struct CompanionMCPServer: Identifiable, Sendable, Equatable {
    /// The CLI's own status (`session_info.mcpServers`), or `configured` for one only set in Clubhouse.
    enum Status: String, Sendable, CaseIterable {
        case connected, needsAuth = "needs_auth", pending, failed, unknown, disabled, configured
        /// The card's status words (`STATUS_WORD`).
        var label: String {
            switch self {
            case .connected: "Connected"
            case .pending: "Connecting"
            case .needsAuth: "Needs sign-in"
            case .failed: "Failed"
            case .disabled: "Off"
            case .unknown: "Unknown"
            case .configured: "Configured"
            }
        }
    }
    var name: String
    var status: Status
    var id: String { name }
    /// Clubhouse injects its own MCP as `clubhouse`; the card calls it Clubhouse.
    var displayName: String { name == "clubhouse" ? "Clubhouse" : name }
}

/// What a chat session reports about itself (`session_started`, `session_info`, `mode_changed`, `model_changed`).
/// Reset with each new session; nil fields weren't reported.
nonisolated struct CompanionSessionFacts: Sendable, Equatable {
    var cliVersion: String?
    var effort: String?
    /// The provider picked the effort itself, rather than one chosen in the session.
    var effortIsDefault = false
    /// Clubhouse's permission level: `plan`, `ask`, `auto_edit`, `auto` or `full_access`.
    var level: String?
    /// The provider's own name for each level.
    var levelNames: [String: String] = [:]
    /// The MCP servers the CLI loaded. Nil when the runtime doesn't report them.
    var mcpServers: [CompanionMCPServer]?

    /// The desktop's names for its five permission levels (`PERMISSION_LEVEL_LABELS`).
    static func levelLabel(_ level: String) -> String {
        switch level {
        case "plan": "Plan"
        case "ask": "Ask first"
        case "auto_edit": "Auto-accept edits"
        case "auto": "Auto"
        case "full_access": "Full access"
        default: level
        }
    }
}

/// The branch against main, as the Changes card's one line. Counts only: the desktop never sends file names here.
nonisolated struct CompanionAgentChanges: Sendable, Equatable {
    var available = true
    var base: String?
    var noBase = false
    var files = 0
    var additions = 0
    var deletions = 0
    var ahead: Int?
    var uncommitted: Int?

    /// "6 files +94 −51", or why there's nothing to count.
    var summary: String {
        guard available else { return "Not a git repository" }
        if noBase { return "No main branch to compare with" }
        guard files > 0 else { return "No changes" }
        return "\(files) \(files == 1 ? "file" : "files") +\(additions) −\(deletions)"
    }
    /// "2 commits ahead of main · 1 uncommitted", when the desktop counted them.
    var detail: String? {
        guard available, !noBase else { return nil }
        var parts: [String] = []
        if let ahead { parts.append("\(ahead) \(ahead == 1 ? "commit" : "commits") ahead of \(base ?? "main")") }
        if let uncommitted, uncommitted > 0 { parts.append("\(uncommitted) uncommitted") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The settings route's `details`: what the hover card shows besides the settings. Older desktops don't send it.
nonisolated struct CompanionAgentWorkspace: Sendable, Equatable {
    var branch: String?
    var worktreePath: String?
    /// Relative to the project folder, as the hover card shows it.
    var worktree: String?
    /// MCP servers set for the agent in Clubhouse.
    var mcpIDs: [String] = []
    /// Nil while the agent is being set up, or when the desktop couldn't read git.
    var changes: CompanionAgentChanges?
}

/// One agent's details, from the snapshot, its chat session and, for durable agents, its settings.
struct CompanionAgentDetails: Equatable {
    var status: CompanionAgentStatus
    var isQuick: Bool
    /// The CLI's name: "Claude Code".
    var runsOn: String?
    /// "Chat" or "Terminal", when known.
    var runtime: String?
    var cliVersion: String?
    var model: String?
    var effort: String?
    /// The permission level, as the Settings card's Access row.
    var access: String?
    var freeAgentMode: Bool
    var autoSleep: String?
    var branch: String?
    var worktree: String?
    var worktreePath: String?
    /// Live servers first by status, then those only set in Clubhouse (`mcpRows`). Nil when nothing is known.
    var mcpServers: [CompanionMCPServer]?
    var changes: CompanionAgentChanges?
    /// The desktop sent the settings route's `details`. Without it, branch-less agents and changes are unknown.
    var hasWorkspace: Bool

    init(agent: CompanionAgent, providers: [CompanionProvider] = [], settings: CompanionAgentSettings? = nil) {
        let session = agent.session
        let workspace = settings?.workspace
        status = agent.status
        isQuick = agent.isQuick
        let orchestrator = settings.map { $0.orchestrator.value ?? $0.resolvedOrchestrator } ?? agent.orchestrator
        runsOn = settings?.orchestratorName ?? orchestrator.map { id in providers.first { $0.id == id }?.name ?? id }
        if let mode = agent.executionMode { runtime = mode == "chat" ? "Chat" : "Terminal" }
        else if let settings { runtime = settings.resolvedRuntime == "terminal" ? "Terminal" : "Chat" }
        cliVersion = session?.cliVersion
        // A running chat session names the model it's on; asleep, the saved setting is what the next wake uses.
        model = agent.executionMode != nil ? agent.model ?? settings?.modelLabel : settings?.modelLabel ?? agent.model
        effort = session?.effort.map { session?.effortIsDefault == true ? "\($0.capitalized) (default)" : $0.capitalized }
        freeAgentMode = settings?.freeAgentMode.value ?? agent.freeAgentMode
        access = Self.access(level: session?.level, levelNames: session?.levelNames ?? [:], freeAgentMode: freeAgentMode,
                             permissions: settings.flatMap { $0.options.orchestrator(orchestrator)?.permissions })
        autoSleep = settings.map { $0.idleSleepApplies ? $0.autoSleepSummary : "Doesn't sleep in a terminal" }
        branch = workspace?.branch ?? agent.branch
        worktree = workspace?.worktree
        worktreePath = workspace?.worktreePath
        mcpServers = Self.mcpRows(live: session?.mcpServers, configured: workspace?.mcpIDs ?? [])
        changes = workspace?.changes
        hasWorkspace = workspace != nil
    }

    /// The Access row (`accessLabel`): the chat's live level, or what Free Agent Mode gives a terminal agent.
    /// `permissions` is whether the CLI takes Clubhouse's levels; nil when the phone doesn't know.
    static func access(level: String?, levelNames: [String: String], freeAgentMode: Bool, permissions: Bool?) -> String? {
        if let level { return levelNames[level] ?? CompanionSessionFacts.levelLabel(level) }
        if permissions == false { return "Set by the CLI" }
        if freeAgentMode { return "Free agent" }
        return permissions == true ? "Ask before edits" : nil
    }

    /// The card's rows: what the CLI loaded, sorted by status, then names only set in Clubhouse.
    static func mcpRows(live: [CompanionMCPServer]?, configured: [String]) -> [CompanionMCPServer]? {
        guard live != nil || !configured.isEmpty else { return nil }
        let order = CompanionMCPServer.Status.allCases
        let rows = (live ?? []).enumerated().sorted {
            let (a, b) = (order.firstIndex(of: $0.element.status) ?? 0, order.firstIndex(of: $1.element.status) ?? 0)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let configuredOnly = configured.filter { id in !rows.contains { $0.name == id } }.map { CompanionMCPServer(name: $0, status: .configured) }
        return rows + configuredOnly
    }

    /// "3 connected · 1 needs sign-in · 2 configured" (`mcpSummary`).
    var mcpSummary: String {
        let rows = mcpServers ?? []
        let connected = rows.filter { $0.status == .connected }.count
        let signIn = rows.filter { $0.status == .needsAuth }.count
        let configured = rows.filter { $0.status == .configured }.count
        let others = rows.count - connected - signIn - configured
        var parts: [String] = []
        if connected > 0 { parts.append("\(connected) connected") }
        if signIn > 0 { parts.append("\(signIn) \(signIn == 1 ? "needs" : "need") sign-in") }
        if others > 0 { parts.append("\(others) not connected") }
        if configured > 0 { parts.append("\(configured) configured") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    /// "Claude Code 2.1.4", or the CLI alone when its version isn't known.
    var cli: String? {
        guard let runsOn else { return cliVersion }
        return cliVersion.map { "\(runsOn) \($0)" } ?? runsOn
    }
}
