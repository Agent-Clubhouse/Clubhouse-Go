import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Wire shapes for `chatControls` and the chat events that change it, folded as the desktop's chat store folds them.
extension CompanionChatControls {
    /// The chat snapshot's `chatControls`. Nil for `null` (no live session) or a desktop that doesn't send it.
    init?(snapshot json: AnnexJSON?) {
        guard let json, case .object = json else { return nil }
        self.init()
        model = json["model"]?.string
        modelUnknown = json["modelUnknown"].boolValue
        effort = json["effort"]?.string
        effortIsDefault = json["effortIsDefault"].boolValue
        effortReported = json["effortReported"].boolValue
        level = json["level"]?.string.flatMap(CompanionPermissionLevel.init(rawValue:))
        models = Self.models(json["models"])
        efforts = Self.efforts(json["efforts"])
        levelNames = Self.levelNames(json["levelNames"])
        liveLevels = Self.levels(json["liveLevels"])
        modelSwitch = .init(wire: json["modelSwitch"]?.string)
        effortSwitch = .init(wire: json["effortSwitch"]?.string)
        effortDefault = json["effortDefault"].boolValue
    }

    /// A session's capabilities: the full set from `session_started` or the snapshot, or the keys `session_info` changed.
    mutating func applyCapabilities(_ caps: AnnexJSON) {
        if let value = caps["modelSwitch"]?.string { modelSwitch = .init(wire: value) }
        if let value = caps["effortSwitch"]?.string { effortSwitch = .init(wire: value) }
        if case .bool(let value)? = caps["effortDefault"] { effortDefault = value }
        if caps["liveLevels"] != nil { liveLevels = Self.levels(caps["liveLevels"]) }
    }

    /// `session_started`, `session_info`, `model_changed` and `mode_changed`. Other events change nothing here.
    mutating func apply(type: String, data: AnnexJSON) {
        switch type {
        case "session_started":
            model = data["model"]?.string ?? model; modelUnknown = false
            level = data["level"]?.string.flatMap(CompanionPermissionLevel.init(rawValue:)) ?? level
            models = []; efforts = []; levelNames = [:]; awaitingEfforts = false
            if let caps = data["capabilities"] { applyCapabilities(caps) }
        case "session_info":
            // `model: null` means the provider's default, not yet named.
            if let value = data["model"] { model = value.string; modelUnknown = value == .null }
            if data["models"] != nil { models = Self.models(data["models"]) }
            if data["efforts"] != nil { efforts = Self.efforts(data["efforts"]); awaitingEfforts = false }
            if data["levelNames"] != nil { levelNames = Self.levelNames(data["levelNames"]) }
            if let caps = data["capabilities"] { applyCapabilities(caps) }
        case "model_changed":
            guard let id = data["modelId"]?.string else { return }
            model = id; modelUnknown = false
            effort = data["effort"]?.string; effortIsDefault = data["effortIsDefault"].boolValue; effortReported = true
        case "mode_changed":
            if let value = data["level"]?.string.flatMap(CompanionPermissionLevel.init(rawValue:)) { level = value }
        default: break
        }
    }

    private static func models(_ value: AnnexJSON?) -> [CompanionChatModel] {
        var seen: Set<String> = []
        return value.arrayValue.prefix(100).compactMap { model -> CompanionChatModel? in
            guard let id = model["id"]?.string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return .init(id: id, label: model["label"]?.string ?? id, description: model["description"]?.string, costHint: model["costHint"]?.string)
        }
    }
    private static func efforts(_ value: AnnexJSON?) -> [String] {
        var seen: Set<String> = []
        return value.arrayValue.prefix(20).compactMap(\.string).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private static func levels(_ value: AnnexJSON?) -> [CompanionPermissionLevel] {
        let listed = Set(value.arrayValue.compactMap { $0.string.flatMap(CompanionPermissionLevel.init(rawValue:)) })
        return CompanionPermissionLevel.allCases.filter(listed.contains)
    }
    private static func levelNames(_ value: AnnexJSON?) -> [CompanionPermissionLevel: String] {
        guard case .object(let names)? = value else { return [:] }
        var result: [CompanionPermissionLevel: String] = [:]
        for (key, name) in names {
            if let level = CompanionPermissionLevel(rawValue: key), let name = name.string, !name.isEmpty { result[level] = name }
        }
        return result
    }
}
