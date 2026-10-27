import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(days: Double = 0, minutes: Double = 0) -> Date { now.addingTimeInterval(-(days * 86_400 + minutes * 60)) }

private func agent(_ name: String, _ status: CompanionAgentStatus = .idle, project: String = "p1", activity: Date? = nil, quick: Bool = false) -> CompanionAgent {
    var agent = CompanionAgent(id: .init(hostID: "mac", projectID: project, agentID: name), name: name, subtitle: "", status: status, lastActivity: activity)
    agent.isQuick = quick
    return agent
}

private func entries(_ projects: [(String, [CompanionAgent])]) -> [CompanionProjectEntry] {
    let host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: .connected,
                             projects: projects.map { .init(id: $0.0, name: $0.0, agents: $0.1) })
    return host.projects.map { CompanionProjectEntry(host: host, project: $0) }
}

private func key(_ project: String) -> String { CompanionProjectOrdering.key(.init(hostID: "mac", projectID: project)) }

/// Project activity as Home computes it: the newest agent activity in the project.
private func layout(_ entries: [CompanionProjectEntry], sort: CompanionProjectSort = .recent, rule: CompanionIdleRule = .init(),
                    hold: CompanionListHold? = nil) -> CompanionHomeLayout {
    CompanionHomeLayout.build(entries, sort: sort, customOrder: [], rule: rule, now: now, hold: hold,
                              projectActivity: { target in entries.first { $0.id == target }?.project.agents.compactMap(\.lastActivity).max() },
                              agentActivity: \.lastActivity)
}

struct CompanionAgentOrderingTests {
    /// #126: newest project first, and inside each project newest agent first; agents without activity keep desktop order at the end.
    @Test func recentSortsProjectsAndTheirAgents() {
        let list = entries([
            ("older", [agent("a1", project: "older", activity: ago(minutes: 30)), agent("a2", project: "older"), agent("a3", project: "older", activity: ago(minutes: 10)), agent("a4", project: "older")]),
            ("newer", [agent("b1", project: "newer", activity: ago(minutes: 20)), agent("b2", project: "newer", activity: ago(minutes: 1))])
        ])
        let result = layout(list)
        #expect(result.projects.map(\.entry.project.id) == ["newer", "older"])
        #expect(result.projects[0].agents.map(\.name) == ["b2", "b1"])
        #expect(result.projects[1].agents.map(\.name) == ["a3", "a1", "a2", "a4"])
    }

    @Test func alphabeticalSortsAgentsByName() {
        let agents = [agent("zed", activity: ago(minutes: 1)), agent("Alma"), agent("mia", activity: ago(minutes: 5))]
        #expect(CompanionAgentOrdering.ordered(agents, sort: .alphabetical, lastActivity: \.lastActivity).map(\.name) == ["Alma", "mia", "zed"])
    }

    @Test func yourOrderKeepsDesktopAgentOrder() {
        let agents = [agent("zed", activity: ago(minutes: 9)), agent("Alma", activity: ago(minutes: 1))]
        #expect(CompanionAgentOrdering.ordered(agents, sort: .custom, lastActivity: \.lastActivity).map(\.name) == ["zed", "Alma"])
    }

    @Test func tiesKeepSnapshotOrder() {
        let same = ago(minutes: 3)
        let agents = [agent("first", activity: same), agent("second", activity: same)]
        #expect(CompanionAgentOrdering.ordered(agents, sort: .recent, lastActivity: \.lastActivity).map(\.name) == ["first", "second"])
    }

