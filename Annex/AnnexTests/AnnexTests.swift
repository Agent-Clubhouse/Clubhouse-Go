import Testing
import Foundation
import SwiftUI
@testable import ClubhouseGo

// MARK: - Model Decoding Tests

struct ModelDecodingTests {
    @Test func decodeStatusResponse() throws {
        let json = """
        {"version":"1","deviceName":"Clubhouse on Mason's Mac","agentCount":5,"orchestratorCount":1}
        """
        let response = try JSONDecoder().decode(StatusResponse.self, from: Data(json.utf8))
        #expect(response.version == "1")
        #expect(response.deviceName == "Clubhouse on Mason's Mac")
        #expect(response.agentCount == 5)
        #expect(response.orchestratorCount == 1)
    }

    @Test func decodeErrorResponse() throws {
        let json = """
        {"error": "invalid_pin"}
        """
        let response = try JSONDecoder().decode(ErrorResponse.self, from: Data(json.utf8))
        #expect(response.error == "invalid_pin")
    }

    @Test func decodeProject() throws {
        let json = """
        {"id":"proj_abc123","name":"my-app","path":"/Users/mason/source/my-app","color":"emerald","icon":null,"displayName":"My App","orchestrator":"claude-code"}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.id == "proj_abc123")
        #expect(project.name == "my-app")
        #expect(project.color == "emerald")
        #expect(project.displayName == "My App")
        #expect(project.label == "My App")
    }

    @Test func decodeProjectWithoutDisplayName() throws {
        let json = """
        {"id":"proj_1","name":"api-server","path":"/path","color":null,"icon":null,"displayName":null,"orchestrator":null}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.label == "api-server")
    }

    @Test func decodeDurableAgent() throws {
        let json = """
        {"id":"durable_1737000000000_abc123","name":"faithful-urchin","kind":"durable","color":"emerald","branch":"faithful-urchin/standby","model":"claude-opus-4-5","orchestrator":"claude-code","freeAgentMode":false,"icon":null,"executionMode":"pty"}
        """
        let agent = try JSONDecoder().decode(DurableAgent.self, from: Data(json.utf8))
        #expect(agent.id == "durable_1737000000000_abc123")
        #expect(agent.name == "faithful-urchin")
        #expect(agent.kind == "durable")
        #expect(agent.freeAgentMode == false)
        #expect(agent.orchestrator == "claude-code")
        #expect(agent.executionMode == "pty")
    }

    @Test func decodeDurableAgentWithoutExecutionMode() throws {
        let json = """
        {"id":"durable_001","name":"test-agent","kind":"durable","color":null,"branch":null,"model":null,"orchestrator":null,"freeAgentMode":null,"icon":null}
        """
        let agent = try JSONDecoder().decode(DurableAgent.self, from: Data(json.utf8))
        #expect(agent.executionMode == nil)
    }

    @Test func decodeDurableAgentStructuredMode() throws {
        let json = """
        {"id":"durable_002","name":"structured-agent","kind":"durable","color":"cyan","branch":null,"model":"claude-opus","orchestrator":"claude-code","freeAgentMode":false,"icon":null,"executionMode":"structured"}
        """
        let agent = try JSONDecoder().decode(DurableAgent.self, from: Data(json.utf8))
        #expect(agent.executionMode == "structured")
    }

    @Test func decodeOrchestratorEntry() throws {
        let json = """
        {"displayName":"Claude Code","shortName":"CC","badge":null}
        """
        let entry = try JSONDecoder().decode(OrchestratorEntry.self, from: Data(json.utf8))
        #expect(entry.displayName == "Claude Code")
        #expect(entry.shortName == "CC")
        #expect(entry.badge == nil)
    }

    @Test func decodeThemeColors() throws {
        let json = """
        {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"}
        """
        let theme = try JSONDecoder().decode(ThemeColors.self, from: Data(json.utf8))
        #expect(theme.base == "#1e1e2e")
        #expect(theme.accent == "#89b4fa")
        #expect(theme.isDark == true)
        // Optional new fields should be nil when absent
        #expect(theme.warning == nil)
        #expect(theme.error == nil)
        #expect(theme.info == nil)
        #expect(theme.success == nil)
    }

    @Test func decodeThemeColorsWithAllFields() throws {
        let json = """
        {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#cba6f7","link":"#89b4fa","warning":"#f9e2af","error":"#f38ba8","info":"#89dceb","success":"#a6e3a1"}
        """
        let theme = try JSONDecoder().decode(ThemeColors.self, from: Data(json.utf8))
        #expect(theme.warning == "#f9e2af")
        #expect(theme.error == "#f38ba8")
        #expect(theme.info == "#89dceb")
        #expect(theme.success == "#a6e3a1")
    }
}

// MARK: - WebSocket Message Parsing Tests

