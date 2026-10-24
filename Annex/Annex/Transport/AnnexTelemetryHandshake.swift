import Foundation

/// Optional authenticated WebSocket capability negotiation. No REST endpoint,
/// persistent registration, new permission, or change to controller authentication.
nonisolated public struct AnnexTelemetryHandshake: Sendable, Equatable {
    public struct Request: Encodable, Sendable {
        public let version = 1
        public let serviceName = "clubhouse-go"
        public let serviceInstanceId: String
        public let connectionAttemptId: String
        public let traceContext = "w3c-v00"
        public init(instanceID: UUID, attemptID: UUID) {
            serviceInstanceId = instanceID.uuidString.lowercased()
            connectionAttemptId = attemptID.uuidString.lowercased()
        }
    }
    private struct Response: Decodable {
        let version: Int
        let serviceName: String
        let serviceInstanceId: String
        let peerServiceInstanceId: String
        let connectionAttemptId: String
        let connectionId: String
        let traceContext: String
    }
    public let peerInstanceID: UUID
    public let attemptID: UUID
    public let connectionID: UUID
    public static func validate(_ data: Data, request: Request) throws -> Self {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Response.self, from: data),
              value.version == 1, value.serviceName == "clubhouse", value.traceContext == "w3c-v00",
              value.peerServiceInstanceId == request.serviceInstanceId,
              value.connectionAttemptId == request.connectionAttemptId,
              let peer = canonicalUUID(value.serviceInstanceId),
              let attempt = canonicalUUID(value.connectionAttemptId),
              let connection = canonicalUUID(value.connectionId),
              value.serviceInstanceId != request.serviceInstanceId else { throw AnnexTransportError.malformedResponse }
        return Self(peerInstanceID: peer, attemptID: attempt, connectionID: connection)
    }
    static func canonicalUUID(_ value: String) -> UUID? {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value,
              uuid.uuid.6 >> 4 == 4, uuid.uuid.8 & 0xc0 == 0x80 else { return nil }
        return uuid
    }
    public func annotate(_ span: AnnexDiagnosticSpan?) {
        span?.identifier(.peerInstanceID, peerInstanceID)
        span?.identifier(.connectionAttemptID, attemptID)
        span?.identifier(.connectionID, connectionID)
    }
}
