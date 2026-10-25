import Foundation

/// Identity includes the host and project: desktop-local IDs are not globally unique.
struct CompanionTarget: Hashable, Codable, Sendable, Identifiable {
    var hostID: String
    var projectID: String
    var agentID: String
    var id: Self { self }
}

struct CompanionProjectTarget: Hashable, Sendable, Identifiable {
    var hostID: String
    var projectID: String
    var id: Self { self }
}

enum CompanionConnection: Equatable, Sendable {
    case offline
    case connecting
    case reconnecting
    case synchronizing
    case connected
    case failed(String)

    var canOperate: Bool { self == .connected }
    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .synchronizing: "Catching up"
        case .connected: "Connected"
        case .failed: "Connection issue"
        }
    }
    var detail: String {
        switch self {
        case .offline: "Your conversation and draft stay here. Reconnect to continue."
        case .connecting: "Connecting securely to your desktop."
        case .reconnecting: "Waiting for your desktop. Your draft is safe."
        case .synchronizing: "Refreshing the conversation before you continue."
        case .connected: "Your desktop is ready."
        case .failed(let message): message
        }
    }
}

struct CompanionHost: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var endpoint: String
    var connection: CompanionConnection
    var projects: [CompanionProject]
    var richContentAvailable = false
    var canSpawn = false
    var canRevokeSession = false
    /// The desktop's active theme colors, from its snapshot and `theme:changed`.
    var theme: CompanionDesktopTheme?
}

struct CompanionProject: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var agents: [CompanionAgent]
}

struct CompanionAgent: Identifiable, Sendable, Equatable {
    var id: CompanionTarget
    var name: String
    var subtitle: String
    var status: CompanionAgentStatus
    var model: String?
    var capabilities: CompanionCapabilities = []
}

enum CompanionAgentStatus: String, Sendable, Codable {
    case idle, working, approval, waiting, completed, failed, stopped, sleeping
    var label: String {
        switch self {
        case .idle: "Ready"
        case .working: "Working"
        case .approval: "Needs approval"
        case .waiting: "Waiting for you"
        case .completed: "Completed"
        case .failed: "Needs attention"
        case .sleeping: "Asleep"
        case .stopped: "Stopped"
        }
    }
    var symbol: String {
        switch self {
        case .idle: "circle.dotted"
        case .working: "waveform"
        case .approval: "hand.raised.fill"
        case .waiting: "questionmark.bubble.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .sleeping: "moon.zzz"
        case .stopped: "stop.circle"
        }
    }
    /// Approvals, questions and failures wait on the person holding the phone.
    var needsYou: Bool { self == .approval || self == .waiting || self == .failed }
}

struct CompanionCapabilities: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let chat = Self(rawValue: 1 << 0)
    static let steer = Self(rawValue: 1 << 1)
    static let cancel = Self(rawValue: 1 << 2)
    static let approve = Self(rawValue: 1 << 3)
    static let answer = Self(rawValue: 1 << 4)
    static let queue = Self(rawValue: 1 << 5)
    static let removeQueued = Self(rawValue: 1 << 6)
    static let wake = Self(rawValue: 1 << 7)
}

struct CompanionMessage: Identifiable, Sendable, Equatable {
    enum QueueState: String, Sendable { case queued, dispatching, delivered, failed, removed, submitted }
    enum Role: String, Sendable { case user, assistant, system }
    enum Delivery: Equatable, Sendable {
        case confirmed, sending, accepted, failed(String), uncertain(String)
        var label: String? {
            switch self {
            case .confirmed: nil
            case .sending: "Sending…"
            case .accepted: "Accepted by desktop"
            case .failed: "Not sent"
            case .uncertain: "Delivery unknown"
            }
        }
    }
    var id: String
    var role: Role
    var text: String
    var timestamp: Date?
    var isStreaming = false
    var delivery: Delivery = .confirmed
    var clientCommandID: String?
    var queueState: QueueState?
}

struct CompanionTool: Identifiable, Sendable, Equatable {
    enum State: String, Sendable { case running, completed, failed }
    var id: String
    var name: String
    var summary: String
    var output: String?
    var state: State
    var images: [CompanionContentReference] = []
}

struct CompanionApproval: Identifiable, Sendable, Equatable {
    enum Resolution: Equatable, Sendable { case pending, submitting, allowed, denied, expired, uncertain }
    var id: String
    var toolName: String
    var summary: String
    var detail: String?
    var deadline: Date?
    var resolution: Resolution = .pending
    var options: [CompanionApprovalOption] = []
    func isExpired(at date: Date) -> Bool { deadline.map { $0 <= date } ?? false }
}

