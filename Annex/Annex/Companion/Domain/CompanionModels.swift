import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

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
    /// Set only after a complete catalog from this desktop. Unknown agents remain loading until then.
    var hasLoadedCatalog = false
    var richContentAvailable = false
    /// The desktop says what a chat link names and lists folders (`chatLinks` v1).
    var canResolveLinks = false
    var canSpawn = false
    /// The desktop creates durable agents (`agent.create` and create options v1). Older ones offer quick agents only.
    var canCreateDurable = false
    /// The desktop reads and changes durable agents' settings (`agent.update` and agent settings v1).
    var canEditSettings = false
    /// Whole-agent stop, distinct from interrupting a chat turn.
    var canStopAgents = false
    var canControlProvider = false
    var canRevokeSession = false
    /// The desktop answers "Allow always" and the other lasting options from a phone (`permissions.persistentApprovals`).
    var canAnswerPersistentApprovals = false
    /// The desktop takes Free Agent Mode from a phone (`permissions.freeAgentMode`).
    var canSetFreeAgentMode = false
    var canSetAccess = false
    var canSetContextWindow = false
    var helperRouting: AnnexCapabilities.HelperRouting?
    var canEditHelperPresets = false
    /// Settings > Dispatcher from the phone: Behavior, models, look, personality, usage and its two resets (`dispatcher.settings` v1).
    var canEditDispatcherSettings = false
    /// The last Settings > Dispatcher read or result. Re-read on `dispatcher:changed` and when the snapshot's Dispatcher changes; nil while it is off.
    var dispatcherSettings: CompanionDispatcherSettings?
    var helperRoutingRevision: String?
    var helperRoutingLabels: CompanionHelperRouting.Labels = [:]
    /// The desktop shows and takes agents' orchestration policy (`orchestration` v1).
    var canOrchestrate = false
    /// The desktop's active theme colors, from its snapshot and `theme:changed`.
    var theme: CompanionDesktopTheme?
    var providers: [CompanionProvider] = []
    /// Image upload limits. Nil when the desktop is too old to take images: messages are text only.
    var attachments: CompanionAttachmentLimits?
    /// The desktop lists helper starts and disposes waiting on the user, and takes Approve and Decline (helper requests v1).
    var canAnswerHelperRequests = false
    /// Helper starts and disposes orchestrators asked the user to decide, oldest first, from the desktop's snapshot.
    var helperRequests: [CompanionHelperRequest] = []
    /// The desktop lists Clubhouse grant requests and takes `grant.answer` (grant requests v1).
    var canAnswerGrantRequests = false
    /// Clubhouse permission requests waiting on the user, oldest first, from the desktop's snapshot. A Manage devices
    /// call that names this device is never listed: only the desktop or another device can answer it.
    var grantRequests: [CompanionGrantRequest] = []
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
    /// The desktop's app-wide Dispatcher (`dispatcher` v1). Nil on desktops without one. Kept out of `projects`, so it
    /// never sorts, pins, idles or spawns like a project.
    var dispatcher: CompanionDispatcher?

    /// Every listed agent, including a Dispatcher retained under the MCP-off contract.
    var allAgents: [CompanionAgent] { projects.flatMap(\.agents) + (dispatcher?.liveAgent.map { [$0] } ?? []) }
    /// The agent behind a target: in its project, or the Dispatcher.
    func agent(for target: CompanionTarget) -> CompanionAgent? {
        if let agent = dispatcher?.liveAgent, agent.id == target { return agent }
        return projects.first { $0.id == target.projectID }?.agents.first { $0.id == target }
    }
    /// The target is the Dispatcher's, by the project id the desktop gives it.
    func isDispatcher(_ target: CompanionTarget) -> Bool {
        target.hostID == id && dispatcher.map { $0.projectID == target.projectID } == true
    }
    /// A project's name for a caption: the project's, or "Dispatcher" for its agent.
    func placeName(for target: CompanionTarget) -> String? {
        isDispatcher(target) ? CompanionDispatcher.name : projects.first { $0.id == target.projectID }?.name
    }
}