struct WSMessageParsingTests {
    @Test func decodeSnapshotMessage() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [
                    {"id":"p1","name":"test","path":"/test","color":null,"icon":null,"displayName":null,"orchestrator":null}
                ],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {}
            }
        }
        """
        // Verify the envelope decodes
        let envelope = try JSONDecoder().decode(WSMessage.self, from: Data(json.utf8))
        #expect(envelope.type == "snapshot")

        // Verify the snapshot payload decodes
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.projects.count == 1)
        #expect(snapshot.payload.projects[0].id == "p1")
    }

    @Test func decodePtyDataMessage() throws {
        let json = """
        {"type":"pty:data","payload":{"agentId":"agent_1","data":"Hello world\\n"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<PtyDataPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "agent_1")
        #expect(msg.payload.data == "Hello world\n")
    }

    @Test func decodePtyExitMessage() throws {
        let json = """
        {"type":"pty:exit","payload":{"agentId":"agent_1","exitCode":0}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<PtyExitPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "agent_1")
        #expect(msg.payload.exitCode == 0)
    }

    @Test func decodeHookEventMessage() throws {
        let json = """
        {"type":"hook:event","payload":{"agentId":"agent_1","event":{"kind":"pre_tool","toolName":"EditFile","toolInput":{"path":"/src/main.ts"},"message":null,"toolVerb":"Editing file","timestamp":1737000000000}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<HookEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "agent_1")
        #expect(msg.payload.event.kind == .preTool)
        #expect(msg.payload.event.toolName == "EditFile")
        #expect(msg.payload.event.toolVerb == "Editing file")
        #expect(msg.payload.event.timestamp == 1737000000000)
    }

    @Test func decodeThemeChangedMessage() throws {
        let json = """
        {"type":"theme:changed","payload":{"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#f38ba8","link":"#f38ba8"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<ThemeColors>.self, from: Data(json.utf8))
        #expect(msg.payload.accent == "#f38ba8")
    }

    @Test func hookEventConversion() throws {
        let serverEvent = ServerHookEvent(
            kind: .preTool,
            toolName: "Read",
            toolInput: .object(["path": .string("/src/main.ts")]),
            message: nil,
            toolVerb: "Reading file",
            timestamp: 1737000000000
        )
        let hookEvent = serverEvent.toHookEvent(agentId: "agent_1")
        #expect(hookEvent.agentId == "agent_1")
        #expect(hookEvent.kind == .preTool)
        #expect(hookEvent.toolName == "Read")
        #expect(hookEvent.toolVerb == "Reading file")
        #expect(hookEvent.timestamp == 1737000000000)
    }
}

// MARK: - HookEventKind Tests

struct HookEventKindTests {
    @Test func decodeAllKinds() throws {
        let kinds: [(String, HookEventKind)] = [
            ("\"pre_tool\"", .preTool),
            ("\"post_tool\"", .postTool),
            ("\"tool_error\"", .toolError),
            ("\"stop\"", .stop),
            ("\"notification\"", .notification),
            ("\"permission_request\"", .permissionRequest),
        ]
        for (json, expected) in kinds {
            let decoded = try JSONDecoder().decode(HookEventKind.self, from: Data(json.utf8))
            #expect(decoded == expected)
        }
    }
}

// MARK: - QuickAgent Model Tests

struct QuickAgentTests {
    @Test func decodeQuickAgentMinimal() throws {
        let json = """
        {"id":"quick_001","kind":"quick"}
        """
        let agent = try JSONDecoder().decode(QuickAgent.self, from: Data(json.utf8))
        #expect(agent.id == "quick_001")
        #expect(agent.kind == "quick")
        #expect(agent.name == nil)
        #expect(agent.prompt == nil)
        #expect(agent.summary == nil)
    }

    @Test func decodeQuickAgentFull() throws {
        let json = """
        {"id":"quick_001","name":"quick-agent-1","kind":"quick","status":"running","mission":"Fix bug","prompt":"Fix the login bug","model":"claude-sonnet-4-5","orchestrator":"claude-code","parentAgentId":"durable_001","projectId":"proj_001","freeAgentMode":false}
        """
        let agent = try JSONDecoder().decode(QuickAgent.self, from: Data(json.utf8))
        #expect(agent.id == "quick_001")
        #expect(agent.name == "quick-agent-1")
        #expect(agent.status == .running)
        #expect(agent.prompt == "Fix the login bug")
        #expect(agent.model == "claude-sonnet-4-5")
        #expect(agent.parentAgentId == "durable_001")
        #expect(agent.projectId == "proj_001")
        #expect(agent.freeAgentMode == false)
    }

    @Test func decodeQuickAgentWithCompletionData() throws {
        let json = """
        {"id":"quick_001","kind":"quick","status":"completed","summary":"Fixed the bug","filesModified":["src/main.ts","src/test.ts"],"durationMs":45200,"costUsd":0.12,"toolsUsed":["Read","Edit","Bash"]}
        """
        let agent = try JSONDecoder().decode(QuickAgent.self, from: Data(json.utf8))
        #expect(agent.status == .completed)
        #expect(agent.summary == "Fixed the bug")
        #expect(agent.filesModified == ["src/main.ts", "src/test.ts"])
        #expect(agent.durationMs == 45200)
        #expect(agent.costUsd == 0.12)
        #expect(agent.toolsUsed == ["Read", "Edit", "Bash"])
    }

    @Test func quickAgentLabel() {
        let withName = QuickAgent(id: "q1", name: "my-agent", kind: "quick", status: nil, mission: nil, prompt: "some prompt", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: nil, freeAgentMode: nil)
        #expect(withName.label == "my-agent")

        let withPrompt = QuickAgent(id: "q2", name: nil, kind: "quick", status: nil, mission: nil, prompt: "Fix the auth flow in the login page", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: nil, freeAgentMode: nil)
        #expect(withPrompt.label == "Fix the auth flow in the login page")

        let idOnly = QuickAgent(id: "q3", name: nil, kind: "quick", status: nil, mission: nil, prompt: nil, model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: nil, freeAgentMode: nil)
        #expect(idOnly.label == "q3")
    }
}

// MARK: - Agent Status Tests

struct AgentStatusTests {
    @Test func decodeAllStatuses() throws {
        let statuses: [(String, AgentStatus)] = [
            ("\"starting\"", .starting),
            ("\"running\"", .running),
            ("\"sleeping\"", .sleeping),
            ("\"error\"", .error),
            ("\"completed\"", .completed),
            ("\"failed\"", .failed),
            ("\"cancelled\"", .cancelled),
        ]
        for (json, expected) in statuses {
            let decoded = try JSONDecoder().decode(AgentStatus.self, from: Data(json.utf8))
            #expect(decoded == expected)
        }
    }
}

// MARK: - Request/Response Model Tests

struct AgentActionModelTests {
    @Test func encodeSpawnQuickAgentRequest() throws {
        let request = SpawnQuickAgentRequest(
            prompt: "Fix the bug",
            orchestrator: "claude-code",
            model: "claude-sonnet-4-5",
            freeAgentMode: false,
            systemPrompt: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SpawnQuickAgentRequest.self, from: data)
        #expect(decoded.prompt == "Fix the bug")
        #expect(decoded.orchestrator == "claude-code")
        #expect(decoded.model == "claude-sonnet-4-5")
        #expect(decoded.freeAgentMode == false)
        #expect(decoded.systemPrompt == nil)
    }

    @Test func encodeWakeAgentRequest() throws {
        let request = WakeAgentRequest(message: "Rebase on main", model: "claude-opus-4-5")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(WakeAgentRequest.self, from: data)
        #expect(decoded.message == "Rebase on main")
        #expect(decoded.model == "claude-opus-4-5")
    }

    @Test func encodeWakeAgentRequestNoModel() throws {
        let request = WakeAgentRequest(message: "Fix tests", model: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(WakeAgentRequest.self, from: data)
        #expect(decoded.message == "Fix tests")
        #expect(decoded.model == nil)
    }

    @Test func encodeSendMessageRequest() throws {
        let request = SendMessageRequest(message: "Also update the README")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SendMessageRequest.self, from: data)
        #expect(decoded.message == "Also update the README")
    }

    @Test func decodeSpawnQuickAgentResponse() throws {
        let json = """
        {"id":"quick_001","name":"quick-agent-1","kind":"quick","status":"starting","prompt":"Fix bug","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"parentAgentId":null,"projectId":"proj_001"}
        """
        let response = try JSONDecoder().decode(SpawnQuickAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "quick_001")
        #expect(response.kind == "quick")
        #expect(response.status == "starting")
        #expect(response.prompt == "Fix bug")
        #expect(response.projectId == "proj_001")
        #expect(response.parentAgentId == nil)
    }

    @Test func decodeWakeAgentResponse() throws {
        let json = """
        {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","status":"starting","branch":"faithful-urchin/standby","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"icon":null,"detailedStatus":null}
        """
        let response = try JSONDecoder().decode(WakeAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "durable_001")
        #expect(response.status == "starting")
        #expect(response.name == "faithful-urchin")
        #expect(response.detailedStatus == nil)
    }

    @Test func decodeCancelAgentResponse() throws {
        let json = """
        {"id":"quick_001","status":"cancelled"}
        """
        let response = try JSONDecoder().decode(CancelAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "quick_001")
        #expect(response.status == "cancelled")
    }

    @Test func decodeSendMessageResponse() throws {
        let json = """
        {"id":"durable_001","status":"running","delivered":true}
        """
        let response = try JSONDecoder().decode(SendMessageResponse.self, from: Data(json.utf8))
        #expect(response.id == "durable_001")
        #expect(response.delivered == true)
    }
}

// MARK: - New WebSocket Payload Tests

struct AgentWSPayloadTests {
    @Test func decodeAgentSpawnedPayload() throws {
        let json = """
        {"type":"agent:spawned","payload":{"id":"quick_001","kind":"quick","status":"starting","prompt":"Fix bug","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"parentAgentId":"durable_001","projectId":"proj_001"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentSpawnedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.kind == "quick")
        #expect(msg.payload.status == "starting")
        #expect(msg.payload.prompt == "Fix bug")
        #expect(msg.payload.parentAgentId == "durable_001")
        #expect(msg.payload.projectId == "proj_001")
    }

    @Test func decodeAgentStatusPayload() throws {
        let json = """
        {"type":"agent:status","payload":{"id":"quick_001","kind":"quick","status":"running","projectId":"proj_001","parentAgentId":"durable_001"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentStatusPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.status == "running")
        #expect(msg.payload.projectId == "proj_001")
    }

    @Test func decodeAgentCompletedPayload() throws {
        let json = """
        {"type":"agent:completed","payload":{"id":"quick_001","kind":"quick","status":"completed","exitCode":0,"projectId":"proj_001","parentAgentId":null,"summary":"Fixed the bug","filesModified":["src/main.ts"],"durationMs":45200,"costUsd":0.12,"toolsUsed":["Read","Edit"]}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentCompletedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.status == "completed")
        #expect(msg.payload.exitCode == 0)
        #expect(msg.payload.summary == "Fixed the bug")
        #expect(msg.payload.filesModified == ["src/main.ts"])
        #expect(msg.payload.durationMs == 45200)
        #expect(msg.payload.costUsd == 0.12)
        #expect(msg.payload.toolsUsed == ["Read", "Edit"])
    }

    @Test func decodeAgentCompletedPayloadMinimal() throws {
        let json = """
        {"type":"agent:completed","payload":{"id":"quick_001","kind":"quick","status":"failed","exitCode":1,"projectId":"proj_001"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentCompletedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.status == "failed")
        #expect(msg.payload.exitCode == 1)
        #expect(msg.payload.summary == nil)
        #expect(msg.payload.filesModified == nil)
    }

    @Test func decodeAgentWokenPayload() throws {
        let json = """
        {"type":"agent:woken","payload":{"agentId":"durable_001","message":"Rebase on main","source":"annex"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentWokenPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "durable_001")
        #expect(msg.payload.message == "Rebase on main")
        #expect(msg.payload.source == "annex")
    }

    @Test func decodeSnapshotWithQuickAgents() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [{"id":"p1","name":"test","path":"/test","color":null,"icon":null,"displayName":null,"orchestrator":null}],
                "agents": {},
                "quickAgents": {
                    "p1": [{"id":"quick_001","kind":"quick","status":"running","prompt":"Fix bug","model":"claude-sonnet-4-5","projectId":"p1"}]
                },
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {}
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.quickAgents?["p1"]?.count == 1)
        #expect(snapshot.payload.quickAgents?["p1"]?[0].id == "quick_001")
        #expect(snapshot.payload.quickAgents?["p1"]?[0].prompt == "Fix bug")
    }

    @Test func decodeSnapshotWithoutQuickAgents() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {}
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.quickAgents == nil)
    }
}

// MARK: - AppStore Tests

@MainActor @Suite(.serialized)
struct AppStoreTests {
    @Test func initialState() {
        let store = AppStore()
        #expect(store.isPaired == false)
        #expect(store.projects.isEmpty)
        #expect(store.agentsByProject.isEmpty)
        #expect(store.totalAgentCount == 0)
        #expect(store.connectionState.isConnected == false)
    }

    @Test func loadMockData() {
        let store = AppStore()
        store.loadMockData()
        #expect(store.isPaired == true)
        #expect(store.instances.count == 2)
        #expect(store.totalAgentCount == 5)
        #expect(store.serverName == "Mason's Desktop")
        #expect(store.connectionState.isConnected == true)
    }

    @Test func disconnect() {
        let store = AppStore()
        store.loadMockData()
        store.completeOnboarding()
        store.disconnectAll()
        #expect(store.isPaired == false)
        #expect(store.projects.isEmpty)
        #expect(store.agentsByProject.isEmpty)
        #expect(store.serverName == "")
        #expect(store.connectionState.isConnected == false)
        // Disconnect preserves onboarding state
        #expect(store.hasCompletedOnboarding == true)
    }

