import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Create Durable Agent Request Tests

struct CreateDurableAgentRequestTests {
    @Test func encodesAllFields() throws {
        let request = CreateDurableAgentRequest(
            name: "brave-falcon",
            color: "emerald",
            model: "claude-opus-4-6",
            orchestrator: "claude-code",
            freeAgentMode: false
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(json["name"] == .string("brave-falcon"))
        #expect(json["color"] == .string("emerald"))
        #expect(json["model"] == .string("claude-opus-4-6"))
        #expect(json["orchestrator"] == .string("claude-code"))
        #expect(json["freeAgentMode"] == .bool(false))
    }

    @Test func encodesWithNilOptionals() throws {
        let request = CreateDurableAgentRequest(
            name: "test-agent",
            color: nil,
            model: nil,
            orchestrator: nil,
            freeAgentMode: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"name\":\"test-agent\""))
    }
}

// MARK: - Create Durable Agent Response Tests

struct CreateDurableAgentResponseTests {
    @Test func decodesFullResponse() throws {
        let json = """
        {
            "id": "durable_12345",
            "name": "brave-falcon",
            "kind": "durable",
            "color": "emerald",
            "status": "sleeping",
            "branch": "brave-falcon/standby",
            "model": "claude-opus-4-6",
            "orchestrator": "claude-code",
            "freeAgentMode": false,
            "icon": null,
            "executionMode": "pty",
            "projectId": "proj_001"
        }
        """
        let response = try JSONDecoder().decode(CreateDurableAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "durable_12345")
        #expect(response.name == "brave-falcon")
        #expect(response.kind == "durable")
        #expect(response.color == "emerald")
        #expect(response.status == "sleeping")
        #expect(response.projectId == "proj_001")
        #expect(response.executionMode == "pty")
    }

    @Test func decodesMinimalResponse() throws {
        let json = """
        {
            "id": "durable_99",
            "name": "test",
            "kind": "durable",
            "color": null,
            "status": "sleeping",
            "branch": null,
            "model": null,
            "orchestrator": null,
            "freeAgentMode": null,
            "icon": null,
            "executionMode": null,
            "projectId": "proj_001"
        }
        """
        let response = try JSONDecoder().decode(CreateDurableAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "durable_99")
        #expect(response.color == nil)
        #expect(response.model == nil)
    }
}

// MARK: - Delete Agent Request/Response Tests

struct DeleteAgentTests {
    @Test func requestEncodesConfirm() throws {
        let request = DeleteAgentRequest(confirm: true)
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"confirm\":true"))
    }

    @Test func responseDecodes() throws {
        let json = """
        {"id": "durable_123", "deleted": true}
        """
        let response = try JSONDecoder().decode(DeleteAgentResponse.self, from: Data(json.utf8))
        #expect(response.id == "durable_123")
        #expect(response.deleted == true)
    }

    @Test func responseDecodesFailedDelete() throws {
        let json = """
        {"id": "durable_123", "deleted": false}
        """
        let response = try JSONDecoder().decode(DeleteAgentResponse.self, from: Data(json.utf8))
        #expect(response.deleted == false)
    }
}

// MARK: - Agent Name Validation Tests

struct AgentNameValidationTests {
    @Test func validNames() {
        #expect(validateAgentName("brave-falcon") == nil)
        #expect(validateAgentName("my-agent-123") == nil)
        #expect(validateAgentName("ab") == nil)
        #expect(validateAgentName("a-very-long-but-still-valid-name-here12") == nil) // 40 chars
    }

    @Test func emptyReturnsNil() {
        #expect(validateAgentName("") == nil)
        #expect(validateAgentName("   ") == nil)
    }

    @Test func tooShort() {
        #expect(validateAgentName("a") != nil)
    }

    @Test func tooLong() {
        let long = String(repeating: "a", count: 41)
        #expect(validateAgentName(long) != nil)
    }

    @Test func spacesRejected() {
        #expect(validateAgentName("my agent") != nil)
    }