/// The desktop's app-wide Dispatcher (#2533): one durable agent outside every project that coordinates orchestrators.
/// It shows as a pinned row above the projects while it's on.
struct CompanionDispatcher: Sendable, Equatable {
    static let name = "Dispatcher"
    static let defaultProjectID = "__dispatcher__"
    /// The desktop's Settings › Dispatcher notes.
    static let flagOffNote = "Turn on Dispatcher in Settings > Experimental on the desktop first."
    static let layoutOffNote = "The Dispatcher needs the new layout. Turn off Classic layout in Settings > Display & UI on the desktop, then restart Clubhouse."
    static let offNote = "Turning it off stops it. Its folder and notes are kept, so turning it back on carries on where it left off."
    /// The experimental flag and the app setting are both on.
    var enabled: Bool
    /// The experimental flag alone.
    var flagOn: Bool
    var newLayout = true
    /// The project id its agent is listed under, as the desktop sends it.
    var projectID = Self.defaultProjectID
    /// The desktop takes `dispatcher.setEnabled` from this phone.
    var canToggle = false
    /// Only the recognized MCP-off contract retains the agent and transcript while disabled.
    var mcpOff: CompanionDispatcherMCPOff?
    var isVisible: Bool { (enabled && flagOn) || mcpOff != nil }
    var statusNote: String? { mcpOff?.note }
    /// Its desktop record. MCP-off retains it after the session stops.
    var agent: CompanionAgent?
    /// Its agent while on, or retained under MCP-off.
    var liveAgent: CompanionAgent? { isVisible ? agent : nil }
    /// Use the same identity as the composer, with a feature-name fallback until its agent is available.
    var displayName: String { liveAgent?.displayName ?? Self.name }
    /// On, but its agent hasn't arrived yet.
    var isLoading: Bool { enabled && mcpOff == nil && agent == nil }
    /// Why it can't be turned on from here, or nil when it can.
    var turnOnBlocker: String? {
        if mcpOff != nil { return "MCP is off on the desktop." }
        if !flagOn { return Self.flagOffNote }
        if !newLayout { return Self.layoutOffNote }
        if !canToggle { return "Update Clubhouse on your desktop to turn the Dispatcher on from your phone." }
        return nil
    }
}

/// Additive desktop contract. Missing and unknown reasons deliberately retain legacy shutdown behaviour.
struct CompanionDispatcherMCPOff: Sendable, Equatable {
    var running: Bool
    var status: String?
    var detail: String?
    var commands: Set<String>
    var note: String { running ? "MCP is off. This session is still running." : "MCP is off on the desktop." }
    func allows(_ command: String) -> Bool { running && commands.contains(command) }

