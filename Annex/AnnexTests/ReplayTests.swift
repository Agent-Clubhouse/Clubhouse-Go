import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - ReplayState Tests

struct ReplayStateTests {

    @Test func idleState() {
        let state = ReplayState.idle
        #expect(state.isReplaying == false)
        #expect(state.hasGap == false)
        #expect(state.label == "")
    }

    @Test func replayingState() {
        let state = ReplayState.replaying(fromSeq: 100, toSeq: 200, count: 101)
        #expect(state.isReplaying == true)
        #expect(state.hasGap == false)
        #expect(state.label == "Catching up... (101 events)")
    }

    @Test func gapState() {
        let state = ReplayState.gap(oldestAvailable: 500)
        #expect(state.isReplaying == false)
        #expect(state.hasGap == true)
        #expect(state.label == "Some events may be missing")
    }

    @Test func replayStateEquatable() {
        #expect(ReplayState.idle == ReplayState.idle)
        #expect(ReplayState.replaying(fromSeq: 1, toSeq: 10, count: 10) == ReplayState.replaying(fromSeq: 1, toSeq: 10, count: 10))
        #expect(ReplayState.gap(oldestAvailable: 5) == ReplayState.gap(oldestAvailable: 5))
        #expect(ReplayState.idle != ReplayState.gap(oldestAvailable: 5))
        #expect(ReplayState.replaying(fromSeq: 1, toSeq: 10, count: 10) != ReplayState.idle)
    }
}

// MARK: - ServerInstance Replay State Tests

struct ServerInstanceReplayStateTests {

    private func makeInstance() -> ServerInstance {
        ServerInstance(
            id: ServerInstanceID(value: "test-replay"),
            protocolConfig: .v2(host: "localhost", mainPort: 4321, pairingPort: 4322, fingerprint: "fp")
        )
    }

    @Test func initialReplayStateIsIdle() {
        let instance = makeInstance()
        #expect(instance.replayState == .idle)
    }

    @Test func replayStateUpdatesOnGap() {
        let instance = makeInstance()
        // Simulate receiving a gap by directly setting replayState
        instance.replayState = .gap(oldestAvailable: 500)
        #expect(instance.replayState.hasGap == true)
        #expect(instance.replayState.label == "Some events may be missing")
    }

    @Test func replayStateUpdatesOnReplaying() {
        let instance = makeInstance()
        instance.replayState = .replaying(fromSeq: 50, toSeq: 150, count: 101)
        #expect(instance.replayState.isReplaying == true)
    }

    @Test func replayStateResetsToIdle() {
        let instance = makeInstance()
        instance.replayState = .replaying(fromSeq: 50, toSeq: 150, count: 101)
        instance.replayState = .idle
        #expect(instance.replayState == .idle)
    }
}

// MARK: - LocalCache Tests

struct LocalCacheTests {

    private let testInstanceId = ServerInstanceID(value: "test-cache-\(UUID().uuidString.prefix(8))")

    @Test func saveAndLoadSnapshot() {
        let snapshot = LocalCache.CachedSnapshot(
            projects: [Project(id: "proj_001", name: "test-project", path: "/test", color: "blue", icon: nil, displayName: "Test Project", orchestrator: nil)],
            agents: [:],
            quickAgents: [:],
            theme: .mock,
            orchestrators: [:],
            serverName: "Test Server",
            lastSeq: 42,
            savedAt: Date()
        )

        LocalCache.saveSnapshot(snapshot, instanceId: testInstanceId)
        let loaded = LocalCache.loadSnapshot(instanceId: testInstanceId)

        #expect(loaded != nil)
        #expect(loaded?.projects.count == 1)
        #expect(loaded?.projects[0].id == "proj_001")
        #expect(loaded?.serverName == "Test Server")
        #expect(loaded?.lastSeq == 42)

        // Cleanup
        LocalCache.clearInstance(testInstanceId)
    }

    @Test func loadSnapshotReturnsNilWhenNoCache() {
        let id = ServerInstanceID(value: "nonexistent-\(UUID().uuidString)")
        let loaded = LocalCache.loadSnapshot(instanceId: id)
        #expect(loaded == nil)
    }

