import Foundation

/// Explicit, reviewed references to locally recorded spans. No guarantee of remote ingestion.
/// This value is snapshotted when feedback opens and survives queue retries unchanged.
public struct FeedbackIncident: Codable, Sendable, Equatable {
    public enum Availability: String, Codable, Sendable { case recorded, unavailable, collection_off }
    public struct Trace: Codable, Sendable, Equatable {
        public let traceId: String
        public let spanId: String
        public init(traceId: String, spanId: String) throws {
            guard matches(traceId, "^[0-9a-f]{32}$"), traceId != String(repeating: "0", count: 32),
                  matches(spanId, "^[0-9a-f]{16}$"), spanId != String(repeating: "0", count: 16) else { throw FramebriarError.invalidInput }
            self.traceId = traceId; self.spanId = spanId
        }
    }
    public let version: Int
    public let id: String
    public let capturedAt: String
    public let windowStart: String
    public let windowEnd: String
    public let availability: Availability
    public let phoneInstanceId: String
    public let hostInstanceIds: [String]
    public let connectionIds: [String]
    public let traces: [Trace]
    public let backendRef: String?

    public init(id: UUID = UUID(), capturedAt: Date, windowStart: Date, availability: Availability,
                phoneInstanceId: String, hostInstanceIds: [String] = [], connectionIds: [String] = [],
                traces: [Trace] = [], backendRef: String? = nil) throws {
        version = 1; self.id = id.uuidString.lowercased(); self.capturedAt = iso(capturedAt)
        self.windowStart = iso(windowStart); windowEnd = self.capturedAt; self.availability = availability
        self.phoneInstanceId = phoneInstanceId; self.hostInstanceIds = hostInstanceIds
        self.connectionIds = connectionIds; self.traces = traces; self.backendRef = backendRef
        try validate()
    }
    public func validate() throws {
        func uuid(_ value: String) -> Bool { matches(value, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") }
        func timestamp(_ value: String) -> Date? {
            guard matches(value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z$"),
                  let date = parseDate(value), iso(date) == String(value.prefix(19)) + "Z" else { return nil }
            return date
        }
        guard version == 1, uuid(id), uuid(phoneInstanceId), hostInstanceIds.count <= 4, connectionIds.count <= 4,
              hostInstanceIds.allSatisfy(uuid), connectionIds.allSatisfy(uuid), backendRef.map(uuid) ?? true,
              Set(hostInstanceIds).count == hostInstanceIds.count, Set(connectionIds).count == connectionIds.count,
              traces.count <= 8, (availability == .recorded) == !traces.isEmpty,
              let start = timestamp(windowStart), let end = timestamp(windowEnd), let at = timestamp(capturedAt),
              end == at, start <= end, end.timeIntervalSince(start) <= 300 else { throw FramebriarError.invalidInput }
        for trace in traces { _ = try Trace(traceId: trace.traceId, spanId: trace.spanId) }
        guard try JSONEncoder().encode(self).count <= 4096 else { throw FramebriarError.invalidInput }
    }
}
