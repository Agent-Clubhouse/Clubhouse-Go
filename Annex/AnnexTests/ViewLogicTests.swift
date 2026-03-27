import Testing
import Foundation
import SwiftUI
@testable import ClubhouseGo

// MARK: - Agent Sort Order Tests

struct AgentSortOrderTests {
    @Test func sortByStatusPutsRunningFirst() {
        let running = DurableAgent(
            id: "a1", name: "runner", kind: "durable", color: "emerald",
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: .running, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )
        let sleeping = DurableAgent(
            id: "a2", name: "sleeper", kind: "durable", color: "rose",
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: .sleeping, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )
        let errored = DurableAgent(
            id: "a3", name: "broken", kind: "durable", color: "amber",
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: .error, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )

        let agents = [sleeping, errored, running]
        let sorted = agents.sorted { $0.statusSortOrder < $1.statusSortOrder }

        #expect(sorted[0].id == "a1") // running first
        #expect(sorted[1].id == "a3") // error second
        #expect(sorted[2].id == "a2") // sleeping third
    }

    @Test func statusSortOrderCoversAllStatuses() {
        let statuses: [AgentStatus] = [.starting, .running, .sleeping, .error, .failed, .completed, .cancelled]
        for status in statuses {
            let agent = DurableAgent(
                id: "test", name: nil, kind: nil, color: nil,
                branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                icon: nil, executionMode: nil, status: status, mission: nil,
                detailedStatus: nil, quickAgents: nil
            )
            let order = agent.statusSortOrder
            #expect(order >= 0 && order <= 5, "Status \(status) should have valid sort order")
        }
    }

    @Test func nilStatusSortedLast() {
        let agent = DurableAgent(
            id: "test", name: nil, kind: nil, color: nil,
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: nil, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )
        #expect(agent.statusSortOrder == 5)
    }
}

// MARK: - Agent Filtering Tests

struct AgentFilteringTests {
    private func makeAgent(id: String, name: String, status: AgentStatus?) -> DurableAgent {
        DurableAgent(
            id: id, name: name, kind: "durable", color: "emerald",
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: status, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )
    }

    @Test func filterHideSleepingExcludesSleepingAgents() {
        let agents = [
            makeAgent(id: "1", name: "runner", status: .running),
            makeAgent(id: "2", name: "sleeper", status: .sleeping),
            makeAgent(id: "3", name: "errored", status: .error),
            makeAgent(id: "4", name: "starter", status: .starting),
        ]

        let hideSleeping = true
        let filtered = agents.filter { agent in
            !hideSleeping || agent.status == .running || agent.status == .error || agent.status == .starting
        }

        #expect(filtered.count == 3)
        #expect(!filtered.contains { $0.status == .sleeping })
    }

    @Test func filterShowAllIncludesEverything() {
        let agents = [
            makeAgent(id: "1", name: "runner", status: .running),
            makeAgent(id: "2", name: "sleeper", status: .sleeping),
        ]

        let hideSleeping = false
        let filtered = agents.filter { agent in
            !hideSleeping || agent.status == .running
        }

        #expect(filtered.count == 2)
    }
}

// MARK: - Activity Aggregation Tests

struct ActivityAggregationTests {
    @Test func hookEventsAreSortedByTimestampDescending() {
        let events = [
            HookEvent(id: UUID(), agentId: "a1", kind: .preTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: 100),
            HookEvent(id: UUID(), agentId: "a1", kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: 300),
            HookEvent(id: UUID(), agentId: "a2", kind: .preTool, toolName: "Edit", toolVerb: nil, message: nil, timestamp: 200),
        ]

        let sorted = events.sorted { $0.timestamp > $1.timestamp }

        #expect(sorted[0].timestamp == 300)
        #expect(sorted[1].timestamp == 200)
        #expect(sorted[2].timestamp == 100)
    }

    @Test func recentActivityLimitedToMax() {
        var events: [HookEvent] = []
        for i in 0..<20 {
            events.append(HookEvent(
                id: UUID(), agentId: "a1", kind: .preTool,
                toolName: "Read", toolVerb: nil, message: nil,
                timestamp: 1000 + i
            ))
        }

        let limited = events
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(8)
            .map { $0 }

        #expect(limited.count == 8)
        #expect(limited[0].timestamp == 1019) // Most recent first
    }
}

// MARK: - Compact Time Formatting Tests

