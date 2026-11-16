import Foundation
import ClubhouseTransport

/// The live counts in Home's scrolling summary header. Attention keeps the Needs you badge's request count.
struct CompanionHomeSummary: Equatable, Sendable {
    var working: Int
    var needsYou: Int
    var connected: Int
    var desktops: Int

    init(hosts: [CompanionHost], needsYou: Int) {
        // Cached agents on unavailable desktops describe the last snapshot, not live work.
        working = hosts.filter(\.connection.canOperate).flatMap(\.allAgents).filter { $0.status == .working }.count
        self.needsYou = needsYou
        connected = hosts.filter(\.connection.canOperate).count
        desktops = hosts.count
    }

    var workingLabel: String { "\(working) working" }
    var attentionLabel: String { "\(needsYou) \(needsYou == 1 ? "needs" : "need") you" }
    var connectionLabel: String? { desktops >= 3 || (desktops > 1 && connected < desktops) ? "\(connected) of \(desktops) desktops connected" : nil }
    var accessibilityLabel: String { ([workingLabel, attentionLabel] + [connectionLabel].compactMap { $0 }).joined(separator: ", ") }
}

/// Home's launch-lifetime desktop filter. It never mutates the store or command authority.
/// Linked copies are projected before layout so another machine's agents cannot leak into a scope.
struct CompanionHomeScope: Sendable {
    let allHosts: [CompanionHost]
    let selectedHostID: String?

    init(hosts: [CompanionHost], selectedHostID: String?) {
        allHosts = hosts
        self.selectedHostID = selectedHostID.flatMap { id in hosts.contains { $0.id == id } ? id : nil }
    }

    var hosts: [CompanionHost] { allHosts.filter { selectedHostID == nil || $0.id == selectedHostID } }
    var impliedHostID: String? { selectedHostID ?? (allHosts.count == 1 ? allHosts.first?.id : nil) }
    var showsHostTags: Bool { allHosts.count > 1 && selectedHostID == nil }
    func contains(_ target: CompanionTarget) -> Bool { selectedHostID == nil || target.hostID == selectedHostID }

    func projects(_ entries: [CompanionProjectEntry]) -> [CompanionProjectEntry] {
        guard let selectedHostID else { return entries }
        return entries.compactMap { entry in
            let members = entry.members.filter { $0.host.id == selectedHostID }
            guard let first = members.first else { return nil }
            var scoped = entry
            scoped.host = first.host
            scoped.project = first.project
            scoped.project.name = entry.project.name
            scoped.project.agents = members.flatMap(\.project.agents)
            scoped.linkedMembers = entry.linkedMembers.isEmpty ? [] : members
            // Keep linkID/orderKey stable while the command target follows the selected copy.
            return scoped
        }
    }
}

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

/// One project's pins, mark and idle flag, as the desktop shares them (`projectState` v1). `idle` is the
/// desktop's own rule, so the phone uses it as sent instead of working it out.
struct CompanionProjectState: Sendable, Equatable {
    var pinned = false
    var inactive = false
    var idle = false
    var linked = false
    var lastActivity: Date?

    /// One entry of the snapshot's `projectState`, or a command's result. Nil when it isn't an object.
    init?(json: AnnexJSON?) {
        guard case .object? = json else { return nil }
        pinned = json?["pinned"].boolValue == true
        linked = json?["linked"].boolValue == true
        inactive = json?["inactive"].boolValue == true
        idle = json?["idle"].boolValue == true
        lastActivity = json?["lastActivityAt"].flatMap(CompanionLiveService.date(from:))
    }
    init(pinned: Bool = false, inactive: Bool = false, idle: Bool = false, lastActivity: Date? = nil, linked: Bool = false) {
        self.pinned = pinned; self.inactive = inactive; self.idle = idle; self.lastActivity = lastActivity; self.linked = linked
    }

    /// The snapshot's `projectState`, by project id. Nil when the desktop didn't send it.
    static func map(from json: AnnexJSON?) -> [String: CompanionProjectState]? {
        guard case .object(let entries)? = json else { return nil }
        return entries.compactMapValues { CompanionProjectState(json: $0) }
    }

    /// What the phone shows while a change is on its way, following the desktop's rules:
    /// a pinned project is never idle, and marking active clears the mark and counts as activity now.
    func with(pinned: Bool? = nil, inactive: Bool? = nil, now: Date = Date()) -> Self {
        var next = self
        if let pinned { next.pinned = pinned; if pinned { next.idle = false; if next.linked { next.inactive = false } } }
        if let inactive {
            next.inactive = inactive && !(next.linked && next.pinned)
            if inactive { next.idle = !next.pinned } else { next.idle = false; next.lastActivity = now }
        }
        return next
    }
}

