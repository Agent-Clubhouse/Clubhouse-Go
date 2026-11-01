import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Wire shapes for create options and agent settings (`docs/mobile-control-v1.md` → Durable agents).
/// A setting the desktop leaves out reads as `never`, so the phone never offers an edit it can't make.
extension CompanionAgentOptions {
    init(json: AnnexJSON?) {
        orchestrators = json?["orchestrators"].arrayValue.compactMap { value -> CompanionOrchestratorOption? in
            guard let id = value["id"]?.string else { return nil }
            let models = value["models"].arrayValue.compactMap { model -> CompanionModelOption? in
                guard let id = model["id"]?.string else { return nil }
                return .init(id: id, label: model["label"]?.string ?? id)
            }
            return .init(id: id, displayName: value["displayName"]?.string ?? id, shortName: value["shortName"]?.string ?? id,
                         badge: value["badge"]?.string, available: value["available"]?.boolOrNil ?? true,
                         unavailableReason: value["unavailableReason"]?.string, permissions: value["permissions"].boolValue,
                         chat: value["chat"].boolValue, models: models)
        } ?? []
        personas = json?["personas"].arrayValue.compactMap { value -> CompanionPersonaOption? in
            guard let id = value["id"]?.string else { return nil }
            return .init(id: id, name: value["name"]?.string ?? id, source: value["source"]?.string ?? "")
        } ?? []
        colors = json?["colors"].arrayValue.compactMap { value -> CompanionColorOption? in
            guard let id = value["id"]?.string else { return nil }
            return .init(id: id, label: value["label"]?.string ?? id, hex: value["hex"]?.string ?? "")
        } ?? []
    }
}

extension CompanionCreateOptions {
    init(json: AnnexJSON) throws {
        guard case .object = json, !json["orchestrators"].arrayValue.isEmpty || json["defaults"] != nil else {
            throw AnnexTransportError.malformedResponse
        }
        options = CompanionAgentOptions(json: json)
        mcpCatalog = json["mcp"]?["catalog"].arrayValue.compactMap { value -> CompanionMCPOption? in
            guard let id = value["id"]?.string else { return nil }
            return .init(id: id, name: value["name"]?.string ?? id, description: value["description"]?.string)
        } ?? []
        mcpDefaults = json["mcp"]?["defaults"].arrayValue.compactMap(\.string) ?? []
        isGitRepo = json["isGitRepo"].boolValue
        suggestedName = json["suggestedName"]?.string ?? ""
        let defaults = json["defaults"]
        defaultOrchestrator = defaults?["orchestrator"]?.string ?? options.orchestrators.first?.id
        defaultColor = defaults?["color"]?.string ?? options.colors.first?.id ?? "indigo"
        defaultModel = defaults?["model"]?.string ?? "default"
        defaultUseWorktree = defaults?["useWorktree"]?.boolOrNil ?? isGitRepo
        freeAgentModeAllowed = json["freeAgentMode"]?["allowed"].boolValue ?? false
    }
}

extension CompanionAgentSettings {
    /// A settings read, or an `agent.update` result (which has no `options`; see `keepingOptions(of:)`).
    init(json: AnnexJSON) throws {
        guard let settings = json["settings"], let name = settings["name"]?["value"]?.string else { throw AnnexTransportError.malformedResponse }
        func editable(_ key: String) -> CompanionSettingEditable {
            settings[key]?["editable"]?.string.flatMap(CompanionSettingEditable.init(rawValue:)) ?? .never
        }
        func string(_ key: String) -> String? { settings[key]?["value"]?.string }
        state = json["state"]?.string ?? "sleeping"
        sleeping = json["sleeping"].boolValue
        self.name = .init(value: name, editable: editable("name"))
        color = .init(value: string("color") ?? "indigo", editable: editable("color"))
        emoji = .init(value: string("emoji"), editable: editable("emoji"))
        hasImageIcon = settings["hasImageIcon"].boolValue
        orchestrator = .init(value: string("orchestrator"), editable: editable("orchestrator"))
        resolvedOrchestrator = settings["orchestrator"]?["resolved"]?.string ?? string("orchestrator") ?? ""
        model = .init(value: string("model") ?? "default", editable: editable("model"))
        runtime = .init(value: string("runtime") ?? "default", editable: editable("runtime"))
        resolvedRuntime = settings["runtime"]?["resolved"]?.string ?? "chat"
        persona = .init(value: string("persona"), editable: editable("persona"))
        clubhouseMode = .init(value: settings["clubhouseMode"]?["value"]?.boolOrNil, editable: editable("clubhouseMode"))
        clubhouseModeProjectEnabled = settings["clubhouseMode"]?["projectEnabled"].boolValue ?? false
        // `never` on desktops that keep it for themselves; `sleeping` when the CLI has permission support and the phone may set it.
        freeAgentMode = .init(value: settings["freeAgentMode"]?["value"].boolValue ?? false, editable: editable("freeAgentMode") == .never ? .never : .sleeping)
        let idle = settings["idleSleep"]
        idleSleep = .init(value: Self.idleSleep(idle?["value"]), editable: editable("idleSleep"))
        idleSleepApplies = idle?["applies"]?.boolOrNil ?? true
        if let options = json["options"] {
            self.options = CompanionAgentOptions(json: options)
            let minutes = options["idleSleep"]?["minutes"].arrayValue.compactMap(\.integer).map(Int.init) ?? []
            idleSleepMinutes = minutes.isEmpty ? [15, 30, 60, 240] : minutes
            appIdleMinutes = options["idleSleep"]?["appMinutes"]?.integer.map(Int.init) ?? 30
        }
        if let details = json["details"], case .object = details { workspace = CompanionAgentWorkspace(json: details) }
        orchestration = CompanionOrchestration(json: json["orchestration"])
    }

