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
    /// A whole number from either JSON number form. Nil for anything that isn't one or doesn't fit, so an
    /// out-of-range value like `1e300` reads as missing instead of trapping in `Int(_:)`.
    public var int: Int? {
        switch self {
        case .integer(let v): Int(exactly: v)
        case .number(let v) where v.isFinite && abs(v) <= 9_007_199_254_740_991: Int(v.rounded())
        default: nil
        }
    }
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
    /// Optional outer W3C traceparent. Kept JSON-typed so malformed diagnostic
    /// metadata is ignored without rejecting a valid application envelope.
    public let tc: AnnexJSON?
    /// Local authenticated socket binding only. Never decoded from or encoded to wire data.
    public internal(set) var diagnosticBinding: AnnexTelemetryHandshake? = nil
    private enum CodingKeys: String, CodingKey {
        case type, payload, seq, replayed, oldestAvailable, lastSeq, fromSeq, toSeq, count, epoch, tc
    }

    public init(type: String, payload: AnnexJSON? = nil, seq: Int64? = nil, replayed: Bool? = nil, oldestAvailable: Int64? = nil, lastSeq: Int64? = nil, fromSeq: Int64? = nil, toSeq: Int64? = nil, count: Int? = nil, epoch: String? = nil, tc: AnnexJSON? = nil) {
        self.type = type; self.payload = payload; self.seq = seq; self.replayed = replayed
        self.oldestAvailable = oldestAvailable; self.lastSeq = lastSeq; self.fromSeq = fromSeq
        self.toSeq = toSeq; self.count = count; self.epoch = epoch; self.tc = tc
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
    case chatContent(agentID: String, mediaRef: String?, filePath: String?)
    case chat(agentID: String)
    case chatSessions(agentID: String)
    case chatHistory(agentID: String, sessionID: String?, beforeSeq: Int64?, limit: Int)
    case agents(projectID: String)
    case sessions(agentID: String)
    case transcript(agentID: String, sessionID: String, offset: Int, limit: Int)
    /// What the New agent form offers for one project.
    case createOptions(projectID: String)
    /// One durable agent's settings, each with when it can change.
    case agentSettings(agentID: String)
    /// The project root's branch and uncommitted files (`git status --porcelain`).
    case gitStatus(projectID: String)
    /// One file's text at HEAD (or in the index when `staged`) and in the working tree, for a read-only diff.
    case gitDiff(projectID: String, filePath: String, staged: Bool)
}

/// A gateway can implement this interface later without weakening direct-host trust.
nonisolated public protocol AnnexTransporting: Sendable {
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error>
    func connect() async throws
    func disconnect() async
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt
    func revokeSessionPairing() async throws
    /// Uploads one image's raw bytes for a later `chat.send`. Not idempotent: each call returns a new id.
    func upload(agentID: String, data: Data, mimeType: String) async throws -> AnnexAttachmentUpload
    /// Terminal frames and connection changes, on their own stream so a busy shell can't overflow `events()`.
    func terminalEvents() async -> AsyncStream<AnnexTerminalEvent>
    /// Sends one terminal message over the WebSocket. `pty:input` longer than the desktop's cap is split.
    func sendTerminal(_ frame: AnnexTerminalFrame) async throws
}

nonisolated public extension AnnexTransporting {
    func revokeSessionPairing() async throws { throw AnnexTransportError.unsupportedCapability("session-revocation") }
    func upload(agentID: String, data: Data, mimeType: String) async throws -> AnnexAttachmentUpload {
        throw AnnexTransportError.unsupportedCapability("attachments")
    }
    func terminalEvents() async -> AsyncStream<AnnexTerminalEvent> { AsyncStream { $0.finish() } }
    func sendTerminal(_ frame: AnnexTerminalFrame) async throws { throw AnnexTransportError.unsupportedCapability("terminal") }
}
