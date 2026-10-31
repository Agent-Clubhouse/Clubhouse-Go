import Foundation

// Durable agents from the phone: the desktop's New agent page (#131) and its Details → Settings card (#132).
// Shapes follow `docs/mobile-control-v1.md` → Durable agents.

/// When a setting can change from the phone: at any time, only while the agent sleeps, or not from a phone.
nonisolated enum CompanionSettingEditable: String, Sendable, Equatable {
    case always, sleeping, never
}

/// One setting's value and when it can change.
nonisolated struct CompanionSetting<Value: Sendable & Equatable>: Sendable, Equatable {
    var value: Value
    var editable: CompanionSettingEditable
    /// Read at spawn, so it waits for the agent to sleep: the desktop's "Sleep the agent to change these".
    func isLocked(sleeping: Bool) -> Bool { editable == .sleeping && !sleeping }
    func canEdit(sleeping: Bool) -> Bool { editable == .always || (editable == .sleeping && sleeping) }
}

nonisolated struct CompanionModelOption: Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var label: String
}

/// A CLI the agent can run on ("Runs on").
nonisolated struct CompanionOrchestratorOption: Identifiable, Sendable, Equatable {
    var id: String
    var displayName: String
    var shortName: String
    var badge: String?
    /// False when the CLI isn't found. The desktop still lets you create the agent, with a warning.
    var available: Bool
    var unavailableReason: String?
    var permissions: Bool
    /// The agent can run in chat on this CLI.
    var chat: Bool
    var models: [CompanionModelOption]
    var warning: String? { available ? nil : (unavailableReason ?? "CLI not found. The agent may fail to start.") }
}

nonisolated struct CompanionPersonaOption: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var source: String
}

nonisolated struct CompanionColorOption: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var hex: String
    /// The swatch colour, from `#rrggbb`.
    var rgb: CompanionRGB? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return .init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

nonisolated struct CompanionMCPOption: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var description: String?
}

/// What both the New agent form and the settings sheet pick from.
nonisolated struct CompanionAgentOptions: Sendable, Equatable {
    var orchestrators: [CompanionOrchestratorOption] = []
    var personas: [CompanionPersonaOption] = []
    var colors: [CompanionColorOption] = []
    func orchestrator(_ id: String?) -> CompanionOrchestratorOption? { orchestrators.first { $0.id == id } }
    /// The models for a CLI, keeping a saved custom model in the list.
    func models(for orchestrator: String?, keeping current: String? = nil) -> [CompanionModelOption] {
        var models = self.orchestrator(orchestrator)?.models ?? []
        if models.isEmpty { models = [.init(id: "default", label: "Default")] }
        if let current, !models.contains(where: { $0.id == current }) { models.append(.init(id: current, label: current)) }
        return models
    }
}

/// The New agent form for one project.
nonisolated struct CompanionCreateOptions: Sendable, Equatable {
    var options: CompanionAgentOptions
    var mcpCatalog: [CompanionMCPOption] = []
    var mcpDefaults: [String] = []
    var isGitRepo = false
    var suggestedName = ""
    var defaultOrchestrator: String?
    var defaultColor = "indigo"
    var defaultModel = "default"
    var defaultUseWorktree = false
    /// `agent.create` takes `freeAgentMode` (`freeAgentMode.allowed`). Offer it only for CLIs with permission support.
    var freeAgentModeAllowed = false
}

/// An agent's own auto-sleep: follow the app's chat idle timeout, never sleep, or sleep after this many minutes idle.
nonisolated enum CompanionIdleSleep: Sendable, Equatable, Hashable {
    case inherit, never, minutes(Int)

    /// "30 min", "4 h" or "Never", as the desktop's `formatIdleMinutes`.
    static func format(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        return minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min"
    }
    /// Minutes before the agent sleeps, where 0 means never.
    func resolvedMinutes(appMinutes: Int) -> Int {
        switch self {
        case .never: 0
        case .minutes(let minutes): minutes
        case .inherit: max(0, appMinutes)
        }
    }
    /// The Settings card summary: "Sleeps after 30 min" or "Never sleeps".
    func summary(appMinutes: Int) -> String {
        let minutes = resolvedMinutes(appMinutes: appMinutes)
        return minutes > 0 ? "Sleeps after \(Self.format(minutes))" : "Never sleeps"
    }
    /// The picker's option text: "App default (30 min)", "After 30 min idle", "Never".
    func label(appMinutes: Int) -> String {
        switch self {
        case .inherit: "App default (\(Self.format(max(0, appMinutes))))"
        case .never: "Never"
        case .minutes(let minutes): "After \(Self.format(minutes)) idle"
        }
    }
    /// The line under the picker: where the value comes from.
    func source(appMinutes: Int) -> String {
        let app = Self.format(max(0, appMinutes))
        return self == .inherit ? "App default: \(app)" : "Set for this agent. App default: \(app)"
    }
    /// The choices, in the desktop's order, keeping a hand-edited value that isn't in the list.
    static func choices(minutes offered: [Int], current: CompanionIdleSleep) -> [CompanionIdleSleep] {
        var minutes = offered
        if case .minutes(let value) = current, !minutes.contains(value) { minutes.append(value) }
        return [.inherit] + minutes.sorted().map(CompanionIdleSleep.minutes) + [.never]
    }
}

