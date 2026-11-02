import Foundation

/// Desktop `HelperRollup`: all descendants, excluding the parent. Needs/error wins over working.
struct CompanionHelperRollup: Sendable, Equatable {
    var count = 0
    var needs = 0
    var working = 0
    var dot: CompanionStatusDot? { needs > 0 ? .needsYou : working > 0 ? .working : nil }
}

/// A preorder row keeps navigation flat while retaining the real depth, even beyond the phone's indent cap.
struct CompanionAgentTreeRow: Identifiable, Sendable, Equatable {
    var agent: CompanionAgent
    var depth: Int
    var parentName: String?
    var rollup: CompanionHelperRollup
    var id: CompanionTarget { agent.id }
}

/// Shared Home/project tree. The forest and subtree summaries take O(n) time and space, with no recursive
/// walks. Sorting happens before linking, so every sibling group follows the chosen order, and a helper's
/// activity never lifts its root. Quick agents remain independent roots.
struct CompanionAgentTree: Sendable, Equatable {
    var active: [CompanionAgentTreeRow]
    var sleeping: [CompanionAgentTreeRow]
    var finishedQuick: [CompanionAgentTreeRow]
    var all: [CompanionAgentTreeRow] { active + sleeping + finishedQuick }

    func isInSleepingFold(_ id: CompanionTarget) -> Bool { sleeping.contains { $0.id == id } }

    func visible(_ rows: [CompanionAgentTreeRow], collapsed: Set<CompanionTarget>) -> [CompanionAgentTreeRow] {
        var hiddenBelow: Int?
        return rows.filter { row in
            if let depth = hiddenBelow, row.depth > depth { return false }
            hiddenBelow = collapsed.contains(row.id) && row.rollup.count > 0 ? row.depth : nil
            return true
        }
    }

    static func build(_ agents: [CompanionAgent], sort: CompanionProjectSort,
                      held: [CompanionTarget]? = nil, lastActivity: (CompanionAgent) -> Date?) -> Self {
        var ordered = CompanionAgentOrdering.ordered(agents, sort: sort, lastActivity: lastActivity)
        if let held { ordered = CompanionListHold.apply(ordered, order: held, id: \.id) }
        let byID = Dictionary(ordered.indices.filter { !ordered[$0].isQuick }.map { (ordered[$0].id.agentID, $0) },
                              uniquingKeysWith: { first, _ in first })
        var parents = ordered.map { $0.isQuick ? nil : $0.parentAgentID.flatMap { byID[$0] } }
        // A functional graph has at most one cycle per walk. Mark every cycle member as a root,
        // retaining incoming links (desktop x↔y, z→x becomes x→z and y).
        var done = Array(repeating: false, count: ordered.count)
        for start in ordered.indices where !done[start] {
            var path: [Int] = [], position: [Int: Int] = [:]
            var cursor: Int? = start
            while let index = cursor, !done[index], position[index] == nil {
                position[index] = path.count; path.append(index); cursor = parents[index]
            }
            if let index = cursor, let loopStart = position[index] {
                for member in path[loopStart...] { parents[member] = nil }
            }
            for index in path { done[index] = true }
        }
        var children = Array(repeating: [Int](), count: ordered.count), roots: [Int] = []
        for index in ordered.indices {
            if let parent = parents[index] { children[parent].append(index) } else { roots.append(index) }
        }
        var preorder: [(index: Int, depth: Int)] = []
        var stack = roots.reversed().map { (index: $0, depth: 0) }
        while let item = stack.popLast() {
            preorder.append(item)
            for child in children[item.index].reversed() { stack.append((child, item.depth + 1)) }
        }
        var asleep = ordered.map(CompanionHomeLayout.isSleeping)
        var rollups = Array(repeating: CompanionHelperRollup(), count: ordered.count)
        for (index, _) in preorder.reversed() {
            guard let parent = parents[index] else { continue }
            asleep[parent] = asleep[parent] && asleep[index]
            rollups[parent].count += 1 + rollups[index].count
            rollups[parent].needs += (ordered[index].status.needsYou ? 1 : 0) + rollups[index].needs
            rollups[parent].working += (ordered[index].status.dot == .working ? 1 : 0) + rollups[index].working
        }
        var tree = Self(active: [], sleeping: [], finishedQuick: [])
        var inSleepingFold = false
        for (index, depth) in preorder {
            if depth == 0 { inSleepingFold = asleep[index] }
            let row = CompanionAgentTreeRow(agent: ordered[index], depth: depth,
                                            parentName: parents[index].map { ordered[$0].name }, rollup: rollups[index])
            if CompanionHomeLayout.isFinishedQuick(row.agent) { tree.finishedQuick.append(row) }
            else if inSleepingFold { tree.sleeping.append(row) }
            else { tree.active.append(row) }
        }
        return tree
    }

    /// Host-scoped lookup: an absent parent stays a root without a label. Flat views also name local parents.
    static func parentLines(hosts: [CompanionHost], includingLocal: Bool = false) -> [CompanionTarget: String] {
        var lines: [CompanionTarget: String] = [:]
        for host in hosts {
            let parents = Dictionary(host.projects.flatMap { project in
                project.agents.map { ($0.id.agentID, (agent: $0, project: project)) }
            }, uniquingKeysWith: { first, _ in first })
            for project in host.projects {
                for helper in project.agents where !helper.isQuick {
                    guard let id = helper.parentAgentID, let parent = parents[id] else { continue }
                    if parent.project.id != project.id {
                        lines[helper.id] = "Helper of \(parent.agent.name) in \(parent.project.name)"
                    } else if includingLocal {
                        lines[helper.id] = "Helper of \(parent.agent.name)"
                    }
                }
            }
        }
        return lines
    }
}
