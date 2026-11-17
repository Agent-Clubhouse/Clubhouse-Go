import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

struct CompanionHomeLinkedRowsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entries(_ hosts: [CompanionHost]) -> [CompanionProjectEntry] {
        CompanionLinkedProjects.entries(hosts: hosts, links: hosts[0].projectLinks!.projectLinks)
    }

    private func layout(_ entries: [CompanionProjectEntry], sort: CompanionProjectSort = .recent,
                        hold: CompanionListHold? = nil) -> CompanionHomeLayout {
        CompanionHomeLayout.build(entries, sort: sort, customOrder: [], rule: .init(), now: now, hold: hold,
            projectActivity: { _ in now }, agentActivity: \.lastActivity)
    }

    @Test func combinedOrderKeepsEachHelperUnderItsOwnMachineRoot() throws {
        let group = try #require(layout(entries(CompanionHomeLinkedFixture.hosts(now: now))).projects.first)
        #expect(group.tree.active.map(\.agent.name) == ["River", "Willow", "Cedar", "Fern"])
        #expect(group.tree.active.map(\.depth) == [0, 1, 0, 1])
        #expect(group.tree.active.map(\.id.hostID) == ["combined-1", "combined-1", "combined-0", "combined-0"])
        #expect(group.tree.active.map(\.parentName) == [nil, "River", nil, "Cedar"])
        #expect(group.tree.sleeping.map(\.agent.name) == ["Juniper"], "A quiet-only desktop contributes to the one fold")
        #expect(!group.tree.all.contains { $0.id.hostID == "combined-3" }, "Cached offline work is never live")
    }

    @MainActor @Test func sameMachineCopiesKeepProjectOriginsInAllAndSingleDesktopScopes() throws {
        // The same Studio/Docs/Travel members as --companion-preview-linked-projects-same-machine.
        var hosts = CompanionPreviewService.hosts(now: now)
        hosts[0].projects = hosts[0].projects.filter { $0.id == "clubhouse" }
        hosts[0].projects.append(.init(id: "docs", name: "Docs", agents: []))
        let links: [AnnexProjectLinks.Group] = [.init(id: "preview-linked-clubhouse", projects: [
            .init(machine: "preview-studio", projectId: "clubhouse"),
            .init(machine: "preview-laptop", projectId: "notes"),
            .init(machine: "preview-studio", projectId: "docs")
        ])]
        let entry = try #require(CompanionLinkedProjects.entries(hosts: hosts, links: links).first)
        let studio = CompanionProjectTarget(hostID: "preview-studio", projectID: "clubhouse")
        let docs = CompanionProjectTarget(hostID: "preview-studio", projectID: "docs")
        let travel = CompanionProjectTarget(hostID: "preview-laptop", projectID: "notes")
        let all = CompanionHomeLinkedRows(entry: entry, finished: { _ in [] })
        #expect(all.projectOriginLabels == [studio: "Studio Mac · Clubhouse", docs: "Studio Mac · Docs"])
        #expect(all.projectOriginLabels[travel] == nil, "Ordinary members keep the normal machine-only badge")
        let scoped = try #require(CompanionHomeScope(hosts: hosts, selectedHostID: "preview-studio").projects([entry]).first)
        #expect(scoped.isLinked && scoped.members.count == 2)
        #expect(CompanionHomeLinkedRows(entry: scoped, finished: { _ in [] }).projectOriginLabels == all.projectOriginLabels,
                "A desktop scope must still distinguish two local projects")
        #expect(scoped.orderKey == entry.orderKey)
    }

    @Test func combinedTreeUsesSelectedSortAndHeldOrderWithoutMovingHelpers() throws {
        var hosts = CompanionHomeLinkedFixture.hosts(now: now)
        let original = layout(entries(hosts))
        #expect(layout(entries(hosts), sort: .alphabetical).projects[0].tree.active.map(\.agent.name) == ["Cedar", "Fern", "River", "Willow"])
        #expect(layout(entries(hosts), sort: .custom).projects[0].tree.active.map(\.agent.name) == ["Cedar", "Fern", "River", "Willow"])
        hosts[0].projects[0].agents[0].lastActivity = now
        #expect(layout(entries(hosts), hold: original.hold).projects[0].tree.active == original.projects[0].tree.active.map {
            var row = $0
            if row.id.hostID == "combined-0", row.depth == 0 { row.agent.lastActivity = now }
            return row
        })
        #expect(layout(entries(hosts)).projects[0].tree.active.first?.agent.name == "Cedar")
    }

    @MainActor @Test func oneQuietProjectionKeepsFullTargetsAndStableCompletionTies() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        defer { store.shutdown() }
        store.apply(.hosts(CompanionHomeLinkedFixture.hosts(now: now)))
        let entry = try #require(store.projectEntries.first)
        let quiet = CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:))
        #expect(quiet.foldID == "link:combined-home")
        #expect(quiet.finishedRuns.map(\.name) == ["Maple", "Birch", "Ash"])
        #expect(Set(quiet.finishedRuns.map(\.target)).count == 3, "Repeated agent IDs on different desktops stay distinct")
        #expect(quiet.finishedProjects.map(\.hostID) == ["combined-0", "combined-1", "combined-2"])
        let duplicate = CompanionHomeLinkedRows(entry: entry, finished: { target in
            let runs = store.finished(in: target)
            return runs + runs
        })
        #expect(duplicate.finishedRuns == quiet.finishedRuns)
        var newer = quiet.finishedRuns[1]
        newer.completedAt = now
        let sorted = CompanionHomeLinkedRows(entry: entry, finished: { target in
            target.hostID == "combined-1" ? [newer] : store.finished(in: target)
        })
        #expect(sorted.finishedRuns.map(\.name) == ["Birch", "Maple", "Ash"])
    }

    @MainActor @Test func singleMachineScopeAndOfflineChangesConstrainBothLiveAndQuietRows() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        defer { store.shutdown() }
        var hosts = CompanionHomeLinkedFixture.hosts(now: now)
        store.apply(.hosts(hosts))
        let entry = try #require(store.projectEntries.first)
        let scope = CompanionHomeScope(hosts: hosts, selectedHostID: "combined-2")
        let scoped = try #require(scope.projects([entry]).first)
        #expect(scope.impliedHostID == "combined-2" && !scope.showsHostTags)
        #expect(layout([scoped]).projects[0].tree.active.isEmpty)
        #expect(layout([scoped]).projects[0].tree.sleeping.map(\.agent.name) == ["Juniper"])
        #expect(CompanionHomeLinkedRows(entry: scoped, finished: store.finished(in:)).finishedRuns.map(\.name) == ["Ash"])
        hosts[1].connection = .offline
        store.apply(.hosts(hosts))
        let current = try #require(store.projectEntries.first)
        #expect(layout([current]).projects[0].tree.active.map(\.agent.name) == ["Cedar", "Fern"])
        #expect(CompanionHomeLinkedRows(entry: current, finished: store.finished(in:)).finishedRuns.map(\.name) == ["Maple", "Ash"])
        #expect(CompanionHomeSummary(hosts: hosts, needsYou: 0).working == 1)
    }

    @MainActor @Test func dismissAndClearRetainTheOtherMachinesRuns() async throws {
        let store = CompanionStore(service: CompanionPreviewService())
        defer { store.shutdown() }
        store.apply(.hosts(CompanionHomeLinkedFixture.hosts(now: now)))
        let entry = try #require(store.projectEntries.first)
        let quiet = CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:))
        await store.dismissFinished(quiet.finishedRuns[0].target)
        #expect(CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:)).finishedRuns.map(\.name) == ["Birch", "Ash"])
        await store.clearFinished(in: quiet.finishedProjects[1])
        #expect(CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:)).finishedRuns.map(\.name) == ["Ash"])
        await store.clearFinished(in: quiet.finishedProjects[2])
        #expect(CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:)).finishedRuns.isEmpty)
        #expect(layout([entry]).projects[0].tree.sleeping.map(\.agent.name) == ["Juniper"])
    }
}