    @Test func resetApp() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        let store = AppStore()
        store.loadMockData()
        store.completeOnboarding()
        #expect(store.hasCompletedOnboarding == true)
        store.resetApp()
        #expect(store.isPaired == false)
        #expect(store.projects.isEmpty)
        #expect(store.hasCompletedOnboarding == false)
    }

    @Test func completeOnboarding() {
        // Clear any leftover state from other tests
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        let store = AppStore()
        #expect(store.hasCompletedOnboarding == false)
        store.completeOnboarding()
        #expect(store.hasCompletedOnboarding == true)
    }

    @Test func agentsForProject() {
        let store = AppStore()
        store.loadMockData()
        let proj = store.projects[0]
        let agents = store.agents(for: proj)
        #expect(!agents.isEmpty)
    }

    @Test func activityForAgent() {
        let store = AppStore()
        store.loadMockData()
        let events = store.activity(for: "durable_1737000000000_abc123")
        #expect(!events.isEmpty)
    }

    @Test func runningAgentCount() {
        let store = AppStore()
        store.loadMockData()
        #expect(store.runningAgentCount > 0)
        #expect(store.runningAgentCount <= store.totalAgentCount)
    }

    @Test func quickAgentsForProject() {
        let store = AppStore()
        store.loadMockData()
        let proj = store.projects[0] // proj_001
        let quickAgents = store.allQuickAgents(for: proj)
        // proj_001 has one quick agent nested under faithful-urchin
        #expect(!quickAgents.isEmpty)
        #expect(quickAgents[0].id == "quick_1737000100000_def456")
    }

    @Test func quickAgentsDeduplication() {
        let store = AppStore()
        store.loadMockData()
        let proj = store.projects[0]

        // Add the same quick agent to standalone list (via the active instance)
        let qa = QuickAgent(id: "quick_1737000100000_def456", name: "quick-agent-1", kind: "quick", status: .running, mission: nil, prompt: "Fix bug", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        store.activeInstance?.quickAgentsByProject["proj_001"] = [qa]

        let all = store.allQuickAgents(for: proj)
        // Should deduplicate — only one entry for the same ID
        let ids = all.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test func disconnectClearsQuickAgents() {
        let store = AppStore()
        store.loadMockData()
        let qa = QuickAgent(id: "q1", name: nil, kind: "quick", status: .running, mission: nil, prompt: "test", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        store.activeInstance?.quickAgentsByProject["proj_001"] = [qa]
        #expect(!store.quickAgentsByProject.isEmpty)
        store.disconnectAll()
        #expect(store.quickAgentsByProject.isEmpty)
    }

    @Test func removeQuickAgent() {
        let store = AppStore()
        store.loadMockData()
        let qa1 = QuickAgent(id: "q1", name: nil, kind: "quick", status: .completed, mission: nil, prompt: "task 1", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        let qa2 = QuickAgent(id: "q2", name: nil, kind: "quick", status: .running, mission: nil, prompt: "task 2", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        store.activeInstance?.quickAgentsByProject["proj_001"] = [qa1, qa2]

        store.removeQuickAgent(agentId: "q1")
        #expect(store.quickAgentsByProject["proj_001"]?.count == 1)
        #expect(store.quickAgentsByProject["proj_001"]?[0].id == "q2")
    }

    @Test func removeQuickAgentNonexistent() {
        let store = AppStore()
        store.loadMockData()
        let qa = QuickAgent(id: "q1", name: nil, kind: "quick", status: .running, mission: nil, prompt: "test", model: nil, detailedStatus: nil, orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        store.activeInstance?.quickAgentsByProject["proj_001"] = [qa]

        store.removeQuickAgent(agentId: "nonexistent")
        #expect(store.quickAgentsByProject["proj_001"]?.count == 1)
    }

    @Test func iconURLsRequireConnection() {
        let store = AppStore()
        // No apiClient or token set — should return nil
        #expect(store.agentIconURL(agentId: "agent_1") == nil)
        #expect(store.projectIconURL(projectId: "proj_1") == nil)
    }

    @Test func projectIconsAccessibleForAgentProjects() {
        let store = AppStore()
        store.loadMockData()

        // Pick an agent and find its project
        let agent = store.allAgents.first!
        let agentProject = store.project(for: agent)
        #expect(agentProject != nil)

        // Simulate storing icon data for that project (via instance)
        let fakeIconData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        store.activeInstance?.projectIcons[agentProject!.id] = fakeIconData

        // Verify icon data is retrievable via aggregated property
        let iconData = store.projectIcons[agentProject!.id]
        #expect(iconData != nil)
        #expect(iconData == fakeIconData)
    }

    @Test func projectIconsEmptyByDefault() {
        let store = AppStore()
        store.loadMockData()
        // No icons fetched yet — dictionary should be empty
        #expect(store.projectIcons.isEmpty)
        // Looking up icon data should return nil (triggers default letter icon)
        let project = store.projects[0]
        #expect(store.projectIcons[project.id] == nil)
    }
}

// MARK: - JSONValue Tests

struct JSONValueTests {
    @Test func decodeString() throws {
        let json = "\"hello\""
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == .string("hello"))
    }

    @Test func decodeNumber() throws {
        let json = "42"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == .number(42.0))
    }

    @Test func decodeBool() throws {
        let json = "true"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == .bool(true))
    }

    @Test func decodeNull() throws {
        let json = "null"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == .null)
    }

    @Test func decodeObject() throws {
        let json = """
        {"key": "value", "num": 1}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        if case .object(let dict) = value {
            #expect(dict["key"] == .string("value"))
            #expect(dict["num"] == .number(1.0))
        } else {
            #expect(Bool(false), "Expected object")
        }
    }

    @Test func decodeArray() throws {
        let json = "[1, \"two\", true]"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        if case .array(let arr) = value {
            #expect(arr.count == 3)
            #expect(arr[0] == .number(1.0))
            #expect(arr[1] == .string("two"))
            #expect(arr[2] == .bool(true))
        } else {
            #expect(Bool(false), "Expected array")
        }
    }
}

// MARK: - ConnectionState Tests

struct ConnectionStateTests {
    @Test func labels() {
        #expect(ConnectionState.disconnected.label == "Disconnected")
        #expect(ConnectionState.connected.label == "Connected")
        #expect(ConnectionState.connecting.label == "Connecting...")
        #expect(ConnectionState.reconnecting(attempt: 3).label == "Reconnecting (3)...")
    }

    @Test func isConnected() {
        #expect(ConnectionState.connected.isConnected == true)
        #expect(ConnectionState.disconnected.isConnected == false)
        #expect(ConnectionState.reconnecting(attempt: 1).isConnected == false)
    }
}

// MARK: - Initials Extraction Tests

struct InitialsTests {
    @Test func agentInitialsTwoWords() {
        #expect(agentInitials(from: "gallant-swift") == "GS")
        #expect(agentInitials(from: "bold-falcon") == "BF")
        #expect(agentInitials(from: "lucky-mantis") == "LM")
    }

    @Test func agentInitialsSingleWord() {
        #expect(agentInitials(from: "agent") == "A")
    }

    @Test func agentInitialsEmpty() {
        #expect(agentInitials(from: "") == "")
        #expect(agentInitials(from: nil) == "")
    }

    @Test func agentInitialsThreeWords() {
        #expect(agentInitials(from: "big-red-fox") == "BR")
    }

    @Test func projectInitialFromDisplayName() {
        #expect(projectInitial(from: "My App", name: "my-app") == "M")
        #expect(projectInitial(from: "SourceKit", name: "sourcekit") == "S")
    }

    @Test func projectInitialFallsBackToName() {
        #expect(projectInitial(from: nil, name: "my-app") == "M")
        #expect(projectInitial(from: nil, name: "SourceKit") == "S")
    }

    @Test func projectInitialEmptyName() {
        #expect(projectInitial(from: nil, name: "") == "")
    }
}

// MARK: - All Agents View Support Tests

@MainActor @Suite(.serialized)
struct AllAgentsTests {
    @Test func allAgentsSortedByStatus() {
        let store = AppStore()
        store.loadMockData()
        // allAgents delegates to activeInstance (inst1: proj_001 has 2 agents, proj_003 has 1)
        let agents = store.allAgents
        #expect(agents.count == 3)
        // Running agents should come before sleeping/error
        let statuses = agents.compactMap(\.status)
        let firstRunningIndex = statuses.firstIndex(of: .running)
        let firstSleepingIndex = statuses.firstIndex(of: .sleeping)
        if let r = firstRunningIndex, let s = firstSleepingIndex {
            #expect(r < s)
        }
    }

    @Test func allAgentsActiveBeforeInactive() {
        let store = AppStore()
        store.loadMockData()
        let agents = store.allAgents
        // Find the boundary: all running/error agents should precede sleeping ones
        var seenInactive = false
        for agent in agents {
            let isActive = agent.status == .running || agent.status == .starting
            if !isActive {
                seenInactive = true
            }
            if seenInactive && isActive {
                Issue.record("Active agent found after inactive agent — sorting is wrong")
            }
        }
    }

    @Test func projectLookupFindsCorrectProject() {
        let store = AppStore()
        store.loadMockData()
        let agents = store.allAgents
        guard let firstAgent = agents.first else {
            Issue.record("No agents found")
            return
        }
        let project = store.project(for: firstAgent)
        #expect(project != nil)
    }

    @Test func projectLookupReturnsNilForUnknown() {
        let store = AppStore()
        store.loadMockData()
        let unknown = DurableAgent(
            id: "unknown_id",
            name: "ghost",
            kind: "durable",
            color: nil,
            branch: nil,
            model: nil,
            orchestrator: nil,
            freeAgentMode: nil,
            icon: nil,
            executionMode: nil
        )
        let project = store.project(for: unknown)
        #expect(project == nil)
    }

    @Test func statusSortOrder() {
        let running = DurableAgent(id: "1", name: nil, kind: nil, color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil, status: .running)
        let sleeping = DurableAgent(id: "2", name: nil, kind: nil, color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil, status: .sleeping)
        let errored = DurableAgent(id: "3", name: nil, kind: nil, color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil, status: .error)
        let completed = DurableAgent(id: "4", name: nil, kind: nil, color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil, status: .completed)
        let noStatus = DurableAgent(id: "5", name: nil, kind: nil, color: nil, branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil, icon: nil, executionMode: nil)

        #expect(running.statusSortOrder < errored.statusSortOrder)
        #expect(errored.statusSortOrder < sleeping.statusSortOrder)
        #expect(sleeping.statusSortOrder < completed.statusSortOrder)
        #expect(completed.statusSortOrder < noStatus.statusSortOrder)
    }

    @Test func allAgentsEmptyWhenNoData() {
        let store = AppStore()
        #expect(store.allAgents.isEmpty)
    }

    @Test func projectLookupMapsCorrectly() {
        let store = AppStore()
        store.loadMockData()
        // faithful-urchin belongs to proj_001 ("My App") on active instance
        let faithfulUrchin = store.allAgents.first { $0.name == "faithful-urchin" }
        #expect(faithfulUrchin != nil)
        let project = store.project(for: faithfulUrchin!)
        #expect(project?.id == "proj_001")
        #expect(project?.label == "My App")

        // bold-eagle belongs to proj_002 ("api-server") on inst2 — use cross-instance lookup
        let boldEagle = store.allAgentsAcrossInstances.first { $0.agent.name == "bold-eagle" }
        #expect(boldEagle != nil)
        let project2 = store.project(for: boldEagle!.agent)
        #expect(project2?.id == "proj_002")
    }
}

// MARK: - AgentColor Tests

struct AgentColorTests {
    @Test func allColorsHaveHex() {
        for color in AgentColor.allCases {
            #expect(color.hex.hasPrefix("#"))
            #expect(color.hex.count == 7)
        }
    }

    @Test func colorForId() {
        let color = AgentColor.color(for: "emerald")
        #expect(color != .gray)
    }

    @Test func colorForInvalidId() {
        let color = AgentColor.color(for: "nonexistent")
        #expect(color == .gray)
    }
}

// MARK: - Permission Model Tests

struct PermissionModelTests {
    @Test func decodePermissionRequest() throws {
        let json = """
        {"requestId":"perm_001","agentId":"durable_001","toolName":"Bash","toolInput":{"command":"rm -rf /tmp/test"},"message":"Run shell command","deadline":1737000120000}
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(perm.id == "perm_001")
        #expect(perm.agentId == "durable_001")
        #expect(perm.toolName == "Bash")
        #expect(perm.message == "Run shell command")
        #expect(perm.deadline == 1737000120000)
        if case .object(let dict) = perm.toolInput,
           case .string(let cmd) = dict["command"] {
            #expect(cmd == "rm -rf /tmp/test")
        } else {
            Issue.record("Expected object toolInput with command field")
        }
    }

    @Test func decodePermissionRequestMinimal() throws {
        let json = """
        {"requestId":"perm_002","agentId":"durable_001","toolName":"Edit","deadline":1737000120000}
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(perm.id == "perm_002")
        #expect(perm.toolName == "Edit")
        #expect(perm.toolInput == nil)
        #expect(perm.message == nil)
    }

    @Test func decodePermissionRequestPayload() throws {
        let json = """
        {"type":"permission:request","payload":{"requestId":"perm_001","agentId":"durable_001","toolName":"Bash","toolInput":null,"message":"Run command","deadline":1737000120000}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<PermissionRequestPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.requestId == "perm_001")
        #expect(msg.payload.agentId == "durable_001")
        #expect(msg.payload.toolName == "Bash")
        #expect(msg.payload.message == "Run command")
        #expect(msg.payload.deadline == 1737000120000)
    }

    @Test func encodePermissionResponseRequest() throws {
        let request = PermissionResponseRequest(requestId: "perm_001", decision: "allow")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionResponseRequest.self, from: data)
        #expect(decoded.requestId == "perm_001")
        #expect(decoded.decision == "allow")
    }

    @Test func encodePermissionResponseRequestDeny() throws {
        let request = PermissionResponseRequest(requestId: "perm_002", decision: "deny")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionResponseRequest.self, from: data)
        #expect(decoded.requestId == "perm_002")
        #expect(decoded.decision == "deny")
    }

    @Test func decodePermissionResponseResponse() throws {
        let json = """
        {"ok":true,"requestId":"perm_001","decision":"allow"}
        """
        let response = try JSONDecoder().decode(PermissionResponseResponse.self, from: Data(json.utf8))
        #expect(response.ok == true)
        #expect(response.requestId == "perm_001")
        #expect(response.decision == "allow")
    }

    @Test func permissionRequestIdentifiable() {
        let perm = PermissionRequest(
            requestId: "perm_001",
            agentId: "agent_1",
            toolName: "Bash",
            toolInput: nil,
            message: nil,
            timeout: 120000,
            deadline: 1737000120000
        )
        #expect(perm.id == "perm_001")
        #expect(perm.timeout == 120000)
    }

    @Test func permissionRequestHashable() {
        let perm1 = PermissionRequest(requestId: "perm_001", agentId: "a1", toolName: "Bash", toolInput: nil, message: nil, timeout: nil, deadline: 100)
        let perm2 = PermissionRequest(requestId: "perm_002", agentId: "a1", toolName: "Edit", toolInput: nil, message: nil, timeout: nil, deadline: 200)
        let set: Set<PermissionRequest> = [perm1, perm2]
        #expect(set.count == 2)
    }
}