struct CompanionApprovalOption: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case allowOnce, rejectOnce, cancelTurn }
    var id: String
    var label: String
    var kind: Kind
}

struct CompanionQuestion: Identifiable, Sendable, Equatable {
    struct Prompt: Identifiable, Sendable, Equatable {
        struct Option: Identifiable, Sendable, Equatable { var id: String; var label: String; var detail: String? }
        var id: String
        var text: String
        var options: [Option]
        var allowsMultiple: Bool
        var allowsFreeText: Bool
    }
    enum Resolution: Sendable, Equatable { case pending, submitting, answered, uncertain }
    var id: String
    var prompts: [Prompt]
    var resolution: Resolution = .pending
}

enum CompanionAnswer: Sendable, Equatable {
    case text(String)
    case choices([String])
}

enum CompanionTimelineItem: Identifiable, Sendable, Equatable {
    case message(CompanionMessage)
    case tool(CompanionTool)
    case approval(CompanionApproval)
    case question(CompanionQuestion)
    case notice(id: String, text: String)

    var id: String {
        switch self {
        case .message(let value): "message:\(value.id)"
        case .tool(let value): "tool:\(value.id)"
        case .approval(let value): "approval:\(value.id)"
        case .question(let value): "question:\(value.id)"
        case .notice(let id, _): "notice:\(id)"
        }
    }
}

struct CompanionConversation: Equatable, Sendable {
    var items: [CompanionTimelineItem] = []
    var isLoading = false
    var isLoaded = false
    var error: String?
    var hasEarlierMessages = false
    var lastSequence: Int?
    var requiresResync = false
    var sessionID: String?
}

struct CompanionHistory: Sendable {
    var items: [CompanionTimelineItem]
    var hasEarlierMessages = false
    var lastSequence: Int?
    var sessionID: String?
}

enum CompanionEvent: Sendable {
    case hosts([CompanionHost])
    case timeline(CompanionTarget, items: [CompanionTimelineItem], sequence: Int, reset: Bool, sessionID: String? = nil)
    case upsert(CompanionTarget, CompanionTimelineItem, sequence: Int?)
    case textDelta(CompanionTarget, messageID: String, text: String, sequence: Int?)
    case streamFinished(CompanionTarget, messageID: String, sequence: Int?)
    case resyncRequired(hostID: String)
}

struct CompanionSendRequest: Sendable {
    var target: CompanionTarget
    var text: String
    var clientCommandID: String
    var isSteering: Bool
    var queueIfBusy = false
}

struct CompanionSpawnRequest: Sendable {
    var project: CompanionProjectTarget
    var prompt: String
    var provider: String?
    var model: String?
    var clientCommandID: String
}

/// A receipt confirms desktop acceptance, not agent completion.
struct CompanionCommandReceipt: Sendable {
    var clientCommandID: String
    var agentTarget: CompanionTarget?
}

enum CompanionServiceError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case rejected(String)
    case uncertain(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .rejected(let text), .uncertain(let text): text
        }
    }
}

/// Presentation boundary. Wire decoding, credentials and reconnect policy belong to the transport adapter.
@MainActor protocol CompanionService: AnyObject {
    func events() -> AsyncStream<CompanionEvent>
    func history(for target: CompanionTarget) async throws -> CompanionHistory
    func sessions(for target: CompanionTarget) async throws -> [CompanionSessionSummary]
    func archive(for target: CompanionTarget, sessionID: String) throws -> any CompanionArchiveReading
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt
    func wake(_ target: CompanionTarget, clientCommandID: String) async throws
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt
    func reconnect(hostID: String) async
}

@MainActor extension CompanionService {
    func wake(_ target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("This desktop does not support waking this agent.")
    }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        throw CompanionServiceError.unavailable("Rich content is unavailable. Enable Rich chat content on your desktop and use a compatible Annex version.")
    }
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool {
        throw CompanionServiceError.unavailable("This desktop does not support removing queued messages.")
    }
    func sessions(for target: CompanionTarget) async throws -> [CompanionSessionSummary] {
        throw CompanionServiceError.unavailable("This desktop does not support conversation archives yet.")
    }
    func archive(for target: CompanionTarget, sessionID: String) throws -> any CompanionArchiveReading {
        throw CompanionServiceError.unavailable("This desktop does not support conversation archives yet.")
    }
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("This desktop does not support answering questions yet.")
    }
}