    /// Store activity falls back to the newest chat message when the desktop sends no time.
    @MainActor @Test func chatTimeCountsAsAgentActivity() {
        let quiet = agent("quiet"), chatty = agent("chatty")
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts([entries([("p1", [quiet, chatty])])[0].host]))
        store.apply(.timeline(chatty.id, items: [.message(.init(id: "m", role: .user, text: "hi", timestamp: ago(minutes: 2)))], sequence: 1, reset: true))
        #expect(CompanionAgentOrdering.ordered([quiet, chatty], sort: .recent, lastActivity: store.lastActivity(of:)).map(\.name) == ["chatty", "quiet"])
    }

    @Test func heldOrderKeepsRowsStillAndAppendsNewOnes() {
        let list = entries([("p1", [agent("a", activity: ago(minutes: 5)), agent("b", activity: ago(minutes: 1))])])
        let hold = layout(list).hold
        #expect(layout(list).projects[0].agents.map(\.name) == ["b", "a"])
        // "a" becomes newest and "c" arrives while the list is held.
        let changed = entries([("p1", [agent("a", activity: now), agent("b", activity: ago(minutes: 1)), agent("c", activity: now)])])
        #expect(layout(changed, hold: hold).projects[0].agents.map(\.name) == ["b", "a", "c"])
        #expect(layout(changed).projects[0].agents.map(\.name) == ["a", "c", "b"])
    }
}

struct CompanionPinTests {
    @Test func pinnedProjectsGoFirstInSortOrder() {
        let list = entries([("a", [agent("x", project: "a", activity: ago(minutes: 1))]), ("b", [agent("y", project: "b", activity: ago(minutes: 2))]),
                            ("c", [agent("z", project: "c", activity: ago(minutes: 3))])])
        let result = layout(list, rule: .init(pinned: [key("c"), key("b")]))
        #expect(result.projects.map(\.entry.project.id) == ["b", "c", "a"])
        #expect(result.projects.map(\.isPinned) == [true, true, false])
    }

    @Test func pinnedProjectIsNeverIdle() {
        let list = entries([("old", [agent("x", .sleeping, project: "old", activity: ago(days: 60))])])
        #expect(layout(list, rule: .init(pinned: [key("old")], inactive: [key("old")])).idle.isEmpty)
    }

    @MainActor @Test func pinsPersistAndBlockMarkingInactive() throws {
        let defaults = try #require(UserDefaults(suiteName: "companion-pins-\(UUID().uuidString)"))
        let preferences = CompanionPreferences(defaults: defaults)
        preferences.togglePinned(key("a"))
        preferences.markInactive(key("a"))
        #expect(preferences.inactiveProjects.isEmpty)
        let reloaded = CompanionPreferences(defaults: defaults)
        #expect(reloaded.pinnedProjects == [key("a")])
        #expect(key("a") == "mac\u{1F}a")
        reloaded.togglePinned(key("a"))
        #expect(CompanionPreferences(defaults: defaults).pinnedProjects.isEmpty)
    }
}

struct CompanionIdleRuleTests {
    private let rule = CompanionIdleRule()

    @Test func idleAfterTheWindowWithNothingAwake() {
        #expect(rule.isIdle("p", running: false, lastActivity: ago(days: 8), now: now))
        #expect(!rule.isIdle("p", running: false, lastActivity: ago(days: 6), now: now))
        #expect(!rule.isIdle("p", running: true, lastActivity: ago(days: 30), now: now))
        // No activity yet is active, as on the desktop.
        #expect(!rule.isIdle("p", running: false, lastActivity: nil, now: now))
    }

    @Test func windowChoicesAndNever() {
        #expect(CompanionIdleRule.dayChoices == [3, 7, 14, 30, 0])
        #expect(CompanionIdleRule(days: 3).isIdle("p", running: false, lastActivity: ago(days: 4), now: now))
        #expect(!CompanionIdleRule(days: 30).isIdle("p", running: false, lastActivity: ago(days: 29), now: now))
        #expect(!CompanionIdleRule(days: 0).isIdle("p", running: false, lastActivity: ago(days: 400), now: now))
    }

    @Test func manualMarkIsIdleAtOnceButAwakeAgentsKeepItInView() {
        let marked = CompanionIdleRule(inactive: ["p"])
        #expect(marked.isIdle("p", running: false, lastActivity: now, now: now))
        #expect(CompanionIdleRule(days: 0, inactive: ["p"]).isIdle("p", running: false, lastActivity: nil, now: now))
        #expect(!marked.isIdle("p", running: true, lastActivity: now, now: now))
    }

