import Testing
import Foundation
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

    @Test func hookEventKindIconMapping() {
        // Verify all kinds have distinct representations
        let kinds: [HookEventKind] = [.preTool, .postTool, .toolError, .stop, .notification, .permissionRequest]
        let seen = Set(kinds.map(\.rawValue))
        #expect(seen.count == kinds.count, "All hook event kinds should be distinct")
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
        // Mock data has: proj_001 (2 agents), proj_002 (2 agents), proj_003 (1 agent) = 5 total
        #expect(store.totalAgentCount == 5)
    }

    @Test func runningAgentCountAcrossInstances() {
        let store = makeStore()
        // Mock data: faithful-urchin (running), bold-eagle (running), swift-crane (running) = 3
        #expect(store.runningAgentCount == 3)
    }

    @Test func allProjectsAcrossInstances() {
        let store = makeStore()
        // 3 projects across 2 instances
        #expect(store.allProjects.count == 3)
    }

    @Test func allPendingPermissionsAcrossInstances() {
        let store = makeStore()
        // Mock data has 1 pending permission on inst2
        #expect(store.allPendingPermissions.count == 1)
    }

    @Test func allAgentsSortedByStatus() {
        let store = makeStore()
        let agents = store.allAgentsAcrossInstances
        // Running agents should come first
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

// MARK: - Status Indicator Tests

struct StatusIndicatorTests {
    @Test func agentInitialsFromHyphenatedName() {
        #expect(agentInitials(from: "faithful-urchin") == "FU")
        #expect(agentInitials(from: "bold-eagle") == "BE")
        #expect(agentInitials(from: "swift-crane") == "SC")
    }

    @Test func agentInitialsFromSingleWord() {
        #expect(agentInitials(from: "agent") == "A")
    }

    @Test func agentInitialsFromNil() {
        #expect(agentInitials(from: nil) == "")
    }

    @Test func projectInitialFromDisplayName() {
        #expect(projectInitial(from: "My App", name: "my-app") == "M")
    }

    @Test func projectInitialFallsBackToName() {
        #expect(projectInitial(from: nil, name: "api-server") == "A")
    }
}