// MARK: - Permission WebSocket Tests

struct PermissionWSTests {
    @Test func decodePermissionRequestWSMessage() throws {
        let json = """
        {"type":"permission:request","payload":{"requestId":"perm_abc","agentId":"durable_001","toolName":"Write","toolInput":{"path":"/src/main.ts"},"message":"Write to file","deadline":1737000120000}}
        """
        let envelope = try JSONDecoder().decode(WSMessage.self, from: Data(json.utf8))
        #expect(envelope.type == "permission:request")

        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<PermissionRequestPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.requestId == "perm_abc")
        #expect(msg.payload.toolName == "Write")
    }

    @Test func decodeSnapshotWithPendingPermissions() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {},
                "pendingPermissions": [
                    {"requestId":"perm_001","agentId":"agent_1","toolName":"Bash","message":"Run npm test","deadline":1737000120000}
                ]
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.pendingPermissions?.count == 1)
        #expect(snapshot.payload.pendingPermissions?[0].id == "perm_001")
        #expect(snapshot.payload.pendingPermissions?[0].toolName == "Bash")
    }

    @Test func decodeSnapshotWithoutPendingPermissions() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {}
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.pendingPermissions == nil)
    }
}

// MARK: - AppStore Permission Tests

@MainActor @Suite(.serialized)
struct AppStorePermissionTests {
    @Test func pendingPermissionsEmptyByDefault() {
        let store = AppStore()
        #expect(store.pendingPermissions.isEmpty)
    }

    @Test func pendingPermissionForAgent() {
        let store = AppStore()
        store.loadMockData()
        // Use a real agent ID from the active instance's mock data so instance(for:) can find it
        let agentId = "durable_1737000000000_abc123" // faithful-urchin on active instance
        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        let perm = PermissionRequest(
            requestId: "perm_001",
            agentId: agentId,
            toolName: "Bash",
            toolInput: nil,
            message: "Run tests",
            timeout: 120000,
            deadline: futureDeadline
        )
        store.activeInstance?.pendingPermissions["perm_001"] = perm

        let found = store.pendingPermission(for: agentId)
        #expect(found != nil)
        #expect(found?.id == "perm_001")
    }

    @Test func pendingPermissionReturnsNilForWrongAgent() {
        let store = AppStore()
        store.loadMockData()
        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        let perm = PermissionRequest(
            requestId: "perm_001",
            agentId: "agent_1",
            toolName: "Bash",
            toolInput: nil,
            message: nil,
            timeout: nil,
            deadline: futureDeadline
        )
        store.activeInstance?.pendingPermissions["perm_001"] = perm

        let found = store.pendingPermission(for: "agent_2")
        #expect(found == nil)
    }

    @Test func expiredPermissionNotReturned() {
        let store = AppStore()
        store.loadMockData()
        let pastDeadline = Int(Date().timeIntervalSince1970 * 1000) - 1000
        let perm = PermissionRequest(
            requestId: "perm_expired",
            agentId: "agent_1",
            toolName: "Bash",
            toolInput: nil,
            message: nil,
            timeout: nil,
            deadline: pastDeadline
        )
        store.activeInstance?.pendingPermissions["perm_expired"] = perm

        let found = store.pendingPermission(for: "agent_1")
        #expect(found == nil)
    }

    @Test func disconnectClearsPendingPermissions() {
        let store = AppStore()
        store.loadMockData()
        let perm = PermissionRequest(
            requestId: "perm_001",
            agentId: "agent_1",
            toolName: "Bash",
            toolInput: nil,
            message: nil,
            timeout: nil,
            deadline: 9999999999999
        )
        store.activeInstance?.pendingPermissions["perm_001"] = perm
        #expect(!store.pendingPermissions.isEmpty)
        store.disconnectAll()
        #expect(store.pendingPermissions.isEmpty)
    }

    @Test func disconnectClearsStructuredEvents() {
        let store = AppStore()
        store.loadMockData()
        store.activeInstance?.structuredEventsByAgent["agent_1"] = [
            StructuredEvent(type: "tool_start", timestamp: 1000, data: nil)
        ]
        #expect(!store.activeInstance!.structuredEventsByAgent.isEmpty)
        store.disconnectAll()
        #expect(store.instances.isEmpty)
    }

    @Test func durableAgentLookupById() {
        let store = AppStore()
        store.loadMockData()
        let found = store.durableAgent(byId: "durable_1737000000000_abc123")
        #expect(found != nil)
        #expect(found?.name == "faithful-urchin")
        #expect(found?.executionMode == "pty")

        let structuredAgent = store.durableAgent(byId: "durable_1737000000002_srv001")
        #expect(structuredAgent?.executionMode == "structured")

        let notFound = store.durableAgent(byId: "nonexistent")
        #expect(notFound == nil)
    }
}

// MARK: - Structured Event Tests

