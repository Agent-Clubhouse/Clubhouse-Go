import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionNavigationTests {
    private func host(_ id: String = "mac", enabled: Bool = true, flagOn: Bool = true,
                      connection: CompanionConnection = .connected, status: CompanionAgentStatus = .idle) -> CompanionHost {
        var agent = CompanionAgent(id: .init(hostID: id, projectID: "__dispatcher__", agentID: "dispatcher"), name: "Dispatcher", subtitle: "", status: status)
        agent.isDispatcher = true
        return .init(id: id, name: id, endpoint: "", connection: connection, projects: [],
                     dispatcher: .init(enabled: enabled, flagOn: flagOn, agent: agent))
    }

    @Test func tabsDependOnReportedFlagsAndNotConnection() {
        for connection in [CompanionConnection.connected, .offline, .connecting, .reconnecting, .synchronizing, .failed("lost")] {
            var navigation = CompanionNavigation(startScreen: .dispatcher)
            navigation.update(hosts: [host(connection: connection)])
            #expect(navigation.tabs == [.dispatcher, .home, .needsYou, .agents, .search])
        }
        for flags in [(false, true), (true, false), (false, false)] {
            var navigation = CompanionNavigation(startScreen: .dispatcher)
            navigation.update(hosts: [host(enabled: flags.0, flagOn: flags.1)])
            #expect(navigation.tabs == [.home, .needsYou, .agents, .search])
            #expect(navigation.tab == .home)
        }
    }

    @Test func launchResolvesOnceAndOnlyBeforeInteraction() {
        for preference in CompanionStartScreen.allCases {
            var navigation = CompanionNavigation(startScreen: preference)
            navigation.update(hosts: [])
            #expect(navigation.tab == .home)
            navigation.update(hosts: [host()])
            #expect(navigation.tab == (preference == .dispatcher ? .dispatcher : .home))
            navigation.select(.agents)
            navigation.update(hosts: [host(connection: .offline)])
            navigation.update(hosts: [host()])
            #expect(navigation.tab == .agents)
        }
        var touched = CompanionNavigation(startScreen: .dispatcher)
        touched.interact()
        touched.update(hosts: [host()])
        #expect(touched.tab == .home)
        var initiallyOff = CompanionNavigation(startScreen: .dispatcher)
        initiallyOff.update(hosts: [host(enabled: false)])
        initiallyOff.update(hosts: [host()])
        #expect(initiallyOff.tab == .home, "Turning on later never changes tabs")
    }

    @Test func cacheAvoidsHomeFlashAndIsNotASecondLaunchOpportunity() {
        let cached = [CompanionDispatcherDesktop(host: host())!]
        var navigation = CompanionNavigation(startScreen: .dispatcher, cached: cached, lastHostID: "mac")
        #expect(navigation.tab == .dispatcher && navigation.dispatcherHostID == "mac")
        navigation.update(hosts: [])
        #expect(navigation.tab == .dispatcher)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .home)
        navigation.select(.search)
        navigation.update(hosts: [host()])
        #expect(navigation.tab == .search)
        #expect(CompanionNavigation(startScreen: .home, cached: cached).tab == .home)
        var knownOff = CompanionNavigation(startScreen: .dispatcher, cached: [])
        knownOff.update(hosts: [host()])
        #expect(knownOff.tab == .home)
    }

    @Test func disconnectedUnknownStateKeepsCachedTabAndExplicitOffLeavesOnce() {
        var navigation = CompanionNavigation(startScreen: .dispatcher)
        navigation.update(hosts: [host()])
        var connecting = host(connection: .reconnecting)
        connecting.dispatcher = nil
        navigation.update(hosts: [connecting])
        #expect(navigation.tab == .dispatcher && navigation.dispatcherDesktops.count == 1)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .home && !navigation.tabs.contains(.dispatcher))
        navigation.select(.agents)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .agents)
    }

    @Test func severalDesktopsHaveOneTabAndRememberTheLastUsed() throws {
        var navigation = CompanionNavigation(startScreen: .dispatcher, lastHostID: "b")
        navigation.update(hosts: [host("a"), host("b")])
        #expect(navigation.tabs.filter { $0 == .dispatcher }.count == 1)
        #expect(navigation.dispatcherHostID == "b")
        navigation.chooseDispatcher(hostID: "a")
        #expect(navigation.visibleAgent?.hostID == "a")
        navigation.update(hosts: [host("a", enabled: false), host("b")])
        #expect(navigation.tab == .dispatcher && navigation.dispatcherHostID == "b")
        navigation.update(hosts: [])
        #expect(navigation.tab == .home, "Removing paired desktops removes their tabs")
    }

    @Test func linksFromEveryTabRouteToOneDispatcherAndCleanOldCopies() throws {
        var navigation = CompanionNavigation(startScreen: .home)
        navigation.update(hosts: [host()])
        let dispatcher = try #require(host().dispatcher?.agent?.id)
        let worker = CompanionTarget(hostID: "mac", projectID: "p", agentID: "worker")
        for tab in [CompanionTab.home, .needsYou, .agents, .search, .dispatcher] {
            navigation.select(tab)
            navigation.paths[.home] = [.agent(worker), .agent(dispatcher)]
            navigation.paths[.search] = [.agent(dispatcher)]
            navigation.open(dispatcher, hosts: [host()])
            #expect(navigation.tab == .dispatcher && navigation.visibleAgent == dispatcher)
            #expect(navigation.paths.values.flatMap { $0 }.allSatisfy { $0.agent != dispatcher })
            #expect(navigation.paths[.home] == [.agent(worker)])
        }
        navigation.open(worker, hosts: [host()])
        #expect(navigation.paths[.dispatcher] == [.agent(worker)] && navigation.visibleAgent == worker)
        navigation.select(.home)
        #expect(navigation.visibleAgent == worker)
        navigation.select(.search)
        #expect(navigation.visibleAgent == nil, "Hidden Dispatcher isn't viewed")
        navigation.setPath([.agent(dispatcher)], for: .search, hosts: [host()])
        #expect(navigation.tab == .dispatcher && navigation.paths[.search] == [])
    }

    @MainActor @Test func badgeUsesNeedsYouRuleIncludingConnectionAndHelpers() {
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts([host("a", status: .waiting), host("b", status: .approval), host("c", connection: .offline, status: .failed)]))
        #expect(store.dispatcherNeedsYouCount == 2 && store.needsYouCount == 2)
        store.apply(.hosts([host(status: .working)]))
        #expect(store.dispatcherNeedsYouCount == 0)
    }

    @MainActor @Test func preferencesPersistStartScreenAndLastKnownState() throws {
        let name = "dispatcher-navigation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompanionPreferences(defaults: defaults)
        #expect(preferences.startScreen == .dispatcher && preferences.dispatcherDesktops == nil)
        preferences.startScreen = .home
        preferences.dispatcherDesktops = [try #require(CompanionDispatcherDesktop(host: host()))]
        let restored = CompanionPreferences(defaults: defaults)
        #expect(restored.startScreen == .home && restored.dispatcherDesktops == preferences.dispatcherDesktops)
        preferences.dispatcherDesktops = []
        #expect(CompanionPreferences(defaults: defaults).dispatcherDesktops == [])
    }
}
