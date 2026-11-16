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
        // Keep large Host/Member values out of nested generic flatMap/compactMap frames.
        // This runs when Store receives a catalog generation, never while a header builds its menu.
        var all: [CompanionProjectMember] = []
        var catalog: [AnnexProjectLinks.Reference: Int] = [:]
        for host in hosts {
            for project in host.projects {
                let key = AnnexProjectLinks.Reference(machine: host.id.lowercased(), projectId: project.id)
                if catalog[key] == nil { catalog[key] = all.count }
                all.append(.init(host: host, project: project))
            }
        }
        var groups: [CompanionProjectTarget: Int] = [:]
        var linkedEntries: [CompanionProjectEntry] = []
        var claimed: Set<CompanionProjectTarget> = []
        for link in links {
            var seen: Set<AnnexProjectLinks.Reference> = []
            var members: [CompanionProjectMember] = []
            for ref in link.projects {
                let key = AnnexProjectLinks.Reference(machine: ref.machine.lowercased(), projectId: ref.projectId)
                if seen.insert(key).inserted, let index = catalog[key] { members.append(all[index]) }
            }
            // Desktop groups are disjoint. Never duplicate a project if a malformed replica overlaps them.
            guard members.count > 1, members.allSatisfy({ !claimed.contains($0.id) }), let first = members.first else { continue }
            var project = first.project
            if let name = link.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { project.name = name }
            project.agents = []
            for member in members { project.agents.append(contentsOf: member.project.agents) }
            let index = linkedEntries.count
            linkedEntries.append(.init(host: first.host, project: project, linkedMembers: members, linkID: link.id))
            for member in members { groups[member.id] = index; claimed.insert(member.id) }
        }
        var emitted: Set<CompanionProjectTarget> = []
        var result: [CompanionProjectEntry] = []
        result.reserveCapacity(all.count)
        for member in all {
            if let index = groups[member.id] {
                let entry = linkedEntries[index]
                if emitted.insert(entry.id).inserted { result.append(entry) }
            } else if emitted.insert(member.id).inserted {
                result.append(.init(host: member.host, project: member.project))
            }
        }
        return result
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
        // Register the catalog dependency even though the prebuilt cache itself is ignored by Observation.
        _ = projectCatalogRevision
        return cachedProjectEntries
    }
    func projectEntry(containing target: CompanionProjectTarget) -> CompanionProjectEntry? {
        projectEntries.first { $0.id == target || $0.linkedMembers.contains { $0.id == target } }
    }
    /// A render snapshot is display context, never command authority. Resolve again at the tap.
    func resolveProjectActionEntry(containing target: CompanionProjectTarget, expectedLinkID: String?, hostID: String? = nil) -> CompanionProjectEntry? {
        guard let current = projectEntry(containing: target), current.linkID == expectedLinkID else { return nil }
        guard let hostID else { return current }
        guard current.members.contains(where: { $0.host.id == hostID }) else { return nil }
        return CompanionHomeScope(hosts: hosts, selectedHostID: hostID).projects([current]).first
    }

    func projectName(for target: CompanionTarget) -> String? {
        if isDispatcher(target) { return CompanionDispatcher.name }
        return projectEntry(containing: .init(hostID: target.hostID, projectID: target.projectID))?.project.name
    }
}
