import Foundation

// The desktop composer's level, model and effort pills (`Composer.tsx` `LevelPill`, `ModelPill`, `EffortPill`), from the
// chat snapshot's `chatControls` and the session's own events. See `docs/mobile-control-v1.md` → Chat controls.

/// Clubhouse's five-level permission ladder, lowest first. Each driver maps these to its own modes (`levelNames`).
nonisolated enum CompanionPermissionLevel: String, CaseIterable, Sendable, Comparable {
    case plan, ask, autoEdit = "auto_edit", auto, fullAccess = "full_access"

    /// The desktop's `PERMISSION_LEVEL_LABELS`.
    var label: String {
        switch self {
        case .plan: "Plan"
        case .ask: "Ask first"
        case .autoEdit: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }
    /// The desktop's `LEVEL_DESCRIPTIONS`.
    var detail: String {
        switch self {
        case .plan: "Reads and plans, changes nothing"
        case .ask: "Asks before edits and commands"
        case .autoEdit: "Edits files, asks before commands"
        case .auto: "Decides what needs approval"
        case .fullAccess: "No prompts"
        }
    }
    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .ask: "hand.raised"
        case .autoEdit: "pencil"
        case .auto: "sparkles"
        case .fullAccess: "exclamationmark.shield"
        }
    }
    /// Auto and Full access stop asking first, so the phone confirms a move up to them.
    func needsConfirmation(from current: Self) -> Bool { self > current && self >= .auto }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// When a model or effort change takes effect (`ChatCapabilities.modelSwitch` / `effortSwitch`).
nonisolated enum CompanionSwitchTiming: String, Sendable {
    case live, perTurn = "per_turn", restart, none
    init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .none }
    fileprivate var phrase: String? {
        switch self {
        case .perTurn: "from the next message"
        case .restart: "the next time the agent starts"
        case .live, .none: nil
        }
    }
}

/// A model the session can switch to (`ChatModelOption`).
nonisolated struct CompanionChatModel: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var description: String?
    var costHint: String?
}

/// What to send as the effort with `chat.setModel`.
nonisolated enum CompanionEffortChoice: Sendable, Equatable {
    case set(String)
    /// The provider's own default; only offered with `effortDefault`.
    case providerDefault
}

