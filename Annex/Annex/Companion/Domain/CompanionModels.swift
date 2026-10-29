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
        // The desktop's host words (`HostSwitcher.tsx` STATE_LABEL): still finding it, then connecting to it.
        case .connecting, .synchronizing: "Connecting…"
        case .reconnecting: "Looking for it…"
        case .connected: "Connected"
        case .failed: "Connection issue"
        }
    }
    /// The state as a sentence about one desktop, such as "Looking for Mac…".
    func sentence(hostName name: String) -> String {
        switch self {
        case .offline: "\(name) is offline"
        case .connecting, .synchronizing: "Connecting to \(name)…"
        case .reconnecting: "Looking for \(name)…"
        case .connected: "\(name) is connected"
        case .failed: "\(name) has a connection issue"
        }
    }
    var detail: String {
        switch self {
        case .offline: "Your conversation and draft stay here. Retry to continue."
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
    /// The desktop creates durable agents (`agent.create` and create options v1). Older ones offer quick agents only.
    var canCreateDurable = false
    /// The desktop reads and changes durable agents' settings (`agent.update` and agent settings v1).
    var canEditSettings = false
    var canRevokeSession = false
    /// The desktop answers "Allow always" and the other lasting options from a phone (`permissions.persistentApprovals`).
    var canAnswerPersistentApprovals = false
    /// The desktop takes Free Agent Mode from a phone (`permissions.freeAgentMode`).
    var canSetFreeAgentMode = false
    /// The desktop's active theme colors, from its snapshot and `theme:changed`.
    var theme: CompanionDesktopTheme?
    var providers: [CompanionProvider] = []
    /// Image upload limits. Nil when the desktop is too old to take images: messages are text only.
    var attachments: CompanionAttachmentLimits?
    /// The desktop lists helper starts and disposes waiting on the user, and takes Approve and Decline (helper requests v1).
    var canAnswerHelperRequests = false
    /// Helper starts and disposes orchestrators asked the user to decide, oldest first, from the desktop's snapshot.
    var helperRequests: [CompanionHelperRequest] = []
    /// The desktop offers `projectState` v1 with `project.setPinned` and `project.setInactive`.
    var canSyncProjectState = false
    /// Each project's pins, mark and idle flag from the snapshot. Nil until the desktop sends it (after its one-time migration).
    var projectState: [String: CompanionProjectState]?
    /// The desktop's idle window in days, for display. 0 is never.
    var idleDays: Int?
    /// Pins and idle projects come from the desktop. Otherwise this phone keeps its own.
    var sharesProjectState: Bool { canSyncProjectState && projectState != nil }
    /// The desktop offers `finishedQuickAgents` v1 with `quick.dismiss` and `quick.clear`.
    var canSyncFinishedQuick = false
    /// Each project's "Finished, waiting on you", newest first, from the snapshot. Nil until the desktop sends it (after its one-time migration).
    var finishedQuickAgents: [String: [CompanionFinishedRun]]?
    /// The finished list comes from the desktop. Otherwise this phone keeps its own.
    var sharesFinishedQuick: Bool { canSyncFinishedQuick && finishedQuickAgents != nil }
    /// Project and agent terminals (`terminal` v1). Nil when the desktop has none: every terminal entry point is hidden.
    var terminal: CompanionTerminalSupport?
}

/// A helper start or dispose an orchestrator asked the user to decide (the snapshot's `helperRequests`).
/// The desktop shows it under Needs you: a start on the orchestrator's row, a dispose on the helper's.
struct CompanionHelperRequest: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case start, dispose }
    /// What disposing would lose, from the desktop's checks.
    struct Dispose: Sendable, Equatable {
        var uncommittedFiles = 0
        var unpushedCommits = 0
        /// Information only: disposing never deletes a remote branch. Nil when no base branch was found.
        var unmergedCommits: Int?
        /// A check that couldn't run. The helper can't be disposed then, only declined.
        var checkError: String?
        /// The orchestrator asked to force. The desktop refuses that; only the user's own Dispose anyway counts.
        var forceRequested = false
        /// Uncommitted files or unpushed commits: approving is "Dispose anyway".
        var workAtRisk = false
        var canDispose = true
    }
    /// The desktop's request id. A dispose gets a new one when its checks change.
    var id: String
    var hostID: String
    var projectID: String
    var kind: Kind
    var requesterID: String
    var requesterName: String
    /// Nil for a start: the helper has no id until it is approved.
    var helperID: String?
    var helperName: String
    var requestedAt: Date?
    var expiresAt: Date?
    /// The desktop's Needs you line.
    var summary: String
    /// For a start: what the helper is asked to do.
    var task: String?
    var dispose: Dispose?

    /// The agent whose Needs you row shows it: the helper for a dispose, the orchestrator for a start.
    var agentTarget: CompanionTarget {
        .init(hostID: hostID, projectID: projectID, agentID: kind == .dispose ? (helperID ?? requesterID) : requesterID)
    }
    /// Stays the same when a dispose is reissued with new checks, so its error and progress stay with it.
    var slot: String { kind == .dispose ? "dispose:\(hostID):\(helperID ?? id)" : "start:\(hostID):\(id)" }
    /// Approving needs a confirmation first: a dispose deletes the helper's folder and branch.
    var approveLabel: String {
        guard kind == .dispose else { return "Approve" }
        return dispose?.workAtRisk == true ? "Dispose anyway" : "Dispose"
    }
    var canApprove: Bool { kind == .start || dispose?.canDispose == true }
}

