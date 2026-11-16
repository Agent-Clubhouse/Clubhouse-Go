import Foundation
import Testing
@testable import CompanionDomain

struct CompanionHomeProjectActivityTests {
    @Test func offlineDisclosureUsesKnownSeenTimeAndCountWithoutInventingMissingData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CompanionHomeOfflineMachineSummary(name: "Office Mac", lastSeen: now.addingTimeInterval(-720), agentCount: 2).text(now: now)
                == "Office Mac offline, seen 12m ago · 2 agents")
        #expect(CompanionHomeOfflineMachineSummary(name: "Office Mac", lastSeen: nil, agentCount: 1).text(now: now)
                == "Office Mac not connected · 1 agent")
        #expect(CompanionHomeOfflineMachineSummary(name: "Office Mac", lastSeen: nil, agentCount: nil).text(now: now)
                == "Office Mac not connected")
        #expect(CompanionHomeOfflineMachineSummary(name: "Office Mac", lastSeen: Date(timeIntervalSince1970: .nan), agentCount: 0).text(now: now)
                == "Office Mac not connected · 0 agents")
    }

    private func member(_ hostID: String, status: CompanionAgentStatus,
                        connection: CompanionConnection = .connected,
                        activity: Date? = nil, turn: Date? = nil) -> CompanionProjectMember {
        var agent = CompanionAgent(id: .init(hostID: hostID, projectID: "project", agentID: "river"),
                                   name: "River", subtitle: "", status: status, lastActivity: activity)
        agent.turnStartedAt = turn
        let project = CompanionProject(id: "project", name: "Shared", agents: [agent])
        return .init(host: .init(id: hostID, name: hostID, endpoint: "", connection: connection,
                                projects: [project]), project: project)
    }

    private func entry(_ members: [CompanionProjectMember], name: String = "Shared") -> CompanionProjectEntry {
        var project = members[0].project
        project.name = name
        project.agents = members.flatMap(\.project.agents)
        return .init(host: members[0].host, project: project, linkedMembers: members, linkID: name)
    }

    private func activity(_ members: [CompanionProjectMember]) -> CompanionHomeProjectActivity {
        .init(entry: entry(members), recordedProjectActivity: { _ in nil })
    }

    @Test func eitherLiveMemberAloneOrBothKeepTheMergedProjectRunning() {
        for statuses: [CompanionAgentStatus] in [[.working, .sleeping], [.sleeping, .working], [.working, .working]] {
            let members = [member("Studio", status: statuses[0]), member("Laptop", status: statuses[1])]
            #expect(activity(members).isRunning)
            #expect(activity(members).status == .working)
        }
        #expect(!activity([member("Studio", status: .sleeping), member("Laptop", status: .stopped)]).isRunning)
    }

    @Test func theMostUrgentLiveMemberWinsRegardlessOfCanonicalCopy() {
        for statuses: [CompanionAgentStatus] in [[.working, .approval], [.approval, .working]] {
            #expect(activity([member("Studio", status: statuses[0]), member("Laptop", status: statuses[1])]).status == .approval)
        }
        #expect(activity([member("Studio", status: .waiting), member("Laptop", status: .failed)]).status == .waiting)
    }

    @Test func unavailableCachedWorkIsNeverLiveAndDoesNotKeepTheGroupActive() {
        for connection: CompanionConnection in [.offline, .connecting, .reconnecting, .synchronizing, .failed("Lost") ] {
            let members = [member("Studio", status: .sleeping), member("Laptop", status: .working, connection: connection)]
            #expect(!activity(members).isRunning)
            #expect(activity(members).status == .sleeping)
            let group = entry(members)
            let layout = CompanionHomeLayout.build([group], sort: .recent, customOrder: [],
                rule: .init(inactive: Set(members.map { CompanionProjectEntry(host: $0.host, project: $0.project).orderKey })),
                projectActivity: { _ in nil }, agentActivity: \.lastActivity)
            #expect(layout.projects.isEmpty)
            #expect(layout.idle.count == 1)
            #expect(layout.idle[0].tree.all.map(\.agent.id.hostID) == ["Studio"])
        }
        let old = Date(timeIntervalSince1970: 1)
        #expect(activity([member("Studio", status: .working, activity: old, turn: old)]).isRunning,
                "A connected report stays authoritative; no wall-clock timer expires a long turn")
    }

    @Test func recentPutsAnyMemberRunningFirstThenUsesMaxRecordedRecencyAcrossMembers() {
        let older = Date(timeIntervalSince1970: 100), newest = Date(timeIntervalSince1970: 300)
        let running = entry([member("first", status: .sleeping), member("second", status: .working, activity: older)], name: "running")
        let sleeping = entry([member("third", status: .sleeping), member("fourth", status: .sleeping, turn: newest)], name: "sleeping")
        #expect(CompanionHomeProjectActivity.ordered([sleeping, running], recordedProjectActivity: { _ in nil }).map(\.orderKey) == [running.orderKey, sleeping.orderKey])
        #expect(CompanionHomeProjectActivity(entry: sleeping, recordedProjectActivity: { _ in older }).lastActivity == newest)
        let recorded = newest.addingTimeInterval(100)
        #expect(CompanionHomeProjectActivity(entry: sleeping, recordedProjectActivity: { $0.hostID == "third" ? recorded : nil }).lastActivity == recorded)
    }

    @Test func tiesKeepCatalogOrderAndNonFiniteTimesCannotChurnIt() {
        let same = Date(timeIntervalSince1970: 100)
        let first = entry([member("first", status: .sleeping, activity: same)], name: "first")
        let second = entry([member("second", status: .sleeping, activity: same)], name: "second")
        let invalid = entry([member("invalid", status: .sleeping, activity: Date(timeIntervalSince1970: .nan),
                                    turn: Date(timeIntervalSince1970: .infinity))], name: "invalid")
        #expect(CompanionHomeProjectActivity(entry: invalid, recordedProjectActivity: { _ in Date(timeIntervalSince1970: -.infinity) }).lastActivity == nil)
        let input = [second, invalid, first]
        let ordered = CompanionHomeProjectActivity.ordered(input, recordedProjectActivity: { _ in nil })
        #expect(ordered.map(\.orderKey) == [second.orderKey, first.orderKey, invalid.orderKey])
        #expect(CompanionHomeProjectActivity.ordered(ordered, recordedProjectActivity: { _ in nil }).map(\.orderKey) == ordered.map(\.orderKey))
    }
}
