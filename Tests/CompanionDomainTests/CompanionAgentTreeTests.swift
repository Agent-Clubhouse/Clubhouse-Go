import Foundation
import Testing
@testable import CompanionDomain

private func treeAgent(_ id: String, parent: String? = nil, status: CompanionAgentStatus = .idle,
                       quick: Bool = false, project: String = "p", activity: Double? = nil) -> CompanionAgent {
    var a = CompanionAgent(id: .init(hostID: "host", projectID: project, agentID: id), name: id, subtitle: "", status: status,
                           lastActivity: activity.map(Date.init(timeIntervalSince1970:)))
    a.parentAgentID = parent; a.isQuick = quick
    return a
}
private func tree(_ agents: [CompanionAgent], sort: CompanionProjectSort = .custom, held: [CompanionTarget]? = nil) -> CompanionAgentTree {
    .build(agents, sort: sort, held: held, lastActivity: \.lastActivity)
}

struct CompanionAgentTreeTests {
    @Test func forestPreservesSiblingOrderAndQuickAgentsStayRoots() {
        let result = tree([treeAgent("lead"), treeAgent("h1", parent: "lead"), treeAgent("other"),
                           treeAgent("h2", parent: "lead"), treeAgent("h2a", parent: "h2"), treeAgent("q", parent: "lead", quick: true)])
        #expect(result.active.map(\.agent.name) == ["lead", "h1", "h2", "h2a", "other", "q"])
        #expect(result.active.map(\.depth) == [0, 1, 1, 2, 0, 0])
        #expect(result.active[3].parentName == "h2")
        #expect(result.active[0].rollup.count == 3)
    }
    @Test func unknownParentLoopsSelfParentAndIncomingChildrenNeverDisappear() {
        let result = tree([treeAgent("orphan", parent: "gone"), treeAgent("x", parent: "y"), treeAgent("y", parent: "x"),
                           treeAgent("z", parent: "x"), treeAgent("self", parent: "self"), treeAgent("quick", quick: true),
                           treeAgent("quick-child", parent: "quick")])
        #expect(result.active.map(\.agent.name) == ["orphan", "x", "z", "y", "self", "quick", "quick-child"])
        #expect(result.active.map(\.depth) == [0, 0, 1, 0, 0, 0, 0])
    }
    @Test func sleepingFoldRequiresTheWholeSubtreeAndCountsHelpers() {
        let result = tree([treeAgent("lead", status: .sleeping), treeAgent("h1", parent: "lead", status: .working),
                           treeAgent("nap", status: .sleeping), treeAgent("nap-h", parent: "nap", status: .stopped),
                           treeAgent("awake"), treeAgent("awake-h", parent: "awake", status: .sleeping),
                           treeAgent("done", status: .completed, quick: true)])
        #expect(result.active.map(\.agent.name) == ["lead", "h1", "awake", "awake-h"])
        #expect(result.sleeping.map(\.agent.name) == ["nap", "nap-h"])
        #expect(result.finishedQuick.map(\.agent.name) == ["done"])
        #expect(result.isInSleepingFold(treeAgent("nap-h").id))
        #expect(!result.isInSleepingFold(treeAgent("awake-h").id))
    }
    @Test func rollupCountsEveryDepthAndExcludesTheParent() {
        let result = tree([treeAgent("lead", status: .approval), treeAgent("h1", parent: "lead", status: .working),
                           treeAgent("h2", parent: "lead"), treeAgent("h2a", parent: "h2", status: .waiting),
                           treeAgent("h3", parent: "lead", status: .failed)])
        #expect(result.active[0].rollup == .init(count: 4, needs: 2, working: 1))
        #expect(result.active[0].rollup.dot == .needsYou)
        #expect(result.active[1].rollup.dot == nil)
        #expect(tree([treeAgent("p"), treeAgent("h", parent: "p", status: .working)]).active[0].rollup.dot == .working)
        #expect(result.visible(result.active, collapsed: [treeAgent("lead").id]).map(\.agent.name) == ["lead"])
    }
    @Test func sortsAtEveryLevelWithoutLiftingRootForHelperActivity() {
        let agents = [treeAgent("zed", activity: 1), treeAgent("z-helper", parent: "zed", activity: 9),
                      treeAgent("alpha", activity: 2), treeAgent("a-helper", parent: "zed", activity: 10)]
        #expect(tree(agents, sort: .recent).active.map(\.agent.name) == ["alpha", "zed", "a-helper", "z-helper"])
        #expect(tree(agents, sort: .alphabetical).active.map(\.agent.name) == ["alpha", "zed", "a-helper", "z-helper"])
        #expect(tree(agents).active.map(\.agent.name) == ["zed", "z-helper", "a-helper", "alpha"])
        #expect(tree([treeAgent("a", activity: 1), treeAgent("b", activity: 1), treeAgent("c")], sort: .recent).active.map(\.agent.name) == ["a", "b", "c"])
    }
    @Test func holdKeepsEachSiblingGroupStableAndAppendsNewChildren() {
        let first = tree([treeAgent("p"), treeAgent("a", parent: "p", activity: 1), treeAgent("b", parent: "p", activity: 2), treeAgent("q")], sort: .recent)
        let next = tree([treeAgent("p"), treeAgent("a", parent: "p", activity: 3), treeAgent("b", parent: "p", activity: 2),
                         treeAgent("c", parent: "p", activity: 4), treeAgent("q", activity: 10)], sort: .recent, held: first.all.map(\.id))
        #expect(next.active.map(\.agent.name) == ["p", "b", "a", "c", "q"])
    }
    @Test func deepChainUsesRealDepthAndCollapseWorksAtAnyDepth() {
        let agents = (0..<5_000).map { treeAgent("a\($0)", parent: $0 == 0 ? nil : "a\($0 - 1)") }
        let result = tree(agents)
        #expect(result.active.count == 5_000)
        #expect(result.active.last?.depth == 4_999)
        #expect(result.active.first?.rollup.count == 4_999)
        #expect(result.visible(result.active, collapsed: [agents[3].id]).count == 4)
    }
    @Test func crossProjectParentLineUsesOnlyThisHostsProjectsAndKnownParents() {
        let parent = treeAgent("Ada", project: "other"), helper = treeAgent("h", parent: "Ada")
        let projects = [CompanionProject(id: "p", name: "App", agents: [helper]), .init(id: "other", name: "Annex", agents: [parent])]
        let host = CompanionHost(id: "host", name: "Mac", endpoint: "", connection: .connected, projects: projects)
        let lines = CompanionAgentTree.parentLines(hosts: [host])
        #expect(lines[helper.id] == "Helper of Ada in Annex")
        #expect(lines[parent.id] == nil)
        let localHost = CompanionHost(id: "host", name: "Mac", endpoint: "", connection: .connected,
                                      projects: [.init(id: "p", name: "App", agents: [treeAgent("Ada"), helper])])
        #expect(CompanionAgentTree.parentLines(hosts: [localHost], includingLocal: true)[helper.id] == "Helper of Ada")
        var foreign = host; foreign.id = "different-host"; foreign.projects = [.init(id: "elsewhere", name: "Elsewhere", agents: [treeAgent("Ada", project: "elsewhere")])]
        #expect(CompanionAgentTree.parentLines(hosts: [host, foreign])[helper.id] == "Helper of Ada in Annex")
        #expect(tree([helper]).active.first?.depth == 0)
        #expect(CompanionAgentTree.parentLines(hosts: [.init(id: "host", name: "Mac", endpoint: "", connection: .connected, projects: [projects[0]])]).isEmpty)
        #expect(CompanionAgentTree.parentLines(hosts: [.init(id: "host", name: "Mac", endpoint: "", connection: .connected,
                      projects: [.init(id: "p", name: "App", agents: [treeAgent("Ada"), helper])])]).isEmpty)
    }
    @MainActor @Test func homeHoldAndIdleConsiderHiddenHelpersAndPreviewFixture() throws {
        let hosts = CompanionPreviewService.hosts(now: Date(), helperTree: true)
        let entries = hosts[0].projects.map { CompanionProjectEntry(host: hosts[0], project: $0) }
        let layout = CompanionHomeLayout.build(entries, sort: .custom, customOrder: [], rule: .init(inactive: Set(entries.map(\.orderKey))),
                                               projectActivity: { _ in nil }, agentActivity: \.lastActivity)
        let clubhouse = try #require(layout.projects.first { $0.entry.project.id == "clubhouse" })
        #expect(!clubhouse.isIdle, "Awake River keeps sleeping Cedar's project out of idle")
        #expect(clubhouse.tree.active.first?.agent.name == "Cedar")
        #expect(clubhouse.tree.active.prefix(3).map(\.depth) == [0, 1, 2])
        #expect(clubhouse.sleeping.map(\.name) == ["Elm", "Moss"])
        #expect(layout.hold.agents[clubhouse.id]?.contains(CompanionPreviewService.target) == true)
        #expect(CompanionAgentTree.parentLines(hosts: hosts).values.contains("Helper of Cedar in Clubhouse"))
    }
    @MainActor @Test func collapseAndFoldsPersistPerHostAndPruneOnlyKnownConnectedCatalogs() throws {
        let suite = "agent-tree-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = CompanionPreferences(defaults: defaults)
        let a = treeAgent("a"), b = treeAgent("b")
        var other = a.id; other.hostID = "other"
        p.toggleAgentCollapsed(a.id); p.toggleAgentCollapsed(b.id); p.toggleAgentCollapsed(other)
        p.toggleFold("sleeping:host-p"); p.toggleFold("finished:host-p")
        let loaded = CompanionPreferences(defaults: defaults)
        #expect(loaded.isAgentCollapsed(a.id) && loaded.isAgentCollapsed(other))
        #expect(loaded.expandedFolds == ["sleeping:host-p", "finished:host-p"])
        loaded.pruneAgentCollapse(hosts: [.init(id: "host", name: "Mac", endpoint: "", connection: .offline, projects: [])])
        #expect(loaded.isAgentCollapsed(a.id))
        loaded.pruneAgentCollapse(hosts: [.init(id: "host", name: "Mac", endpoint: "", connection: .connected,
                                              projects: [.init(id: "p", name: "App", agents: [a])])])
        let pruned = CompanionPreferences(defaults: defaults)
        #expect(pruned.isAgentCollapsed(a.id) && !pruned.isAgentCollapsed(b.id) && pruned.isAgentCollapsed(other))
        pruned.toggleAgentCollapsed(a.id); pruned.toggleFold("finished:host-p")
        #expect(!CompanionPreferences(defaults: defaults).isAgentCollapsed(a.id))
        #expect(CompanionPreferences(defaults: defaults).expandedFolds == ["sleeping:host-p"])
    }
}