/// The desktop's `/mobile/capabilities.attachments`.
struct CompanionAttachmentLimits: Sendable, Equatable {
    var imageTypes: [String]
    var maxImageBytes: Int
    var maxCount: Int
}

struct CompanionProject: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var agents: [CompanionAgent]
    /// The desktop's identity for the project: an `AGENT_COLORS` id, an emoji, and its icon image.
    var color: String? = nil
    var emoji: String? = nil
    var iconData: Data? = nil
}

struct CompanionAgent: Identifiable, Sendable, Equatable {
    var id: CompanionTarget
    var name: String
    var subtitle: String
    var status: CompanionAgentStatus
    var model: String?
    var capabilities: CompanionCapabilities = []
    /// `chat`, `pty` or `headless` while the agent runs; nil when the desktop doesn't say (a sleeping agent).
    var executionMode: String?
    /// The desktop's last-activity time for this agent, when it sends one.
    var lastActivity: Date?
    /// Quick agents run one task and finish; durable agents sleep and wake.
    var isQuick = false
    /// A quick agent's process has exited (the desktop's `completed`, `failed` or `cancelled`).
    var hasExited = false
    /// Its exit code, from the desktop's `agent:completed`.
    var exitCode: Int?
    /// When the current turn started, from chat events. Nil between turns.
    var turnStartedAt: Date?
    /// Context fill from the latest chat `usage` event that reported it.
    var contextUsage: CompanionContextUsage?
    /// The desktop's identity for the agent: an `AGENT_COLORS` id, an emoji, and its icon image.
    var color: String? = nil
    var emoji: String? = nil
    var iconData: Data? = nil
    /// Free Agent Mode bypasses every permission prompt, so nothing reaches Needs you. A safety signal.
    var freeAgentMode = false
    /// What the desktop says the agent is doing (`detailedStatus`), for Needs you's wording and order.
    var detail: CompanionAgentDetail?
    /// The desktop has a previous session to resume (`hasSession`). Nil when the desktop doesn't say.
    var hasSession: Bool?
    /// The snapshot's branch and CLI id, for Agent details.
    var branch: String? = nil
    var orchestrator: String? = nil
    /// What the agent's chat session reported about itself. Nil without one.
    var session: CompanionSessionFacts? = nil
    /// Model, effort and permission level, while a live session runs on a desktop that offers them. Nil hides the controls.
    var chatControls: CompanionChatControls?
    /// Only chat-runtime agents take messages from the phone. A terminal agent is driven on the desktop.
    var runsInTerminal: Bool { executionMode.map { $0 != "chat" } ?? false }
}

