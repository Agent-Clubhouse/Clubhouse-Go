import Foundation

/// Settings > Dispatcher, as the desktop sends it (`GET /api/v1/mobile/dispatcher/settings`, Clubhouse #3206).
/// Labels, descriptions, help and notes are the desktop's words and are drawn as sent.
nonisolated struct CompanionDispatcherSettings: Sendable, Equatable {
    struct Choice: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var description: String?
    }
    /// Light, Standard or Thorough. Saved at once.
    struct Behavior: Sendable, Equatable {
        var value: String
        var editable = true
        var choices: [Choice] = []
        /// False while the models are chosen by hand: then Behavior only sets how often it checks in.
        var setsModels = true
        /// The line to show under the field.
        var note: String?
        var selected: Choice? { choices.first { $0.id == value } }
    }
    /// One role's model when they're chosen by hand. Nil or `default` means the CLI's own.
    struct Pick: Sendable, Equatable {
        var provider: String?
        var model: String?
        var effort: String?
        var contextWindow: String?
    }
    struct Role: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var help: String?
        /// Nil before Choose models yourself was first turned on.
        var pick: Pick?
    }
    /// Choose models yourself.
    struct Models: Sendable, Equatable {
        var byHand = false
        var editable = true
        var note: String?
        var roles: [Role] = []
    }
    struct Identity: Sendable, Equatable {
        var name: String
        var nameEditable = true
        var maxNameLength = 40
        var color: String?
        var colorEditable = true
        var emoji: String?
        var emojiEditable = true
        /// A phone can't set an image; setting an emoji replaces it.
        var hasImageIcon = false
    }
    struct PersonalityPreset: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var description: String?
        /// Nil for Custom.
        var text: String?
    }
    /// What it's told about how to sound. Read when a session starts.
    struct Personality: Sendable, Equatable {
        var preset: String?
        var text: String
        var editable = true
        var maxLength = 2000
        var presets: [PersonalityPreset] = []
        var selected: PersonalityPreset? { presets.first { $0.id == preset } }
    }
    /// One half of today's usage.
    struct UsageSplit: Sendable, Equatable {
        var turns = 0
        var turnsWithoutUsage = 0
        var input = 0
        var cachedInput = 0
        var cacheWrite = 0
        var output = 0
        var reasoning = 0
        var costUSD: Double?
        var costIsEstimate = false
        var tokens: Int { input + output + reasoning }
    }
    struct Usage: Sendable, Equatable {
        var day: String?
        var conversations: UsageSplit?
        var background: UsageSplit?
    }
    /// A reset's confirmation: opaque, bound to this phone and action, and stale once what it would remove changes.
    struct Confirmation: Sendable, Equatable {
        var expectedState: String?
        /// Clear chat: `now` while its chat runs, `next_start` while it sleeps.
        var applies: String?
    }

    var agentID: String
    var behavior: Behavior
    var models: Models
    var identity: Identity
    var personality: Personality?
    var usage: Usage?
    /// Rows of its raw agent settings that Settings > Dispatcher doesn't offer, to hide.
    var notHonored: Set<String> = []
    var clearChat: Confirmation
    var forgetEverything: Confirmation

    /// The desktop's labels for the usage split.
    static let conversationsLabel = "Conversations today"
    static let backgroundLabel = "Background work today"
    static let noUsage = "None yet"
    static let updateDesktop = "Update Clubhouse on your desktop to change the Dispatcher's settings from your phone."
}

/// The Dispatcher's two resets. Each is confirmed on its own, and never retried without asking again.
nonisolated enum CompanionDispatcherReset: String, Sendable, Equatable, Identifiable {
    case clearChat, forgetEverything
    var id: String { rawValue }
    var title: String { self == .clearChat ? "Clear chat?" : "Forget everything?" }
    var action: String { self == .clearChat ? "Clear chat" : "Forget everything" }
    /// The desktop's own words for what goes and what stays.
    func message(name: String) -> String {
        switch self {
        case .clearChat:
            "The conversation starts over. \(name) still remembers what you decided and who is doing what, and your agents, connections and Actions stay as they are."
        case .forgetEverything:
            "\(name) forgets its notes on your agents and your work, its timeline, and news waiting for the next check-in. This can’t be undone. Your agents, connections, Actions and its chat stay."
        }
    }
    func confirmation(in settings: CompanionDispatcherSettings) -> CompanionDispatcherSettings.Confirmation {
        self == .clearChat ? settings.clearChat : settings.forgetEverything
    }
}

/// A reset waiting on the person: what it will remove, and the confirmation it was read with.
nonisolated struct CompanionDispatcherResetPrompt: Sendable, Equatable, Identifiable {
    var reset: CompanionDispatcherReset
    var hostID: String
    var expectedState: String
    var name: String
    var applies: String?
    /// Set when an earlier confirmation went stale: what changed since the person was asked.
    var changed: String?
    var id: String { "\(hostID)|\(reset.rawValue)|\(expectedState)" }
    var title: String { reset.title }
    var message: String {
        var text = reset.message(name: name)
        if reset == .clearChat, applies == "next_start" { text += " It starts over the next time it wakes." }
        if let changed { text = "\(changed)\n\n\(text)" }
        return text
    }

    init?(_ reset: CompanionDispatcherReset, settings: CompanionDispatcherSettings, hostID: String, changed: String? = nil) {
        guard let state = reset.confirmation(in: settings).expectedState, !state.isEmpty else { return nil }
        self.reset = reset; self.hostID = hostID; self.expectedState = state
        name = settings.identity.name; applies = reset.confirmation(in: settings).applies; self.changed = changed
    }

    /// What a stale confirmation means to the person, from the settings it was asked with and the fresh ones.
    static func changes(_ reset: CompanionDispatcherReset, from old: CompanionDispatcherSettings?, to new: CompanionDispatcherSettings) -> String {
        var parts: [String] = []
        if let old, old.identity.name != new.identity.name { parts.append("It's now called \(new.identity.name).") }
        switch reset {
        case .clearChat:
            // Only a change it can see: without the earlier settings, it doesn't know whether the chat woke or slept.
            let before = old?.clearChat.applies, after = new.clearChat.applies
            if let before, before != after, after == "now" { parts.append("Its chat woke up, so it would start over at once.") }
            else if let before, before != after, after == "next_start" { parts.append("Its chat went to sleep, so it would start over when it next wakes.") }
            else { parts.append("Its conversation changed since you were asked.") }
        case .forgetEverything:
            parts.append("Its memory changed since you were asked, as it does while it works.")
        }
        return (["This changed since you were asked."] + parts + ["Check again and confirm."]).joined(separator: " ")
    }
}

/// What a confirmed reset did.
nonisolated enum CompanionDispatcherResetOutcome: Sendable, Equatable {
    /// `now`, or `next_start` while its chat sleeps.
    case chatCleared(now: Bool)
    case forgot(removed: Int, heldNews: Int)
    var message: String {
        switch self {
        case .chatCleared(let now): now ? "Its conversation started over." : "Its conversation starts over the next time it wakes."
        case .forgot(let removed, let news):
            news > 0 ? "Its memory was cleared (\(removed) removed, \(news) held news dropped)." : "Its memory was cleared."
        }
    }
}

nonisolated enum CompanionDispatcherSettingsError: LocalizedError, Equatable {
    /// The confirmation went stale. Nothing happened; the fresh settings are attached so the person can be asked again.
    case stale(CompanionDispatcherSettings)
    var errorDescription: String? { "This changed since you were asked. Check again and confirm." }
}