    @Test func saveAndLoadActivity() {
        let events = [
            HookEvent(id: UUID(), agentId: "agent_001", kind: .preTool, toolName: "Read", toolVerb: "Reading", message: nil, timestamp: 1737000000000),
            HookEvent(id: UUID(), agentId: "agent_001", kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: 1737000001000)
        ]
        let activity = ["agent_001": events]

        LocalCache.saveActivity(activity, instanceId: testInstanceId)
        let loaded = LocalCache.loadActivity(instanceId: testInstanceId)

        #expect(loaded != nil)
        #expect(loaded?["agent_001"]?.count == 2)
        #expect(loaded?["agent_001"]?[0].toolName == "Read")

        // Cleanup
        LocalCache.clearInstance(testInstanceId)
    }

    @Test func activityCacheTrimmedTo50() {
        var events: [HookEvent] = []
        for i in 0..<100 {
            events.append(HookEvent(
                id: UUID(), agentId: "agent_001", kind: .preTool,
                toolName: "Tool\(i)", toolVerb: nil, message: nil,
                timestamp: Int(1737000000000) + i * 1000
            ))
        }
        let activity = ["agent_001": events]

        LocalCache.saveActivity(activity, instanceId: testInstanceId)
        let loaded = LocalCache.loadActivity(instanceId: testInstanceId)

        #expect(loaded?["agent_001"]?.count == 50)
        // Should keep the last 50 (newest)
        #expect(loaded?["agent_001"]?.first?.toolName == "Tool50")

        // Cleanup
        LocalCache.clearInstance(testInstanceId)
    }

    @Test func clearInstanceRemovesCache() {
        let snapshot = LocalCache.CachedSnapshot(
            projects: [], agents: [:], quickAgents: [:],
            theme: .mock, orchestrators: [:], serverName: "Test",
            lastSeq: nil, savedAt: Date()
        )
        LocalCache.saveSnapshot(snapshot, instanceId: testInstanceId)
        LocalCache.clearInstance(testInstanceId)

        let loaded = LocalCache.loadSnapshot(instanceId: testInstanceId)
        #expect(loaded == nil)
    }

    @Test func loadActivityReturnsNilWhenNoCache() {
        let id = ServerInstanceID(value: "nonexistent-\(UUID().uuidString)")
        let loaded = LocalCache.loadActivity(instanceId: id)
        #expect(loaded == nil)
    }
}

// MARK: - Replay Model Tests

struct ReplayModelCodableTests {

    @Test func decodeReplayStartPayload() throws {
        let json = """
        {"fromSeq":50,"toSeq":150,"count":101}
        """
        let payload = try JSONDecoder().decode(ReplayStartPayload.self, from: Data(json.utf8))
        #expect(payload.fromSeq == 50)
        #expect(payload.toSeq == 150)
        #expect(payload.count == 101)
    }

    @Test func decodeReplayGapPayload() throws {
        let json = """
        {"oldestAvailable":500,"lastSeq":1000}
        """
        let payload = try JSONDecoder().decode(ReplayGapPayload.self, from: Data(json.utf8))
        #expect(payload.oldestAvailable == 500)
        #expect(payload.lastSeq == 1000)
    }

    @Test func encodeReplayRequest() throws {
        let request = ReplayRequest(type: "replay", since: 42)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ReplayRequest.self, from: data)
        #expect(decoded.type == "replay")
        #expect(decoded.since == 42)
    }

    @Test func cachedSnapshotRoundTrip() throws {
        let snapshot = LocalCache.CachedSnapshot(
            projects: [Project(id: "p1", name: "test", path: "/test", color: nil, icon: nil, displayName: nil, orchestrator: nil)],
            agents: ["p1": [DurableAgent(id: "a1", name: "agent", kind: "durable", color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil)]],
            quickAgents: [:],
            theme: .mock,
            orchestrators: ["cc": OrchestratorEntry(displayName: "Claude Code", shortName: "CC", badge: nil)],
            serverName: "My Mac",
            lastSeq: 999,
            savedAt: Date()
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LocalCache.CachedSnapshot.self, from: data)
        #expect(decoded.projects.count == 1)
        #expect(decoded.agents["p1"]?.count == 1)
        #expect(decoded.serverName == "My Mac")
        #expect(decoded.lastSeq == 999)
    }
}
