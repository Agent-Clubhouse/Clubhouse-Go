import Foundation

nonisolated public extension AnnexCapabilities {
    struct FullEvents: Decodable, Sendable {
        public let version: Int
        public let path: String
        public let maximumBytes: Int
        public let approvalField: String
        public var isSupported: Bool {
            version == 1 && path == "/api/v1/mobile/agents/{agentId}/chat/events/{seq}?sessionId={sessionId}"
                && maximumBytes > 0 && approvalField == "reviewedDigest"
        }
    }
}

/// Keeps the original event intact, including seq, session and all structured payload fields.
nonisolated public struct AnnexFullEvent: Sendable, Equatable {
    public static let maximumBytes = 32 * 1024 * 1024
    public let agentID: String
    public let sessionID: String
    public let sequence: Int64
    public let digest: String
    public let event: AnnexJSON

    public static func isDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public init(data: Data, agentID: String, sessionID: String, sequence: Int64) throws {
        guard data.count <= Self.maximumBytes else { throw AnnexTransportError.responseTooLarge }
        let body = try JSONDecoder().decode(AnnexJSON.self, from: data)
        guard body["version"] == .integer(1), body["agentId"] == .string(agentID),
              body["sessionId"] == .string(sessionID), body["seq"] == .integer(sequence),
              let digest = body["digest"]?.string, Self.isDigest(digest), let event = body["event"],
              event["agentId"] == .string(agentID), event["sessionId"] == .string(sessionID),
              event["seq"] == .integer(sequence), event["type"]?.string != nil,
              event["truncated"] == nil, event["data"]?["truncated"] == nil else {
            throw AnnexTransportError.malformedResponse
        }
        self.agentID = agentID; self.sessionID = sessionID; self.sequence = sequence
        self.digest = digest; self.event = event
    }
}
