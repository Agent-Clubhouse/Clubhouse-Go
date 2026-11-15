import Foundation

/// Split whole active subtrees so a helper's request does not detach it from its parent or break disclosure.
struct CompanionProjectAgentSections: Equatable, Sendable {
    var needsYou: [CompanionAgentTreeRow] = []
    var agents: [CompanionAgentTreeRow] = []

    init(tree: CompanionAgentTree) {
        var needs = false
        for row in tree.active {
            if row.depth == 0 { needs = row.agent.status.needsYou || row.rollup.needs > 0 }
            if needs { needsYou.append(row) } else { agents.append(row) }
        }
    }
}
