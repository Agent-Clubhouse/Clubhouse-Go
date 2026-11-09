import Testing
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor @Suite(.serialized) struct CompanionDispatcherNameTests {
    private func host(_ id: String = "studio", name: String = "Navi") -> CompanionHost {
        var agent = CompanionAgent(id: .init(hostID: id, projectID: CompanionDispatcher.defaultProjectID, agentID: "dispatcher"),
                                   name: name, subtitle: "", status: .waiting)
        agent.isDispatcher = true
        return .init(id: id, name: id, endpoint: "", connection: .connected, projects: [],
                     dispatcher: .init(enabled: true, flagOn: true, agent: agent))
    }

    @Test func titleFollowsTheVisibleDesktopAndCurrentAgentName() {
        var hosts = [host(), host("laptop", name: "Echo")]
        var navigation = CompanionNavigation(startScreen: .dispatcher, lastHostID: "studio")
        navigation.update(hosts: hosts)
        navigation.chooseDispatcher(hostID: "studio")
        #expect(navigation.dispatcherTitle(hosts: hosts) == "Navi")
        navigation.chooseDispatcher(hostID: "laptop")
        #expect(navigation.dispatcherTitle(hosts: hosts) == "Echo")
        hosts[1].dispatcher?.agent?.name = "Atlas"
        #expect(navigation.dispatcherTitle(hosts: hosts) == "Atlas", "Identity updates need no cached navigation refresh")
        navigation.chooseDispatcher(hostID: "studio")
        #expect(navigation.dispatcherTitle(hosts: hosts) == "Navi")
    }

    @Test func missingUnavailableAndBlankNamesFallBackToDispatcher() {
        let named = host()
        let cached = [CompanionDispatcherDesktop(host: named)!]
        var navigation = CompanionNavigation(startScreen: .dispatcher, cached: cached)
        #expect(navigation.dispatcherTitle(hosts: []) == "Dispatcher")
        var loading = named
        loading.dispatcher?.agent = nil
        navigation.update(hosts: [loading])
        #expect(navigation.dispatcherTitle(hosts: [loading]) == "Dispatcher")
        var unavailable = named
        unavailable.dispatcher?.enabled = false
        #expect(navigation.dispatcherTitle(hosts: [unavailable]) == "Dispatcher")
        for name in ["", " \n\t"] {
            let unnamed = host(name: name)
            #expect(unnamed.dispatcher?.agent?.displayName == "Dispatcher")
            #expect(navigation.dispatcherTitle(hosts: [unnamed]) == "Dispatcher")
        }
        var mcpOff = named
        mcpOff.dispatcher?.enabled = false
        mcpOff.dispatcher?.mcpOff = .init(json: .object(["offReason": .string("mcp_off"), "running": .bool(false)]))
        #expect(navigation.dispatcherTitle(hosts: [mcpOff]) == "Navi", "MCP-off retains the agent's known identity")
    }

    @Test func placeCaptionsKeepTheDispatcherRoleAlongsideTheAgentName() {
        let named = host()
        let agent = named.dispatcher!.agent!
        let store = CompanionStore(service: CompanionPreviewService())
        store.hosts = [named]
        #expect(agent.displayName == "Navi")
        #expect(named.placeName(for: agent.id) == "Dispatcher")
        #expect(store.attentionItems().first?.agent.displayName == "Navi")
        #expect(store.attentionItems().first?.projectName == "Dispatcher")
        #expect(store.reviewEntries.first?.agent.displayName == "Navi")
        #expect(store.reviewEntries.first?.projectName == "Dispatcher")

        var unnamed = named
        unnamed.dispatcher?.agent?.name = ""
        store.hosts = [unnamed]
        #expect(unnamed.placeName(for: agent.id) == "Dispatcher")
        #expect(store.attentionItems().first?.projectName == "Dispatcher")
        #expect(store.reviewEntries.first?.projectName == "Dispatcher")

        var projectAgent = agent
        projectAgent.isDispatcher = false
        projectAgent.name = "River"
        #expect(projectAgent.displayName == "River")
    }

    @Test func hostedTitleFollowsTheSelectedConversationWhileBothDesktopsStayMounted() async throws {
        let store = CompanionStore(service: CompanionPreviewService())
        store.start()
        // Consume the preview's initial catalog before replacing it with two named Dispatchers.
        for _ in 0..<100 {
            if !store.hosts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hosts = [host(), host("laptop", name: "Echo")]
        store.hosts = hosts
        store.selection = hosts[0].dispatcher?.agent?.id
        let suite = "CompanionDispatcherNameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = CompanionPreferences(defaults: defaults)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionRootView(store: store, preferences: preferences,
                                                                                   onPair: {}, onSettings: {}))
        window.makeKeyAndVisible()
        defer {
            store.stop()
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        func title(in controller: UIViewController) -> String? {
            if let navigation = controller as? UINavigationController, navigation.viewIfLoaded?.window != nil {
                return navigation.navigationBar.topItem?.title
            }
            return controller.children.lazy.compactMap { title(in: $0) }.first
        }
        func awaitTitle(_ expected: String) async throws {
            for _ in 0..<100 {
                window.layoutIfNeeded()
                if title(in: window.rootViewController!) == expected { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(title(in: window.rootViewController!) == expected)
        }
        try await awaitTitle("Navi")
        store.selection = hosts[1].dispatcher?.agent?.id
        try await awaitTitle("Echo")
        store.hosts[1].dispatcher?.agent?.name = "Atlas"
        try await awaitTitle("Atlas")
        store.selection = hosts[0].dispatcher?.agent?.id
        try await awaitTitle("Navi")
    }
}