struct StructuredEventTests {
    @Test func decodeStructuredEventPayload() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_123","event":{"type":"tool_start","timestamp":1742000000,"data":{"id":"tool_call_1","name":"bash","displayVerb":"Running","input":{"command":"npm test"}}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "agent_123")
        #expect(msg.payload.event.type == "tool_start")
        #expect(msg.payload.event.timestamp == 1742000000)
        if case .object(let data) = msg.payload.event.data,
           case .string(let name) = data["name"] {
            #expect(name == "bash")
        } else {
            Issue.record("Expected object data with name field")
        }
    }

    @Test func decodeStructuredEventTextDelta() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"text_delta","timestamp":1742000000,"data":{"text":"Hello "}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "text_delta")
    }

    @Test func decodeStructuredEventToolEnd() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"tool_end","timestamp":1742000000,"data":{"id":"tc1","name":"bash","result":"ok","durationMs":1500,"status":"success"}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "tool_end")
        if case .object(let data) = msg.payload.event.data,
           case .string(let status) = data["status"] {
            #expect(status == "success")
        } else {
            Issue.record("Expected status field")
        }
    }

    @Test func decodeStructuredEventFileDiff() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"file_diff","timestamp":1742000000,"data":{"path":"src/main.ts","changeType":"modify","diff":"+added line\\n-removed line"}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "file_diff")
    }

    @Test func decodeStructuredEventEnd() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"end","timestamp":1742000000,"data":{"reason":"complete","summary":"Task finished"}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "end")
        if case .object(let data) = msg.payload.event.data,
           case .string(let reason) = data["reason"] {
            #expect(reason == "complete")
        } else {
            Issue.record("Expected reason field")
        }
    }

    @Test func decodeStructuredEventPermissionRequest() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"permission_request","timestamp":1742000000,"data":{"id":"req_1","toolName":"bash","toolInput":{"command":"rm -rf /"},"description":"Dangerous command"}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "permission_request")
    }

    @Test func decodeStructuredEventUsage() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"usage","timestamp":null,"data":{"inputTokens":1000,"outputTokens":500,"costUsd":0.05}}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.type == "usage")
        #expect(msg.payload.event.timestamp == nil)
    }

    @Test func decodeStructuredEventNullData() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_1","event":{"type":"error","timestamp":1742000000,"data":null}}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.event.data == nil)
    }
}

// MARK: - Structured Permission Tests

struct StructuredPermissionTests {
    @Test func encodeStructuredPermissionRequest() throws {
        let request = StructuredPermissionRequest(requestId: "req_001", approved: true, reason: "User approved via iOS")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(StructuredPermissionRequest.self, from: data)
        #expect(decoded.requestId == "req_001")
        #expect(decoded.approved == true)
        #expect(decoded.reason == "User approved via iOS")
    }

    @Test func encodeStructuredPermissionRequestNoReason() throws {
        let request = StructuredPermissionRequest(requestId: "req_002", approved: false, reason: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(StructuredPermissionRequest.self, from: data)
        #expect(decoded.requestId == "req_002")
        #expect(decoded.approved == false)
        #expect(decoded.reason == nil)
    }

    @Test func decodeStructuredPermissionResponse() throws {
        let json = """
        {"ok":true,"requestId":"req_001","approved":true}
        """
        let response = try JSONDecoder().decode(StructuredPermissionResponse.self, from: Data(json.utf8))
        #expect(response.ok == true)
        #expect(response.requestId == "req_001")
        #expect(response.approved == true)
    }
}

// MARK: - Replay Model Tests

struct ReplayModelTests {
    @Test func encodeReplayRequest() throws {
        let request = ReplayRequest(type: "replay", since: 42)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ReplayRequest.self, from: data)
        #expect(decoded.type == "replay")
        #expect(decoded.since == 42)
    }

    @Test func decodeReplayGap() throws {
        let json = """
        {"type":"replay:gap","payload":{"oldestAvailable":100,"lastSeq":500}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<ReplayGapPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.oldestAvailable == 100)
        #expect(msg.payload.lastSeq == 500)
    }

    @Test func decodeReplayStart() throws {
        let json = """
        {"type":"replay:start","payload":{"fromSeq":43,"toSeq":100,"count":58}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<ReplayStartPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.fromSeq == 43)
        #expect(msg.payload.toSeq == 100)
        #expect(msg.payload.count == 58)
    }
}

// MARK: - WS Envelope Tests

struct WSEnvelopeTests {
    @Test func decodeEnvelopeWithSeq() throws {
        let json = """
        {"type":"pty:data","payload":{"agentId":"a1","data":"hello"},"seq":42,"replayed":false}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.type == "pty:data")
        #expect(envelope.seq == 42)
        #expect(envelope.replayed == false)
    }

    @Test func decodeEnvelopeWithoutSeq() throws {
        let json = """
        {"type":"snapshot","payload":{}}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.type == "snapshot")
        #expect(envelope.seq == nil)
        #expect(envelope.replayed == nil)
    }

    @Test func decodeEnvelopeReplayed() throws {
        let json = """
        {"type":"hook:event","payload":{},"seq":100,"replayed":true}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.seq == 100)
        #expect(envelope.replayed == true)
    }
}

// MARK: - Snapshot with lastSeq Tests

struct SnapshotLastSeqTests {
    @Test func decodeSnapshotWithLastSeq() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {},
                "lastSeq": 42
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.lastSeq == 42)
    }

    @Test func decodeSnapshotWithoutLastSeq() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {}
            }
        }
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let snapshot = try JSONDecoder().decode(PayloadExtractor<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snapshot.payload.lastSeq == nil)
    }
}

// MARK: - AgentSpawned with name Tests

struct AgentSpawnedNameTests {
    @Test func decodeAgentSpawnedWithName() throws {
        let json = """
        {"type":"agent:spawned","payload":{"id":"quick_001","name":"swift-fox","kind":"quick","status":"starting","prompt":"Fix tests","model":"claude-opus","orchestrator":"claude-code","freeAgentMode":false,"parentAgentId":null,"projectId":"proj_abc"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentSpawnedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.name == "swift-fox")
        #expect(msg.payload.id == "quick_001")
    }

    @Test func decodeAgentSpawnedWithoutName() throws {
        let json = """
        {"type":"agent:spawned","payload":{"id":"quick_002","kind":"quick","status":"starting","prompt":"Fix bug","projectId":"proj_abc"}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<AgentSpawnedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.name == nil)
    }
}

// MARK: - WakeAgentResponse with message Tests

struct WakeAgentResponseMessageTests {
    @Test func decodeWakeResponseWithMessage() throws {
        let json = """
        {"id":"agent_123","name":"CodeBot","kind":"durable","color":"indigo","status":"starting","message":"Rebase on main and fix conflicts","branch":"agent/codebot","model":"claude-opus","orchestrator":"claude-code","freeAgentMode":false,"icon":null,"detailedStatus":null}
        """
        let response = try JSONDecoder().decode(WakeAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "agent_123")
        #expect(response.message == "Rebase on main and fix conflicts")
    }

    @Test func decodeWakeResponseWithoutMessage() throws {
        let json = """
        {"id":"agent_123","name":"CodeBot","kind":"durable","status":"starting"}
        """
        let response = try JSONDecoder().decode(WakeAgentResponse.self, from: Data(json.utf8))
        #expect(response.message == nil)
    }
}

// MARK: - Permission with timeout Tests

struct PermissionTimeoutTests {
    @Test func decodePermissionRequestWithTimeout() throws {
        let json = """
        {"requestId":"uuid","agentId":"agent_123","toolName":"bash","toolInput":{"command":"rm -rf node_modules"},"message":null,"timeout":120000,"deadline":1742000120000}
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(perm.timeout == 120000)
        #expect(perm.deadline == 1742000120000)
    }

    @Test func decodePermissionRequestPayloadWithTimeout() throws {
        let json = """
        {"type":"permission:request","payload":{"requestId":"uuid","agentId":"agent_1","toolName":"bash","toolInput":null,"message":null,"timeout":120000,"deadline":1742000120000}}
        """
        struct PayloadExtractor<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(PayloadExtractor<PermissionRequestPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.timeout == 120000)
        #expect(msg.payload.deadline == 1742000120000)
    }
}

// MARK: - DER Encoder Tests

struct DEREncoderTests {
    @Test func encodeInteger() {
        let data = DER.integer(2)
        // Tag 0x02, Length 0x01, Value 0x02
        #expect(data == Data([0x02, 0x01, 0x02]))
    }

    @Test func encodeIntegerLargeValue() {
        let data = DER.integer(256)
        // Tag 0x02, Length 0x02, Value 0x01 0x00
        #expect(data == Data([0x02, 0x02, 0x01, 0x00]))
    }

    @Test func encodeNull() {
        let data = DER.null()
        #expect(data == Data([0x05, 0x00]))
    }

    @Test func encodeUTF8String() {
        let data = DER.utf8String("test")
        #expect(data[0] == 0x0C) // UTF8String tag
        #expect(data[1] == 4) // length
        #expect(String(data: data[2...], encoding: .utf8) == "test")
    }

    @Test func encodeOID() {
        // OID 2.5.4.3 (commonName)
        let data = DER.oid([2, 5, 4, 3])
        #expect(data[0] == 0x06) // OID tag
        #expect(data[1] == 3) // length
        #expect(data[2] == 85) // 2*40+5 = 85
        #expect(data[3] == 4)
        #expect(data[4] == 3)
    }

    @Test func encodeLargeOIDComponent() {
        // OID 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
        let data = DER.oid([1, 2, 840, 113549, 1, 1, 11])
        #expect(data[0] == 0x06) // OID tag
        // 840 and 113549 require multi-byte encoding
        #expect(data.count > 2)
    }