/// One durable agent's settings, as the desktop's Settings card shows them.
nonisolated struct CompanionAgentSettings: Sendable, Equatable {
    /// `sleeping`, `running`, `starting`, `creating` or `failed`.
    var state: String
    /// Settings marked `sleeping` can change now.
    var sleeping: Bool
    var name: CompanionSetting<String>
    var color: CompanionSetting<String>
    var emoji: CompanionSetting<String?>
    var hasImageIcon = false
    /// Nil means the project default; `resolvedOrchestrator` is what it runs on.
    var orchestrator: CompanionSetting<String?>
    var resolvedOrchestrator: String
    var model: CompanionSetting<String>
    /// `default`, `chat` or `terminal`; `resolvedRuntime` is `chat` or `terminal`.
    var runtime: CompanionSetting<String>
    var resolvedRuntime: String
    /// Nil means the project default.
    var persona: CompanionSetting<String?>
    /// Nil when the project isn't in Clubhouse mode.
    var clubhouseMode: CompanionSetting<Bool?>
    var clubhouseModeProjectEnabled = false
    var freeAgentMode: CompanionSetting<Bool>
    var idleSleep: CompanionSetting<CompanionIdleSleep>
    /// Only chat agents idle-sleep; the value is kept either way.
    var idleSleepApplies = true
    var options = CompanionAgentOptions()
    var idleSleepMinutes: [Int] = [15, 30, 60, 240]
    var appIdleMinutes = 30
    /// Branch, worktree, MCP servers and changes for Agent details. Nil from desktops that don't send them.
    var workspace: CompanionAgentWorkspace?
    /// The Orchestrate card's policy. Nil from desktops without `orchestration` v1.
    var orchestration: CompanionOrchestration?

    /// Any setting is waiting for the agent to sleep, so the sheet shows the desktop's hint.
    var hasLockedSettings: Bool {
        [name.isLocked(sleeping: sleeping), color.isLocked(sleeping: sleeping), emoji.isLocked(sleeping: sleeping),
         orchestrator.isLocked(sleeping: sleeping), model.isLocked(sleeping: sleeping), runtime.isLocked(sleeping: sleeping),
         persona.isLocked(sleeping: sleeping), clubhouseMode.isLocked(sleeping: sleeping), freeAgentMode.isLocked(sleeping: sleeping)].contains(true)
    }
    /// The Settings card's Auto-sleep summary.
    var autoSleepSummary: String { idleSleep.value.summary(appMinutes: appIdleMinutes) }
    var personaName: String {
        guard let id = persona.value else { return "Project default" }
        return options.personas.first { $0.id == id }?.name ?? id
    }
    var orchestratorName: String {
        let id = orchestrator.value ?? resolvedOrchestrator
        return options.orchestrator(id)?.displayName ?? id
    }
    var modelLabel: String {
        options.models(for: orchestrator.value ?? resolvedOrchestrator, keeping: model.value).first { $0.id == model.value }?.label ?? model.value
    }
    static let lockedHint = "Sleep the agent to change these"

    /// An `agent.update` result has no option lists; keep the ones already on screen.
    func keepingOptions(of previous: CompanionAgentSettings?) -> CompanionAgentSettings {
        guard let previous, options.orchestrators.isEmpty, options.colors.isEmpty else { return self }
        var merged = self
        merged.options = previous.options
        merged.idleSleepMinutes = previous.idleSleepMinutes
        merged.appIdleMinutes = previous.appIdleMinutes
        merged.workspace = workspace ?? previous.workspace
        merged.orchestration = orchestration ?? previous.orchestration
        return merged
    }
}

/// The settings a phone may change, sending only what changed.
nonisolated struct CompanionSettingsChange: Sendable, Equatable {
    enum Clearable: Sendable, Equatable { case set(String), clear }
    var name: String?
    var color: String?
    var emoji: Clearable?
    var orchestrator: String?
    var model: String?
    var runtime: String?
    var persona: Clearable?
    var clubhouseMode: Bool?
    /// Only to desktops that take it (`permissions.freeAgentMode`).
    var freeAgentMode: Bool?
    var idleSleep: CompanionIdleSleep?
    /// Only to desktops that take it (`orchestration` v1).
    var orchestration: CompanionOrchestrationChange?
    var isEmpty: Bool { self == .init() || self == .init(orchestration: .init()) }
}

