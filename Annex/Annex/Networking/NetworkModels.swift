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
    let canvasState: [String: SnapshotCanvasEntry]?
    let appCanvasState: SnapshotCanvasEntry?
    let plugins: [PluginSummary]?
}

/// Plugin summary from the server snapshot.
struct PluginSummary: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: String?
    let scope: String?
    let annexEnabled: Bool
}

/// Per-project canvas entry as delivered in the snapshot.
/// Contains an array of canvases and the active canvas ID.
struct SnapshotCanvasEntry: Codable, Sendable {
    let canvases: [CanvasState]
    let activeCanvasId: String?
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

// MARK: - Session History Models

enum SessionStatus: String, Codable, Sendable {
    case active
    case completed
    case error
}

struct SessionInfo: Codable, Sendable, Identifiable {
    let id: String
    let agentId: String
    let startedAt: Int? // Unix ms
    let endedAt: Int? // Unix ms
    let status: SessionStatus?
    let messageCount: Int?
    let model: String?
    let costUsd: Double?
    let inputTokens: Int?
    let outputTokens: Int?
}

struct TranscriptEntry: Codable, Sendable, Identifiable {
    let id: String
    let role: String // "user", "assistant", "tool_use", "tool_result"
    let content: String?
    let toolName: String?
    let timestamp: Int? // Unix ms
    let index: Int?
}

struct TranscriptResponse: Codable, Sendable {
    let entries: [TranscriptEntry]
    let total: Int?
    let hasMore: Bool?
}

struct SessionSummary: Codable, Sendable {
    let sessionId: String
    let summary: String?
    let filesChanged: [String]?
    let toolsUsed: [String]?
    let duration: Int? // seconds
    let model: String?
    let costUsd: Double?
    let inputTokens: Int?
    let outputTokens: Int?
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

    /// Human-readable summary of the tool input (path, command, or pattern).
    var toolInputSummary: String? {
        guard let input = toolInput else { return nil }
        switch input {
        case .object(let dict):
            if let path = dict["path"], case .string(let s) = path { return s }
            if let command = dict["command"], case .string(let s) = command {
                return String(s.prefix(120))
            }
            if let pattern = dict["pattern"], case .string(let s) = pattern { return s }
            return nil
        case .string(let s):
            return String(s.prefix(120))
        default:
            return nil
        }
    }

    /// Whether this permission has expired based on its deadline.
    var isExpired: Bool {
        guard let deadline else { return false }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return now >= deadline
    }
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

// MARK: - Canvas Models

struct CanvasTab: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct CanvasViewport: Codable, Sendable, Hashable {
    let panX: Double
    let panY: Double
    let zoom: Double
}

struct CanvasViewPosition: Codable, Sendable, Hashable {
    let x: Double
    let y: Double
}

struct CanvasViewSize: Codable, Sendable, Hashable {
    let width: Double
    let height: Double
}

enum CanvasViewType: String, Codable, Sendable {
    case agent
    case anchor
    case plugin
    case zone
}

struct CanvasView: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let type: CanvasViewType
    let position: CanvasViewPosition
    let size: CanvasViewSize
    let title: String?
    let displayName: String?
    let zIndex: Int?
    let metadata: JSONValue?

    // Agent view fields
    let agentId: String?
    let projectId: String?

    // Anchor view fields
    let label: String?
    let autoCollapse: Bool?

    // Plugin view fields
    let pluginWidgetType: String?
    let pluginId: String?

    // Zone view fields
    let themeId: String?
    let containedViewIds: [String]?

    var displayLabel: String {
        displayName ?? title ?? label ?? id
    }
}

struct CanvasState: Codable, Sendable, Identifiable, Hashable {
    let canvasId: String
    let name: String?
    let views: [CanvasView]
    let viewport: CanvasViewport
    let nextZIndex: Int?
    let zoomedViewId: String?
    let selectedViewId: String?
    let allCanvasTabs: [CanvasTab]?
    let activeCanvasId: String?

    var id: String { canvasId }

    private enum CodingKeys: String, CodingKey {
        case canvasId, name, views, viewport, nextZIndex
        case zoomedViewId, selectedViewId, allCanvasTabs, activeCanvasId
        // Server may send "id" instead of "canvasId"
        case serverId = "id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept either "canvasId" or "id"
        canvasId = (try? c.decode(String.self, forKey: .canvasId))
            ?? (try? c.decode(String.self, forKey: .serverId))
            ?? "unknown"
        name = try? c.decode(String.self, forKey: .name)
        views = (try? c.decode([CanvasView].self, forKey: .views)) ?? []
        viewport = (try? c.decode(CanvasViewport.self, forKey: .viewport))
            ?? CanvasViewport(panX: 0, panY: 0, zoom: 1)
        nextZIndex = try? c.decode(Int.self, forKey: .nextZIndex)
        zoomedViewId = try? c.decode(String.self, forKey: .zoomedViewId)
        selectedViewId = try? c.decode(String.self, forKey: .selectedViewId)
        allCanvasTabs = try? c.decode([CanvasTab].self, forKey: .allCanvasTabs)
        activeCanvasId = try? c.decode(String.self, forKey: .activeCanvasId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canvasId, forKey: .canvasId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(views, forKey: .views)
        try c.encode(viewport, forKey: .viewport)
        try c.encodeIfPresent(nextZIndex, forKey: .nextZIndex)
        try c.encodeIfPresent(zoomedViewId, forKey: .zoomedViewId)
        try c.encodeIfPresent(selectedViewId, forKey: .selectedViewId)
        try c.encodeIfPresent(allCanvasTabs, forKey: .allCanvasTabs)
        try c.encodeIfPresent(activeCanvasId, forKey: .activeCanvasId)
    }

    init(canvasId: String, name: String?, views: [CanvasView], viewport: CanvasViewport,
         nextZIndex: Int? = nil, zoomedViewId: String? = nil, selectedViewId: String? = nil,
         allCanvasTabs: [CanvasTab]? = nil, activeCanvasId: String? = nil) {
        self.canvasId = canvasId; self.name = name; self.views = views; self.viewport = viewport
        self.nextZIndex = nextZIndex; self.zoomedViewId = zoomedViewId
        self.selectedViewId = selectedViewId; self.allCanvasTabs = allCanvasTabs
        self.activeCanvasId = activeCanvasId
    }
}

struct CanvasStatePayload: Codable, Sendable {
    let projectId: String
    let state: CanvasState
}

// MARK: - File Browser Models

struct FileNode: Identifiable, Codable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let children: [FileNode]?

    var id: String { path }
}

// MARK: - Git Models

struct GitCommit: Identifiable, Codable, Sendable, Hashable {
    let hash: String
    let shortHash: String?
    let author: String
    let email: String?
    let message: String
    let timestamp: Int

    var id: String { hash }

    var shortMessage: String {
        message.components(separatedBy: .newlines).first ?? message
    }

    var displayHash: String {
        shortHash ?? String(hash.prefix(7))
    }
}

struct GitDiffFile: Identifiable, Codable, Sendable, Hashable {
    let path: String
    let status: String        // "added", "modified", "deleted", "renamed"
    let additions: Int?
    let deletions: Int?
    let patch: String?

    var id: String { path }
}

struct GitDiffResponse: Codable, Sendable {
    let files: [GitDiffFile]
    let stats: GitDiffStats?
}

struct GitDiffStats: Codable, Sendable {
    let totalAdditions: Int
    let totalDeletions: Int
    let filesChanged: Int
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
