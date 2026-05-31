import Testing
@testable import ClubhouseGo

// MARK: - Dashboard Stats Formatting Tests
//
// Covers the combined "Agents" tile introduced in #84, which replaces the
// separate Running / Total Agents tiles with a single value reading
// `N (M running)`.

struct DashboardStatsTests {
    @Test func agentsValueCombinesTotalAndRunning() {
        #expect(DashboardStats.agentsValue(total: 48, running: 4) == "48 (4 running)")
    }

    @Test func agentsValueWithNoneRunning() {
        #expect(DashboardStats.agentsValue(total: 1, running: 0) == "1 (0 running)")
    }

    @Test func agentsValueWithNoAgents() {
        #expect(DashboardStats.agentsValue(total: 0, running: 0) == "0 (0 running)")
    }

    @Test func agentsValueWhenAllRunning() {
        #expect(DashboardStats.agentsValue(total: 5, running: 5) == "5 (5 running)")
    }

    @Test func accessibilityLabelPrefixesAgents() {
        #expect(
            DashboardStats.agentsAccessibilityLabel(total: 48, running: 4)
                == "Agents: 48 (4 running)"
        )
    }
}
