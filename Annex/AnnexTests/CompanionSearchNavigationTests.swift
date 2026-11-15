import Foundation
import Testing
@testable import ClubhouseGo

@MainActor @Suite struct CompanionSearchNavigationTests {
    @Test func savedAgentsTabMigratesToSearchAndRetainsRecentChoices() throws {
        let name = "hosted-search-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("agents", forKey: "companion.lastTab")
        let preferences = CompanionPreferences(defaults: defaults)
        #expect(preferences.lastTab == .search)
        #expect(defaults.string(forKey: "companion.lastTab") == "search")
        let target = CompanionTarget(hostID: "studio", projectID: "project", agentID: "river")
        preferences.recordOpenedAgent(target)
        let restored = CompanionPreferences(defaults: defaults)
        #expect(restored.recentAgents == [target])
        var navigation = CompanionNavigation(lastTab: restored.lastTab)
        navigation.select(.agents)
        navigation.setPath([.agent(target)], for: .agents, hosts: [])
        #expect(navigation.tab == .search && navigation.visibleAgent == target)
        #expect(!navigation.tabs.contains(.agents))
    }
}
