import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

struct CompanionHomeScopeTests {
    private func host(_ id: String, connection: CompanionConnection = .connected) -> CompanionHost {
        .init(id: id, name: "\(id) Mac", endpoint: "", connection: connection,
              projects: [.init(id: "project", name: "\(id) project", agents: [
                .init(id: .init(hostID: id, projectID: "project", agentID: "river"),
                      name: "River", subtitle: "", status: .working)
              ])])
    }

    @Test func selectedDesktopProjectsAndSameNamedAgentsNeverLeakAcrossMachines() throws {
        let first = host("one"), second = host("two")
        let members = [first, second].map { CompanionProjectMember(host: $0, project: $0.projects[0]) }
        var merged = first.projects[0]
        merged.name = "Shared project"
        merged.agents = members.flatMap(\.project.agents)
        let entry = CompanionProjectEntry(host: first, project: merged, linkedMembers: members, linkID: "shared")
        for selected in ["one", "two"] {
            let scope = CompanionHomeScope(hosts: [first, second], selectedHostID: selected)
            let scoped = try #require(scope.projects([entry]).first)
            #expect(scoped.members.map(\.host.id) == [selected])
            #expect(scoped.project.agents.map(\.id.hostID) == [selected])
            #expect(scoped.id.hostID == selected)
            #expect(scoped.project.name == "Shared project")
            #expect(scoped.orderKey == entry.orderKey)
            #expect(scope.contains(scoped.project.agents[0].id))
            #expect(!scope.contains(.init(hostID: selected == "one" ? "two" : "one", projectID: "project", agentID: "river")))
        }
        #expect(CompanionHomeScope(hosts: [first, second], selectedHostID: nil).projects([entry]) == [entry])
    }

    @Test func offlineDesktopRemainsAValidScopeWithoutOperableAuthority() {
        let first = host("one"), offline = host("two", connection: .offline)
        let scope = CompanionHomeScope(hosts: [first, offline], selectedHostID: "two")
        #expect(scope.hosts.map(\.id) == ["two"])
        #expect(scope.hosts.allSatisfy { !$0.connection.canOperate })
        #expect(scope.impliedHostID == "two" && !scope.showsHostTags)
        let entries = [first, offline].map { CompanionProjectEntry(host: $0, project: $0.projects[0]) }
        #expect(scope.projects(entries).map(\.host.id) == ["two"])
    }

    @Test func disappearedSelectionImmediatelyFallsBackToAllAndOneDesktopHasImpliedContext() {
        let remaining = host("one")
        let scope = CompanionHomeScope(hosts: [remaining], selectedHostID: "removed")
        #expect(scope.selectedHostID == nil)
        #expect(scope.hosts == [remaining])
        #expect(scope.impliedHostID == "one")
        #expect(!scope.showsHostTags)
        #expect(CompanionHomeScope(hosts: [remaining, host("two")], selectedHostID: nil).showsHostTags)
    }

    @Test func connectionSummaryIncludesTwoDesktopDisconnectionButSuppressesSoleDesktopIdentity() {
        let first = host("one"), offline = host("two", connection: .offline)
        #expect(CompanionHomeSummary(hosts: [first, offline], needsYou: 0).connectionLabel == "1 of 2 desktops connected")
        #expect(CompanionHomeSummary(hosts: [offline], needsYou: 0).connectionLabel == nil)
    }
}
