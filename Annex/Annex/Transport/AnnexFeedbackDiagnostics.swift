import Foundation

/// Go's SDK-independent closed-field snapshot for Framebriar report diagnostics v1.
/// The app adapts this value to the SDK only for an explicitly prepared one-report test;
/// ordinary feedback keeps report diagnostics OFF. Capture once on composer open, then
/// persist the frozen value with its report. Export never consumes AnnexTelemetry's ring.
nonisolated public struct AnnexFeedbackDiagnostics: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case attached, none, left_out, unavailable }
    public enum Reason: String, Codable, Sendable { case recorded, empty, collection_off, no_provider, user_choice, invalid_provider }
    public enum Level: String, Codable, Sendable { case debug, info, warn, error }
    public enum Failure: String, Codable, Sendable {
        case timeout, tls, dns, refused, closed, oversize, overflow, busy, storage, auth, `protocol`, cancelled, server, offline, unknown
        public init?(_ value: AnnexDiagnosticFailure) {
            switch value {
            case .none: return nil
            case .timeout: self = .timeout
            case .tls: self = .tls
            case .dns: self = .dns
            case .connection: self = .closed
            case .tooLarge: self = .oversize
            case .overflow: self = .overflow
            case .busy: self = .busy
            case .storage: self = .storage
            case .trust, .identity, .authentication, .forbidden: self = .auth
            case .invalidInput, .malformed, .unsupported, .conflict, .rejected: self = .protocol
            case .cancelled, .abandoned: self = .cancelled
            case .server: self = .server
            case .offline: self = .offline
            case .outcomeUnknown, .unknown: self = .unknown
            }
        }
    }
    public enum Value: Codable, Sendable, Equatable {
        case string(String), number(Double)
        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Double.self) { self = .number(number) }
            else { self = .string(try c.decode(String.self)) }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let value): try c.encode(value); case .number(let value): try c.encode(value) }
        }
    }
    public struct Entry: Codable, Sendable, Equatable {
        public let at: String
        public let level: Level
        public let ns: String
        public let event: String
        public let attrs: [String: Value]
    }
    public let state: State
    public let reason: Reason
    public let windowStart: String
    public let windowEnd: String
    public let lines: Int
    /// UTF-8 bytes of the compact JSON entries array, as defined by diagnostics v1.
    public let bytes: Int
    public let dropped: Int
    public let droppedAttrs: Int
    public let entries: [Entry]
    public static let maximumBytes = 64 * 1024
    public static let maximumEntries = 200

    public static func capture(from source: AnnexTelemetry, now: Date = Date()) -> Self {
        make(snapshot: source.snapshot(), now: now)
    }
    /// A missing provider is distinct from a provider that failed. Neither rejects feedback.
    public static func noProvider(now: Date = Date()) -> Self { empty(state: .none, reason: .no_provider, now: now) }
    public static func unavailable(now: Date = Date()) -> Self { empty(state: .unavailable, reason: .invalid_provider, now: now) }
    public func leavingOut() -> Self {
        Self.sized(state: .left_out, reason: .user_choice, start: windowStart, end: windowEnd, entries: [], dropped: dropped, droppedAttrs: droppedAttrs)
    }
    public func encoded() throws -> Data { try Self.encoder().encode(self) }

    public static func make(snapshot: AnnexDiagnosticSnapshot, now: Date = Date()) -> Self {
        guard now.timeIntervalSince1970.isFinite else { return unavailable() }
        guard snapshot.schemaVersion == 1, snapshot.records.allSatisfy({
            $0.startedAt.timeIntervalSince1970.isFinite && $0.durationMs.isFinite && (0...600_000).contains($0.durationMs)
                && validHex($0.traceID, length: 32) && validHex($0.id, length: 16)
        }) else { return unavailable(now: now) }
        guard snapshot.enabled else { return empty(state: .none, reason: .collection_off, now: now) }
        let start = now.addingTimeInterval(-300)
        // A long operation that finishes now is recent even if it began before this window.
        let records = snapshot.records.filter {
            let end = $0.startedAt.addingTimeInterval($0.durationMs / 1000)
            return end >= start && end <= now
        }.sorted { $0.startedAt.addingTimeInterval($0.durationMs / 1000) < $1.startedAt.addingTimeInterval($1.durationMs / 1000) }
        var entries: [Entry] = [], droppedAttrs = 0
        for record in records {
            var attrs: [String: Value] = ["operation": .string(record.operation.rawValue), "durationMs": .number(record.durationMs),
                                           "traceId": .string(record.traceID), "spanId": .string(record.id)]
            if let failure = Failure(record.failure) { attrs["failure"] = .string(failure.rawValue) }
            for (key, value) in record.measurements {
                // No aliases with ambiguous semantics (for example chunks -> count).
                guard ["attempt", "backoffMs", "bytes", "requestBytes", "responseBytes", "connectMs", "tlsMs", "firstByteMs", "statusCode"].contains(key),
                      value.isFinite, value >= 0,
                      key != "statusCode" || (value.rounded() == value && (100...599).contains(value)) else { droppedAttrs += 1; continue }
                attrs[key] = .number(value)
            }
            for (key, value) in record.identifiers {
                let name: String
                switch AnnexDiagnosticIdentifier(rawValue: key) {
                case .connectionID: name = "connectionId"
                case .connectionAttemptID: name = "attemptId"
                default: droppedAttrs += 1; continue
                }
                guard let canonical = AnnexTelemetryHandshake.canonicalUUID(value) else { droppedAttrs += 1; continue }
                attrs[name] = .string(canonical.uuidString.lowercased())
            }
            let level: Level = record.failure == .none ? .info : Failure(record.failure) == .cancelled ? .debug : .error
            entries.append(Entry(at: timestamp(record.startedAt.addingTimeInterval(record.durationMs / 1000)), level: level,
                                 ns: "annex", event: record.operation.rawValue, attrs: attrs))
        }
        var dropped = max(0, snapshot.dropped)
        if entries.count > maximumEntries { dropped += entries.count - maximumEntries; entries = Array(entries.suffix(maximumEntries)) }
        let startText = timestamp(start), endText = timestamp(now)
        func result(keeping count: Int) -> Self {
            sized(state: count == 0 ? .none : .attached, reason: count == 0 ? .empty : .recorded,
                  start: startText, end: endText, entries: Array(entries.suffix(count)),
                  dropped: dropped + entries.count - count, droppedAttrs: droppedAttrs)
        }
        // At most eight encodes for <=200 entries. Avoid re-encoding one record at a time on
        // the main actor when a busy transport fills the local ring.
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high + 1) / 2
            if (try? result(keeping: middle).encoded().count).map({ $0 <= maximumBytes }) == true { low = middle }
            else { high = middle - 1 }
        }
        return result(keeping: low)
    }

    private static func empty(state: State, reason: Reason, now: Date) -> Self {
        sized(state: state, reason: reason, start: timestamp(now.addingTimeInterval(-300)), end: timestamp(now), entries: [], dropped: 0, droppedAttrs: 0)
    }
    private static func sized(state: State, reason: Reason, start: String, end: String, entries: [Entry], dropped: Int, droppedAttrs: Int) -> Self {
        let bytes = (try? encoder().encode(entries).count) ?? 2
        return Self(state: state, reason: reason, windowStart: start, windowEnd: end, lines: entries.count, bytes: bytes,
                    dropped: dropped, droppedAttrs: droppedAttrs, entries: entries)
    }
    private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder }
    private static func timestamp(_ date: Date) -> String { date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true).timeZone(separator: .omitted)) }
    private static func validHex(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { "0123456789abcdef".contains($0) } && text.contains { $0 != "0" }
    }
}
