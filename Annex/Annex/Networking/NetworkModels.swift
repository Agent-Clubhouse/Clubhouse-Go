import Foundation

// MARK: - Multi-Instance Identity

/// Unique, stable identifier for a Clubhouse server instance.
/// Uses the Ed25519 fingerprint from TXT records / pairing response.
struct ServerInstanceID: Hashable, Codable, Sendable {
    let value: String
}

/// Connection configuration for a v2 server.
enum ServerProtocol: Codable, Sendable {
    case v2(host: String, mainPort: UInt16, pairingPort: UInt16, fingerprint: String)

    var host: String {
        switch self {
        case .v2(let host, _, _, _): return host
        }
    }

    var mainPort: UInt16 {
        switch self {
        case .v2(_, let mainPort, _, _): return mainPort
        }
    }

    var label: String {
        switch self {
        case .v2(let host, let mainPort, let pairingPort, _): return "v2(\(host):\(mainPort)/\(pairingPort))"
        }
    }
}

// MARK: - REST Responses

struct V2PairRequest: Encodable, Sendable {
    let pin: String
    let publicKey: String
    let alias: String
    let icon: String
    let color: String
}

struct V2PairResponse: Decodable, Sendable {
    let token: String
    let publicKey: String
    let alias: String
    let icon: String
    let color: String
    let fingerprint: String
}

struct StatusResponse: Codable, Sendable {
    let version: String
    let deviceName: String
    let agentCount: Int
    let orchestratorCount: Int
}

struct ErrorResponse: Codable, Sendable {
    let error: String
}

// MARK: - WebSocket Message Envelope

struct WSMessage: Codable, Sendable {
    let type: String
    let payload: JSONValue
}

// MARK: - WebSocket Payloads

struct SnapshotPayload: Codable, Sendable {
    let projects: [Project]
    let agents: [String: [DurableAgent]]
    let quickAgents: [String: [QuickAgent]]?
    let theme: ThemeColors
    let orchestrators: [String: OrchestratorEntry]
    let pendingPermissions: [PermissionRequest]?
    let lastSeq: Int?
}

struct PtyDataPayload: Codable, Sendable {
    let agentId: String
    let data: String
}

struct PtyExitPayload: Codable, Sendable {
    let agentId: String
    let exitCode: Int
}

struct HookEventPayload: Codable, Sendable {
    let agentId: String
    let event: ServerHookEvent
}

/// Wire format for hook events from the server (spec §5.5).
/// Converted to the app's `HookEvent` model after decoding.
struct ServerHookEvent: Codable, Sendable {
    let kind: HookEventKind
    let toolName: String?
    let toolInput: JSONValue?
    let message: String?
    let toolVerb: String?
    let timestamp: Int

    func toHookEvent(agentId: String) -> HookEvent {
        HookEvent(
            id: UUID(),
            agentId: agentId,
            kind: kind,
            toolName: toolName,
            toolVerb: toolVerb,
            message: message,
            timestamp: timestamp
        )
    }
}

// MARK: - Agent Action Requests

struct SpawnQuickAgentRequest: Codable, Sendable {
    let prompt: String
    let orchestrator: String?
    let model: String?
    let freeAgentMode: Bool?
    let systemPrompt: String?
}

struct WakeAgentRequest: Codable, Sendable {
    let message: String
    let model: String?
}

struct SendMessageRequest: Codable, Sendable {
    let message: String
}

// MARK: - Agent Action Responses

struct SpawnQuickAgentResponse: Codable, Sendable {
    let id: String
    let name: String?
    let kind: String
    let status: String
    let prompt: String
    let model: String?
    let orchestrator: String?
    let freeAgentMode: Bool?
    let parentAgentId: String?
    let projectId: String
}

struct WakeAgentResponse: Codable, Sendable {
    let id: String
    let name: String?
    let kind: String?
    let color: String?
    let status: String
    let message: String?
    let branch: String?
    let model: String?
    let orchestrator: String?
    let freeAgentMode: Bool?
    let icon: String?
    let detailedStatus: AgentDetailedStatus?
}

struct CancelAgentResponse: Codable, Sendable {
    let id: String
    let status: String
}

struct SendMessageResponse: Codable, Sendable {
    let id: String
    let status: String
    let delivered: Bool
}

// MARK: - New WebSocket Payloads

struct AgentSpawnedPayload: Codable, Sendable {
    let id: String
    let name: String?
    let kind: String
    let status: String
    let prompt: String?
    let model: String?
    let orchestrator: String?
    let freeAgentMode: Bool?
    let parentAgentId: String?
    let projectId: String
}

struct AgentStatusPayload: Codable, Sendable {
    let id: String
    let kind: String
    let status: String
    let projectId: String?
    let parentAgentId: String?
}

struct AgentCompletedPayload: Codable, Sendable {
    let id: String
    let kind: String
    let status: String
    let exitCode: Int?
    let projectId: String?
    let parentAgentId: String?
    let summary: String?
    let filesModified: [String]?
    let durationMs: Int?
    let costUsd: Double?
    let toolsUsed: [String]?
}

struct AgentWokenPayload: Codable, Sendable {
    let agentId: String
    let message: String
    let source: String?
}

// MARK: - Permission Models

struct PermissionRequest: Identifiable, Codable, Sendable, Hashable {
    let requestId: String
    let agentId: String
    let toolName: String
    let toolInput: JSONValue?
    let message: String?
    let timeout: Int?       // Duration in ms (e.g. 120000)
    let deadline: Int?      // Unix timestamp (ms) when permission expires

    var id: String { requestId }
}

struct PermissionRequestPayload: Codable, Sendable {
    let requestId: String
    let agentId: String
    let toolName: String
    let toolInput: JSONValue?
    let message: String?
    let timeout: Int?
    let deadline: Int?
}

struct PermissionResponseRequest: Codable, Sendable {
    let requestId: String
    let decision: String    // "allow" or "deny"
}

struct PermissionResponseResponse: Codable, Sendable {
    let ok: Bool
    let requestId: String
    let decision: String
}

struct PermissionResponsePayload: Codable, Sendable {
    let requestId: String
    let decision: String
}

// MARK: - Structured Permission (spec §3.9)

struct StructuredPermissionRequest: Codable, Sendable {
    let requestId: String
    let approved: Bool
    let reason: String?
}

struct StructuredPermissionResponse: Codable, Sendable {
    let ok: Bool
    let requestId: String
    let approved: Bool
}

// MARK: - Structured Events (spec §4.3 structured:event)

struct StructuredEventPayload: Codable, Sendable {
    let agentId: String
    let event: StructuredEvent
}

struct StructuredEvent: Codable, Sendable {
    let type: String
    let timestamp: Int?
    let data: JSONValue?
}

// MARK: - WebSocket Envelope with seq (spec §4.2)

struct WSEnvelope: Codable, Sendable {
    let type: String
    let payload: JSONValue?
    let seq: Int?
    let replayed: Bool?
}

// MARK: - Replay Messages (spec §4.4)

struct ReplayRequest: Codable, Sendable {
    let type: String  // "replay"
    let since: Int
}

struct ReplayGapPayload: Codable, Sendable {
    let oldestAvailable: Int
    let lastSeq: Int
}

struct ReplayStartPayload: Codable, Sendable {
    let fromSeq: Int
    let toSeq: Int
    let count: Int
}

// MARK: - Flexible JSON type for arbitrary payloads

enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
