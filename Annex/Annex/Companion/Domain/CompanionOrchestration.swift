import Foundation

// A durable agent's orchestration policy: the desktop's Orchestrate card in Agent details and its Helpers settings
// (`helper-model.ts`, `OrchestrationFields.tsx`). Shapes follow `docs/mobile-control-v1.md` → Orchestration.

/// Whether an agent may start and manage helper agents, what access its helpers get, how much you're asked,
/// and how many helpers it may run at once. Each field comes from the agent, its persona, or the default.
nonisolated struct CompanionOrchestration: Sendable, Equatable {
    /// Where a field's value comes from. Only `agent` is set on the agent itself, so only it can be cleared.
    enum Source: String, Sendable, Equatable { case agent, persona, `default` }

    /// "Let this agent orchestrate".
    var orchestrate = false
    /// "Helpers get": `same` as the orchestrator, or a launch access level.
    var access = "same"
    /// "Control": `hands-off`, `ask-before-start` or `ask-everything`.
    var control = "hands-off"
    /// "Helpers at once", 1 to `maxHelpersCap`.
    var maxHelpers = 5
    /// The app-wide helper limit, so the most "Helpers at once" can be.
    var maxHelpersCap = 20
    /// "Cross-project helpers": helpers may be started in other projects. False from desktops that don't send it.
    var crossProjectHelpers = false
    /// "Connect to Dispatcher": the Dispatcher may message this agent and get its reports.
    var connectToDispatcher = false
    var controls = CompanionOrchestration.defaultControls
    var accessLevels = CompanionOrchestration.defaultAccessLevels
    var sources: [String: Source] = [:]

    static let defaultControls = ["hands-off", "ask-before-start", "ask-everything"]
    static let defaultAccessLevels = ["same", "standard", "auto", "bypass"]

    /// The access levels in the words the chat level menu uses, as the desktop's `ACCESS_LEVEL_LABELS`.
    static func accessLabel(_ access: String, agentName: String) -> String {
        switch access {
        case "same": "Same as \(agentName)"
        case "standard": "Ask first"
        case "auto": "Auto"
        case "bypass": "Full access"
        default: access
        }
    }
    /// The desktop's `CONTROL_LABELS`.
    static func controlLabel(_ control: String) -> String {
        switch control {
        case "hands-off": "Hands-off"
        case "ask-before-start": "Ask before starting"
        case "ask-everything": "Ask for everything"
        default: control
        }
    }
    /// The desktop's `controlHelp`.
    static func controlHelp(_ control: String, agentName: String) -> String? {
        switch control {
        case "hands-off": "Helpers start and are disposed without asking you. \(agentName) can still ask when it judges it should."
        case "ask-before-start": "New helpers wait for your approval in \(agentName)’s Helpers card. The sidebar shows when one is waiting."
        case "ask-everything": "Starting a helper and every dispose come to you."
        default: nil
        }
    }
    static func offHelp(agentName: String) -> String {
        "Turn this on to give \(agentName) the tools to start, message and dispose of helper agents."
    }
    static func accessNote(agentName: String) -> String { "Never more than \(agentName)’s level when a helper starts." }
    static func nextStartNote(agentName: String) -> String { "The helper tools appear the next time \(agentName) starts." }
    /// The desktop's `CROSS_PROJECT_HELP` and `DISPATCHER_HELP` (`OrchestrationFields.tsx`).
    static let crossProjectHelp = "Let this agent start helpers in other projects."
    static let dispatcherHelp = "Let the Dispatcher message this agent and get its reports."

    /// The Orchestrate card's one line: "off", or "hands-off · up to 5".
    var summary: String { orchestrate ? "\(Self.controlLabel(control).lowercased()) · up to \(maxHelpers)" : "off" }

    /// The access choices, keeping a saved value the desktop no longer lists.
    var accessChoices: [String] { accessLevels.contains(access) ? accessLevels : accessLevels + [access] }
    var controlChoices: [String] { controls.contains(control) ? controls : controls + [control] }
    /// "Helpers at once" never goes above the cap, but a saved value over it still shows.
    var maxHelpersRange: ClosedRange<Int> { 1...max(1, maxHelpersCap, maxHelpers) }
}

/// The orchestration fields a phone changes, sending only what changed. `clear` goes back to the persona's value or the default.
nonisolated struct CompanionOrchestrationChange: Sendable, Equatable {
    enum Field<Value: Sendable & Equatable>: Sendable, Equatable { case set(Value), clear }
    var orchestrate: Field<Bool>?
    var access: Field<String>?
    var control: Field<String>?
    var maxHelpers: Field<Int>?
    var crossProjectHelpers: Field<Bool>?
    var connectToDispatcher: Field<Bool>?
    var isEmpty: Bool { self == .init() }

    /// The policy after this change, for showing it before the desktop answers. A cleared field keeps its value.
    func applied(to policy: CompanionOrchestration) -> CompanionOrchestration {
        var next = policy
        if case .set(let value)? = orchestrate { next.orchestrate = value; next.sources["orchestrate"] = .agent }
        if case .set(let value)? = access { next.access = value; next.sources["access"] = .agent }
        if case .set(let value)? = control { next.control = value; next.sources["control"] = .agent }
        if case .set(let value)? = maxHelpers { next.maxHelpers = value; next.sources["maxHelpers"] = .agent }
        if case .set(let value)? = crossProjectHelpers { next.crossProjectHelpers = value; next.sources["crossProjectHelpers"] = .agent }
        if case .set(let value)? = connectToDispatcher { next.connectToDispatcher = value; next.sources["connectToDispatcher"] = .agent }
        return next
    }
}
