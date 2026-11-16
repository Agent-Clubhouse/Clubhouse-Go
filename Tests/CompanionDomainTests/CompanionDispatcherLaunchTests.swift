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
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: ["a"],
            restorationComplete: false, hosts: [a]) == .waiting, "Known IDs do not bypass pairing restoration")
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: nil,
            restorationComplete: false, hosts: [a]) == .waiting)
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: ["a", "b"],
            restorationComplete: true, hosts: [a]) == .waiting, "Do not incorrectly auto-open the first of several paired Dispatchers")
        var connecting = b; connecting.dispatcher = nil; connecting.connection = .connecting
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: desktops, pairedHostIDs: ["a", "b"],
            restorationComplete: true, hosts: [a, connecting]) == .waiting)
    }
    @Test func enabledLoadingDispatcherWaitsForItsAgentBeforeResolvingOneOrMany() {
        var a = host("a"); a.dispatcher?.agent = nil
        let b = host("b"), db = CompanionDispatcherDesktop(host: b)!
        #expect(a.dispatcher?.isLoading == true)
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [CompanionDispatcherDesktop(host: a)!],
            pairedHostIDs: ["a"], restorationComplete: true, hosts: [a]) == .waiting)
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [CompanionDispatcherDesktop(host: a)!, db],
            pairedHostIDs: ["a", "b"], restorationComplete: true, hosts: [a, b]) == .waiting,
            "The ready desktop must not win before the other Dispatcher catalog arrives")
        a = host("a")
        let da = CompanionDispatcherDesktop(host: a)!
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [da], pairedHostIDs: ["a"],
            restorationComplete: true, hosts: [a]) == .open(da))
        #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [da, db], pairedHostIDs: ["a", "b"],
            restorationComplete: true, hosts: [a, b]) == .choose([da, db]))
    }
    @Test func loadingThatFailsOrGoesOfflineResolvesTheHeldRequest() {
        var a = host("a"); a.dispatcher?.agent = nil
        let b = host("b"), c = host("c")
        let db = CompanionDispatcherDesktop(host: b)!, dc = CompanionDispatcherDesktop(host: c)!
        for connection in [CompanionConnection.offline, .failed("Catalog unavailable")] {
            a.connection = connection
            let loading = CompanionDispatcherDesktop(host: a)!
            #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [loading], pairedHostIDs: ["a"],
                restorationComplete: true, hosts: [a]) == .unavailable)
            #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [loading, db], pairedHostIDs: ["a", "b"],
                restorationComplete: true, hosts: [a, b]) == .open(db))
            #expect(CompanionDispatcherLaunchResolution.resolve(desktops: [loading, db, dc], pairedHostIDs: ["a", "b", "c"],
                restorationComplete: true, hosts: [a, b, c]) == .choose([db, dc]))
        }
    }
    @Test func coldReadinessBeforeTheOwnersHostsChangeUsesTheCurrentReport() {
        let a = host("a"), b = host("b")
        let da = CompanionDispatcherDesktop(host: a)!, db = CompanionDispatcherDesktop(host: b)!
        var navigation = CompanionNavigation(cached: [])
        #expect(navigation.dispatcherDesktops.isEmpty)
        #expect(navigation.resolveDispatcherLaunch(pairedHostIDs: ["a", "b"], restorationComplete: false,
            hosts: [a, b]) == .waiting)
        #expect(navigation.dispatcherDesktops.isEmpty, "Cold restoration cannot rewrite navigation")
        // No navigation.update/hosts onChange has run. This is the production Root entry point.
        #expect(navigation.resolveDispatcherLaunch(pairedHostIDs: ["a", "b"], restorationComplete: true,
            hosts: [a, b]) == .choose([da, db]), "Never consume the first cold request as unavailable")
        #expect(navigation.dispatcherDesktops == [da, db])
        var single = CompanionNavigation(cached: [])
        #expect(single.resolveDispatcherLaunch(pairedHostIDs: ["a"], restorationComplete: true,
            hosts: [a]) == .open(da))
        #expect(single.dispatcherTarget == da.target, "Root's subsequent open can use the reconciled target immediately")
    }
    @Test func acknowledgedRestoreFailureResolvesUnavailableWithoutTrustingCachedTargets() {
        let a = host("a"), cached = CompanionDispatcherDesktop(host: a)!
        var navigation = CompanionNavigation(cached: [cached])
        #expect(navigation.resolveDispatcherLaunch(pairedHostIDs: nil, restorationComplete: false,
            restorationFailed: true, hosts: []) == .waiting, "The visible restore error is acknowledged first")
        #expect(navigation.resolveDispatcherLaunch(pairedHostIDs: nil, restorationComplete: true,
            restorationFailed: true, hosts: []) == .unavailable)
        #expect(navigation.dispatcherDesktops == [cached], "Unavailable does not manufacture pairing authority or rewrite saved identity")
        #expect(navigation.resolveDispatcherLaunch(pairedHostIDs: nil, restorationComplete: true,
            hosts: []) == .waiting, "Unknown restoration without a terminal failure still waits")
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