    @Test func specialCharsRejected() {
        #expect(validateAgentName("my_agent") != nil)
        #expect(validateAgentName("my.agent") != nil)
        #expect(validateAgentName("my@agent") != nil)
    }
}

// MARK: - Spawn Quick Agent Request Tests

struct SpawnQuickAgentRequestTests {
    @Test func encodesAllFields() throws {
        let request = SpawnQuickAgentRequest(
            prompt: "Fix the login bug",
            orchestrator: "claude-code",
            model: "claude-sonnet-4-6",
            freeAgentMode: true,
            systemPrompt: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(json["prompt"] == .string("Fix the login bug"))
        #expect(json["orchestrator"] == .string("claude-code"))
        #expect(json["model"] == .string("claude-sonnet-4-6"))
        #expect(json["freeAgentMode"] == .bool(true))
    }

    @Test func encodesMinimalRequest() throws {
        let request = SpawnQuickAgentRequest(
            prompt: "Do something",
            orchestrator: nil,
            model: nil,
            freeAgentMode: nil,
            systemPrompt: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"prompt\":\"Do something\""))
    }
}

// MARK: - AppStore Agent Management Tests

@MainActor struct AppStoreAgentManagementTests {
    private func makeStore() -> AppStore {
        let store = AppStore()
        store.loadMockData()
        return store
    }

    @Test func serverInstanceDeleteRemovesFromCaches() {
        let inst = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "127.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")
        )
        inst.agentsByProject["proj_1"] = [
            DurableAgent(id: "agent_1", name: "test-agent", kind: "durable", color: nil,
                         branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                         icon: nil, executionMode: nil, status: .sleeping, mission: nil,
                         detailedStatus: nil, quickAgents: nil)
        ]
        inst.activityByAgent["agent_1"] = [
            HookEvent(id: UUID(), agentId: "agent_1", kind: .preTool, toolName: "Read",
                      toolVerb: nil, message: nil, timestamp: 100)
        ]
        inst.ptyBufferByAgent["agent_1"] = "some output"

        // Verify agent exists
        #expect(inst.durableAgent(byId: "agent_1") != nil)
        #expect(inst.activity(for: "agent_1").count == 1)

        // Remove from all caches (simulating what deleteAgent does locally)
        inst.agentsByProject["proj_1"] = inst.agentsByProject["proj_1"]?.filter { $0.id != "agent_1" }
        inst.activityByAgent.removeValue(forKey: "agent_1")
        inst.ptyBufferByAgent.removeValue(forKey: "agent_1")

        // Verify removal
        #expect(inst.durableAgent(byId: "agent_1") == nil)
        #expect(inst.activity(for: "agent_1").isEmpty)
        #expect(inst.ptyBuffer(for: "agent_1").isEmpty)
    }

    @Test func instanceLookupForAgentActions() {
        let store = makeStore()
        let inst = store.instance(for: "durable_1737000000000_abc123")
        #expect(inst != nil)
        #expect(inst?.serverName == "Mason's Desktop")
    }

    @Test func projectLookupForCreateAgent() {
        let store = makeStore()
        let inst = store.connectedInstances.first(where: {
            $0.projects.contains { $0.id == "proj_001" }
        })
        #expect(inst != nil)
        #expect(inst?.serverName == "Mason's Desktop")
    }
}

// MARK: - AgentColor Picker Tests

struct AgentColorPickerTests {
    @Test func allCasesHaveHex() {
        for color in AgentColor.allCases {
            #expect(!color.hex.isEmpty)
            #expect(color.hex.hasPrefix("#"))
        }
    }

    @Test func eightColorsAvailable() {
        #expect(AgentColor.allCases.count == 8)
    }

    @Test func allCasesHaveDistinctHex() {
        let hexValues = AgentColor.allCases.map(\.hex)
        let uniqueHex = Set(hexValues)
        #expect(uniqueHex.count == 8)
    }
}
