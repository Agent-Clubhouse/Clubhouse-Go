import Foundation

/// Lossless integers keep sequence numbers out of Double's rounding range.
nonisolated public enum AnnexJSON: Codable, Sendable, Equatable {
    case string(String), integer(Int64), number(Double), bool(Bool)
    case object([String: AnnexJSON]), array([AnnexJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: AnnexJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([AnnexJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> AnnexJSON? {
        if case .object(let values) = self { values[key] } else { nil }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var integer: Int64? { if case .integer(let v) = self { v } else { nil } }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

/// Existing Annex envelopes remain unchanged. Replay control metadata is at the
/// top level on desktop; accepting nested metadata also supports older fixtures.
nonisolated public struct AnnexEnvelope: Codable, Sendable, Equatable {
    public let type: String
    public let payload: AnnexJSON?
    public let seq: Int64?
    public let replayed: Bool?
    public let oldestAvailable: Int64?
    public let lastSeq: Int64?
    public let fromSeq: Int64?
    public let toSeq: Int64?
    public let count: Int?
    public let epoch: String?

    public init(type: String, payload: AnnexJSON? = nil, seq: Int64? = nil, replayed: Bool? = nil, oldestAvailable: Int64? = nil, lastSeq: Int64? = nil, fromSeq: Int64? = nil, toSeq: Int64? = nil, count: Int? = nil, epoch: String? = nil) {
        self.type = type; self.payload = payload; self.seq = seq; self.replayed = replayed
        self.oldestAvailable = oldestAvailable; self.lastSeq = lastSeq; self.fromSeq = fromSeq
        self.toSeq = toSeq; self.count = count; self.epoch = epoch
    }
    public var snapshotSequence: Int64? { lastSeq ?? payload?["lastSeq"]?.integer }
    public var replayUpperBound: Int64? { toSeq ?? payload?["toSeq"]?.integer }
}

nonisolated public enum AnnexConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected, suspended
    case reconnecting(attempt: Int, delaySeconds: Double)
    case failed(AnnexTransportError)
}
nonisolated public enum AnnexResyncReason: String, Sendable { case replayGap, serverRestart, consumerTooSlow, sequenceGap, reconnected }
nonisolated public enum AnnexTransportEvent: Sendable, Equatable {
    case connection(AnnexConnectionState)
    case message(AnnexEnvelope)
    case resyncRequired(AnnexResyncReason)
}

nonisolated public enum AnnexReadRoute: Sendable {
    case identity, status, projects, capabilities
    case chat(agentID: String)
    case chatSessions(agentID: String)
    case chatHistory(agentID: String, sessionID: String?, beforeSeq: Int64?, limit: Int)
    case agents(projectID: String)
    case sessions(agentID: String)
    case transcript(agentID: String, sessionID: String, offset: Int, limit: Int)
}

/// A gateway can implement this interface later without weakening direct-host trust.
nonisolated public protocol AnnexTransporting: Sendable {
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error>
    func connect() async throws
    func disconnect() async
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt
    func revokeSessionPairing() async throws
}

nonisolated public extension AnnexTransporting {
    func revokeSessionPairing() async throws { throw AnnexTransportError.unsupportedCapability("session-revocation") }
}
