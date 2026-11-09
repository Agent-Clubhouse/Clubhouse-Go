import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

extension CompanionHelperRouting {
    init(json: AnnexJSON) throws {
        guard let revision = json["revision"]?.string, !revision.isEmpty,
              case .object(let providers)? = json["providers"], case .object(let labels)? = json["labels"] else {
            throw AnnexTransportError.malformedResponse
        }
        self.revision = revision
        self.labels = labels.compactMapValues { family in
            guard case .object(let codes) = family else { return nil }
            return codes.compactMapValues { $0.string }
        }
        self.providers = providers.compactMapValues { raw in
            guard case .object = raw else { return nil }
            var cells: [String: Cell] = [:]
            if case .object(let values)? = raw["cells"] {
                cells = values.compactMapValues { cell in
                    guard let source = cell["source"]?.string, let state = cell["state"]?.string else { return nil }
                    return Cell(effective: .init(json: cell["effective"]), custom: .init(json: cell["custom"]), builtin: .init(json: cell["builtin"]),
                                source: source, state: state, staleReason: cell["staleReason"]?.string, fallback: cell["fallback"]?.string,
                                editable: cell["editable"].boolValue, follows: cell["follows"]?.string)
                }
            }
            let models = raw["choices"]?["models"].arrayValue.compactMap { value -> Model? in
                guard let id = value["id"]?.string, !id.isEmpty, id != "default", id != "auto" else { return nil }
                return .init(id: id, label: value["label"]?.string ?? id, efforts: value["efforts"].arrayValue.compactMap(\.string))
            }
            return Provider(autoEligible: raw["autoEligible"].boolValue, autoCandidate: raw["autoCandidate"]?.boolOrNil ?? raw["autoEligible"].boolValue, reason: raw["reason"]?.string,
                            choicesSource: raw["choices"]?["source"]?.string, choicesAsOf: raw["choices"]?["asOf"]?.string,
                            models: models ?? [], cells: cells, quota: CompanionHelperQuota(json: raw["quota"]))
        }
        auto = CompanionHelperAuto(json: json["auto"])
        serverTime = json["serverTime"].flatMap(CompanionLiveService.date(from:))
        if let usable = json["agent"]?["usable"]?.boolOrNil { agent = .init(usable: usable, reason: json["agent"]?["reason"]?.string) }
    }
}
extension CompanionHelperRouting.Selection {
    init?(json: AnnexJSON?) {
        guard let model = json?["model"]?.string, !model.isEmpty else { return nil }
        self.init(model: model, effort: json?["effort"]?.string)
    }
}
extension CompanionRequestedRouting {
    init?(json: AnnexJSON?) {
        guard let json, case .object = json else { return nil }
        self.init(provider: json["provider"]?.string, model: json["model"]?.string, effort: json["effort"]?.string, difficulty: json["difficulty"]?.string)
        if summary.isEmpty { return nil }
    }
}
extension CompanionHelperRoutingDecision {
    init?(json: AnnexJSON?) {
        guard let json, let mode = json["mode"]?.string, let reason = json["reason"]?.string,
              let selection = CompanionRequestedRouting(json: json["resolved"] ?? json) else { return nil }
        self.init(mode: mode, selection: selection, reason: reason, fallback: json["fallback"]?.string,
                  summary: json["display"]?["summary"]?.string, displayReason: json["display"]?["reason"]?.string,
                  displayFallback: json["display"]?["fallback"]?.string,
                  decidedAt: json["decidedAt"].flatMap(CompanionLiveService.date(from:)), balanced: json["balanced"].boolValue,
                  warning: CompanionHelperStartWarning(json: json["warning"]), displayWarning: json["display"]?["warning"]?.string)
        if case .object(let load)? = json["load"] { self.load = load.compactMapValues(\.int) }
        if case .object(let quota)? = json["quota"] { self.quota = quota.compactMapValues { CompanionHelperQuota(json: $0) } }
        if case .object(let skipped)? = json["skipped"] { self.skipped = skipped.compactMapValues(\.string) }
    }
}
