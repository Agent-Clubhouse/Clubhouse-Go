import Foundation

/// The desktop sidebar's idle rule (Clubhouse `projectActivity.ts`), applied on this phone only.
/// A project is idle when it's unpinned, no agent in it is awake, and it has had no activity for
/// `days` days. A project marked inactive is idle at once, until it is marked active, though an awake
/// agent still keeps it in view. `days` 0 is never. A project with no activity yet is active.
struct CompanionIdleRule: Sendable, Equatable {
    static let defaultDays = 7
    static let dayChoices = [3, 7, 14, 30, 0]

    var days = defaultDays
    var pinned: Set<String> = []
    var inactive: Set<String> = []

    func isIdle(_ key: String, running: Bool, lastActivity: Date?, now: Date) -> Bool {
        if pinned.contains(key) || running { return false }
        if inactive.contains(key) { return true }
        guard days > 0, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) > Double(days) * 86_400
    }
}

/// One project on Home: its agents in order, with sleeping agents and finished quick agents folded away.
struct CompanionProjectGroup: Identifiable, Sendable, Equatable {
    var entry: CompanionProjectEntry
    var isPinned: Bool
    var isIdle: Bool
    /// Awake agents and anything else that isn't folded, in the Home sort.
    var agents: [CompanionAgent]
    /// Durable agents that are asleep: "N sleeping".
    var sleeping: [CompanionAgent]
    /// Quick agents that have finished their task: "N finished quick agents".
    var finishedQuick: [CompanionAgent]
    var id: CompanionProjectTarget { entry.id }
    var isEmpty: Bool { agents.isEmpty && sleeping.isEmpty && finishedQuick.isEmpty }
}

/// The order a list was in when the person started touching it. While held, rows keep their place and
/// anything new goes after them, so a changing Recent order doesn't move a row under a finger.
struct CompanionListHold: Sendable, Equatable {
    var projects: [String]
    var agents: [CompanionProjectTarget: [CompanionTarget]]

    static func apply<T, ID: Hashable>(_ items: [T], order: [ID], id: (T) -> ID) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let held = items.filter { rank[id($0)] != nil }.sorted { rank[id($0)]! < rank[id($1)]! }
        return held + items.filter { rank[id($0)] == nil }
    }
}

/// Home's project list, as in the desktop sidebar: pinned projects first, then the rest in the chosen
/// sort, then everything idle folded into one "N idle projects" section.
struct CompanionHomeLayout: Sendable, Equatable {
    var projects: [CompanionProjectGroup]
    var idle: [CompanionProjectGroup]

    var hold: CompanionListHold {
        let all = projects + idle
        return .init(projects: all.map(\.entry.orderKey),
                     agents: Dictionary(all.map { ($0.id, ($0.agents + $0.sleeping + $0.finishedQuick).map(\.id)) }, uniquingKeysWith: { first, _ in first }))
    }

    static func build(_ entries: [CompanionProjectEntry], sort: CompanionProjectSort, customOrder: [String], rule: CompanionIdleRule,
                      now: Date = Date(), hold: CompanionListHold? = nil,
                      projectActivity: (CompanionProjectTarget) -> Date?, agentActivity: (CompanionAgent) -> Date?) -> Self {
        var ordered = CompanionProjectOrdering.ordered(entries, sort: sort, customOrder: customOrder, lastActivity: projectActivity)
        if let hold { ordered = CompanionListHold.apply(ordered, order: hold.projects, id: \.orderKey) }
        var pinned: [CompanionProjectGroup] = [], active: [CompanionProjectGroup] = [], idle: [CompanionProjectGroup] = []
        for entry in ordered {
            var agents = CompanionAgentOrdering.ordered(entry.project.agents, sort: sort, lastActivity: agentActivity)
            if let held = hold?.agents[entry.id] { agents = CompanionListHold.apply(agents, order: held, id: \.id) }
            let isPinned = rule.pinned.contains(entry.orderKey)
            let isIdle = rule.isIdle(entry.orderKey, running: agents.contains(where: isAwake), lastActivity: projectActivity(entry.id), now: now)
            let group = CompanionProjectGroup(entry: entry, isPinned: isPinned, isIdle: isIdle,
                                              agents: agents.filter { !isSleeping($0) && !isFinishedQuick($0) },
                                              sleeping: agents.filter(isSleeping), finishedQuick: agents.filter(isFinishedQuick))
            if isPinned { pinned.append(group) } else if isIdle { idle.append(group) } else { active.append(group) }
        }
        return .init(projects: pinned + active, idle: idle)
    }

    /// Running in any way, idle between turns included: the desktop's `running`.
    static func isAwake(_ agent: CompanionAgent) -> Bool { ![.sleeping, .completed, .stopped].contains(agent.status) }
    static func isSleeping(_ agent: CompanionAgent) -> Bool { !agent.isQuick && agent.status == .sleeping }
    static func isFinishedQuick(_ agent: CompanionAgent) -> Bool { agent.isQuick && (agent.status == .completed || agent.status == .stopped) }
}

/// Desktop identity colors (Clubhouse `AGENT_COLORS`). Projects and agents send the id; a hex is taken as is.
enum CompanionIdentityColor {
    static let palette: [String: String] = [
        "indigo": "#6366f1", "emerald": "#10b981", "amber": "#f59e0b", "rose": "#f43f5e",
        "cyan": "#06b6d4", "violet": "#8b5cf6", "orange": "#f97316", "teal": "#14b8a6"
    ]
    static func rgb(_ value: String?) -> CompanionRGB? {
        guard let value, !value.isEmpty else { return nil }
        return CompanionRGB(hex: palette[value] ?? value)
    }

    /// The bytes of a base64 `data:` URL, as the snapshot's `projectIcons` and `agentIcons` send them.
    static func data(fromDataURL value: String?) -> Data? {
        guard let value, value.hasPrefix("data:"), let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }
}