    /// All three desktop surfaces use this one tolerant decode point.
    init?(json: AnnexJSON?) {
        guard json?["offReason"]?.string == "mcp_off" else { return nil }
        running = json?["running"].boolValue == true
        status = json?["status"]?.string
        detail = json?["detail"]?.string
        commands = Set(json?["commandsWhileOff"].arrayValue.compactMap(\.string) ?? [])
    }
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
    var requestedRouting: CompanionRequestedRouting?
    var startWarning: CompanionHelperStartWarning?
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

/// A Clubhouse permission request (the snapshot's `grantRequests`): an agent's Clubhouse MCP call held for Ask first,
/// or the agent asking for a permission for itself (`request_grant`). Not a CLI permission request and not a helper request.
struct CompanionGrantRequest: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case call, grant }
    /// The answers the desktop takes for a request. Offer exactly those the request lists.
    enum Answer: String, Sendable, CaseIterable {
        case allowOnce = "allow_once", allowLasting = "allow_lasting", decline
        var label: String {
            switch self {
            case .allowOnce: "Allow once"
            case .allowLasting: "Allow"
            case .decline: "Decline"
            }
        }
        var allows: Bool { self != .decline }
    }
    /// The desktop's request id (`grant_…`).
    var id: String
    var hostID: String
    /// The asking agent's project, or the Dispatcher's project id.
    var projectID: String
    var kind: Kind
    var agentID: String
    var agentName: String
    /// What the permission lets it do, in the desktop's words ("Manage devices").
    var actionLabels: [String]
    /// Where: "the app", or a project.
    var whereLabel: String?
    /// The held call's tool, for a `call`.
    var toolName: String?
    /// The desktop's line above the request.
    var summary: String
    /// The host's plain-words line for the call, such as which device it removes.
    var detail: String?
    /// The call's arguments in full, as JSON. Allow once covers exactly these, so they are shown whole.
    var arguments: String?
    /// The agent's reason, in its own words.
    var reason: String?
    /// The desktop's line under the request: what Allow does.
    var allowEffect: String?
    var requestedAt: Date?
    var expiresAt: Date?
    /// What this request takes, in the desktop's order.
    var answers: [Answer]

    /// The agent whose Needs you row shows it.
    var agentTarget: CompanionTarget { .init(hostID: hostID, projectID: projectID, agentID: agentID) }
    /// Unique across desktops.
    var slot: String { "\(hostID):\(id)" }
    /// The Allow this request takes: once for a call, lasting for a grant.
    var allowAnswer: Answer? { answers.first(where: \.allows) }
    var canDecline: Bool { answers.contains(.decline) }
    func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
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
    var icon: CompanionIconReference? = nil
}

struct CompanionAgent: Identifiable, Sendable, Equatable {
    var id: CompanionTarget
    var name: String
    var subtitle: String
    var status: CompanionAgentStatus
    /// The durable agent's catalog lifecycle, never inferred from a chat turn ending.
    var isSleepingOnDesktop: Bool?
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
    var icon: CompanionIconReference? = nil
    /// Free Agent Mode bypasses every permission prompt, so nothing reaches Needs you. A safety signal.
    var freeAgentMode = false
    var access: CompanionPermissionLevel?
    /// The desktop's app-wide Dispatcher (`isDispatcher`). It has no project, Changes or helpers settings.
    var isDispatcher = false
    /// An unnamed Dispatcher keeps its feature label until the desktop supplies its name.
    var displayName: String {
        isDispatcher && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CompanionDispatcher.name : name
    }
    /// The Orchestrate card's policy, from the catalog. Nil from desktops without `orchestration` v1, and for quick agents.
    var orchestration: CompanionOrchestration?
    /// Durable helper identity; quick-agent parent metadata belongs to a different payload.
    var parentAgentID: String?
    var routing: CompanionHelperRoutingDecision?
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
    /// The composer's `/` menu, while a live session that reports commands runs on a desktop that sends them. Nil: no menu.
    var slashCommands: [CompanionSlashCommand]?
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
    /// The running session reports slash commands (`capabilities.slashCommands`), so the composer offers a `/` menu.
    static let slashCommands = Self(rawValue: 1 << 9)
}

/// Image bytes held on the phone. Compared by identity, so timeline diffs never compare megabytes.
final class CompanionImageBytes: Sendable, Hashable {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
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
    var subagentID: String?
    var isUserFacingAssistant: Bool { role == .assistant && subagentID == nil }
    var text: String { didSet { updateDisplay() } }
    var timestamp: Date?
    var isStreaming = false
    var delivery: Delivery = .confirmed
    var clientCommandID: String?
    var queueState: QueueState?
    /// The desktop's `MessageSource` for user messages: `user` (typed), `mission`, `mcp`, `annex`, …
    var source: String? { didSet { updateDisplay() } }
    /// The message joined the running turn instead of starting one.
    var isSteered = false
    /// Structured messages from other agents or Clubhouse. Empty on older transcripts or unusable input.
    var routed: [CompanionRoutedMessagePart] = [] { didSet { updateDisplay() } }
    /// Cached once when routing inputs change, including locally constructed preview messages.
    private(set) var display: CompanionMessageDisplay = .you("")
    var metaLabels: [String] {
        let origin: String? = switch source {
        case "mission": "Mission"
        case "shoulder_tap": "Shoulder tap"
        case "annex": "From Annex"
        default: nil
        }
        return [origin, isSteered ? "Steered into the running turn" : nil].compactMap { $0 }
    }
    private mutating func updateDisplay() { display = CompanionMessageRouting.display(source: source, text: text, routed: routed) }