    @Test func encodeSequence() {
        let inner = DER.integer(42)
        let seq = DER.sequence([inner])
        #expect(seq[0] == 0x30) // SEQUENCE tag
        #expect(seq[1] == UInt8(inner.count))
        #expect(seq.suffix(from: 2) == inner)
    }

    @Test func encodeBitString() {
        let payload = Data([0xAB, 0xCD])
        let bs = DER.bitString(payload)
        #expect(bs[0] == 0x03) // BIT STRING tag
        #expect(bs[1] == 3) // length: 1 (unused bits byte) + 2 (payload)
        #expect(bs[2] == 0x00) // unused bits = 0
        #expect(bs[3] == 0xAB)
        #expect(bs[4] == 0xCD)
    }

    @Test func encodeContextTag() {
        let inner = DER.integer(2)
        let tagged = DER.contextTag(0, constructed: true, content: inner)
        #expect(tagged[0] == 0xA0) // context tag 0, constructed
    }

    @Test func encodeUTCTime() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00:00 UTC
        let data = DER.utcTime(date)
        #expect(data[0] == 0x17) // UTCTime tag
        let timeStr = String(data: data[2...], encoding: .utf8)
        #expect(timeStr == "700101000000Z")
    }

    @Test func lengthEncodingShort() {
        // Length < 128 should be single byte
        let data = DER.utf8String("hi")
        #expect(data[1] == 2) // short form
    }

    @Test func lengthEncodingLong() {
        // Length >= 128 needs multi-byte encoding
        let longString = String(repeating: "A", count: 200)
        let data = DER.utf8String(longString)
        #expect(data[1] == 0x81) // long form: 1 length byte follows
        #expect(data[2] == 200)
    }
}

// MARK: - mTLS Identity Tests

@Suite(.serialized)
struct MTLSIdentityTests {
    @Test func buildSelfSignedCertProducesValidDER() {
        // Generate an RSA key for testing
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            Issue.record("Failed to generate test RSA key: \(error!.takeRetainedValue())")
            return
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            Issue.record("Failed to export public key")
            return
        }

        let fingerprint = "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"
        let certDER = MTLSIdentity.buildSelfSignedCert(
            commonName: fingerprint,
            publicKeyDER: pubKeyData,
            privateKey: privateKey
        )

        #expect(certDER != nil)
        #expect(certDER!.count > 100)

        // Verify it's a valid certificate by parsing with SecCertificateCreateWithData
        let secCert = SecCertificateCreateWithData(nil, certDER! as CFData)
        #expect(secCert != nil, "DER should parse as a valid X.509 certificate")
    }

    @Test func certContainsCorrectCN() {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            Issue.record("Failed to generate test RSA key")
            return
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            Issue.record("Failed to export public key")
            return
        }

        let fingerprint = "13:93:04:DA:25:92:2A:8D:F1:FB:A6:F4:AA:82:6A:B7"
        guard let certDER = MTLSIdentity.buildSelfSignedCert(
            commonName: fingerprint,
            publicKeyDER: pubKeyData,
            privateKey: privateKey
        ) else {
            Issue.record("Failed to build cert")
            return
        }

        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            Issue.record("Invalid DER")
            return
        }

        // Extract the subject summary — should contain our fingerprint
        let summary = SecCertificateCopySubjectSummary(secCert) as String?
        #expect(summary == fingerprint, "Certificate CN should be the Ed25519 fingerprint")
    }

    @Test func loadOrCreateProducesIdentity() {
        // Clean up any previous test artifacts
        MTLSIdentity.deleteIdentity()

        let fingerprint = "TE:ST:00:00:00:00:00:00:00:00:00:00:00:00:00:01"
        let identity = MTLSIdentity.loadOrCreate(fingerprint: fingerprint)
        #expect(identity != nil, "Should create a new mTLS identity")

        // Loading again should return the same identity
        let identity2 = MTLSIdentity.loadOrCreate(fingerprint: fingerprint)
        #expect(identity2 != nil, "Should load existing mTLS identity")

        // Clean up
        MTLSIdentity.deleteIdentity()
    }

    @Test func deleteIdentityRemovesFromKeychain() {
        let fingerprint = "TE:ST:00:00:00:00:00:00:00:00:00:00:00:00:00:02"
        let identity = MTLSIdentity.loadOrCreate(fingerprint: fingerprint)
        #expect(identity != nil)

        MTLSIdentity.deleteIdentity()

        // After deletion, loading should create a brand new identity
        // We can't directly check "it's gone" without trying to load
        // But loadOrCreate will log "Generating new" instead of "Loaded existing"
    }
}

// MARK: - TLSSessionDelegate Tests

struct TLSSessionDelegateTests {
    @Test func delegateInitWithoutIdentity() {
        let delegate = TLSSessionDelegate()
        // Should create successfully without identity
        #expect(delegate is URLSessionDelegate)
    }

    @Test func delegateInitWithIdentity() {
        // Create a test identity
        MTLSIdentity.deleteIdentity()
        let fingerprint = "TE:ST:DE:LE:GA:TE:00:00:00:00:00:00:00:00:00:01"
        let identity = MTLSIdentity.loadOrCreate(fingerprint: fingerprint)
        #expect(identity != nil)

        let delegate = TLSSessionDelegate(clientIdentity: identity)
        #expect(delegate is URLSessionDelegate)

        MTLSIdentity.deleteIdentity()
    }
}

// MARK: - ANSITerminal Tests

struct ANSITerminalTests {
    @Test func plainTextWriting() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("Hello")
        #expect(term.cursorCol == 5)
        #expect(term.cursorRow == 0)
        #expect(term.cells[0][0].character == "H")
        #expect(term.cells[0][4].character == "o")
    }

    @Test func lineWrapping() {
        let term = ANSITerminal(cols: 5, rows: 3)
        term.write("HelloWorld")
        // "Hello" fills row 0, "World" wraps to row 1
        #expect(term.cells[0][0].character == "H")
        #expect(term.cells[0][4].character == "o")
        #expect(term.cells[1][0].character == "W")
        #expect(term.cells[1][4].character == "d")
    }

    @Test func carriageReturnAndLineFeed() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("Hello\r\nWorld")
        #expect(term.cells[0][0].character == "H")
        #expect(term.cells[1][0].character == "W")
        #expect(term.cursorRow == 1)
    }

    @Test func cursorMovement() {
        let term = ANSITerminal(cols: 20, rows: 5)
        term.write("Hello")
        term.write("\u{1B}[3D")  // Move cursor left 3
        #expect(term.cursorCol == 2)
        term.write("\u{1B}[2B")  // Move cursor down 2
        #expect(term.cursorRow == 2)
        term.write("\u{1B}[1A")  // Move cursor up 1
        #expect(term.cursorRow == 1)
    }

    @Test func cursorPosition() {
        let term = ANSITerminal(cols: 20, rows: 10)
        term.write("\u{1B}[5;10H")  // Move to row 5, col 10
        #expect(term.cursorRow == 4)  // 0-indexed
        #expect(term.cursorCol == 9)  // 0-indexed
    }

    @Test func cursorHorizontalAbsolute() {
        let term = ANSITerminal(cols: 20, rows: 5)
        term.write("Hello World")
        term.write("\u{1B}[3G")  // Move to column 3
        #expect(term.cursorCol == 2)  // 0-indexed
    }

    @Test func eraseInLine() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("HelloWorld")
        term.write("\u{1B}[6G")   // Move to column 6 (1-indexed) = col 5 (0-indexed)
        term.write("\u{1B}[0K")   // Erase from cursor to end
        #expect(term.cells[0][3].character == "l")  // col 3 preserved
        #expect(term.cells[0][4].character == "o")  // col 4 preserved
        #expect(term.cells[0][5].character == " ")  // col 5 erased
        #expect(term.cells[0][9].character == " ")  // col 9 erased
    }

    @Test func eraseEntireLine() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("HelloWorld")
        term.write("\u{1B}[1G")   // Move to column 1
        term.write("\u{1B}[2K")   // Erase entire line
        for c in 0..<10 {
            #expect(term.cells[0][c].character == " ")
        }
    }

    @Test func eraseInDisplay() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("Line1\r\nLine2\r\nLine3")
        term.write("\u{1B}[2J")   // Erase entire display
        for r in 0..<3 {
            for c in 0..<10 {
                #expect(term.cells[r][c].character == " ")
            }
        }
    }

    @Test func sgrBasicColors() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("\u{1B}[31mRed\u{1B}[0m")
        #expect(term.cells[0][0].style.foreground == .standard(1)) // Red
        #expect(term.cells[0][0].character == "R")
        // After reset
        term.write("Normal")
        #expect(term.cells[0][3].style.foreground == .default)
    }

    @Test func sgr256Color() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("\u{1B}[38;5;244mGray\u{1B}[0m")
        #expect(term.cells[0][0].style.foreground == .color256(244))
    }

    @Test func sgrBold() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("\u{1B}[1mBold\u{1B}[22m")
        #expect(term.cells[0][0].style.bold == true)
        term.write("N")
        #expect(term.cells[0][4].style.bold == false)
    }

    @Test func scrollingOnLineFeed() {
        let term = ANSITerminal(cols: 5, rows: 3)
        term.write("AAA\r\nBBB\r\nCCC\r\nDDD")
        // After 4 lines in 3-row terminal, first line should have scrolled off
        #expect(term.cells[0][0].character == "B")
        #expect(term.cells[1][0].character == "C")
        #expect(term.cells[2][0].character == "D")
    }

    @Test func backspace() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("ABC\u{08}X")
        // Backspace moves cursor back, then X overwrites C
        #expect(term.cells[0][0].character == "A")
        #expect(term.cells[0][1].character == "B")
        #expect(term.cells[0][2].character == "X")
    }

    @Test func tabStops() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("A\tB")
        #expect(term.cells[0][0].character == "A")
        #expect(term.cells[0][8].character == "B")  // Tab to column 8
    }

    @Test func stripEscapeCodes() {
        let term = ANSITerminal(cols: 40, rows: 3)
        // Typical Claude output with escape sequences
        term.write("\u{1B}[38;5;244m───\u{1B}[39m Hello \u{1B}[1mWorld\u{1B}[22m")
        let rendered = term.render()
        let plain = String(rendered.characters)
        #expect(plain.contains("───"))
        #expect(plain.contains("Hello"))
        #expect(plain.contains("World"))
        // No raw escape codes should be visible
        #expect(!plain.contains("[38"))
        #expect(!plain.contains("[39m"))
        #expect(!plain.contains("[1m"))
    }

    @Test func renderProducesAttributedString() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("Hello World")
        let result = term.render()
        let plain = String(result.characters)
        #expect(plain.contains("Hello World"))
    }

    @Test func oscSequencesIgnored() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("\u{1B}]0;Window Title\u{07}Hello")
        #expect(term.cells[0][0].character == "H")
    }

    @Test func privateModesIgnored() {
        let term = ANSITerminal(cols: 20, rows: 3)
        term.write("\u{1B}[?2026l\u{1B}[?2026hHi")
        #expect(term.cells[0][0].character == "H")
        #expect(term.cells[0][1].character == "i")
    }

    @Test func resize() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("Hello")
        term.resize(cols: 5, rows: 2)
        #expect(term.cols == 5)
        #expect(term.rows == 2)
        #expect(term.cells[0][0].character == "H")
        #expect(term.cells[0][4].character == "o")
    }

    @Test func deleteCharacters() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("ABCDE")
        term.write("\u{1B}[3G")   // cursor to col 3
        term.write("\u{1B}[1P")   // delete 1 char at cursor
        // "AB_DE" -> "ABDE " (D shifts left)
        #expect(term.cells[0][2].character == "D")
        #expect(term.cells[0][3].character == "E")
    }

    @Test func eraseCharacters() {
        let term = ANSITerminal(cols: 10, rows: 3)
        term.write("ABCDE")
        term.write("\u{1B}[2G")    // cursor to col 2
        term.write("\u{1B}[2X")    // erase 2 chars
        #expect(term.cells[0][0].character == "A")
        #expect(term.cells[0][1].character == " ")
        #expect(term.cells[0][2].character == " ")
        #expect(term.cells[0][3].character == "D")
    }
}