/// A durable agent to create, as the New agent page sends it.
nonisolated struct CompanionCreateRequest: Sendable, Equatable {
    var project: CompanionProjectTarget
    var name: String
    var color: String
    var orchestrator: String?
    var model: String?
    var persona: String?
    /// Nil leaves it to the project's agent defaults. Only sent to desktops that take it.
    var freeAgentMode: Bool? = nil
    var useWorktree: Bool?
    var mcpIDs: [String]?
    /// Nil leaves it to the persona or the default. Only sent to desktops that take it (`orchestration` v1).
    var orchestrate: Bool? = nil
    var clientCommandID: String
}

/// The agent's record exists; its worktree is still being made while `isCreating`.
nonisolated struct CompanionCreateReceipt: Sendable, Equatable {
    var target: CompanionTarget
    var isCreating: Bool
}

/// Agent names become a folder and a git branch when the agent gets its own worktree, so the phone checks
/// them as the desktop does (`agent-name.ts`).
enum CompanionAgentName {
    static let maxLength = 64

    /// Why `value` can't be an agent folder or branch name, as a sentence for the person, or nil when it can.
    static func problem(_ value: String) -> String? {
        guard !value.isEmpty else { return "Enter a name for the agent." }
        if value.count > maxLength { return "Keep the agent name to \(maxLength) characters or fewer." }
        if value.hasPrefix("-") || value.hasPrefix(".") { return "Start the agent name with a letter, digit or _." }
        if value.contains("..") { return "Remove the \"..\" from the agent name." }
        let allowed = value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        guard allowed else { return "Use only letters, digits, - and _ in the agent name." }
        if value.wholeMatch(of: /(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])/) != nil {
            return "\"\(value)\" is reserved on Windows, so choose another agent name."
        }
        return nil
    }

    /// An `adjective-animal` name, from the desktop's lists.
    static func random() -> String { "\(adjectives.randomElement()!)-\(animals.randomElement()!)" }

    private static let adjectives = [
        "swift", "brave", "calm", "bold", "keen", "wise", "fair", "true", "warm", "cool",
        "wild", "free", "glad", "kind", "sure", "rich", "deep", "soft", "loud", "bright",
        "quick", "sharp", "proud", "steady", "gentle", "clever", "mighty", "nimble", "vivid", "noble",
        "jolly", "merry", "lucky", "plucky", "witty", "crafty", "daring", "hardy", "lively", "snappy",
        "cosmic", "lunar", "solar", "rustic", "golden", "silver", "copper", "crimson", "azure", "amber",
        "silent", "patient", "earnest", "curious", "fearless", "graceful", "honest", "humble", "playful", "faithful",
        "radiant", "serene", "gallant", "valiant", "spirited", "steadfast", "cheerful", "bubbly", "dapper", "zesty",
        "fluffy", "fuzzy", "peppy", "perky", "chirpy", "bouncy", "gritty", "scrappy", "zippy", "snazzy",
        "stellar", "epic", "prime", "ultra", "mega", "hyper", "turbo", "super", "grand", "royal",
        "ancient", "mystic", "arctic", "tropic", "alpine", "coastal", "desert", "forest", "meadow", "summit",
    ]
    private static let animals = [
        "leopard", "falcon", "otter", "panda", "wolf", "eagle", "fox", "hawk", "bear", "lynx",
        "tiger", "raven", "crane", "whale", "cobra", "bison", "heron", "koala", "moose", "viper",
        "badger", "beaver", "bobcat", "condor", "coyote", "dolphin", "ferret", "gazelle", "iguana", "jackal",
        "marten", "osprey", "parrot", "pelican", "python", "rabbit", "salmon", "toucan", "walrus", "wombat",
        "alpaca", "cheetah", "corgi", "dingo", "ermine", "finch", "gecko", "hippo", "ibis", "jaguar",
        "lemur", "mantis", "newt", "ocelot", "puffin", "quail", "robin", "sloth", "stoat", "swift",
        "tapir", "urchin", "vulture", "weasel", "xerus", "yak", "zebra", "ant", "bee", "crow",
        "dove", "elk", "frog", "goat", "hare", "kiwi", "lark", "moth", "owl", "ram",
        "seal", "toad", "wasp", "wren", "crab", "deer", "duck", "gull", "mink", "mole",
        "pika", "slug", "snail", "squid", "stork", "trout", "boar", "camel", "egret", "llama",
    ]
}

