import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionDispatcherLaunchTests {
    private func host(_ id: String, connection: CompanionConnection = .connected, enabled: Bool = true) -> CompanionHost {
        var agent = CompanionAgent(id: .init(hostID: id, projectID: "__dispatcher__", agentID: "dispatcher"), name: id, subtitle: "", status: .idle)
        agent.isDispatcher = true
        return .init(id: id, name: id, endpoint: "", connection: connection, projects: [],
                     dispatcher: .init(enabled: enabled, flagOn: enabled, agent: agent))
    }
    @Test func coldRequestWaitsForRestorationAndUnknownReports() {
        let a = host("a"), b = host("b")
        let desktops = [CompanionDispatcherDesktop(host: a)!]
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: nil,
            restorationComplete: false, hosts: [a]) == .waiting)
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: ["a", "b"],
            restorationComplete: true, hosts: [a]) == .waiting, "Do not incorrectly auto-open the first of several paired Dispatchers")
        var connecting = b; connecting.dispatcher = nil; connecting.connection = .connecting
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: ["a", "b"],
            restorationComplete: true, hosts: [a, connecting]) == .waiting)
    }
    @Test func zeroOneAndManyUseOnlyPairedReportedDispatchers() {
        let a = host("a"), b = host("b")
        let da = CompanionDispatcherDesktop(host: a)!, db = CompanionDispatcherDesktop(host: b)!
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [], pairedHostIDs: [], restorationComplete: true, hosts: []) == .unavailable)
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [da, db], pairedHostIDs: ["a"], restorationComplete: true, hosts: [a, b]) == .open(da))
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [da, db], pairedHostIDs: ["a", "b"], restorationComplete: true, hosts: [a, b]) == .choose([da, db]))
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [da], pairedHostIDs: [], restorationComplete: true, hosts: [a]) == .unavailable)
        var unavailable = da; unavailable.target = nil
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [unavailable], pairedHostIDs: ["a"], restorationComplete: true, hosts: [a]) == .unavailable)
    }
    @Test func offlineCachedDispatcherStillOpensItsExistingDraftWithoutNewAuthority() {
        let a = host("a", connection: .offline), d = CompanionDispatcherDesktop(host: a)!
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [d], pairedHostIDs: ["a"], restorationComplete: true, hosts: [a]) == .open(d))
        var off = a; off.dispatcher = nil
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [], pairedHostIDs: ["a"], restorationComplete: true, hosts: [off]) == .unavailable)
    }
}