/// How full an agent's context window is (`usage.context`).
struct CompanionContextUsage: Sendable, Equatable {
    var used: Int
    var size: Int
    /// Rounded, capped at 100 (`chatUsage`). Nil without a window size.
    var percent: Int? { size > 0 ? min(100, Int((Double(used) / Double(size) * 100).rounded())) : nil }
}

/// The desktop's `AgentDetailedStatus`: its state (`needs_permission`, `tool_error`…), message, tool and when it began.
struct CompanionAgentDetail: Sendable, Equatable {
    var state: String?
    var message: String?
    var toolName: String?
    var since: Date?
}

/// How to wake a sleeping durable agent, as the desktop's row menu offers it.
enum CompanionWakeChoice: String, Sendable, CaseIterable, Identifiable {
    /// Resume the last session (`agent.start` with `resume: true`).
    case resume
    /// Start a fresh session (`resume: false`).
    case newSession
    /// The desktop doesn't say whether there's a session, so let it decide (`resume: true` falls back to fresh).
    case wake
    var id: Self { self }
    var resume: Bool { self != .newSession }
    var label: String {
        switch self {
        case .resume: "Wake & Resume"
        case .newSession: "Start New Session"
        case .wake: "Wake"
        }
    }
    var systemImage: String { self == .newSession ? "plus" : "sun.max" }
    /// Resume only when there's a session to resume; both when there is, as the desktop does.
    static func choices(hasSession: Bool?) -> [Self] {
        switch hasSession {
        case true?: [.resume, .newSession]
        case false?: [.newSession]
        case nil: [.wake]
        }
    }
}

/// A provider the desktop can start agents with, from its snapshot `orchestrators`.
struct CompanionProvider: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
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
    /// The running session takes images (`capabilities.images`).
    static let images = Self(rawValue: 1 << 8)
}

