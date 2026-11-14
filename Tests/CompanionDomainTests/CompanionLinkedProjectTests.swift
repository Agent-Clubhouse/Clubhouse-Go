import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionLinkedProjectTests {
    private let a = "AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA"
    private let b = "bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb"

    private func host(_ id: String, projectID: String = "app", name: String = "App") -> CompanionHost {
        .init(id: id, name: id == a ? "Studio" : "Laptop", endpoint: "", connection: .connected, projects: [
            .init(id: projectID, name: name, agents: [
                .init(id: .init(hostID: id, projectID: projectID, agentID: "parent"), name: "River", subtitle: "", status: .approval),
                .init(id: .init(hostID: id, projectID: projectID, agentID: "helper"), name: "Juniper", subtitle: "", status: .working, parentAgentID: "parent")
            ])
        ])
    }

    private func link(_ refs: [(String, String)], id: String = "accepted", name: String? = nil) -> AnnexProjectLinks.Group {
        .init(id: id, projects: refs.map { .init(machine: $0.0.lowercased(), projectId: $0.1) }, name: name)
    }

    @Test func groupsOnlyQualifiedReferencesAndKeepsAgentIdentityAndTreesMachineScoped() throws {
        let hosts = [host(a), host(b), host("unknown")]
        let entries = CompanionLinkedProjects.entries(hosts: hosts, links: [link([(a, "app"), (b, "app")], name: "Shared app")])
        #expect(entries.count == 2)
        let group = try #require(entries.first)
        #expect(group.project.name == "Shared app")
        #expect(group.members.map(\.host.id) == [a, b])
        #expect(Set(group.project.agents.map(\.id)).count == 4)
        let tree = CompanionAgentTree.build(group.project.agents, sort: .custom, lastActivity: { _ in nil })
        #expect(tree.active.map(\.depth) == [0, 1, 0, 1])
        #expect(tree.active.filter { $0.depth == 0 }.map(\.rollup.count) == [1, 1])
        #expect(entries.last?.host.id == "unknown")
    }

    @Test func duplicateNamesDoNotLinkAndMissingReferencesDisappearWithoutBrokenEntries() {
        let links = [link([(a, "app"), (b, "app"), ("unpaired", "app"), (a, "missing")])]
        #expect(CompanionLinkedProjects.entries(hosts: [host(a), host(b)], links: []).count == 2)
        let group = CompanionLinkedProjects.entries(hosts: [host(a), host(b)], links: links)
        #expect(group.count == 1 && group.first?.project.name == "App")
        #expect(group.first?.members.count == 2)
        let removedMachine = CompanionLinkedProjects.entries(hosts: [host(a)], links: links)
        #expect(removedMachine.count == 1 && removedMachine.first?.isLinked == false)
        let removedProject = CompanionLinkedProjects.entries(hosts: [host(a), host(b, projectID: "other")], links: links)
        #expect(removedProject.count == 2 && removedProject.allSatisfy { !$0.isLinked })
    }

    @Test func unlinkAndMembershipReplacementSplitCleanlyAndTruncationLeavesOmittedProjectsUnlinked() {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = [host(a), host(b), host("third")]
        hosts[0].canLinkProjects = true
        hosts[0].projectLinks = .init(projectLinks: [link([(a, "app"), (b, "app")])], projectLinksTruncated: true)
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 2)
        #expect(store.projectEntry(containing: .init(hostID: b, projectID: "app"))?.members.count == 2)
        #expect(store.attentionItems().filter { [a, b].contains($0.agent.id.hostID) }.allSatisfy { $0.projectName == "App" })
        let attention = store.attentionProjects(store.attentionItems())
        #expect(attention.count == 2 && attention.first?.items.count == 2)
        hosts[0].projectLinks = .init(projectLinks: [link([(a, "app"), ("third", "app")], id: "manual", name: "Manual")])
        store.apply(.hosts(hosts))
        #expect(store.projectEntry(containing: .init(hostID: b, projectID: "app"))?.isLinked == false)
        #expect(store.projectEntry(containing: .init(hostID: a, projectID: "app"))?.project.name == "Manual")
        #expect(store.reviewEntries.first { $0.id.hostID == a }?.projectName == "Manual")
        hosts[0].projectLinks = .init(projectLinks: [])
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 3 && store.projectEntries.allSatisfy { !$0.isLinked })
    }

    @Test func usesOneCapableConnectedReplicaNeverAUnionAndFailsOverWithoutResurrectingRemovedLinks() {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = [host(a), host(b)]
        for index in hosts.indices { hosts[index].canLinkProjects = true }
        hosts[0].projectLinks = .init(projectLinks: [])
        hosts[1].projectLinks = .init(projectLinks: [link([(a, "app"), (b, "app")])])
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 2, "The selected source's empty replacement wins over a stale replica")
        store.apply(.hosts(hosts.reversed()))
        #expect(store.projectEntries.count == 2, "Reordering hosts does not switch a healthy source")
        hosts[0].connection = .offline
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 1, "Another connected member supplies the complete set")
        hosts[0].connection = .connected
        hosts[0].projectLinks = .init(projectLinks: [link([(a, "app"), (b, "app")])])
        hosts[1].projectLinks = .init(projectLinks: [])
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 2, "A later event from the current source replaces, not unions")
        hosts[1].canLinkProjects = false
        hosts[0].canLinkProjects = false
        store.apply(.hosts(hosts))
        #expect(store.projectEntries.count == 2, "Older desktops cannot supply linking information")
    }

    @Test func malformedOverlappingGroupsNeverDuplicateOrTransitivelyMergeProjects() {
        let entries = CompanionLinkedProjects.entries(hosts: [host(a), host(b), host("third")], links: [
            link([(a, "app"), (b, "app")]),
            link([(b, "app"), ("third", "app")], id: "invalid-overlap")
        ])
        #expect(entries.count == 2)
        #expect(entries.first?.members.map(\.host.id) == [a, b])
        #expect(entries.last?.isLinked == false)
    }

    @Test func homeUsesAllMembersActivityAndPinStateAndOnlyIdlesWhenEveryMemberIsIdle() throws {
        var hosts = [host(a), host(b)]
        for index in hosts.indices {
            for agent in hosts[index].projects[0].agents.indices { hosts[index].projects[0].agents[agent].status = .sleeping }
        }
        let entries = CompanionLinkedProjects.entries(hosts: hosts, links: [link([(a, "app"), (b, "app")])])
        let group = try #require(entries.first)
        let layout = CompanionHomeLayout.build(entries, sort: .recent, customOrder: [], rule: .init(),
                                               shared: { .init(pinned: $0.host.id == self.b, idle: $0.host.id == self.a) },
                                               projectActivity: { _ in nil }, agentActivity: { _ in nil })
        #expect(layout.projects.count == 1 && layout.projects.first?.isPinned == true)
        #expect(layout.idle.isEmpty)
        let mixed = CompanionHomeLayout.build(entries, sort: .custom, customOrder: [], rule: .init(),
                                              shared: { .init(idle: $0.host.id == self.a) },
                                              projectActivity: { _ in nil }, agentActivity: { _ in nil })
        #expect(mixed.projects.count == 1 && mixed.idle.isEmpty)
        let idle = CompanionHomeLayout.build(entries, sort: .custom, customOrder: [], rule: .init(),
                                             shared: { _ in .init(idle: true) },
                                             projectActivity: { _ in nil }, agentActivity: { _ in nil })
        #expect(idle.projects.isEmpty && idle.idle.count == 1)
        let ordered = CompanionProjectOrdering.ordered([.init(host: host("third"), project: .init(id: "other", name: "Other", agents: [])), group],
                                                       sort: .recent, customOrder: [], lastActivity: {
            $0.hostID == b ? Date(timeIntervalSince1970: 100) : nil
        })
        #expect(ordered.first?.isLinked == true, "Activity on the second machine sorts the whole project")
    }
}

