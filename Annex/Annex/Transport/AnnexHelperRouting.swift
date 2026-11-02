import Foundation

/// Stage 2 app-wide preset edits. Later Auto fields need their own locked contract.
nonisolated public struct AnnexHelperRoutingUpdate: Decodable, Sendable, Equatable {
    public struct Cell: Decodable, Sendable, Equatable {
        public var provider: String
        public var difficulty: String
        public var model: String
        public var effort: String?
        public init(provider: String, difficulty: String, model: String, effort: String?) {
            self.provider = provider; self.difficulty = difficulty; self.model = model; self.effort = effort
        }
        var json: AnnexJSON { .object(["provider": .string(provider), "difficulty": .string(difficulty), "model": .string(model), "effort": effort.map(AnnexJSON.string) ?? .null]) }
    }
    public struct Reset: Decodable, Sendable, Equatable {
        public var provider: String?
        public var difficulty: String?
        public init(provider: String? = nil, difficulty: String? = nil) { self.provider = provider; self.difficulty = difficulty }
        var json: AnnexJSON {
            var fields: [String: AnnexJSON] = [:]
            if let provider { fields["provider"] = .string(provider) }
            if let difficulty { fields["difficulty"] = .string(difficulty) }
            return .object(fields)
        }
    }
    public var revision: String
    public var scope: String
    public var cells: [Cell]?
    public var reset: Reset?
    public init(revision: String, scope: String = "app", cells: [Cell]? = nil, reset: Reset? = nil) {
        self.revision = revision; self.scope = scope; self.cells = cells; self.reset = reset
    }
    var fields: [String: AnnexJSON] {
        var fields: [String: AnnexJSON] = ["revision": .string(revision), "scope": .string(scope)]
        if let cells { fields["cells"] = .array(cells.map(\.json)) }
        if let reset { fields["reset"] = reset.json }
        return fields
    }
}

extension AnnexCapabilities {
    nonisolated public struct HelperRouting: Decodable, Sendable, Equatable {
        public let version: Int
        public let path: String
        public let modes: [String]
        public let scopes: [String]
        public let quota: Bool
        public let commands: [String]
        public let difficulties: [String]
        public let reasons: [String]
        public let fallbacks: [String]
        public let cellStates: [String]
        public var supportsPresets: Bool { version == 1 && modes.contains("preset") }
        public var canEditPresets: Bool { supportsPresets && scopes.contains("app") && commands.contains("helperRouting.update") }
    }
}
