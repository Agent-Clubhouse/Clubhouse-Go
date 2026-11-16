import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionNavigationTests {
    private func host(_ id: String = "mac", enabled: Bool = true, flagOn: Bool = true,
                      connection: CompanionConnection = .connected, status: CompanionAgentStatus = .idle) -> CompanionHost {
        var agent = CompanionAgent(id: .init(hostID: id, projectID: "__dispatcher__", agentID: "dispatcher"), name: "Dispatcher", subtitle: "", status: status)
        agent.isDispatcher = true
        return .init(id: id, name: id, endpoint: "", connection: connection, projects: [],
                     dispatcher: .init(enabled: enabled, flagOn: flagOn, agent: agent))
    }

    @Test func tabControlEmitsOneTypedIntentFromTheSourceTab() {
        var navigation = CompanionNavigation()
        navigation.update(hosts: [host()])
        let switches: [(CompanionTab, AnnexUIAction)] = [
            (.dispatcher, .init(screen: .home, control: .dispatcherTab)),
            (.needsYou, .init(screen: .dispatcher, control: .needsYouTab)),
            (.search, .init(screen: .needsYou, control: .searchTab)),
            (.home, .init(screen: .search, control: .homeTab)),
            (.agents, .init(screen: .home, control: .searchTab)),
        ]
        for (tab, expected) in switches {
            #expect(navigation.selectFromTabBar(tab) == expected)
            #expect(navigation.tab == tab.destination)
            #expect(navigation.selectFromTabBar(tab) == nil, "An active-tab tap is not another switch")
        }
        navigation.select(.needsYou) // Programmatic navigation changes state without returning an intent.
        #expect(navigation.selectFromTabBar(.needsYou) == nil)
        var unavailable = CompanionNavigation()
        #expect(unavailable.selectFromTabBar(.dispatcher) == nil)
        #expect(unavailable.tab == .home)
    }

    @Test func tabsDependOnReportedFlagsAndNotConnection() {
        for connection in [CompanionConnection.connected, .offline, .connecting, .reconnecting, .synchronizing, .failed("lost")] {
            var navigation = CompanionNavigation(lastTab: .dispatcher)
            navigation.update(hosts: [host(connection: connection)])
            #expect(navigation.tabs == [.home, .dispatcher, .needsYou, .search])
        }
        for flags in [(false, true), (true, false), (false, false)] {
            var navigation = CompanionNavigation(lastTab: .dispatcher)
            navigation.update(hosts: [host(enabled: flags.0, flagOn: flags.1)])
            #expect(navigation.tabs == [.home, .needsYou, .search])
            #expect(navigation.tab == .home)
        }
    }

    @Test func launchRestoresEveryTabAndOnlyResolvesDispatchBeforeInteraction() {
        #expect(CompanionNavigation().tab == .home)
        for lastTab in CompanionTab.allCases {
            var navigation = CompanionNavigation(lastTab: lastTab)
            navigation.update(hosts: [])
            #expect(navigation.tab == (lastTab == .dispatcher ? .home : lastTab.destination))
            navigation.update(hosts: [host()])
            #expect(navigation.tab == lastTab.destination)
            navigation.select(.agents)
            navigation.update(hosts: [host(connection: .offline)])
            navigation.update(hosts: [host()])
            #expect(navigation.tab == .search)
        }
        var touched = CompanionNavigation(lastTab: .dispatcher)
        touched.interact()
        touched.update(hosts: [host()])
        #expect(touched.tab == .home)
        var initiallyOff = CompanionNavigation(lastTab: .dispatcher)
        initiallyOff.update(hosts: [host(enabled: false)])
        initiallyOff.update(hosts: [host()])
        #expect(initiallyOff.tab == .home, "Turning on later never changes tabs")
    }

    @Test func cacheAvoidsHomeFlashAndIsNotASecondLaunchOpportunity() {
        let cached = [CompanionDispatcherDesktop(host: host())!]
        var navigation = CompanionNavigation(lastTab: .dispatcher, cached: cached, lastHostID: "mac")
        #expect(navigation.tab == .dispatcher && navigation.dispatcherHostID == "mac")
        navigation.update(hosts: [])
        #expect(navigation.tab == .dispatcher)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .home)
        navigation.select(.search)
        navigation.update(hosts: [host()])
        #expect(navigation.tab == .search)
        #expect(CompanionNavigation(lastTab: .home, cached: cached).tab == .home)
        var knownOff = CompanionNavigation(lastTab: .dispatcher, cached: [])
        knownOff.update(hosts: [host()])
        #expect(knownOff.tab == .home)
    }

    @Test func disconnectedUnknownStateKeepsCachedTabAndExplicitOffLeavesOnce() {
        var navigation = CompanionNavigation(lastTab: .dispatcher)
        navigation.update(hosts: [host()])
        var connecting = host(connection: .reconnecting)
        connecting.dispatcher = nil
        navigation.update(hosts: [connecting])
        #expect(navigation.tab == .dispatcher && navigation.dispatcherDesktops.count == 1)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .home && !navigation.tabs.contains(.dispatcher))
        navigation.select(.agents)
        navigation.update(hosts: [host(enabled: false)])
        #expect(navigation.tab == .search)
    }

    @Test func severalDesktopsHaveOneTabAndRememberTheLastUsed() throws {
        var navigation = CompanionNavigation(lastTab: .dispatcher, lastHostID: "b")
        navigation.update(hosts: [host("a"), host("b")])
        #expect(navigation.tabs.filter { $0 == .dispatcher }.count == 1)
        #expect(navigation.dispatcherHostID == "b")
        navigation.chooseDispatcher(hostID: "a")
        #expect(navigation.visibleAgent?.hostID == "a")
        navigation.update(hosts: [host("a", enabled: false), host("b")])
        #expect(navigation.tab == .home && navigation.dispatcherHostID == "b")
        navigation.select(.dispatcher)
        #expect(navigation.visibleAgent?.hostID == "b", "Opening the surviving tab views B, which becomes the last-used desktop")
        navigation.update(hosts: [])
        #expect(navigation.tab == .home, "Removing paired desktops removes their tabs")
    }

    @Test func dispatcherLabelsSortByAgentThenMachineAndRefreshOnRename() throws {
        var studio = host("studio")
        studio.name = "Studio Mac"
        studio.dispatcher?.agent?.name = "Navi"
        var travel = host("travel")
        travel.name = "Travel MacBook"
        travel.dispatcher?.agent?.name = "Echo"
        var navigation = CompanionNavigation(lastTab: .dispatcher, lastHostID: studio.id)
        navigation.update(hosts: [studio, travel])
        #expect(navigation.dispatcherDesktops.map(\.displayName) == ["Echo", "Navi"])
        #expect(navigation.dispatcherDesktops.map(\.name) == ["Travel MacBook", "Studio Mac"])
        #expect(navigation.dispatcherDesktops.map(\.accessibilityLabel) == ["Echo on Travel MacBook", "Navi on Studio Mac"])
        #expect(navigation.dispatcherTitle(hosts: [studio, travel]) == "Navi")

        travel.dispatcher?.agent?.name = "Navi"
        navigation.update(hosts: [travel, studio])
        #expect(navigation.dispatcherDesktops.map(\.id) == ["studio", "travel"], "Duplicate names sort by machine")
        #expect(Set(navigation.dispatcherDesktops.map(\.accessibilityLabel)).count == 2)

        studio.dispatcher?.agent?.name = "Atlas"
        studio.name = "Renamed Mac"
        navigation.update(hosts: [travel, studio])
        let selected = try #require(navigation.dispatcherDesktops.first { $0.id == navigation.dispatcherHostID })
        #expect(selected.displayName == "Atlas" && selected.name == "Renamed Mac")
        #expect(selected.accessibilityLabel == "Atlas on Renamed Mac")
        #expect(navigation.dispatcherDesktops.map(\.id) == ["studio", "travel"])
        #expect(navigation.dispatcherTitle(hosts: [studio, travel]) == selected.displayName)
    }

    @Test func unnamedAndLoadingDispatchersKeepMachineDisambiguation() throws {
        for name in ["", " \n\t"] {
            var a = host("a")
            a.dispatcher?.agent?.name = name
            var b = host("b")
            b.dispatcher?.agent = nil
            var navigation = CompanionNavigation(lastTab: .dispatcher)
            navigation.update(hosts: [b, a])
            #expect(navigation.dispatcherDesktops.map(\.displayName) == ["Dispatcher", "Dispatcher"])
            #expect(navigation.dispatcherDesktops.map(\.accessibilityLabel) == ["Dispatcher on a", "Dispatcher on b"])
        }
    }

    @Test func dispatcherCachePreservesDisplayFieldsAndReadsOlderMachineOnlyEntries() throws {
        var named = host()
        named.dispatcher?.agent?.name = "Navi"
        let desktop = try #require(CompanionDispatcherDesktop(host: named))
        let data = try JSONEncoder().encode([desktop])
        #expect(try JSONDecoder().decode([CompanionDispatcherDesktop].self, from: data) == [desktop])
        let legacy = Data(#"[{"id":"mac","name":"Studio Mac"}]"#.utf8)
        let restored = try JSONDecoder().decode([CompanionDispatcherDesktop].self, from: legacy)
        #expect(restored.first?.displayName == "Dispatcher")
        #expect(restored.first?.accessibilityLabel == "Dispatcher on Studio Mac")
        let controllerCache = Data(#"[{"id":"mac","name":"Studio Mac","displayName":"Dispatcher controller"}]"#.utf8)
        #expect(try JSONDecoder().decode([CompanionDispatcherDesktop].self, from: controllerCache).first?.accessibilityLabel == "Dispatcher controller on Studio Mac", "Older caches also stored the snapshot's chosen chat name, not presence")
        var navigation = CompanionNavigation(lastTab: .dispatcher, cached: restored)
        navigation.update(hosts: [named])
        #expect(navigation.dispatcherDesktops.first?.displayName == "Navi")
    }

    @Test func linksFromEveryTabRouteToOneDispatcherAndCleanOldCopies() throws {
        var navigation = CompanionNavigation(lastTab: .home)
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

    @Test func aCachedDesktopWithoutARestoredPairingCannotLeaveAPhantomTab() throws {
        let cache = [try #require(CompanionDispatcherDesktop(host: host("a"))), try #require(CompanionDispatcherDesktop(host: host("b")))]
        var navigation = CompanionNavigation(lastTab: .dispatcher, cached: cache, lastHostID: "a")
        navigation.retainPairedDesktops(["b"])
        #expect(navigation.tab == .home && navigation.dispatcherHostID == "b")
        #expect(navigation.dispatcherDesktops.map(\.id) == ["b"])
        navigation.select(.dispatcher)
        navigation.retainPairedDesktops([])
        #expect(navigation.tab == .home && !navigation.tabs.contains(.dispatcher))
    }

    @Test func aLoadingDispatcherDoesNotRemoveProjectPagesFromOtherStacks() {
        var loading = host()
        loading.dispatcher?.agent = nil
        var navigation = CompanionNavigation(lastTab: .home)
        navigation.update(hosts: [loading])
        let project = CompanionRoute.project(.init(hostID: loading.id, projectID: "project"))
        navigation.setPath([project], for: .home, hosts: [loading])
        navigation.update(hosts: [loading])
        #expect(navigation.paths[.home] == [project] && navigation.visibleAgent == nil)
        #expect(navigation.tabs.first == .home)
    }

    @Test func notificationBeforeFirstSnapshotRoutesOnceAndCanBeCancelled() throws {
        let target = try #require(host().dispatcher?.agent?.id)
        var navigation = CompanionNavigation(lastTab: .home)
        navigation.open(target, hosts: [])
        navigation.update(hosts: [host()])
        #expect(navigation.tab == .dispatcher && navigation.visibleAgent == target)
        #expect(navigation.paths[.home] == [])
        var cancelled = CompanionNavigation(lastTab: .dispatcher)
        cancelled.open(target, hosts: [])
        cancelled.select(.search)
        cancelled.update(hosts: [host()])
        #expect(cancelled.tab == .search)
    }

    @MainActor @Test func disconnectRetainsConversationAndDraftButExplicitOffDropsOnlyConversation() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        let host = host()
        let target = try #require(host.dispatcher?.agent?.id)
        store.apply(.hosts([host]))
        store.apply(.timeline(target, items: [], sequence: 1, reset: true, sessionID: "session"))
        store.drafts[target] = "For A only"
        var disconnected = host
        disconnected.connection = .offline
        disconnected.dispatcher = nil
        store.apply(.hosts([disconnected]))
        #expect(store.agent(for: target) != nil && store.conversation(for: target).sessionID == "session")
        #expect(!store.canOperate(target) && store.drafts[target] == "For A only")
        var off = host
        off.dispatcher?.enabled = false
        store.apply(.hosts([off]))
        #expect(store.conversation(for: target).sessionID == nil && store.drafts[target] == "For A only")
    }

    @MainActor @Test func badgeUsesNeedsYouRuleIncludingConnectionAndHelpers() {
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts([host("a", status: .waiting), host("b", status: .approval), host("c", connection: .offline, status: .failed)]))
        #expect(store.dispatcherNeedsYouCount == 2 && store.needsYouCount == 2)
        var helping = host(status: .working)
        helping.canAnswerHelperRequests = true
        var request = CompanionPreviewService.helperRequests[0]
        request.hostID = helping.id
        request.projectID = "__dispatcher__"
        request.requesterID = "dispatcher"
        helping.helperRequests = [request]
        store.apply(.hosts([helping]))
        #expect(store.dispatcherNeedsYouCount == 1 && store.needsYouCount == 1)
        helping.helperRequests[0].expiresAt = .distantPast
        store.apply(.hosts([helping]))
        #expect(store.dispatcherNeedsYouCount == 0)
    }

    @MainActor @Test func preferencesRestoreEveryLastTabAndIgnoreTheRemovedStartScreen() throws {
        let name = "dispatcher-navigation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dispatcher", forKey: "companion.startScreen")
        let preferences = CompanionPreferences(defaults: defaults)
        #expect(preferences.lastTab == .home && preferences.dispatcherDesktops == nil)
        #expect(defaults.object(forKey: "companion.startScreen") == nil)
        preferences.dispatcherDesktops = [try #require(CompanionDispatcherDesktop(host: host()))]
        for tab in CompanionTab.allCases {
            preferences.lastTab = tab
            let restored = CompanionPreferences(defaults: defaults)
            #expect(restored.lastTab == tab.destination && restored.dispatcherDesktops == preferences.dispatcherDesktops)
            #expect(CompanionNavigation(lastTab: restored.lastTab, cached: restored.dispatcherDesktops).tab == tab.destination)
            #expect(defaults.string(forKey: "companion.lastTab") == tab.destination.rawValue)
        }
        defaults.set("unknown-future-tab", forKey: "companion.lastTab")
        #expect(CompanionPreferences(defaults: defaults).lastTab == .home)
        preferences.dispatcherDesktops = []
        #expect(CompanionPreferences(defaults: defaults).dispatcherDesktops == [])
    }

    @Test func legacyAgentsNavigationUsesSearchAndItsStack() {
        let target = CompanionTarget(hostID: "mac", projectID: "project", agentID: "worker")
        var navigation = CompanionNavigation(lastTab: .agents)
        #expect(navigation.tab == .search && !navigation.tabs.contains(.agents))
        navigation.select(.home)
        navigation.select(.agents)
        navigation.setPath([.agent(target)], for: .agents, hosts: [])
        #expect(navigation.tab == .search && navigation.visibleAgent == target)
        #expect(navigation.paths[.search] == [.agent(target)] && navigation.paths[.agents] == nil)
    }

    @MainActor @Test func recentAgentsKeepTheLastThreeDistinctOpenedAcrossLaunches() throws {
        let name = "search-recent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompanionPreferences(defaults: defaults)
        let targets = (0..<4).map { CompanionTarget(hostID: "mac", projectID: "project", agentID: String($0)) }
        for target in targets { preferences.recordOpenedAgent(target) }
        #expect(preferences.recentAgents == [targets[3], targets[2], targets[1]])
        preferences.recordOpenedAgent(targets[2])
        preferences.recordOpenedAgent(targets[2])
        #expect(preferences.recentAgents == [targets[2], targets[3], targets[1]])
        #expect(CompanionPreferences(defaults: defaults).recentAgents == preferences.recentAgents)
    }

    @MainActor @Test func recentAgentsAreScopedToTheDesktopEvenWhenAgentIDsMatch() throws {
        let name = "search-recent-host-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompanionPreferences(defaults: defaults)
        let store = CompanionStore(service: CompanionPreviewService())
        store.hosts = CompanionPreviewService.hosts(now: Date())
        let studio = CompanionTarget(hostID: "preview-studio", projectID: "clubhouse", agentID: "river")
        let laptop = CompanionTarget(hostID: "preview-laptop", projectID: "notes", agentID: "river")
        preferences.recordOpenedAgent(studio)
        preferences.recordOpenedAgent(laptop)
        #expect(preferences.recentAgents == [laptop, studio])
        #expect(preferences.recentAgents.compactMap { store.agent(for: $0)?.id } == [laptop, studio])
        store.hosts.removeAll { $0.id == studio.hostID }
        #expect(preferences.recentAgents.compactMap { store.agent(for: $0)?.id } == [laptop], "A missing Studio River never resolves to laptop River")
    }

    @MainActor @Test func removingAPairingPrunesItsRecentChoicesFromDisk() throws {
        let name = "search-recent-pairing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompanionPreferences(defaults: defaults)
        let a = CompanionTarget(hostID: "a", projectID: "project", agentID: "river")
        let b = CompanionTarget(hostID: "b", projectID: "project", agentID: "river")
        preferences.recordOpenedAgent(a)
        preferences.recordOpenedAgent(b)
        preferences.retainRecentAgents(on: ["a"])
        #expect(preferences.recentAgents == [a])
        #expect(CompanionPreferences(defaults: defaults).recentAgents == [a])
    }

    @MainActor @Test func connectedCatalogRemovalPrunesRecentButReconnectingDoesNot() throws {
        let name = "search-recent-disposal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CompanionPreferences(defaults: defaults)
        let a = CompanionTarget(hostID: "a", projectID: "project", agentID: "river")
        let b = CompanionTarget(hostID: "b", projectID: "project", agentID: "river")
        preferences.recordOpenedAgent(a)
        preferences.recordOpenedAgent(b)
        preferences.pruneRecentAgents(hosts: [host("a", connection: .reconnecting)])
        #expect(preferences.recentAgents == [b, a])
        preferences.pruneRecentAgents(hosts: [host("a")])
        #expect(preferences.recentAgents == [b], "Only a's authoritative catalog removed its agent")
        #expect(CompanionPreferences(defaults: defaults).recentAgents == [b])
    }

    @MainActor @Test func corruptOrOldRecentChoicesFallBackToEmpty() throws {
        let name = "search-recent-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let storedValues: [Any] = ["old-agent-id", Data("not json".utf8), Data(#"["bare-agent-id"]"#.utf8), Data(#"[{"agentID":"river"}]"#.utf8)]
        for stored in storedValues {
            defaults.set(stored, forKey: "companion.recentAgents")
            #expect(CompanionPreferences(defaults: defaults).recentAgents.isEmpty)
        }
    }
    @MainActor @Test func dispatchSelectionPersistsIndependentlyOfHomeAndRejectsCorruptChoices() throws {
        let suite = "dispatch-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices = try [host("a"), host("b")].map { try #require(CompanionDispatcherDesktop(host: $0)) }
        let preferences = CompanionPreferences(defaults: defaults)
        preferences.lastDispatcherHostID = "b"
        preferences.lastHostID = "a"
        let restored = CompanionPreferences(defaults: defaults)
        #expect(restored.lastDispatcherHostID == "b" && restored.lastHostID == "a")
        var navigation = CompanionNavigation(lastTab: .dispatcher, cached: choices,
            lastHostID: restored.lastHostID, lastDispatcherHostID: restored.lastDispatcherHostID)
        #expect(navigation.dispatcherHostID == "b")
        for cache: [CompanionDispatcherDesktop]? in [nil, []] {
            var cold = CompanionNavigation(lastTab: .dispatcher, cached: cache,
                lastHostID: "a", lastDispatcherHostID: "b")
            cold.update(hosts: [])
            #expect(cold.dispatcherHostID == "b", "The initial unknown catalog cannot discard the saved Dispatcher")
            cold.update(hosts: ["a", "b"].map { CompanionHost(id: $0, name: $0, endpoint: "", connection: .connecting, projects: []) })
            #expect(cold.dispatcherHostID == "b", "Pairing placeholders are not an authoritative Dispatcher catalog")
            cold.update(hosts: [host("a"), host("b")])
            #expect(cold.dispatcherHostID == "b", "The first real report restores the saved choice, not its first row")
            cold.update(hosts: [host("a")])
            #expect(cold.dispatcherHostID == "a", "A real removal still falls back safely")
            cold.update(hosts: [])
            #expect(cold.dispatcherHostID == nil, "Removing every observed host clears the selection")
        }
        navigation.retainPairedDesktops(["a"])
        #expect(navigation.dispatcherHostID == "a")
        for invalid: Any in [17, Data("invalid".utf8), ["a"], ""] {
            defaults.set(invalid, forKey: "companion.lastDispatcherHostID")
            let invalidPreferences = CompanionPreferences(defaults: defaults)
            #expect(invalidPreferences.lastDispatcherHostID == nil)
            let fallback = CompanionNavigation(lastTab: .dispatcher, cached: choices,
                lastHostID: invalidPreferences.lastHostID, lastDispatcherHostID: invalidPreferences.lastDispatcherHostID)
            #expect(fallback.dispatcherHostID == "a", "Missing/corrupt selection preserves the existing fallback")
        }
        let removed = CompanionNavigation(lastTab: .dispatcher, cached: choices,
            lastHostID: "a", lastDispatcherHostID: "forgotten")
        #expect(removed.dispatcherHostID == "a")
    }

}
