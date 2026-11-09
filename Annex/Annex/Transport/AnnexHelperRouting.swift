import Foundation

/// Revisioned helper routing writes. UI gates scopes and modes using the capability.
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
    public enum AutoValue: Decodable, Sendable, Equatable {
        case enabled(Bool), off, inherit
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .inherit }
            else if let enabled = try? value.decode(Bool.self) { self = .enabled(enabled) }
            else if try value.decode(String.self) == "off" { self = .off }
            else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown Auto setting") }
        }
        var json: AnnexJSON { switch self { case .enabled(let value): .bool(value); case .off: .string("off"); case .inherit: .null } }
    }
    public var projectId: String?
    public var auto: AutoValue?
    public var revision: String
    public var scope: String
    public var cells: [Cell]?
    public var reset: Reset?
    public init(revision: String, scope: String = "app", cells: [Cell]? = nil, reset: Reset? = nil, projectId: String? = nil, auto: AutoValue? = nil) {
        self.projectId = projectId; self.auto = auto
        self.revision = revision; self.scope = scope; self.cells = cells; self.reset = reset
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(String.self, forKey: .revision)
        scope = try c.decode(String.self, forKey: .scope)
        cells = try c.decodeIfPresent([Cell].self, forKey: .cells)
        reset = try c.decodeIfPresent(Reset.self, forKey: .reset)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        auto = c.contains(.auto) ? try c.decode(AutoValue.self, forKey: .auto) : nil
    }
    private enum CodingKeys: String, CodingKey { case revision, scope, cells, reset, projectId, auto }
    var fields: [String: AnnexJSON] {
        var fields: [String: AnnexJSON] = ["revision": .string(revision), "scope": .string(scope)]
        if let projectId { fields["projectId"] = .string(projectId) }
        if let auto { fields["auto"] = auto.json }
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
        public let levels: [String]?
        public let presetProviders: [String]?
        public let autoCandidates: [String]?
        public var presetLevels: [String] { levels ?? difficulties }
        public let reasons: [String]
        public let fallbacks: [String]
        public let cellStates: [String]
        public let autoOffReasons: [String]?
        public let skipped: [String]?
        public let quotaStates: [String]?
        public let unknownReasons: [String]?
        public let quotaSources: [String]?
        public var canUpdate: Bool { version == 1 && commands.contains("helperRouting.update") && (canEditPresets || modes.contains("auto")) }
        public var supportsPresets: Bool { version == 1 && modes.contains("preset") }
        public var canEditPresets: Bool { supportsPresets && scopes.contains("app") && commands.contains("helperRouting.update") }
    }
}
