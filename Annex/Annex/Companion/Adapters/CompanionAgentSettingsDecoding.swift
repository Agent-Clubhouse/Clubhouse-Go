import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Wire shapes for create options and agent settings (`docs/mobile-control-v1.md` → Durable agents).
/// A setting the desktop leaves out reads as `never`, so the phone never offers an edit it can't make.
/// `personas`, `persona` and `clubhouseMode` are not read: the desktop retired them (Clubhouse #2901) and keeps the keys
/// only for older phones. An older desktop that still offers them is ignored, as the current desktop line has moved on.
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
        changeStartsNewSession = settings["orchestrator"]?["changeStartsNewSession"]?.boolOrNil ?? false
        model = .init(value: string("model") ?? "default", editable: editable("model"))
        contextWindow = CompanionContextWindow(json: settings["contextWindow"])
        contextWindowReset = CompanionContextWindowReset(json: json["contextWindowReset"])
        runtime = .init(value: string("runtime") ?? "default", editable: editable("runtime"))
        resolvedRuntime = settings["runtime"]?["resolved"]?.string ?? "chat"
        // `never` on desktops that keep it for themselves; `sleeping` when the CLI has permission support and the phone may set it.
        // The Dispatcher takes it at any time, applied on its next start, as its desktop settings page does.
        let freeAgentEditable: CompanionSettingEditable = switch editable("freeAgentMode") {
        case .never: .never
        case .always where json["isDispatcher"].boolValue == true: .always
        default: .sleeping
        }
        freeAgentMode = .init(value: settings["freeAgentMode"]?["value"].boolValue ?? false, editable: freeAgentEditable)
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
        parentAgentID = json["parentAgentId"]?.string
        routing = CompanionHelperRoutingDecision(json: json["routing"])
    }

    /// `"inherit"`, `"never"` or a number of minutes; anything else inherits, as the desktop's `normalizeIdleSleep`.
    static func idleSleep(_ value: AnnexJSON?) -> CompanionIdleSleep {
        switch value {
        case .string("never"): .never
        default: if let minutes = value?.int, minutes > 0 { .minutes(minutes) } else { .inherit }
        }
    }
}

extension CompanionContextWindow {
    /// A small wire seam: no provider/model IDs, inferred capacities or locally invented choices.
    init?(json: AnnexJSON?) {
        guard let json, case .object = json,
              let rawValue = json["value"], rawValue == .null || rawValue.string?.isEmpty == false,
              let editable = json["editable"]?.string.flatMap(CompanionSettingEditable.init(rawValue:)),
              let configurable = json["configurable"]?.boolOrNil,
              case .array(let offered)? = json["choices"],
              case .array(let applies)? = json["applies"] else { return nil }
        for key in ["kind", "label", "description", "defaultLabel", "costNote", "state", "reason", "notice"] {
            if let value = json[key], value != .null, value.string == nil { return nil }
        }
        for key in ["defaultTokens", "maxTokens"] {
            if let count = json[key], count != .null, count.integer.map({ $0 > 0 }) != true { return nil }
        }
        var choices: [Choice] = []
        var seen: Set<String> = []
        for choice in offered {
            guard let id = choice["id"]?.string, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            if let label = choice["label"], label != .null, label.string == nil { return nil }
            if let tokens = choice["tokens"], tokens != .null, tokens.integer.map({ $0 > 0 }) != true { return nil }
            choices.append(.init(id: id, label: choice["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                 tokens: choice["tokens"]?.integer.flatMap { Int(exactly: $0) }))
        }
        guard applies.allSatisfy({ $0.string != nil }) else { return nil }
        func text(_ key: String) -> String? { json[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(value: rawValue.string, editable: editable, configurable: configurable,
                  kind: text("kind").flatMap(Kind.init(rawValue:)), label: text("label"), description: text("description"),
                  defaultLabel: text("defaultLabel"), choices: choices,
                  defaultTokens: json["defaultTokens"]?.integer.flatMap { Int(exactly: $0) },
                  maxTokens: json["maxTokens"]?.integer.flatMap { Int(exactly: $0) }, costNote: text("costNote"),
                  applies: applies.compactMap { $0.string.flatMap(Applies.init(rawValue:)) },
                  state: text("state").flatMap(State.init(rawValue:)), reason: text("reason"), notice: text("notice"))
    }
}

extension CompanionContextWindowReset {
    init?(json: AnnexJSON?) {
        guard let json, case .object = json else { return nil }
        for key in ["previous", "reason"] {
            if let value = json[key], value != .null, value.string == nil { return nil }
        }
        self.init(previous: json["previous"]?.string, reason: json["reason"]?.string)
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
        mcpEnabled = json["mcpEnabled"]?.boolOrNil ?? true
        mcpReportOnly = json["mcpReportOnly"]?.boolOrNil ?? false
        autoHelpers = json["autoHelpers"]?.boolOrNil
        autoHelpersEffective = json["autoHelpersEffective"]?.boolOrNil
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
                  crossProjectHelpers: field(change.crossProjectHelpers), connectToDispatcher: field(change.connectToDispatcher), autoHelpers: field(change.autoHelpers))
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
                  model: change.model, contextWindow: clearable(change.contextWindow), runtime: change.runtime.flatMap(Runtime.init(rawValue:)),
                  freeAgentMode: change.freeAgentMode, idleSleep: idle,
                  orchestration: change.orchestration.map(AnnexOrchestrationPatch.init))
    }
}

extension AnnexJSON {
    nonisolated var boolOrNil: Bool? { if case .bool(let value) = self { value } else { nil } }
}
