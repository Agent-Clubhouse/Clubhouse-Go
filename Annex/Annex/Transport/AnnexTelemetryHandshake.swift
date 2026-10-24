import Foundation

nonisolated public struct AnnexTelemetryHandshake: Sendable {
    public static let path = "/api/v1/mobile/telemetry/handshake"
    public struct Service: Codable, Equatable, Sendable {
        public let name: String
        public let instanceId: String
    }
    public struct Request: Encodable, Sendable {
        public let version = 1
        public let service: Service
        public let connectionAttemptId: String
        public init(instanceID: UUID, attemptID: UUID) {
            service = .init(name: "clubhouse-go", instanceId: instanceID.uuidString.lowercased())
            connectionAttemptId = attemptID.uuidString.lowercased()
        }
    }
    private struct Response: Decodable {
        let version: Int
        let service: Service
        let peer: Service
        let connectionAttemptId: String
        let connectionId: String
    }
    public let peerInstanceID: UUID
    public let attemptID: UUID
    public let connectionID: UUID
    public static func validate(_ data: Data, request: Request) throws -> Self {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Response.self, from: data),
              value.version == 1, value.service.name == "clubhouse", value.peer == request.service,
              value.connectionAttemptId == request.connectionAttemptId,
              let peer = canonicalUUID(value.service.instanceId),
              let attempt = canonicalUUID(value.connectionAttemptId),
              let connection = canonicalUUID(value.connectionId),
              value.service.instanceId != request.service.instanceId else { throw AnnexTransportError.malformedResponse }
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
