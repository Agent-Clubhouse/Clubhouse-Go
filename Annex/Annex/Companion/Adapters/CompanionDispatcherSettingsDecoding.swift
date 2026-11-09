import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Settings > Dispatcher's wire shape (`docs/mobile-control-v1.md` → Dispatcher settings). The route and every
/// command result share it; results leave out `version` and `epoch`. Unknown fields and reasons are tolerated.
/// `editable` is `always` or `never` here: anything else reads as `never`, so the phone never offers an edit it can't make.
extension CompanionDispatcherSettings {
    init(json: AnnexJSON) throws {
        guard let agentID = json["agentId"]?.string, !agentID.isEmpty, let behavior = json["behavior"], let value = behavior["value"]?.string,
              let name = json["identity"]?["name"]?["value"]?.string else { throw AnnexTransportError.malformedResponse }
        func editable(_ field: AnnexJSON?) -> Bool { field?["editable"]?.string == "always" }
        self.agentID = agentID
        self.behavior = .init(value: value, editable: editable(behavior), choices: behavior["choices"].arrayValue.compactMap(Self.choice),
                              setsModels: behavior["setsModels"]?.boolOrNil ?? true, note: behavior["note"]?.string)
        let models = json["models"]
        self.models = .init(byHand: models?["byHand"].boolValue ?? false, editable: editable(models), note: models?["note"]?.string,
                            roles: models?["roles"].arrayValue.compactMap { role -> Role? in
                                guard let id = role["id"]?.string else { return nil }
                                let pick = role["pick"].flatMap { pick -> Pick? in
                                    guard case .object = pick else { return nil }
                                    return Pick(provider: pick["provider"]?.string, model: pick["model"]?.string,
                                                effort: pick["effort"]?.string, contextWindow: pick["contextWindow"]?.string)
                                }
                                return Role(id: id, label: role["label"]?.string ?? id, help: role["help"]?.string, pick: pick)
                            } ?? [])
        let identity = json["identity"]
        self.identity = .init(name: name, nameEditable: editable(identity?["name"]), maxNameLength: identity?["name"]?["maxLength"]?.int ?? 40,
                              color: identity?["color"]?["value"]?.string, colorEditable: editable(identity?["color"]),
                              emoji: identity?["emoji"]?["value"]?.string, emojiEditable: editable(identity?["emoji"]),
                              hasImageIcon: identity?["hasImageIcon"].boolValue ?? false)
        personality = json["personality"].flatMap { personality -> Personality? in
            guard case .object = personality else { return nil }
            return Personality(preset: personality["value"]?["preset"]?.string, text: personality["value"]?["text"]?.string ?? "",
                               editable: editable(personality), maxLength: personality["maxLength"]?.int ?? 2000,
                               presets: personality["presets"].arrayValue.compactMap { preset -> PersonalityPreset? in
                                   guard let id = preset["id"]?.string else { return nil }
                                   return .init(id: id, label: preset["label"]?.string ?? id, description: preset["description"]?.string, text: preset["text"]?.string)
                               })
        }
        usage = json["usage"].flatMap { usage -> Usage? in
            guard case .object = usage else { return nil }
            return Usage(day: usage["day"]?.string, conversations: Self.split(usage["conversations"]), background: Self.split(usage["background"]))
        }
        notHonored = Set(json["notHonored"].arrayValue.compactMap { $0["setting"]?.string })
        clearChat = .init(expectedState: json["clearChat"]?["expectedState"]?.string, applies: json["clearChat"]?["applies"]?.string)
        forgetEverything = .init(expectedState: json["forgetEverything"]?["expectedState"]?.string)
    }

    private static func choice(_ value: AnnexJSON) -> Choice? {
        guard let id = value["id"]?.string else { return nil }
        return .init(id: id, label: value["label"]?.string ?? id, description: value["description"]?.string)
    }

    private static func split(_ value: AnnexJSON?) -> UsageSplit? {
        guard case .object? = value else { return nil }
        func number(_ key: String) -> Int { value?[key]?.int ?? 0 }
        let cost: Double? = switch value?["costUsd"] { case .number(let v)?: v; case .integer(let v)?: Double(v); default: nil }
        return .init(turns: number("turns"), turnsWithoutUsage: number("turnsWithoutUsage"), input: number("input"), cachedInput: number("cachedInput"),
                     cacheWrite: number("cacheWrite"), output: number("output"), reasoning: number("reasoning"),
                     costUSD: cost, costIsEstimate: value?["costIsEstimate"].boolValue ?? false)
    }
}

extension CompanionDispatcherResetOutcome {
    init?(_ reset: CompanionDispatcherReset, result: AnnexJSON?) {
        switch reset {
        case .clearChat:
            guard let cleared = result?["cleared"]?.string, ["now", "next_start"].contains(cleared) else { return nil }
            self = .chatCleared(now: cleared == "now")
        case .forgetEverything:
            guard let removed = result?["removed"]?.int else { return nil }
            self = .forgot(removed: removed, heldNews: result?["heldNews"]?.int ?? 0)
        }
    }
}