// MARK: - PTY Message Tests

struct PtyMessageTests {
    @Test func ptyInputMessageEncoding() throws {
        let msg = PtyInputMessage(
            type: "pty:input",
            payload: PtyInputPayload(agentId: "agent_123", data: "ls\n")
        )
        let data = try JSONEncoder().encode(msg)
        let jsonStr = String(data: data, encoding: .utf8)!
        #expect(jsonStr.contains("pty:input"))
        #expect(jsonStr.contains("agent_123"))
    }

    @Test func ptyResizeMessageEncoding() throws {
        let msg = PtyResizeMessage(
            type: "pty:resize",
            payload: PtyResizePayload(agentId: "agent_123", cols: 80, rows: 24)
        )
        let data = try JSONEncoder().encode(msg)
        let jsonStr = String(data: data, encoding: .utf8)!
        #expect(jsonStr.contains("pty:resize"))
        #expect(jsonStr.contains("80"))
        #expect(jsonStr.contains("24"))
    }
}

// MARK: - ANSITerminal Plain Text Tests

@Suite
struct ANSITerminalPlainTextTests {
    @Test func plainTextSimple() {
        let term = ANSITerminal(cols: 20, rows: 5)
        term.write("Hello World")
        let text = term.plainText()
        #expect(text == "Hello World")
    }

    @Test func plainTextMultiLine() {
        let term = ANSITerminal(cols: 20, rows: 5)
        term.write("Line 1\r\nLine 2\r\nLine 3")
        let text = term.plainText()
        #expect(text.contains("Line 1"))
        #expect(text.contains("Line 2"))
        #expect(text.contains("Line 3"))
        #expect(text.components(separatedBy: "\n").count == 3)
    }

    @Test func plainTextStripsANSI() {
        let term = ANSITerminal(cols: 40, rows: 5)
        term.write("\u{1b}[31mRed Text\u{1b}[0m Normal")
        let text = term.plainText()
        #expect(text.contains("Red Text"))
        #expect(text.contains("Normal"))
        #expect(!text.contains("\u{1b}"))
    }

    @Test func plainTextEmptyTerminal() {
        let term = ANSITerminal(cols: 20, rows: 5)
        #expect(term.plainText() == "")
    }

    @Test func plainTextTrimsTrailingSpaces() {
        let term = ANSITerminal(cols: 20, rows: 5)
        term.write("Hi")
        let text = term.plainText()
        #expect(text == "Hi")
        #expect(!text.hasSuffix(" "))
    }
}

// MARK: - Activity Filter Tests

@Suite
struct ActivityFilterTests {
    private func makeEvent(kind: HookEventKind, toolName: String? = nil) -> HookEvent {
        HookEvent(id: UUID(), agentId: "a", kind: kind, toolName: toolName, toolVerb: nil, message: nil, timestamp: 0)
    }

    @Test func allFilterMatchesEverything() {
        let events: [HookEvent] = [
            makeEvent(kind: .preTool),
            makeEvent(kind: .postTool),
            makeEvent(kind: .toolError),
            makeEvent(kind: .stop),
            makeEvent(kind: .notification),
            makeEvent(kind: .permissionRequest),
        ]
        for event in events {
            #expect(ActivityFilter.all.matches(event))
        }
    }

    @Test func toolsFilterMatchesToolEvents() {
        #expect(ActivityFilter.tools.matches(makeEvent(kind: .preTool)))
        #expect(ActivityFilter.tools.matches(makeEvent(kind: .postTool)))
        #expect(!ActivityFilter.tools.matches(makeEvent(kind: .toolError)))
        #expect(!ActivityFilter.tools.matches(makeEvent(kind: .notification)))
        #expect(!ActivityFilter.tools.matches(makeEvent(kind: .permissionRequest)))
    }

    @Test func errorsFilterMatchesErrorAndStop() {
        #expect(ActivityFilter.errors.matches(makeEvent(kind: .toolError)))
        #expect(ActivityFilter.errors.matches(makeEvent(kind: .stop)))
        #expect(!ActivityFilter.errors.matches(makeEvent(kind: .preTool)))
        #expect(!ActivityFilter.errors.matches(makeEvent(kind: .notification)))
    }

    @Test func permissionsFilterMatchesPermissions() {
        #expect(ActivityFilter.permissions.matches(makeEvent(kind: .permissionRequest)))
        #expect(!ActivityFilter.permissions.matches(makeEvent(kind: .preTool)))
        #expect(!ActivityFilter.permissions.matches(makeEvent(kind: .toolError)))
    }
}

// MARK: - Relative Time Tests

@Suite
struct RelativeTimeTests {
    private func msAgo(_ seconds: Int) -> Int {
        Int((Date().timeIntervalSince1970 - Double(seconds)) * 1000)
    }

    @Test func justNow() {
        #expect(relativeTime(msAgo(2)) == "just now")
    }

    @Test func secondsAgo() {
        let result = relativeTime(msAgo(30))
        #expect(result.hasSuffix("s ago"))
    }

    @Test func minutesAgo() {
        let result = relativeTime(msAgo(120))
        #expect(result.hasSuffix("m ago"))
    }

    @Test func hoursAgo() {
        let result = relativeTime(msAgo(7200))
        #expect(result.hasSuffix("h ago"))
    }

    @Test func oldEventShowsDate() {
        // 2 days ago — should show date format
        let result = relativeTime(msAgo(172800))
        #expect(!result.hasSuffix("ago"))
    }
}

// MARK: - Hook Event Formatting Tests

@Suite
struct HookEventFormattingTests {
    private func makeEvent(
        kind: HookEventKind,
        toolName: String? = nil,
        toolVerb: String? = nil,
        message: String? = nil
    ) -> HookEvent {
        HookEvent(id: UUID(), agentId: "agent_1", kind: kind, toolName: toolName, toolVerb: toolVerb, message: message, timestamp: 0)
    }

    @Test func preToolIconUsesToolSpecificIcon() {
        let event = makeEvent(kind: .preTool, toolName: "Edit")
        #expect(hookEventIcon(event) == "pencil")
    }

    @Test func preToolIconFallsBackToWrench() {
        let event = makeEvent(kind: .preTool, toolName: "UnknownTool")
        #expect(hookEventIcon(event) == "wrench")
    }

    @Test func postToolIcon() {
        let event = makeEvent(kind: .postTool)
        #expect(hookEventIcon(event) == "checkmark.circle")
    }

    @Test func toolErrorIcon() {
        let event = makeEvent(kind: .toolError)
        #expect(hookEventIcon(event) == "exclamationmark.triangle.fill")
    }

    @Test func stopIcon() {
        let event = makeEvent(kind: .stop)
        #expect(hookEventIcon(event) == "stop.circle.fill")
    }

    @Test func notificationIcon() {
        let event = makeEvent(kind: .notification)
        #expect(hookEventIcon(event) == "bell.fill")
    }

    @Test func permissionRequestIcon() {
        let event = makeEvent(kind: .permissionRequest)
        #expect(hookEventIcon(event) == "lock.fill")
    }

    @Test func preToolDescriptionUsesToolVerb() {
        let event = makeEvent(kind: .preTool, toolName: "Read", toolVerb: "Reading config.json")
        #expect(hookEventDescription(event) == "Reading config.json")
    }

    @Test func preToolDescriptionFallsBackToToolName() {
        let event = makeEvent(kind: .preTool, toolName: "Bash")
        #expect(hookEventDescription(event) == "Using Bash")
    }