/// A live session's model, effort and level, and what the phone may switch them to.
nonisolated struct CompanionChatControls: Sendable, Equatable {
    var model: String?
    /// The session runs the provider's default model and hasn't named it yet ("Default model").
    var modelUnknown = false
    var effort: String?
    /// `effort` is the level the provider picked, not one chosen in the session.
    var effortIsDefault = false
    /// False until the session reports its effort: the effort chip waits rather than flashing "Default effort".
    var effortReported = false
    var level: CompanionPermissionLevel?
    var models: [CompanionChatModel] = []
    /// The current model's efforts.
    var efforts: [String] = []
    /// The provider's own name for each level, shown under Clubhouse's.
    var levelNames: [CompanionPermissionLevel: String] = [:]
    var liveLevels: [CompanionPermissionLevel] = []
    var modelSwitch: CompanionSwitchTiming = .none
    var effortSwitch: CompanionSwitchTiming = .none
    var effortDefault = false
    /// The model changed from the phone and the new model's efforts haven't arrived (`session_info.efforts`) yet.
    var awaitingEfforts = false

    /// A null level reads as Ask first, as on the desktop.
    var currentLevel: CompanionPermissionLevel { level ?? .ask }
    /// The current level plus the live ones, in ladder order. The current level stays listed even if it can't be re-entered.
    var levels: [CompanionPermissionLevel] {
        CompanionPermissionLevel.allCases.filter { $0 == currentLevel || liveLevels.contains($0) }
    }
    var canChangeLevel: Bool { levels.contains { $0 != currentLevel } }

    var showsModelMenu: Bool { !models.isEmpty && modelSwitch != .none }
    /// The efforts to offer: none while a new model's list is on its way.
    var offeredEfforts: [String] { awaitingEfforts ? [] : efforts }
    var showsEffortMenu: Bool { !offeredEfforts.isEmpty && effortSwitch != .none && model != nil }
    /// Hidden until the session reports its effort, and when the model has none.
    var showsEffortChip: Bool { effortReported && !awaitingEfforts && (!efforts.isEmpty || effort != nil) }

    /// The model chip: its listed name, the id, or "Default model" while the provider hasn't named it. Nil hides the chip.
    var modelLabel: String? {
        if let model { return models.first { $0.id == model }?.label ?? model }
        return modelUnknown ? "Default model" : nil
    }
    /// "High effort", "High effort (default)" or "Default effort".
    var effortLabel: String {
        guard let effort else { return "Default effort" }
        return "\(Self.effortWord(effort)) effort\(effortIsDefault ? " (default)" : "")"
    }
    /// The "Default" row is checked while the provider's default applies.
    var isOnDefaultEffort: Bool { effort == nil || effortIsDefault }
    /// The checked effort: none while on the default and a Default row is offered, else the level that applies.
    var chosenEffort: String? { isOnDefaultEffort && effortDefault ? nil : effort }
    /// Switching model keeps a chosen effort the list still offers; a default one follows the new model's default.
    var keptEffort: CompanionEffortChoice? {
        guard let effort, !effortIsDefault, efforts.contains(effort) else { return nil }
        return .set(effort)
    }
    /// "Applies from the next message.", as under the desktop's menus. Nil when changes apply at once.
    var switchNote: String? { Self.switchNote(model: modelSwitch, effort: effortSwitch) }

    /// Sentence case, as the desktop's `effortWord`: "xhigh" is "Extra high"; others are capitalised.
    static func effortWord(_ effort: String) -> String {
        if effort == "xhigh" { return "Extra high" }
        return effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// The desktop's `switchNote` (`shared/chat/capabilities.ts`): one sentence when both apply alike.
    static func switchNote(model: CompanionSwitchTiming, effort: CompanionSwitchTiming) -> String? {
        let modelPhrase = model.phrase, effortPhrase = effort.phrase
        if model == effort || effort == .none { return modelPhrase.map { "Applies \($0)." } }
        if model == .none { return effortPhrase.map { "Effort applies \($0)." } }
        guard modelPhrase != nil || effortPhrase != nil else { return nil }
        let parts = [modelPhrase.map { "Model changes apply \($0)" } ?? "Model changes apply now",
                     effortPhrase.map { "effort changes \($0)" } ?? "effort changes now"]
        return parts.joined(separator: "; ") + "."
    }
}

/// What to tell the person when the desktop refuses a chat control or a permission command. Branches on `code`.
enum CompanionChatControlError {
    static let updateDesktop = "Update Clubhouse on your desktop to change the model and permissions from your phone."
    static func message(code: String) -> String? {
        switch code {
        case "model_switch_not_supported": "This agent can't change model mid-session."
        case "unknown_model": "That model isn't offered for this session any more."
        case "effort_switch_not_supported": "This agent can't change effort mid-session."
        case "effort_default_not_supported": "This agent can't go back to the default effort."
        case "unknown_effort": "That effort isn't offered for this model."
        case "level_not_live": "This agent can't switch to that permission level mid-session."
        case "level_switch_not_supported": "This agent can't change permission level mid-session."
        case "persistent_approval_not_supported": "Choose this on your desktop. It doesn't take lasting approvals from a phone."
        default: nil
        }
    }
}

/// The desktop's Free Agent Mode copy, shared by the New agent form and the settings sheet.
enum CompanionFreeAgentMode {
    static let title = "Free Agent Mode"
    static let help = "Skips every permission prompt. Off unless you trust this agent with the project."
    static let unsupported = "This agent's CLI sets its own permissions, so Free Agent Mode isn't supported."
    static let confirmTitle = "Turn on Free Agent Mode?"
}
