import Testing
@testable import CompanionDomain

struct CompanionProjectAgentSectionsTests {
    private func agent(_ id: String, status: CompanionAgentStatus, parent: String? = nil) -> CompanionAgent {
        var value = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: id), name: id, subtitle: "", status: status)
        value.parentAgentID = parent
        return value
    }

    @Test func anUrgentHelperKeepsItsAncestorsAndSiblingsInOneDisclosureTree() {
        let input = [agent("parent", status: .working), agent("request", status: .approval, parent: "parent"),
                     agent("sibling", status: .working, parent: "parent"), agent("other", status: .working)]
        let tree = CompanionAgentTree.build(input, sort: .custom, lastActivity: { _ in nil })
        let sections = CompanionProjectAgentSections(tree: tree)
        #expect(sections.needsYou.map(\.id.agentID) == ["parent", "request", "sibling"])
        #expect(sections.agents.map(\.id.agentID) == ["other"])
        #expect(tree.visible(sections.needsYou, collapsed: [input[0].id]).map(\.id.agentID) == ["parent"])
        #expect(sections.needsYou.first?.rollup.needs == 1)
    }

    @Test func quietAndFinishedRowsStayInTheSharedQuietFold() {
        var quick = agent("quick", status: .completed)
        quick.isQuick = true
        let tree = CompanionAgentTree.build([agent("sleep", status: .sleeping), quick, agent("question", status: .waiting)], sort: .custom, lastActivity: { _ in nil })
        let sections = CompanionProjectAgentSections(tree: tree)
        #expect(sections.needsYou.map(\.id.agentID) == ["question"])
        #expect(sections.agents.isEmpty)
        #expect(tree.sleeping.map(\.id.agentID) == ["sleep"])
        #expect(tree.finishedQuick.map(\.id.agentID) == ["quick"])
    }
}