    @Test func layoutFoldsIdleProjectsInOrder() {
        let list = entries([("busy", [agent("w", .working, project: "busy", activity: ago(days: 20))]),
                            ("stale", [agent("s", .sleeping, project: "stale", activity: ago(days: 20))]),
                            ("fresh", [agent("f", .sleeping, project: "fresh", activity: ago(days: 1))]),
                            ("staler", [agent("t", .completed, project: "staler", activity: ago(days: 40))])])
        let result = layout(list)
        #expect(result.projects.map(\.entry.project.id) == ["fresh", "busy"])
        #expect(result.idle.map(\.entry.project.id) == ["stale", "staler"])
        #expect(result.idle.allSatisfy { $0.isIdle })
    }

    @MainActor @Test func markActiveClearsTheMarkAndCountsAsActivity() throws {
        let defaults = try #require(UserDefaults(suiteName: "companion-idle-\(UUID().uuidString)"))
        let preferences = CompanionPreferences(defaults: defaults)
        #expect(preferences.idleDays == 7)
        preferences.markInactive(key("p"))
        preferences.markInactive(key("p"))
        #expect(CompanionPreferences(defaults: defaults).inactiveProjects == [key("p")])
        preferences.markActive(key("p"), at: now)
        let reloaded = CompanionPreferences(defaults: defaults)
        #expect(reloaded.inactiveProjects.isEmpty)
        #expect(reloaded.projectActivity[key("p")] == now)
        reloaded.idleDays = 0
        #expect(CompanionPreferences(defaults: defaults).idleRule.days == 0)
    }
}

struct CompanionAgentFoldingTests {
    @Test func sleepingAndFinishedQuickAgentsFold() {
        let list = entries([("p1", [agent("awake", .working, activity: ago(minutes: 1)), agent("napping", .sleeping, activity: ago(minutes: 2)),
                                    agent("done", .completed, activity: ago(minutes: 3), quick: true), agent("quickRunning", .working, quick: true),
                                    agent("cancelled", .stopped, quick: true), agent("finishedDurable", .completed),
                                    agent("stoppedDurable", .stopped), agent("startingUp", .starting)])])
        let group = layout(list).projects[0]
        #expect(group.agents.map(\.name) == ["awake", "quickRunning", "finishedDurable", "startingUp"])
        #expect(group.sleeping.map(\.name) == ["napping", "stoppedDurable"])
        #expect(group.finishedQuick.map(\.name) == ["done", "cancelled"])
    }
}

struct CompanionIdentityTests {
    @Test func colorIdsMapToDesktopHex() {
        #expect(CompanionIdentityColor.rgb("emerald") == CompanionRGB(hex: "#10b981"))
        #expect(CompanionIdentityColor.rgb("#123456") == CompanionRGB(hex: "#123456"))
        #expect(CompanionIdentityColor.rgb("plaid") == nil)
        #expect(CompanionIdentityColor.rgb(nil) == nil)
    }

    @Test func dataURLDecodes() {
        #expect(CompanionIdentityColor.data(fromDataURL: "data:image/png;base64,aGk=") == Data("hi".utf8))
        #expect(CompanionIdentityColor.data(fromDataURL: "data:image/svg+xml,<svg/>") == nil)
        #expect(CompanionIdentityColor.data(fromDataURL: "https://example.com/a.png") == nil)
    }

    @MainActor @Test func catalogDecodesProjectAndAgentIdentity() {
        let project = CompanionLiveService.project(.object(["name": .string("repo"), "displayName": .string("Website"), "color": .string("teal"), "emoji": .string("🌐")]),
                                                   id: "p", agents: [], icon: .string("data:image/png;base64,aGk="))
        #expect(project.name == "Website" && project.color == "teal" && project.emoji == "🌐" && project.iconData == Data("hi".utf8))
        var durable = agent("d")
        CompanionLiveService.applyIdentity(.object(["color": .string("rose"), "freeAgentMode": .bool(true)]), icon: .string("data:image/png;base64,aGk="), to: &durable)
        #expect(durable.color == "rose" && durable.freeAgentMode && durable.iconData == Data("hi".utf8))
        var quick = agent("q")
        CompanionLiveService.applyIdentity(.object(["freeAgentMode": .bool(false)]), icon: nil, to: &quick)
        #expect(!quick.freeAgentMode && quick.color == nil)
    }
}