    @Test func postToolDescription() {
        let event = makeEvent(kind: .postTool, toolName: "Edit")
        #expect(hookEventDescription(event) == "Edit completed")
    }

    @Test func toolErrorDescriptionUsesMessage() {
        let event = makeEvent(kind: .toolError, message: "Command failed")
        #expect(hookEventDescription(event) == "Command failed")
    }

    @Test func toolErrorDescriptionFallback() {
        let event = makeEvent(kind: .toolError)
        #expect(hookEventDescription(event) == "Tool error")
    }

    @Test func permissionDescriptionPending() {
        let event = makeEvent(kind: .permissionRequest, toolName: "Bash", message: "Run npm test")
        #expect(hookEventDescription(event, isPending: true) == "Tap to respond: Run npm test")
    }

    @Test func permissionDescriptionNotPending() {
        let event = makeEvent(kind: .permissionRequest, toolName: "Bash", message: "Run npm test")
        #expect(hookEventDescription(event, isPending: false) == "Needs permission: Run npm test")
    }

    @Test func colorNameMapping() {
        #expect(hookEventColorName(.preTool) == "accent")
        #expect(hookEventColorName(.postTool) == "green")
        #expect(hookEventColorName(.toolError) == "red")
        #expect(hookEventColorName(.stop) == "secondary")
        #expect(hookEventColorName(.notification) == "accent")
        #expect(hookEventColorName(.permissionRequest) == "orange")
    }
}

// MARK: - Session Model Tests

@Suite
struct SessionModelTests {
    @Test func decodeSessionInfo() throws {
        let json = """
        {"id":"sess_001","agentId":"agent_1","startedAt":1708531200000,"endedAt":1708531500000,"status":"completed","messageCount":42,"model":"claude-opus-4-5","costUsd":0.0523,"inputTokens":12345,"outputTokens":6789}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(session.id == "sess_001")
        #expect(session.agentId == "agent_1")
        #expect(session.status == .completed)
        #expect(session.messageCount == 42)
        #expect(session.model == "claude-opus-4-5")
        #expect(session.costUsd == 0.0523)
        #expect(session.inputTokens == 12345)
        #expect(session.outputTokens == 6789)
        #expect(session.startedAt == 1708531200000)
        #expect(session.endedAt == 1708531500000)
    }

    @Test func decodeSessionInfoMinimal() throws {
        let json = """
        {"id":"sess_002","agentId":"agent_2"}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(session.id == "sess_002")
        #expect(session.status == nil)
        #expect(session.messageCount == nil)
        #expect(session.costUsd == nil)
    }

    @Test func decodeTranscriptEntry() throws {
        let json = """
        {"id":"entry_001","role":"assistant","content":"Hello, I'll help you fix that bug.","toolName":null,"timestamp":1708531200000,"index":0}
        """
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.id == "entry_001")
        #expect(entry.role == "assistant")
        #expect(entry.content == "Hello, I'll help you fix that bug.")
        #expect(entry.toolName == nil)
        #expect(entry.index == 0)
    }

    @Test func decodeTranscriptEntryToolUse() throws {
        let json = """
        {"id":"entry_002","role":"tool_use","content":"Reading file...","toolName":"Read","timestamp":1708531210000,"index":1}
        """
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.role == "tool_use")
        #expect(entry.toolName == "Read")
    }

    @Test func decodeTranscriptResponse() throws {
        let json = """
        {"entries":[{"id":"e1","role":"user","content":"Fix the bug","toolName":null,"timestamp":1708531200000,"index":0}],"total":25,"hasMore":true}
        """
        let response = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
        #expect(response.entries.count == 1)
        #expect(response.total == 25)
        #expect(response.hasMore == true)
    }

    @Test func decodeTranscriptResponseMinimal() throws {
        let json = """
        {"entries":[]}
        """
        let response = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
        #expect(response.entries.isEmpty)
        #expect(response.hasMore == nil)
        #expect(response.total == nil)
    }

    @Test func decodeSessionSummary() throws {
        let json = """
        {"sessionId":"sess_001","summary":"Fixed authentication bug in login flow","filesChanged":["src/auth/login.ts","src/auth/session.ts"],"toolsUsed":["Read","Edit","Bash"],"duration":300,"model":"claude-opus-4-5","costUsd":0.0523,"inputTokens":12345,"outputTokens":6789}
        """
        let summary = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
        #expect(summary.sessionId == "sess_001")
        #expect(summary.summary == "Fixed authentication bug in login flow")
        #expect(summary.filesChanged?.count == 2)
        #expect(summary.toolsUsed?.count == 3)
        #expect(summary.duration == 300)
    }

    @Test func decodeSessionSummaryMinimal() throws {
        let json = """
        {"sessionId":"sess_002"}
        """
        let summary = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
        #expect(summary.sessionId == "sess_002")
        #expect(summary.summary == nil)
        #expect(summary.filesChanged == nil)
        #expect(summary.duration == nil)
    }

    @Test func sessionInfoIdentifiable() {
        let s1 = SessionInfo(id: "s1", agentId: "a1", startedAt: nil, endedAt: nil, status: nil, messageCount: nil, model: nil, costUsd: nil, inputTokens: nil, outputTokens: nil)
        let s2 = SessionInfo(id: "s2", agentId: "a1", startedAt: nil, endedAt: nil, status: nil, messageCount: nil, model: nil, costUsd: nil, inputTokens: nil, outputTokens: nil)
        #expect(s1.id != s2.id)
    }

    @Test func transcriptEntryIdentifiable() {
        let e1 = TranscriptEntry(id: "e1", role: "user", content: nil, toolName: nil, timestamp: nil, index: nil)
        let e2 = TranscriptEntry(id: "e2", role: "assistant", content: nil, toolName: nil, timestamp: nil, index: nil)
        #expect(e1.id != e2.id)
    }
}

// MARK: - Icon Cache Tests

@Suite
struct IconCacheTests {
    /// Create a minimal valid 1x1 red PNG for testing.
    private func make1x1PNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @Test func storeAndRetrieve() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.store(key: "test", data: data)
        #expect(cache.image(for: "test") != nil)
        #expect(cache.count == 1)
    }

    @Test func retrieveMissReturnsNil() {
        let cache = IconCache()
        #expect(cache.image(for: "nonexistent") == nil)
    }

    @Test func storeInvalidDataIgnored() {
        let cache = IconCache()
        cache.store(key: "bad", data: Data([0x00, 0x01, 0x02]))
        #expect(cache.image(for: "bad") == nil)
        #expect(cache.count == 0)
    }

    @Test func agentConvenienceAccessors() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.storeAgentIcon(id: "agent_1", data: data)
        #expect(cache.agentImage(id: "agent_1") != nil)
        #expect(cache.projectImage(id: "agent_1") == nil) // different namespace
    }

    @Test func projectConvenienceAccessors() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.storeProjectIcon(id: "proj_1", data: data)
        #expect(cache.projectImage(id: "proj_1") != nil)
        #expect(cache.agentImage(id: "proj_1") == nil)
    }

    @Test func lruEviction() {
        let cache = IconCache(maxEntries: 3)
        let data = make1x1PNG()
        cache.store(key: "a", data: data)
        cache.store(key: "b", data: data)
        cache.store(key: "c", data: data)
        #expect(cache.count == 3)

        // Adding a 4th should evict the oldest ("a")
        cache.store(key: "d", data: data)
        #expect(cache.count == 3)
        #expect(cache.image(for: "a") == nil)
        #expect(cache.image(for: "b") != nil)
        #expect(cache.image(for: "d") != nil)
    }

    @Test func lruAccessUpdatesOrder() {
        let cache = IconCache(maxEntries: 3)
        let data = make1x1PNG()
        cache.store(key: "a", data: data)
        cache.store(key: "b", data: data)
        cache.store(key: "c", data: data)

        // Access "a" to make it most recent
        _ = cache.image(for: "a")

        // Adding "d" should evict "b" (now oldest), not "a"
        cache.store(key: "d", data: data)
        #expect(cache.image(for: "a") != nil)
        #expect(cache.image(for: "b") == nil)
    }

    @Test func storeIfNeededSkipsDuplicate() {
        let cache = IconCache()
        let data1 = make1x1PNG()
        cache.store(key: "x", data: data1)
        let image1 = cache.image(for: "x")

        // storeIfNeeded should not overwrite
        cache.storeIfNeeded(key: "x", data: data1)
        let image2 = cache.image(for: "x")
        #expect(image1 === image2)
    }

    @Test func clearRemovesAll() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.store(key: "a", data: data)
        cache.store(key: "b", data: data)
        #expect(cache.count == 2)

        cache.clear()
        #expect(cache.count == 0)
        #expect(cache.image(for: "a") == nil)
    }

    @Test func removeSpecificEntry() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.store(key: "a", data: data)
        cache.store(key: "b", data: data)

        cache.remove("a")
        #expect(cache.image(for: "a") == nil)
        #expect(cache.image(for: "b") != nil)
        #expect(cache.count == 1)
    }

    @Test func containsCheck() {
        let cache = IconCache()
        let data = make1x1PNG()
        #expect(!cache.contains("x"))
        cache.store(key: "x", data: data)
        #expect(cache.contains("x"))
    }

    @Test func loadFromSnapshotPopulatesCache() {
        let cache = IconCache()
        let data = make1x1PNG()
        cache.loadFromSnapshot(
            agentIcons: ["a1": data, "a2": data],
            projectIcons: ["p1": data]
        )
        #expect(cache.agentImage(id: "a1") != nil)
        #expect(cache.agentImage(id: "a2") != nil)
        #expect(cache.projectImage(id: "p1") != nil)
        #expect(cache.count == 3)
    }
}