struct CompactTimeTests {
    @Test func nowForRecentTimestamps() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(compactRelativeTime(from: now) == "now")
        #expect(compactRelativeTime(from: now - 30_000) == "now") // 30 seconds ago
        #expect(compactRelativeTime(from: now - 59_000) == "now") // 59 seconds ago
    }

    @Test func minutesBoundary() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(compactRelativeTime(from: now - 60_000) == "1m")
        #expect(compactRelativeTime(from: now - 300_000) == "5m")
        #expect(compactRelativeTime(from: now - 3_540_000) == "59m") // 59 minutes
    }

    @Test func hoursBoundary() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(compactRelativeTime(from: now - 3_600_000) == "1h")
        #expect(compactRelativeTime(from: now - 7_200_000) == "2h")
        #expect(compactRelativeTime(from: now - 82_800_000) == "23h") // 23 hours
    }

    @Test func daysBoundary() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(compactRelativeTime(from: now - 86_400_000) == "1d")
        #expect(compactRelativeTime(from: now - 172_800_000) == "2d")
    }

    @Test func futureTimestampsReturnNow() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(compactRelativeTime(from: now + 60_000) == "now")
    }
}

// MARK: - Tool Icon Mapping Tests

struct ToolIconMappingTests {
    @Test func knownToolsMapToDistinctIcons() {
        let tools = ["Edit", "Read", "Write", "Bash", "Glob", "Grep", "WebSearch", "WebFetch", "Task"]
        var icons = Set<String>()
        for tool in tools {
            let icon = toolIcon(for: tool)
            #expect(icon != "wrench", "\(tool) should have a specific icon, not the default")
            icons.insert(icon)
        }
        #expect(icons.count == tools.count, "All known tools should map to distinct icons")
    }

    @Test func unknownToolReturnsDefault() {
        #expect(toolIcon(for: "UnknownTool") == "wrench")
        #expect(toolIcon(for: nil) == "wrench")
    }
}

// MARK: - Project Color Tests

struct ProjectColorTests {
    @Test func agentColorMapsAllKnownColors() {
        let colors = ["indigo", "emerald", "amber", "rose", "cyan", "violet", "orange", "teal"]
        for colorName in colors {
            let agentColor = AgentColor(rawValue: colorName)
            #expect(agentColor != nil, "\(colorName) should be a valid AgentColor")
            #expect(!agentColor!.hex.isEmpty)
        }
    }

    @Test func agentColorFallsBackToGrayForUnknown() {
        let color = AgentColor.color(for: "unknown")
        #expect(color == .gray)
    }

    @Test func agentColorFallsBackToGrayForNil() {
        let color = AgentColor.color(for: nil)
        #expect(color == .gray)
    }
}

// MARK: - AppStore Aggregate Query Tests

struct AppStoreAggregateTests {
    private func makeStore() -> AppStore {
        let store = AppStore()
        store.loadMockData()
        return store
    }

    @Test func totalAgentCountAcrossInstances() {
        let store = makeStore()
        #expect(store.totalAgentCount == 5)
    }

    @Test func runningAgentCountAcrossInstances() {
        let store = makeStore()
        #expect(store.runningAgentCount == 3)
    }

    @Test func allProjectsAcrossInstances() {
        let store = makeStore()
        #expect(store.allProjects.count == 3)
    }

    @Test func allPendingPermissionsAcrossInstances() {
        let store = makeStore()
        #expect(store.allPendingPermissions.count == 1)
    }

    @Test func allAgentsSortedByStatus() {
        let store = makeStore()
        let agents = store.allAgentsAcrossInstances
        #expect(agents.first?.agent.status == .running)
    }

    @Test func connectedInstancesExcludesDisconnected() {
        let store = AppStore()
        let inst = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "127.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")
        )
        inst.connectionState = .disconnected
        store.instances = [inst]
        #expect(store.connectedInstances.isEmpty)
    }
}

// MARK: - ServerInstance Activity Tests

struct ServerInstanceActivityTests {
    @Test func allActivityEventsFlattensCorrectly() {
        let inst = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "127.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")
        )
        inst.activityByAgent = [
            "agent1": [
                HookEvent(id: UUID(), agentId: "agent1", kind: .preTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: 100),
                HookEvent(id: UUID(), agentId: "agent1", kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: 200),
            ],
            "agent2": [
                HookEvent(id: UUID(), agentId: "agent2", kind: .preTool, toolName: "Edit", toolVerb: nil, message: nil, timestamp: 150),
            ],
        ]

        let all = inst.allActivityEvents
        #expect(all.count == 3)
    }

    @Test func activityForUnknownAgentReturnsEmpty() {
        let inst = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "127.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")
        )
        #expect(inst.activity(for: "nonexistent").isEmpty)
    }
}
