import Foundation
import ClubhouseTransport

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
    var linkedMembers: [CompanionProjectMember] = []
    var linkID: String?
    var id: CompanionProjectTarget { .init(hostID: host.id, projectID: project.id) }
    var members: [CompanionProjectMember] {
        linkedMembers.isEmpty ? [.init(host: host, project: project)] : linkedMembers
    }
    var isLinked: Bool { linkedMembers.count > 1 }
    var machineNames: String { members.map(\.host.name).joined(separator: " · ") }
    var canSpawn: Bool { members.contains { $0.host.connection.canOperate && $0.host.canSpawn } }
    func label(for member: CompanionProjectMember) -> String {
        members.filter { $0.host.id == member.host.id }.count > 1 ? "\(member.host.name) · \(member.project.name)" : member.host.name
    }
    /// Stable key for persisting the phone's own order.
    var orderKey: String { linkID.map { "link:\($0)" } ?? CompanionProjectOrdering.key(id) }
}

struct CompanionProjectMember: Identifiable, Sendable, Equatable {
    var host: CompanionHost
    var project: CompanionProject
    var id: CompanionProjectTarget { .init(hostID: host.id, projectID: project.id) }
}

enum CompanionLinkedProjects {
    static func entries(hosts: [CompanionHost], links: [AnnexProjectLinks.Group]) -> [CompanionProjectEntry] {
        let all = hosts.flatMap { host in host.projects.map { CompanionProjectMember(host: host, project: $0) } }
        let catalog = Dictionary(all.map { (AnnexProjectLinks.Reference(machine: $0.host.id.lowercased(), projectId: $0.project.id), $0) },
                                 uniquingKeysWith: { first, _ in first })
        var groups: [CompanionProjectTarget: CompanionProjectEntry] = [:]
        var claimed: Set<CompanionProjectTarget> = []
        for link in links {
            var seen: Set<AnnexProjectLinks.Reference> = []
            let members = link.projects.compactMap { ref -> CompanionProjectMember? in
                let key = AnnexProjectLinks.Reference(machine: ref.machine.lowercased(), projectId: ref.projectId)
                return seen.insert(key).inserted ? catalog[key] : nil
            }
            // Desktop groups are disjoint. Never duplicate a project if a malformed replica overlaps them.
            guard members.count > 1, members.allSatisfy({ !claimed.contains($0.id) }), let first = members.first else { continue }
            var project = first.project
            if let name = link.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { project.name = name }
            project.agents = members.flatMap(\.project.agents)
            let entry = CompanionProjectEntry(host: first.host, project: project, linkedMembers: members, linkID: link.id)
            for member in members { groups[member.id] = entry; claimed.insert(member.id) }
        }
        var emitted: Set<CompanionProjectTarget> = []
        return all.compactMap { member in
            let entry = groups[member.id] ?? .init(host: member.host, project: member.project)
            return emitted.insert(entry.id).inserted ? entry : nil
        }
    }
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
            return newestFirst(entries) { $0.members.compactMap { lastActivity($0.id) }.max() }
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
        CompanionLinkedProjects.entries(hosts: hosts, links: projectLinks?.projectLinks ?? [])
    }
    func projectEntry(containing target: CompanionProjectTarget) -> CompanionProjectEntry? {
        projectEntries.first { $0.members.contains { $0.id == target } }
    }
    func projectName(for target: CompanionTarget) -> String? {
        if isDispatcher(target) { return CompanionDispatcher.name }
        return projectEntry(containing: .init(hostID: target.hostID, projectID: target.projectID))?.project.name
    }
}
