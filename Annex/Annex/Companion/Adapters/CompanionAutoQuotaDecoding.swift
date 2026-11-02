import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

extension CompanionHelperAuto.Value {
    nonisolated init?(json: AnnexJSON?) {
        switch json {
        case .bool(let value)?: self = .enabled(value)
        case .string("off")?: self = .off
        case .null?: self = .inherit
        default: return nil
        }
    }
}
extension CompanionHelperAuto {
    nonisolated init?(json: AnnexJSON?) {
        guard let json, let effective = json["effective"]?.boolOrNil, let source = json["source"]?.string,
              case .object(let scopes)? = json["scopes"] else { return nil }
        self.init(effective: effective, source: source, reason: json["reason"]?.string, scopes: scopes.compactMapValues { raw in
            guard let value = Value(json: raw["value"]) else { return nil }
            return .init(value: value, editable: raw["editable"].boolValue, choices: raw["choices"].arrayValue.compactMap { Value(json: $0) })
        })
    }
}
extension CompanionHelperQuota.Window {
    nonisolated init?(json: AnnexJSON?) {
        guard let json, case .object = json else { return nil }
        let percent: Double? = switch json["usedPercent"] { case .integer(let value)?: Double(value); case .number(let value)?: value; default: nil }
        self.init(usedPercent: percent.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100 ? $0 : nil }, resetsAt: json["resetsAt"].flatMap(CompanionLiveService.date(from:)))
    }
}
extension CompanionHelperQuota {
    nonisolated init?(json: AnnexJSON?) {
        guard let json, let state = json["state"]?.string else { return nil }
        let delay: Double? = switch json["refreshAfterSeconds"] { case .integer(let value)?: Double(value); case .number(let value)?: value; default: nil }
        self.init(state: state, unknownReason: json["unknownReason"]?.string, asOf: json["asOf"].flatMap(CompanionLiveService.date(from:)),
                  limitingWindow: json["limitingWindow"]?.string, resetsAt: json["resetsAt"].flatMap(CompanionLiveService.date(from:)),
                  weekly: .init(json: json["weekly"]), fiveHour: .init(json: json["fiveHour"]),
                  unreadableWindows: json["unreadableWindows"].arrayValue.compactMap(\.string),
                  modelWindows: json["modelWindows"].arrayValue.compactMap { raw in
                      guard let name = raw["name"]?.string, let window = Window(json: raw) else { return nil }
                      return .init(name: name, window: window)
                  }, refreshAfterSeconds: delay)
    }
}
extension CompanionHelperStartWarning {
    nonisolated init?(json: AnnexJSON?) {
        guard let code = json?["code"]?.string, let message = json?["message"]?.string, !message.isEmpty else { return nil }
        self.init(code: code, asOf: json?["asOf"].flatMap(CompanionLiveService.date(from:)), message: message)
    }
}