    /// `"inherit"`, `"never"` or a number of minutes; anything else inherits, as the desktop's `normalizeIdleSleep`.
    static func idleSleep(_ value: AnnexJSON?) -> CompanionIdleSleep {
        switch value {
        case .string("never"): .never
        default: if let minutes = value?.int, minutes > 0 { .minutes(minutes) } else { .inherit }
        }
    }
}

extension CompanionOrchestration {
    /// The catalog's and settings route's `orchestration` (`orchestration` v1). Nil when it isn't an object; a field
    /// that's missing or of the wrong type reads as the desktop's default, and unknown fields are ignored.
    init?(json: AnnexJSON?) {
        guard let json, case .object = json else { return nil }
        func strings(_ key: String) -> [String]? {
            let values = json[key].arrayValue.compactMap(\.string)
            return values.isEmpty ? nil : values
        }
        orchestrate = json["orchestrate"]?.boolOrNil ?? false
        access = json["access"]?.string ?? "same"
        control = json["control"]?.string ?? "hands-off"
        maxHelpersCap = json["maxHelpersCap"]?.int.flatMap { $0 > 0 ? $0 : nil } ?? 20
        maxHelpers = json["maxHelpers"]?.int.flatMap { $0 > 0 ? $0 : nil } ?? min(5, maxHelpersCap)
        crossProjectHelpers = json["crossProjectHelpers"]?.boolOrNil ?? false
        connectToDispatcher = json["connectToDispatcher"]?.boolOrNil ?? false
        controls = strings("controls") ?? Self.defaultControls
        accessLevels = strings("accessLevels") ?? Self.defaultAccessLevels
        if case .object(let sources)? = json["sources"] {
            self.sources = sources.compactMapValues { $0.string.flatMap(Source.init(rawValue:)) }
        }
    }
}

extension AnnexOrchestrationPatch {
    init(_ change: CompanionOrchestrationChange) {
        func field<T>(_ value: CompanionOrchestrationChange.Field<T>?) -> Field<T>? {
            switch value {
            case .set(let v): .set(v)
            case .clear: .clear
            case nil: nil
            }
        }
        self.init(orchestrate: field(change.orchestrate), access: field(change.access), control: field(change.control), maxHelpers: field(change.maxHelpers),
                  crossProjectHelpers: field(change.crossProjectHelpers), connectToDispatcher: field(change.connectToDispatcher))
    }
}

extension CompanionAgentWorkspace {
    /// The settings route's `details` (#157). Anything missing or of the wrong type is left out.
    init(json: AnnexJSON) {
        func text(_ key: String) -> String? { json[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        branch = text("branch")
        worktreePath = text("worktreePath")
        worktree = text("worktree") ?? worktreePath
        mcpIDs = json["mcpIds"].arrayValue.compactMap(\.string)
        if let changes = json["changes"], case .object = changes {
            func count(_ key: String) -> Int? { changes[key]?.integer.map { max(0, Int($0)) } }
            self.changes = .init(available: changes["available"]?.boolOrNil ?? true, base: changes["base"]?.string, noBase: changes["noBase"].boolValue,
                                 files: count("files") ?? 0, additions: count("additions") ?? 0, deletions: count("deletions") ?? 0,
                                 ahead: count("ahead"), uncommitted: count("uncommitted"))
        }
    }
}

extension AnnexAgentUpdate {
    init(agentID: String, change: CompanionSettingsChange) {
        func clearable(_ value: CompanionSettingsChange.Clearable?) -> Clearable? {
            switch value {
            case .set(let text): .set(text)
            case .clear: .clear
            case nil: nil
            }
        }
        let idle: IdleSleep? = switch change.idleSleep {
        case .inherit: .inherit
        case .never: .never
        case .minutes(let minutes): .minutes(minutes)
        case nil: nil
        }
        self.init(agentID: agentID, name: change.name, color: change.color, emoji: clearable(change.emoji), orchestrator: change.orchestrator,
                  model: change.model, runtime: change.runtime.flatMap(Runtime.init(rawValue:)), persona: clearable(change.persona),
                  clubhouseMode: change.clubhouseMode, freeAgentMode: change.freeAgentMode, idleSleep: idle,
                  orchestration: change.orchestration.map(AnnexOrchestrationPatch.init))
    }
}

extension AnnexJSON {
    var boolOrNil: Bool? { if case .bool(let value) = self { value } else { nil } }
}
