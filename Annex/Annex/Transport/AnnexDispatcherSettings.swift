import Foundation

/// `dispatcher.update`: Settings > Dispatcher's Behavior, name, look and personality. Only the fields set are sent.
nonisolated public struct AnnexDispatcherUpdate: Sendable, Equatable {
    /// `light`, `standard` or `thorough`.
    public var behavior: String?
    public var name: String?
    public var color: String?
    /// An emoji, or `clear` to remove it.
    public var emoji: AnnexAgentUpdate.Clearable?
    /// A preset id, the text, or both.
    public var personality: Personality?
    public struct Personality: Sendable, Equatable {
        public var preset: String?
        public var text: String?
        public init(preset: String? = nil, text: String? = nil) { self.preset = preset; self.text = text }
        var json: AnnexJSON {
            var v: [String: AnnexJSON] = [:]
            if let preset { v["preset"] = .string(preset) }
            if let text { v["text"] = .string(text) }
            return .object(v)
        }
    }
    public init(behavior: String? = nil, name: String? = nil, color: String? = nil, emoji: AnnexAgentUpdate.Clearable? = nil, personality: Personality? = nil) {
        self.behavior = behavior; self.name = name; self.color = color; self.emoji = emoji; self.personality = personality
    }
    /// The desktop refuses an update that changes nothing, and a personality with neither field.
    public var isValid: Bool {
        (behavior != nil || name != nil || color != nil || emoji != nil || personality != nil)
            && (personality.map { $0.preset != nil || $0.text != nil } ?? true)
    }
    var fields: [String: AnnexJSON] {
        var v: [String: AnnexJSON] = [:]
        if let behavior { v["behavior"] = .string(behavior) }
        if let name { v["name"] = .string(name) }
        if let color { v["color"] = .string(color) }
        if let emoji { v["emoji"] = emoji.json }
        if let personality { v["personality"] = personality.json }
        return v
    }
}

/// `dispatcher.setModels`: Choose models yourself. Either the switch, or one role's pick; never both.
nonisolated public enum AnnexDispatcherModels: Sendable, Equatable {
    /// A field of a pick: a value, or `null` for the CLI's default.
    public enum Field: Sendable, Equatable {
        case set(String), cliDefault
        var json: AnnexJSON { if case .set(let value) = self { .string(value) } else { .null } }
    }
    case byHand(Bool)
    /// `role` is `chat` or `work`. Fields left nil aren't sent.
    case pick(role: String, provider: String? = nil, model: String? = nil, effort: Field? = nil, contextWindow: Field? = nil)
    public var isValid: Bool {
        guard case .pick(let role, let provider, let model, let effort, let context) = self else { return true }
        return ["chat", "work"].contains(role) && (provider != nil || model != nil || effort != nil || context != nil)
    }
    var fields: [String: AnnexJSON] {
        switch self {
        case .byHand(let on): return ["byHand": .bool(on)]
        case .pick(let role, let provider, let model, let effort, let context):
            var v: [String: AnnexJSON] = ["role": .string(role)]
            if let provider { v["provider"] = .string(provider) }
            if let model { v["model"] = .string(model) }
            if let effort { v["effort"] = effort.json }
            if let context { v["contextWindow"] = context.json }
            return v
        }
    }
}

extension AnnexCapabilities {
    /// Settings > Dispatcher from a phone: the settings route and its four commands (`dispatcher.settings` v1).
    public var supportsDispatcherSettings: Bool {
        supportsDispatcher && (dispatcher?.settings?.version ?? 0) >= 1
            && ["dispatcher.update", "dispatcher.setModels", "dispatcher.clearChat", "dispatcher.forgetEverything"].allSatisfy(commands.contains)
    }
}
