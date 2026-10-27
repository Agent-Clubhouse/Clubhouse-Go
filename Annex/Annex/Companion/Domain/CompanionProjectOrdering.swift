import Foundation

enum CompanionProjectSort: String, CaseIterable, Identifiable, Sendable {
    case recent, alphabetical, custom
    var id: Self { self }
    var label: String {
        switch self {
        case .recent: "Recent"
        case .alphabetical: "A–Z"
        case .custom: "Your order"
        }
    }
}

struct CompanionProjectEntry: Identifiable, Sendable, Equatable {
    var host: CompanionHost
    var project: CompanionProject
    var id: CompanionProjectTarget { .init(hostID: host.id, projectID: project.id) }
    /// Stable key for persisting the phone's own order.
    var orderKey: String { CompanionProjectOrdering.key(id) }
}

enum CompanionProjectOrdering {
    static func key(_ target: CompanionProjectTarget) -> String { "\(target.hostID)\u{1F}\(target.projectID)" }

    /// Recent sorts by last seen activity, projects with none keep desktop order after the rest.
    /// Your order follows `customOrder`; projects not in it yet go to the end in desktop order.
    static func ordered(_ entries: [CompanionProjectEntry], sort: CompanionProjectSort, customOrder: [String],
                        lastActivity: (CompanionProjectTarget) -> Date?) -> [CompanionProjectEntry] {
        let indexed = Array(entries.enumerated())
        switch sort {
        case .alphabetical:
            return indexed.sorted { lhs, rhs in
                let order = lhs.element.project.name.localizedStandardCompare(rhs.element.project.name)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        case .recent:
            return newestFirst(entries) { lastActivity($0.id) }
        case .custom:
            let position = Dictionary(customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return indexed.sorted { lhs, rhs in
                switch (position[lhs.element.orderKey], position[rhs.element.orderKey]) {
                case let (a?, b?): return a < b
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
    }

    /// Most recent first. Items with no activity go last, and ties keep the given order.
    static func newestFirst<T>(_ items: [T], activity: (T) -> Date?) -> [T] {
        let dates = items.map(activity)
        return items.indices.sorted { lhs, rhs in
            switch (dates[lhs], dates[rhs]) {
            case let (a?, b?) where a != b: return a > b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs < rhs
            }
        }.map { items[$0] }
    }
}

/// Agents inside a project follow the Home sort, as in the desktop sidebar (#126): Recent is most
/// recent first, A–Z by name, and Your order keeps the desktop's order (agents aren't reordered here).
enum CompanionAgentOrdering {
    static func ordered(_ agents: [CompanionAgent], sort: CompanionProjectSort, lastActivity: (CompanionAgent) -> Date?) -> [CompanionAgent] {
        switch sort {
        case .recent: return CompanionProjectOrdering.newestFirst(agents, activity: lastActivity)
        case .alphabetical:
            return agents.enumerated().sorted { lhs, rhs in
                let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        case .custom: return agents
        }
    }
}

extension CompanionStore {
    var projectEntries: [CompanionProjectEntry] {
        hosts.flatMap { host in host.projects.map { CompanionProjectEntry(host: host, project: $0) } }
    }
}