/// One project on Home: its agents in order, with sleeping agents and finished quick agents folded away.
struct CompanionProjectGroup: Identifiable, Sendable, Equatable {
    var entry: CompanionProjectEntry
    var isPinned: Bool
    var isIdle: Bool
    /// Awake agents and anything else that isn't folded, in the Home sort.
    var tree: CompanionAgentTree
    var agents: [CompanionAgent] { tree.active.map(\.agent) }
    /// Durable agents that are asleep: "N sleeping".
    var sleeping: [CompanionAgent] { tree.sleeping.map(\.agent) }
    /// Quick agents that have finished their task: "N finished quick agents".
    var finishedQuick: [CompanionAgent] { tree.finishedQuick.map(\.agent) }
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
/// sort, then everything idle folded into one "N idle projects" section. A project whose desktop shares its
/// state (`shared`) takes its pin and idle flag from there; the rest follow this phone's `rule`.
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
                      shared: (CompanionProjectEntry) -> CompanionProjectState? = { _ in nil },
                      projectActivity: (CompanionProjectTarget) -> Date?, agentActivity: (CompanionAgent) -> Date?) -> Self {
        var ordered = CompanionProjectOrdering.ordered(entries, sort: sort, customOrder: customOrder, lastActivity: projectActivity)
        if let hold { ordered = CompanionListHold.apply(ordered, order: hold.projects, id: \.orderKey) }
        var pinned: [CompanionProjectGroup] = [], active: [CompanionProjectGroup] = [], idle: [CompanionProjectGroup] = []
        for entry in ordered {
            let tree = CompanionAgentTree.build(entry.project.agents.filter { !CompanionFinishedRuns.hasFinished($0) }, sort: sort, held: hold?.agents[entry.id], lastActivity: agentActivity)
            let running = entry.project.agents.contains(where: isAwake)
            let capable = entry.members.filter { $0.host.canSyncLinkedProjectState }
            let orderedSources = capable.filter { $0.host.connection.canOperate } + capable.filter { !$0.host.connection.canOperate }
            let linked = entry.isLinked ? orderedSources.compactMap { member -> CompanionProjectState? in
                let state = shared(.init(host: member.host, project: member.project))
                return state?.linked == true ? state : nil
            }.first : nil
            let states = entry.members.map { member in
                let single = CompanionProjectEntry(host: member.host, project: member.project)
                let state = shared(single)
                let pinned = linked?.pinned ?? state?.pinned ?? rule.pinned.contains(single.orderKey)
                let idle: Bool
                if let linked {
                    // Raw idle remains per machine; shared inactive applies to every copy.
                    // Unreported copies never borrow this phone's old preferences.
                    idle = !running && (linked.inactive || state?.idle == true)
                } else {
                    idle = state.map { $0.idle && !running }
                        ?? rule.isIdle(single.orderKey, running: running, lastActivity: projectActivity(single.id), now: now)
                }
                return (pinned: pinned, idle: idle)
            }
            let isPinned = states.contains { $0.pinned }
            let isIdle = !isPinned && states.allSatisfy { $0.idle }
            let group = CompanionProjectGroup(entry: entry, isPinned: isPinned, isIdle: isIdle,
                                              tree: tree)
            if isPinned { pinned.append(group) } else if isIdle { idle.append(group) } else { active.append(group) }
        }
        return .init(projects: pinned + active, idle: idle)
    }

    /// Running in any way, idle between turns included: the desktop's `running`.
    static func isAwake(_ agent: CompanionAgent) -> Bool { ![.sleeping, .completed, .stopped].contains(agent.status) }
    /// Durable agents the status dot shows as Sleeping (asleep, or stopped).
    static func isSleeping(_ agent: CompanionAgent) -> Bool { !agent.isQuick && agent.status.dot == .sleeping }
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

    /// Agents use getAgentColorHex: only palette ids are accepted, with indigo for nil or unknown.
    /// Keep rgb's optional/hex behavior for project faces.
    static func agentRGB(_ value: String?) -> CompanionRGB {
        CompanionRGB(hex: palette[value ?? ""] ?? "#6366f1")!
    }

    /// The bytes of a base64 `data:` URL, as the snapshot's `projectIcons` and `agentIcons` send them.
    static func data(fromDataURL value: String?) -> Data? {
        guard let value, value.hasPrefix("data:"), let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }
}