/// What to tell the person when the desktop refuses `agent.create` or `agent.update`. Branches on `code`; the
/// desktop's `message` is a sentence only for the refusals it explains (invalid names, create conflicts, running).
enum CompanionAgentCommandError {
    static func message(code: String, message: String?) -> String? {
        let detail = message.flatMap { $0.isEmpty || $0 == code ? nil : $0 }
        switch code {
        case "agent_running": return detail ?? CompanionAgentSettings.lockedHint
        case "create_refused": return detail ?? "The desktop couldn't create this agent."
        case "invalid_name": return detail ?? "Choose a different agent name."
        case "invalid_color": return detail ?? "Choose one of the colours offered."
        case "free_agent_mode_not_allowed": return "Free Agent Mode can only be changed on the desktop."
        case "free_agent_mode_unavailable": return CompanionFreeAgentMode.unsupported
        case "agent_creating": return "This agent is still being set up. Try again when it's ready."
        case "orchestrator_unavailable": return "That CLI isn't enabled for this project on the desktop."
        case "runtime_unavailable": return "Chat isn't available for this agent's CLI."
        case "clubhouse_mode_unavailable": return "This project isn't in Clubhouse mode."
        case "not_git_repo": return "This project isn't a git repository, so the agent can't have its own worktree."
        case "unknown_persona": return "That persona is no longer on the desktop. Choose another."
        case "unknown_mcp": return "One of those MCP servers is no longer in the project's catalog."
        case "agent_not_found": return "This agent is no longer on the desktop."
        case "project_not_found": return "This project is no longer on the desktop."
        case "helper_request_not_found": return "This request was already answered, or what it would change has changed. Check Needs you again."
        case "project_pinned": return "Unpin this project before marking it inactive."
        case "project_state_unavailable": return "Your desktop is still setting up shared pins. Try again in a moment."
        case "finished_quick_agents_unavailable": return "Your desktop is still setting up its finished list. Try again in a moment."
        case "worktree_options_require_worktree": return "A folder or branch name needs the agent to have its own worktree."
        case "agent_already_running": return "This agent is already running."
        case "invalid_orchestration": return detail ?? "The desktop couldn't accept these orchestration settings."
        case "orchestration_has_helpers": return "This agent has helpers running. Turn orchestration off on the desktop to keep or dispose of them."
        // Chat commands (`docs/mobile-control-v1.md` → Commands).
        case "session_mismatch": return "This conversation moved to a new session. Refresh it and try again."
        case "not_chat": return "This agent isn't running in chat. Start it first."
        case "pending_request_not_found": return "This request was already answered or has expired."
        case "revert_in_progress": return "The desktop is restoring an earlier point in this conversation. Try again when it finishes."
        case "queue_removal_not_supported": return "This agent's queue can't be changed from your phone."
        case "images_not_supported": return CompanionAttachmentError.imagesNotSupported.errorDescription
        case "attachment_unavailable": return CompanionAttachmentError.attachmentUnavailable.errorDescription
        // Helper requests: the desktop's sentence when it sends one.
        case "helper_start_blocked": return detail ?? "Wake the orchestrator, then approve again."
        case "helper_start_refused": return detail ?? "The desktop couldn't start this helper."
        case "helper_check_failed": return detail ?? "The desktop couldn't check this helper. Decline, or check it again on the desktop."
        case "helper_work_at_risk": return detail ?? "This helper has work that disposing would lose. Dispose anyway to delete it."
        case "helper_work_changed": return detail ?? "What disposing would lose has changed. Review it and confirm again."
        case "helper_dispose_failed": return detail ?? "The desktop couldn't dispose this helper. Check it on the desktop."
        // Any command.
        case "invalid_command": return detail ?? "The desktop couldn't read this command. Updating Clubhouse may help."
        case "unsupported_version": return "This phone and your desktop speak different versions. Update Clubhouse on both."
        case "epoch_mismatch": return "The desktop restarted. Refresh and try again."
        case "command_conflict": return "The desktop already has a different command with this id. Refresh and try again."
        case "command_capacity": return "The desktop is busy. Try again in a moment."
        case "client_certificate_required": return "Pair this desktop again to control it from your phone."
        case "authorization_revoked": return "This phone's access to the desktop changed. Pair again to continue."
        case "command_failed": return "The desktop hit an error running this command. It may have partly run. Refresh to check."
        case "start_cancelled": return "The agent was stopped while it started. Refresh to check whether it's running."
        default:
            if code.hasPrefix("invalid_") { return detail ?? "The desktop couldn't accept these settings." }
            return CompanionChatControlError.message(code: code)
        }
    }
}
