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
            let dates = indexed.map { lastActivity($0.element.id) }
            return indexed.sorted { lhs, rhs in
                switch (dates[lhs.offset], dates[rhs.offset]) {
                case let (a?, b?) where a != b: return a > b
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
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
}

extension CompanionStore {
    var projectEntries: [CompanionProjectEntry] {
        hosts.flatMap { host in host.projects.map { CompanionProjectEntry(host: host, project: $0) } }
    }
}