    init(id: String, role: Role, text: String, timestamp: Date? = nil, isStreaming: Bool = false,
         delivery: Delivery = .confirmed, clientCommandID: String? = nil, queueState: QueueState? = nil,
         source: String? = nil, isSteered: Bool = false, routed: [CompanionRoutedMessagePart] = [], images: [CompanionMessageImage] = [], subagentID: String? = nil) {
        self.id = id; self.role = role; self.subagentID = subagentID; self.text = text; self.timestamp = timestamp; self.isStreaming = isStreaming
        self.delivery = delivery; self.clientCommandID = clientCommandID; self.queueState = queueState
        self.source = source; self.isSteered = isSteered; self.routed = routed; self.images = images
        updateDisplay()
    }
    var images: [CompanionMessageImage] = []
}

/// One desktop `RoutedMessagePart`. Each part keeps its own sender, caption and bubble.
struct CompanionRoutedMessagePart: Sendable, Equatable {
    struct Sender: Sendable, Equatable {
        var agentID: String?
        var name: String
    }
    var sender: Sender?
    var fromClubhouse = false
    var text: String

    /// Desktop `shown` strips only a leading reply marker; never parse routing tags from structured text.
    var displayText: String {
        CompanionMessageRouting.stripTaskMarker(text)
    }

    /// Desktop SentPart's words, with its source and delivery metadata.
    func caption(source: String?, isSteered: Bool = false, currentName: String? = nil) -> String {
        let name = currentName ?? sender?.name ?? (fromClubhouse ? "Clubhouse" : source == "group_project" ? "Group project" : "Another agent")
        let origin: String? = switch source {
        case "mission": "Mission"
        case "shoulder_tap": "Shoulder tap"
        default: nil
        }
        return [name, origin, isSteered ? "Steered into the running turn" : nil].compactMap { $0 }.joined(separator: " · ")
    }
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

    /// Only structured terminal content supplies this value; output prose never does.
    var exitCode: Int?
    var subagentID: String?
    var cutEvents: [CompanionEventReference] = []

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
    /// The pending permission can arrive separately from an in-progress tool update.
    var toolCallID: String? = nil
    var eventReference: CompanionEventReference?
    var isIncomplete: Bool { eventReference?.truncation != nil || summary.hasPrefix("Incomplete input:") }
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
    /// The desktop supplied a prompt this client could not read. Never answer a partial list.
    var hasUnreadablePrompts = false
    var canAnswerOnPhone: Bool {
        !hasUnreadablePrompts && !prompts.isEmpty && Set(prompts.map(\.id)).count == prompts.count
            && prompts.allSatisfy { !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var desktopAnswerMessage: String? { canAnswerOnPhone ? nil : "Answer this question on the desktop. This phone can't show all of its prompts." }
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
    /// Revision metadata is deliberately excluded from semantic equality. No old item array is retained.
    var itemsRevision = UUID()
    /// A full history replacement has its own layout boundary; streamed items do not advance it.
    var historyRevision = UUID()
    var items: [CompanionTimelineItem] = [] { didSet { itemsRevision = UUID() } }
    var isLoading = false
    var isLoaded = false
    var error: String?
    var hasEarlierMessages = false
    var lastSequence: Int?
    var requiresResync = false
    var sessionID: String?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.isLoading == rhs.isLoading && lhs.isLoaded == rhs.isLoaded
            && lhs.error == rhs.error && lhs.hasEarlierMessages == rhs.hasEarlierMessages
            && lhs.lastSequence == rhs.lastSequence && lhs.requiresResync == rhs.requiresResync && lhs.sessionID == rhs.sessionID
    }

}

struct CompanionHistory: Sendable {
    var items: [CompanionTimelineItem]
    var hasEarlierMessages = false
    var lastSequence: Int?
    var sessionID: String?
    /// This chat snapshot's `contentRoots` and strict `contentAnyPath` hint; conservative defaults on omission.
    var contentRoots = CompanionContentRoots()
    /// What the agent can do now that its chat is read (such as Wake), as the next hosts update will also say.
    /// The store applies it at once, so an action right after loading doesn't depend on when that update lands.
    var capabilities: CompanionCapabilities?
}

enum CompanionEvent: Sendable {
    case hosts([CompanionHost])
    case helperStartWarning(CompanionHelperStartWarning)
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
    /// The desktop requires a fresh, complete review before this request can be allowed.
    case incompleteRepresentation(String)
    case uncertain(String)
    /// The desktop refused the command with `wrong_machine`: the agent is on another machine.
    case wrongMachine(CompanionWrongMachine)
    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .rejected(let text), .incompleteRepresentation(let text), .uncertain(let text): text
        case .wrongMachine(let refusal): refusal.message
        }
    }
}