/// Image bytes held on the phone. Compared by identity, so timeline diffs never compare megabytes.
final class CompanionImageBytes: Sendable, Hashable {
    let data: Data
    init(_ data: Data) { self.data = data }
    static func == (lhs: CompanionImageBytes, rhs: CompanionImageBytes) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// An image ready to upload: re-encoded without metadata and within the desktop's limits.
struct CompanionImageAttachment: Identifiable, Sendable, Equatable {
    var id = UUID().uuidString
    var bytes: CompanionImageBytes
    var mimeType: String
    var width: Int
    var height: Int
}

enum CompanionImageLimits {
    /// The wire maximum for `chat.send.attachmentIds`, whatever a desktop advertises.
    static let maximumPerMessage = 10
}

/// An image in a user message. The phone keeps its own copy of what it sent; the desktop's echo adds a `mediaRef`.
struct CompanionMessageImage: Identifiable, Sendable, Equatable {
    var id: String
    var mimeType: String?
    var mediaRef: String?
    /// A file name only, never a desktop path.
    var name: String?
    var width: Int?
    var height: Int?
    var local: CompanionImageBytes?
}

struct CompanionMessage: Identifiable, Sendable, Equatable {
    enum QueueState: String, Sendable { case queued, dispatching, delivered, failed, removed, submitted }
    enum Role: String, Sendable { case user, assistant, system }
    enum Delivery: Equatable, Sendable {
        case confirmed, sending, accepted, failed(String), uncertain(String)
        /// Images go up one at a time before the message is sent.
        case uploading(completed: Int, total: Int)
        var label: String? {
            switch self {
            case .confirmed: nil
            case .sending: "Sending…"
            case .uploading(let completed, let total): total == 1 ? "Uploading image…" : "Uploading image \(min(total, completed + 1)) of \(total)…"
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
    /// The desktop's `MessageSource` for user messages: `user` (typed), `mission`, `mcp`, `annex`, …
    var source: String?
    /// The message joined the running turn instead of starting one.
    var isSteered = false

    /// The desktop's caption above a user message, such as "Mission · Steered into the running turn".
    var sourceLabel: String? {
        let origin: String? = switch source {
        case "mission": "Mission"
        case "mcp": "From another agent"
        case "shoulder_tap": "Shoulder tap"
        case "group_project": "Group project"
        case "annex": "From Annex"
        case "system": "Clubhouse"
        default: nil
        }
        let parts = [origin, isSteered ? "Steered into the running turn" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var images: [CompanionMessageImage] = []
}

struct CompanionTool: Identifiable, Sendable, Equatable {
    enum State: String, Sendable { case running, completed, failed }
    /// The desktop's `ToolKind`. Older desktops don't send one.
    enum Kind: String, Sendable {
        case read, edit, delete, move, search, execute, think, fetch
        case switchMode = "switch_mode", other
        /// The desktop's `KIND_VERBS` (`ToolBlocks.tsx`).
        var verb: String {
            switch self {
            case .read: "Read"
            case .edit: "Edit"
            case .delete: "Delete"
            case .move: "Move"
            case .search: "Search"
            case .execute: "Run"
            case .think: "Think"
            case .fetch: "Fetch"
            case .switchMode: "Mode"
            case .other: "Tool"
            }
        }
        /// Kinds that only look around, and fold into "Explored…" (`READ_ONLY_KINDS`).
        var isReadOnly: Bool { [.read, .search, .fetch, .think].contains(self) }
    }
    var id: String
    var name: String
    var summary: String
    var output: String?
    var state: State
    var images: [CompanionContentReference] = []
    var kind: Kind?
    /// The first location the tool touches, shown after its verb.
    var location: String?
    /// The tool returned a diff or terminal output, so it's worth seeing on its own.
    var hasChanges = false
    /// Waiting for your approval, not yet running.
    var awaitsApproval = false

    /// "Read", "Run"…, or nil when the desktop didn't say what kind of tool this is.
    var verb: String? { kind?.verb }
    /// What follows the verb: the file it touches, else its title (`toolTarget`).
    var target: String { location ?? name }
    /// A tool call that only looks around and didn't fail (`isExploreTool`). Images are worth seeing, so they stay out.
    var isExplore: Bool {
        guard let kind, kind.isReadOnly else { return false }
        return state != .failed && !awaitsApproval && !hasChanges && images.isEmpty
    }
}

struct CompanionApproval: Identifiable, Sendable, Equatable {
    enum Resolution: Equatable, Sendable { case pending, submitting, allowed, denied, expired, cancelled, uncertain }
    var id: String
    var toolName: String
    var summary: String
    /// The request's own title ("Run `npm test`"), when the desktop sends one.
    var title: String?
    var detail: String?
    var deadline: Date?
    var resolution: Resolution = .pending
    var options: [CompanionApprovalOption] = []
    func isExpired(at date: Date) -> Bool { deadline.map { $0 <= date } ?? false }
}

struct CompanionApprovalOption: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case allowOnce, rejectOnce, cancelTurn
        /// Lasting changes. Older desktops refuse them from a phone (`persistent_approval_not_supported`).
        case allowSession, allowAlways, rejectAlways, other
    }
    var id: String
    var label: String
    var kind: Kind
    /// What an "always" option covers, when the desktop says (`npm install:*`).
    var scope: String?
    /// A decision for this request only. Every desktop takes these from a phone.
    var isOneOff: Bool { kind == .allowOnce || kind == .rejectOnce || kind == .cancelTurn }
    /// Changes the agent's permissions for good ("Allow always"). Sent only to desktops with `permissions.persistentApprovals`.
    var isPersistent: Bool { kind == .allowSession || kind == .allowAlways || kind == .rejectAlways }
    /// Whether the phone can send it: one-off decisions always, lasting ones when the desktop takes them.
    func isAnswerable(persistentApprovals: Bool) -> Bool { isOneOff || (persistentApprovals && isPersistent) }
    /// A lasting allow is confirmed first.
    var needsConfirmation: Bool { kind == .allowAlways || kind == .allowSession }
    var allows: Bool { kind == .allowOnce || kind == .allowSession || kind == .allowAlways }
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
    enum Resolution: Sendable, Equatable { case pending, submitting, answered, cancelled, uncertain }
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
    /// The agent's `contentRoots` from the chat snapshot; empty from older desktops.
    var contentRoots = CompanionContentRoots()
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
    /// Uploaded images, in order. Part of the command: a retry with the same id sends the same ids.
    var attachmentIDs: [String] = []
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

/// Image failures with a recovery the store acts on, rather than only text to show.
enum CompanionAttachmentError: Error, LocalizedError, Equatable, Sendable {
    /// An uploaded id expired, or the desktop restarted: upload again and send as a new command.
    case attachmentUnavailable
    /// The agent's session can't take images.
    case imagesNotSupported
    /// The desktop is limiting uploads; `Retry-After` seconds when it said.
    case rateLimited(retryAfter: Int?)
    var errorDescription: String? {
        switch self {
        case .attachmentUnavailable: "The desktop no longer has these images. Try sending again."
        case .imagesNotSupported: "This agent can't take images. Send your message as text."
        case .rateLimited(let seconds): seconds.map { "The desktop is limiting image uploads. Try again in \($0) seconds." } ?? "The desktop is limiting image uploads. Try again shortly."
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
    /// Uploads one image for a later send and returns its desktop id.
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String
    func wake(_ target: CompanionTarget, resume: Bool, clientCommandID: String) async throws
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt
    func reconnect(hostID: String) async
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings
    /// `chat.setModel`. A nil effort leaves it to the desktop: a chosen effort the new model offers is kept.
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws
    /// Approve or decline a helper request. `force` approves a dispose that would lose work.
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws
    /// The project root's uncommitted files. Read-only.
    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges
    /// One uncommitted file's diff.
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff
    func setProject(_ project: CompanionProjectTarget, pinned: Bool, clientCommandID: String) async throws -> CompanionProjectState
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState
    /// Removes one run from the desktop's finished list, and returns the project's list after it.
    func dismissFinishedQuick(_ target: CompanionTarget, clientCommandID: String) async throws -> [CompanionFinishedRun]
    /// Empties a project's finished list on the desktop.
    func clearFinishedQuick(_ project: CompanionProjectTarget, clientCommandID: String) async throws -> [CompanionFinishedRun]
    /// A shell or an agent's terminal on the desktop. Opening and every message are the channel's.
    func terminal(_ scope: CompanionTerminalScope) throws -> any CompanionTerminalChannel
}

@MainActor extension CompanionService {
    func terminal(_ scope: CompanionTerminalScope) throws -> any CompanionTerminalChannel {
        throw CompanionServiceError.unavailable(CompanionTerminalAvailability.updateDesktop)
    }
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String {
        throw CompanionServiceError.unavailable("This desktop can't take images. Update Clubhouse on your desktop.")
    }
    func wake(_ target: CompanionTarget, resume: Bool, clientCommandID: String) async throws {
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
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to create durable agents from your phone.")
    }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to create durable agents from your phone.")
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.")
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.")
    }
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable(CompanionChatControlError.updateDesktop)
    }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable(CompanionChatControlError.updateDesktop)
    }
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to answer helper requests from your phone.")
    }
    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges {
        throw CompanionServiceError.unavailable("This desktop can't show its changes.")
    }
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff {
        throw CompanionServiceError.unavailable("This desktop can't show its changes.")
    }
    func setProject(_ project: CompanionProjectTarget, pinned: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share pins with your phone.")
    }
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share pins with your phone.")
    }
    func dismissFinishedQuick(_ target: CompanionTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share its finished list with your phone.")
    }
    func clearFinishedQuick(_ project: CompanionProjectTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share its finished list with your phone.")
    }
}