@Suite @MainActor struct CompanionProjectLinksStreamTests {
    @Test func snapshotsAndSequencedReplayEventsReplaceIncludingEmptyAndMissingSnapshots() async throws {
        let harness = try await LiveServiceHarness.start { transport in
            await transport.setCapability("projectLinks", .object([
                "version": .integer(1), "snapshotField": .string("projectLinks"), "event": .string("project-links:changed")
            ]))
        }
        defer { harness.stop() }
        let linked: AnnexJSON = .array([.object(["id": .string("group"), "projects": .array([
            .object(["machine": .string(LiveServiceHarness.hostID), "projectId": .string("project")]),
            .object(["machine": .string("other"), "projectId": .string("project")])
        ])])])
        await harness.transport.emit(harness.snapshotEvent(["projectLinks": linked, "projectLinksTruncated": .bool(true)]))
        try await harness.waitUntil { harness.host?.projectLinks?.projectLinks.count == 1 }
        #expect(harness.host?.canLinkProjects == true)
        #expect(harness.host?.projectLinks?.projectLinksTruncated == true)
        await harness.transport.emit(.message(.init(type: "project-links:changed", payload: .object(["projectLinks": .array([])]), seq: 101, replayed: true)))
        try await harness.waitUntil { harness.host?.projectLinks?.projectLinks.isEmpty == true }
        #expect(harness.host?.projectLinks?.projectLinksTruncated == nil)
        await harness.transport.emit(.message(.init(type: "project-links:changed", payload: .object(["projectLinks": linked]), seq: 102)))
        try await harness.waitUntil { harness.host?.projectLinks?.projectLinks.count == 1 }
        await harness.transport.emit(harness.snapshotEvent([:]))
        try await harness.waitUntil { harness.host?.projectLinks == nil }
        await harness.transport.emit(harness.snapshotEvent(["projectLinks": .array([])]))
        try await harness.waitUntil { harness.host?.projectLinks?.projectLinks.isEmpty == true }
    }

    @Test func malformedReplacementSplitsAndExplainsTheFailure() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["projectLinks": .string("invalid")]))
        try await harness.waitUntil { harness.host?.projectLinksError != nil }
        #expect(harness.host?.projectLinks == nil)
        await harness.transport.emit(harness.snapshotEvent(["projectLinks": .array([])]))
        try await harness.waitUntil { harness.host?.projectLinks != nil && harness.host?.projectLinksError == nil }
    }
}