/// A `wrong_machine` refusal, with the machine it names and, when this phone is connected to that machine and
/// knows the agent there, the agent to open instead. Nothing is sent there on its own.
struct CompanionWrongMachine: Sendable, Equatable {
    /// The identity fingerprint the desktop named.
    var machine: String
    /// This phone's name for that machine, when it's one of its desktops.
    var machineName: String?
    var agentName: String?
    /// The agent on that machine.
    var target: CompanionTarget?
    var message: String {
        guard let machineName else {
            return "That agent is on another computer, which isn't connected to this phone. Pair it to reach the agent."
        }
        let agent = agentName ?? "That agent"
        return target == nil
            ? "\(agent) is on \(machineName). Open it from \(machineName) to continue."
            : "\(agent) is on \(machineName). Open it there to continue."
    }
}

/// One command on one desktop: command ids are unique per machine, not across the network.
struct CompanionCommandKey: Hashable, Sendable {
    var hostID: String
    var commandID: String
}

extension CompanionTarget {
    /// The agent's network-wide address, `agentId@machine` (`docs/annex-network-phone.md` §Agent addresses).
    var address: AnnexAgentAddress { .init(agentID: agentID, machine: hostID) }
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
    /// What a chat link names on the desktop (`chatLinks` v1). `href` is the link as the agent wrote it, or a listed folder entry's path.
    func resolveLink(_ href: String, target: CompanionTarget) async throws -> CompanionLinkTarget
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws
    func respond(to approvalID: String, optionID: String, reviewedDigest: String?, target: CompanionTarget, clientCommandID: String) async throws
    func fullEvent(_ reference: CompanionEventReference, target: CompanionTarget) async throws -> AnnexFullEvent
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt
    func reconnect(hostID: String) async
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt
    func helperRouting(hostID: String, projectID: String?, agentID: String?) async throws -> CompanionHelperRouting
    func updateHelperRouting(_ update: AnnexHelperRoutingUpdate, hostID: String, clientCommandID: String) async throws -> CompanionHelperRouting
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings
    /// `chat.setModel`. A nil effort leaves it to the desktop: a chosen effort the new model offers is kept.
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws
    /// Approve or decline a helper request. `force` approves a dispose that would lose work.
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws
    /// `grant.answer`: answers a Clubhouse grant request. A retry with the same `clientCommandID` replays the desktop's receipt.
    func answerGrantRequest(_ request: CompanionGrantRequest, answer: CompanionGrantRequest.Answer, clientCommandID: String) async throws
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
    /// `dispatcher.setEnabled`: turns the desktop's Dispatcher on or off.
    func setDispatcher(enabled: Bool, hostID: String, clientCommandID: String) async throws
    /// Settings > Dispatcher (`dispatcher.settings` v1): read, change, and its two confirmed resets.
    func dispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings
    func setDispatcherModels(_ models: AnnexDispatcherModels, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings
    /// Sent once with the prompt's confirmation. Throws `CompanionDispatcherSettingsError.stale` with fresh settings when it went stale.
    func resetDispatcher(_ prompt: CompanionDispatcherResetPrompt, clientCommandID: String) async throws -> CompanionDispatcherResetOutcome
    func sleepDispatcher(_ target: CompanionTarget, clientCommandID: String) async throws
    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws
    func refreshSleepState(_ target: CompanionTarget) async throws
    func sleepAndWait(_ target: CompanionTarget, clientCommandID: String) async throws
    func providerPreview(_ target: CompanionTarget, provider: String) async throws -> AnnexProviderPreview
    func changeProvider(_ target: CompanionTarget, preview: AnnexProviderPreview, clientCommandID: String) async throws -> AnnexProviderChangeResult
    func startNewProvider(_ target: CompanionTarget, provider: String, clientCommandID: String) async throws
}

@MainActor extension CompanionService {
    func fullEvent(_ reference: CompanionEventReference, target: CompanionTarget) async throws -> AnnexFullEvent {
        throw CompanionServiceError.unavailable("Reconnect to the latest desktop to review this event in full.")
    }
    func respond(to approvalID: String, optionID: String, reviewedDigest: String?, target: CompanionTarget, clientCommandID: String) async throws {
        guard reviewedDigest == nil else { throw CompanionServiceError.rejected("Fetch and review this request again on this device.") }
        try await respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }

    func sleepAndWait(_ target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Update the desktop to confirm Sleep.") }
    func providerPreview(_ target: CompanionTarget, provider: String) async throws -> AnnexProviderPreview { throw CompanionServiceError.unavailable("Update the desktop to preview a provider change.") }
    func changeProvider(_ target: CompanionTarget, preview: AnnexProviderPreview, clientCommandID: String) async throws -> AnnexProviderChangeResult { throw CompanionServiceError.unavailable("Update the desktop to save a provider change.") }
    func startNewProvider(_ target: CompanionTarget, provider: String, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Update the desktop to start with a checked provider.") }
    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("This desktop does not offer Sleep for this agent.")
    }
    func refreshSleepState(_ target: CompanionTarget) async throws {
        throw CompanionServiceError.unavailable("Reconnect to the desktop to check whether the agent is asleep.")
    }
    func sleepDispatcher(_ target: CompanionTarget, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("This desktop does not offer Sleep for the Dispatcher.")
    }

    func helperRouting(hostID: String, projectID: String?, agentID: String?) async throws -> CompanionHelperRouting {
        throw CompanionServiceError.unavailable("This desktop does not offer helper presets.")
    }
    func updateHelperRouting(_ update: AnnexHelperRoutingUpdate, hostID: String, clientCommandID: String) async throws -> CompanionHelperRouting {
        throw CompanionServiceError.unavailable("This desktop does not offer helper preset changes.")
    }
    func setDispatcher(enabled: Bool, hostID: String, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to turn the Dispatcher on from your phone.")
    }
    func dispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings {
        throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
    }
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
    }
    func setDispatcherModels(_ models: AnnexDispatcherModels, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
    }
    func resetDispatcher(_ prompt: CompanionDispatcherResetPrompt, clientCommandID: String) async throws -> CompanionDispatcherResetOutcome {
        throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
    }
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
    func resolveLink(_ href: String, target: CompanionTarget) async throws -> CompanionLinkTarget {
        throw CompanionServiceError.unavailable(CompanionContentReference.linksNeedUpdate)
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
    func answerGrantRequest(_ request: CompanionGrantRequest, answer: CompanionGrantRequest.Answer, clientCommandID: String) async throws {
        throw CompanionServiceError.unavailable(CompanionGrantRequestError.updateDesktop)
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
