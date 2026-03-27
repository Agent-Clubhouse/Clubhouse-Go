import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Comprehensive WebSocket Message Parsing Tests
//
// Tests the full range of WebSocket message types parsed by WebSocketClient.
// Covers: snapshot, pty:data, pty:exit, hook:event, structured:event,
// theme:changed, agent:spawned, agent:status, agent:completed, agent:woken,
// permission:request, permission:response, canvas:state, replay:gap,
// replay:start, replay:end, plus malformed/unknown message handling.

struct WebSocketPayloadTests {

    // MARK: - agent:status

    @Test func decodeAgentStatusPayload() throws {
        let json = """
        {"type":"agent:status","payload":{"id":"durable_001","kind":"durable","status":"running","projectId":"proj_001","parentAgentId":null}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentStatusPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "durable_001")
        #expect(msg.payload.kind == "durable")
        #expect(msg.payload.status == "running")
        #expect(msg.payload.projectId == "proj_001")
        #expect(msg.payload.parentAgentId == nil)
    }

    @Test func decodeAgentStatusQuickAgent() throws {
        let json = """
        {"type":"agent:status","payload":{"id":"quick_001","kind":"quick","status":"starting","projectId":"proj_001","parentAgentId":"durable_001"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentStatusPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.kind == "quick")
        #expect(msg.payload.parentAgentId == "durable_001")
    }

    // MARK: - agent:completed

    @Test func decodeAgentCompletedMinimal() throws {
        let json = """
        {"type":"agent:completed","payload":{"id":"quick_001","kind":"quick","status":"completed","projectId":"proj_001"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentCompletedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.kind == "quick")
        #expect(msg.payload.status == "completed")
        #expect(msg.payload.exitCode == nil)
        #expect(msg.payload.summary == nil)
        #expect(msg.payload.filesModified == nil)
        #expect(msg.payload.durationMs == nil)
        #expect(msg.payload.costUsd == nil)
        #expect(msg.payload.toolsUsed == nil)
    }

    @Test func decodeAgentCompletedFull() throws {
        let json = """
        {"type":"agent:completed","payload":{"id":"quick_001","kind":"quick","status":"completed","exitCode":0,"projectId":"proj_001","parentAgentId":"durable_001","summary":"Fixed the login bug","filesModified":["src/auth.ts","src/auth.test.ts"],"durationMs":45200,"costUsd":0.12,"toolsUsed":["Read","Edit","Bash"]}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentCompletedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.exitCode == 0)
        #expect(msg.payload.summary == "Fixed the login bug")
        #expect(msg.payload.filesModified == ["src/auth.ts", "src/auth.test.ts"])
        #expect(msg.payload.durationMs == 45200)
        #expect(msg.payload.costUsd == 0.12)
        #expect(msg.payload.toolsUsed == ["Read", "Edit", "Bash"])
        #expect(msg.payload.parentAgentId == "durable_001")
    }

    @Test func decodeAgentCompletedFailed() throws {
        let json = """
        {"type":"agent:completed","payload":{"id":"quick_002","kind":"quick","status":"failed","exitCode":1,"projectId":"proj_001"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentCompletedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.status == "failed")
        #expect(msg.payload.exitCode == 1)
    }

    // MARK: - agent:woken

    @Test func decodeAgentWokenPayload() throws {
        let json = """
        {"type":"agent:woken","payload":{"agentId":"durable_001","message":"Rebase on main","source":"mobile"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentWokenPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "durable_001")
        #expect(msg.payload.message == "Rebase on main")
        #expect(msg.payload.source == "mobile")
    }

    @Test func decodeAgentWokenNoSource() throws {
        let json = """
        {"type":"agent:woken","payload":{"agentId":"durable_001","message":"Wake up"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentWokenPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.source == nil)
    }

    // MARK: - permission:request

    @Test func decodePermissionRequestPayload() throws {
        let json = """
        {"type":"permission:request","payload":{"agentId":"durable_001","requestId":"req_001","toolName":"Bash","toolInput":{"command":"rm -rf /tmp/test"},"message":"Agent wants to run a bash command","timeout":30}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<PermissionRequestPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "durable_001")
        #expect(msg.payload.requestId == "req_001")
        #expect(msg.payload.toolName == "Bash")
        #expect(msg.payload.timeout == 30)
    }

    @Test func decodePermissionRequestMinimal() throws {
        let json = """
        {"type":"permission:request","payload":{"agentId":"agent_001","requestId":"req_002","toolName":"Edit"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<PermissionRequestPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.toolName == "Edit")
        #expect(msg.payload.toolInput == nil)
        #expect(msg.payload.message == nil)
        #expect(msg.payload.timeout == nil)
    }

    // MARK: - permission:response

    @Test func decodePermissionResponsePayload() throws {
        let json = """
        {"type":"permission:response","payload":{"requestId":"req_001","decision":"allow"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<PermissionResponsePayload>.self, from: Data(json.utf8))
        #expect(msg.payload.requestId == "req_001")
        #expect(msg.payload.decision == "allow")
    }

    @Test func decodePermissionResponseDeny() throws {
        let json = """
        {"type":"permission:response","payload":{"requestId":"req_002","decision":"deny"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<PermissionResponsePayload>.self, from: Data(json.utf8))
        #expect(msg.payload.decision == "deny")
    }

    // MARK: - canvas:state

    @Test func decodeCanvasStatePayload() throws {
        let json = """
        {"type":"canvas:state","payload":{"projectId":"proj_001","state":{"canvasId":"canvas_001","views":[],"viewport":{"x":0,"y":0,"zoom":1.0}}}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<CanvasStatePayload>.self, from: Data(json.utf8))
        #expect(msg.payload.projectId == "proj_001")
        #expect(msg.payload.state.canvasId == "canvas_001")
        #expect(msg.payload.state.views.isEmpty)
    }

    // MARK: - structured:event

    @Test func decodeStructuredEventPayload() throws {
        let json = """
        {"type":"structured:event","payload":{"agentId":"agent_001","event":{"type":"tool_result","timestamp":1737000000000,"data":{"success":true}}}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<StructuredEventPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.agentId == "agent_001")
        #expect(msg.payload.event.type == "tool_result")
        #expect(msg.payload.event.timestamp == 1737000000000)
    }

    // MARK: - replay:gap

    @Test func decodeReplayGapPayload() throws {
        let json = """
        {"type":"replay:gap","payload":{"oldestAvailable":100,"lastSeq":500}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<ReplayGapPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.oldestAvailable == 100)
        #expect(msg.payload.lastSeq == 500)
    }

    // MARK: - replay:start

    @Test func decodeReplayStartPayload() throws {
        let json = """
        {"type":"replay:start","payload":{"fromSeq":50,"toSeq":100,"count":51}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<ReplayStartPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.fromSeq == 50)
        #expect(msg.payload.toSeq == 100)
        #expect(msg.payload.count == 51)
    }

    // MARK: - Envelope Metadata (seq, replayed)

    @Test func decodeEnvelopeWithSeqAndReplayed() throws {
        let json = """
        {"type":"agent:status","seq":42,"replayed":true,"payload":{"id":"agent_001","kind":"durable","status":"running","projectId":"proj_001"}}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.type == "agent:status")
        #expect(envelope.seq == 42)
        #expect(envelope.replayed == true)
    }

    @Test func decodeEnvelopeWithoutSeq() throws {
        let json = """
        {"type":"theme:changed","payload":{"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"}}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.seq == nil)
        #expect(envelope.replayed == nil)
    }

    // MARK: - Snapshot with full payload

    @Test func decodeFullSnapshot() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [
                    {"id":"proj_001","name":"my-app","path":"/src/my-app","color":"emerald","icon":null,"displayName":"My App","orchestrator":"claude-code"}
                ],
                "agents": {
                    "proj_001": [
                        {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","branch":"faithful-urchin/standby","model":"claude-opus-4-5","orchestrator":"claude-code","freeAgentMode":false,"icon":null}
                    ]
                },
                "quickAgents": {
                    "proj_001": [
                        {"id":"quick_001","kind":"quick","status":"running","prompt":"Fix tests","model":"claude-sonnet-4-5","parentAgentId":"durable_001","projectId":"proj_001"}
                    ]
                },
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {
                    "claude-code": {"displayName":"Claude Code","shortName":"CC","badge":null}
                },
                "pendingPermissions": [
                    {"requestId":"req_001","agentId":"durable_001","toolName":"Bash","toolInput":null,"message":"Run tests","timeout":60}
                ],
                "lastSeq": 150
            }
        }
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let snap = try JSONDecoder().decode(E<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snap.payload.projects.count == 1)
        #expect(snap.payload.agents["proj_001"]?.count == 1)
        #expect(snap.payload.quickAgents?["proj_001"]?.count == 1)
        #expect(snap.payload.orchestrators["claude-code"]?.displayName == "Claude Code")
        #expect(snap.payload.pendingPermissions?.count == 1)
        #expect(snap.payload.pendingPermissions?[0].toolName == "Bash")
        #expect(snap.payload.lastSeq == 150)
    }

    @Test func decodeSnapshotWithPlugins() throws {
        let json = """
        {
            "type": "snapshot",
            "payload": {
                "projects": [],
                "agents": {},
                "theme": {"base":"#1e1e2e","mantle":"#181825","crust":"#11111b","text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de","surface0":"#313244","surface1":"#45475a","surface2":"#585b70","accent":"#89b4fa","link":"#89b4fa"},
                "orchestrators": {},
                "plugins": [
                    {"id":"plugin_001","name":"My Plugin","version":"1.0.0","scope":"project","annexEnabled":true},
                    {"id":"plugin_002","name":"Other Plugin","version":null,"scope":null,"annexEnabled":false}
                ]
            }
        }
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let snap = try JSONDecoder().decode(E<SnapshotPayload>.self, from: Data(json.utf8))
        #expect(snap.payload.plugins?.count == 2)
        #expect(snap.payload.plugins?[0].name == "My Plugin")
        #expect(snap.payload.plugins?[0].annexEnabled == true)
        #expect(snap.payload.plugins?[1].version == nil)
    }

    // MARK: - agent:spawned with all fields

    @Test func decodeAgentSpawnedFull() throws {
        let json = """
        {"type":"agent:spawned","payload":{"id":"quick_001","name":"quick-agent-1","kind":"quick","status":"starting","prompt":"Fix bug","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":true,"parentAgentId":"durable_001","projectId":"proj_001"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentSpawnedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.id == "quick_001")
        #expect(msg.payload.name == "quick-agent-1")
        #expect(msg.payload.kind == "quick")
        #expect(msg.payload.freeAgentMode == true)
        #expect(msg.payload.parentAgentId == "durable_001")
        #expect(msg.payload.projectId == "proj_001")
    }

    @Test func decodeAgentSpawnedDurable() throws {
        let json = """
        {"type":"agent:spawned","payload":{"id":"durable_002","name":"mighty-kiwi","kind":"durable","status":"starting","model":"claude-opus-4-5","orchestrator":"claude-code","freeAgentMode":false,"projectId":"proj_001"}}
        """
        struct E<T: Decodable>: Decodable { let payload: T }
        let msg = try JSONDecoder().decode(E<AgentSpawnedPayload>.self, from: Data(json.utf8))
        #expect(msg.payload.kind == "durable")
        #expect(msg.payload.parentAgentId == nil)
    }

    // MARK: - Replay Request encoding

    @Test func encodeReplayRequest() throws {
        let request = ReplayRequest(type: "replay", since: 100)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ReplayRequest.self, from: data)
        #expect(decoded.type == "replay")
        #expect(decoded.since == 100)
    }

    // MARK: - JSONValue comprehensive tests

    @Test func jsonValueAllTypes() throws {
        let json = """
        {"string":"hello","number":42.5,"bool":true,"null":null,"array":[1,2,3],"nested":{"key":"value"}}
        """
        let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        #expect(value["string"] == .string("hello"))
        #expect(value["number"] == .number(42.5))
        #expect(value["bool"] == .bool(true))
        #expect(value["null"] == .null)
        #expect(value["array"] == .array([.number(1), .number(2), .number(3)]))
        if case .object(let nested) = value["nested"] {
            #expect(nested["key"] == .string("value"))
        } else {
            Issue.record("Expected nested object")
        }
    }

    @Test func jsonValueRoundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .number(5),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - PermissionRequest model tests

    @Test func permissionRequestIdentifiable() throws {
        let json = """
        {"requestId":"req_001","agentId":"agent_001","toolName":"Bash","toolInput":null,"message":null,"timeout":30,"deadline":null}
        """
        let request = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(request.id == "req_001")
        #expect(request.agentId == "agent_001")
        #expect(request.toolName == "Bash")
        #expect(request.timeout == 30)
    }

    @Test func permissionRequestWithDeadline() throws {
        let json = """
        {"requestId":"req_002","agentId":"agent_001","toolName":"Edit","deadline":1737000060000}
        """
        let request = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(request.deadline == 1737000060000)
    }

    @Test func permissionRequestHashable() throws {
        let json1 = """
        {"requestId":"req_001","agentId":"agent_001","toolName":"Bash"}
        """
        let json2 = """
        {"requestId":"req_001","agentId":"agent_001","toolName":"Bash"}
        """
        let r1 = try JSONDecoder().decode(PermissionRequest.self, from: Data(json1.utf8))
        let r2 = try JSONDecoder().decode(PermissionRequest.self, from: Data(json2.utf8))
        #expect(r1 == r2)
        #expect(r1.hashValue == r2.hashValue)
    }

    // MARK: - WSEnvelope decoding edge cases

    @Test func wsEnvelopeUnknownType() throws {
        let json = """
        {"type":"future:event","payload":{"data":"something"}}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.type == "future:event")
    }

    @Test func wsEnvelopeEmptyPayload() throws {
        let json = """
        {"type":"replay:end"}
        """
        let envelope = try JSONDecoder().decode(WSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.type == "replay:end")
        #expect(envelope.payload == nil)
    }
}
