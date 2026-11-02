import Foundation

/// `report.diagnostics` v1: a bounded excerpt of recent app events, captured once when the composer
/// opens and stored with the queued report, so retries and relaunches send the same bytes.
/// Holds only closed-vocabulary tokens and numbers. There is no free-text field by design.
public struct FeedbackDiagnostics: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case attached, none, left_out, unavailable }
    public enum Level: String, Codable, Sendable { case debug, info, warn, error }

    public enum Limits {
        public static let totalBytes = 64 * 1024
        public static let entries = 500
        public static let stringBytes = 4 * 1024
        public static let attrsPerEntry = 32
        /// Room kept for everything outside `entries` when trimming to `totalBytes`.
        static let envelopeBytes = 512
    }
    public enum Reason {
        public static let empty = "empty", noProvider = "no-provider"
        public static let providerFailed = "provider-failed", invalid = "invalid"
    }

    public enum Value: Codable, Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
        case number(Double), string(String)
        public init(integerLiteral value: Int) { self = .number(Double(value)) }
        public init(floatLiteral value: Double) { self = .number(value) }
        public init(stringLiteral value: String) { self = .string(value) }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Double.self) { self = .number(number) } else { self = .string(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            // Whole numbers are written without a fraction, so `bytes` matches the server's JSON.stringify.
            case .number(let n): if n == n.rounded(), abs(n) <= maxSafeInteger { try c.encode(Int64(n)) } else { try c.encode(n) }
            }
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let at: String
        public let level: Level
        public let ns: String
        public let event: String
        public let attrs: [String: Value]?
        public init(at: Date, level: Level, ns: String, event: String, attrs: [String: Value] = [:]) {
            self.at = isoMillis(at); self.level = level; self.ns = ns; self.event = event
            self.attrs = attrs.isEmpty ? nil : attrs
        }
        init(at: String, level: Level, ns: String, event: String, attrs: [String: Value]?) {
            self.at = at; self.level = level; self.ns = ns; self.event = event; self.attrs = attrs
        }
    }

    /// Feedback-client state when the composer opened. `lastResult` is `ok`, `none` (no attempt in this
    /// process) or a `failure` value. Absent when the user left diagnostics out.
    public struct Delivery: Codable, Sendable, Equatable {
        public let queued: Int
        public let lastResult: String
        public init(queued: Int, lastResult: String) { self.queued = queued; self.lastResult = lastResult }
    }

    public let v: Int
    public let state: State
    public let reason: String?
    public let windowStart: String
    public let windowEnd: String
    public let lines: Int
    public let bytes: Int
    public let dropped: Int
    public let droppedAttrs: Int
    public let entries: [Entry]
    public private(set) var delivery: Delivery?
    /// SDK-stamped client state. Ignored for `left_out`, which carries none.
    public mutating func setDelivery(_ value: Delivery?) { delivery = state == .left_out ? nil : value }

    /// For a `diagnosticsProvider`: entries go through the allowlist and are trimmed oldest-first to the
    /// limits. Empty entries give `none`/`empty`; entries that are all unusable give `unavailable`/`invalid`.
    public init(windowStart: Date, windowEnd: Date, entries: [Entry], dropped: Int = 0, droppedAttrs: Int = 0) {
        self = FeedbackDiagnostics(state: entries.isEmpty ? .none : .attached, reason: entries.isEmpty ? Reason.empty : nil,
                                   windowStart: isoMillis(windowStart), windowEnd: isoMillis(windowEnd),
                                   dropped: dropped, droppedAttrs: droppedAttrs, entries: entries).normalized(at: windowEnd)
    }
    public static func none(reason: String = Reason.empty, at: Date = Date()) -> FeedbackDiagnostics {
        FeedbackDiagnostics(state: .none, reason: closed(reason, [Reason.empty, Reason.noProvider], else: Reason.empty), at: at)
    }
    public static func unavailable(reason: String = Reason.providerFailed, at: Date = Date()) -> FeedbackDiagnostics {
        FeedbackDiagnostics(state: .unavailable, reason: closed(reason, [Reason.providerFailed, Reason.invalid], else: Reason.providerFailed), at: at)
    }
    /// The user turned the switch off. No entries, counts or delivery state.
    public static func leftOut(at: Date = Date()) -> FeedbackDiagnostics { FeedbackDiagnostics(state: .left_out, reason: nil, at: at) }

    private init(state: State, reason: String?, at: Date) {
        self.init(state: state, reason: reason, windowStart: isoMillis(at), windowEnd: isoMillis(at), dropped: 0, droppedAttrs: 0, entries: [])
    }
    init(state: State, reason: String?, windowStart: String, windowEnd: String, dropped: Int, droppedAttrs: Int, entries: [Entry]) {
        v = 1; self.state = state; self.reason = reason
        self.windowStart = windowStart; self.windowEnd = windowEnd
        self.dropped = dropped; self.droppedAttrs = droppedAttrs; self.entries = entries
        lines = entries.count; bytes = Self.entriesBytes(entries); delivery = nil
    }

    /// Whatever a provider returned, in contract form. Never throws: unusable input becomes `unavailable`.
    public func normalized(at now: Date) -> FeedbackDiagnostics {
        guard v == 1, let start = timestamp(windowStart), let end = timestamp(windowEnd), start <= end else { return .unavailable(reason: Reason.invalid, at: now) }
        let priorDropped = max(0, dropped), priorDroppedAttrs = max(0, droppedAttrs)
        var result: FeedbackDiagnostics
        switch state {
        case .left_out:
            return FeedbackDiagnostics(state: .left_out, reason: nil, windowStart: windowStart, windowEnd: windowEnd, dropped: 0, droppedAttrs: 0, entries: [])
        case .none:
            result = FeedbackDiagnostics(state: .none, reason: Self.closed(reason ?? "", [Reason.empty, Reason.noProvider], else: Reason.empty),
                                         windowStart: windowStart, windowEnd: windowEnd, dropped: priorDropped, droppedAttrs: priorDroppedAttrs, entries: [])
        case .unavailable:
            result = FeedbackDiagnostics(state: .unavailable, reason: Self.closed(reason ?? "", [Reason.providerFailed, Reason.invalid], else: Reason.providerFailed),
                                         windowStart: windowStart, windowEnd: windowEnd, dropped: priorDropped, droppedAttrs: priorDroppedAttrs, entries: [])
        case .attached:
            var droppedAttrs = priorDroppedAttrs
            var scrubber = TokenScrubber()
            var kept = entries.compactMap { Self.sanitized($0, droppedAttrs: &droppedAttrs, scrubber: &scrubber) }
            var dropped = priorDropped + entries.count - kept.count
            if kept.isEmpty {
                result = FeedbackDiagnostics(state: .unavailable, reason: Reason.invalid, windowStart: windowStart, windowEnd: windowEnd,
                                             dropped: dropped, droppedAttrs: droppedAttrs, entries: [])
                break
            }
            kept.sort { $0.at < $1.at }
            if kept.count > Limits.entries {
                dropped += kept.count - Limits.entries
                kept.removeFirst(kept.count - Limits.entries)
            }
            // One encode when it fits, the common case. Per-entry sizes are only computed to trim.
            if Self.entriesBytes(kept) + Limits.envelopeBytes > Limits.totalBytes {
                let encoder = JSONEncoder()
                let sizes = kept.map { ((try? encoder.encode($0).count) ?? 0) + 1 }
                var total = sizes.reduce(0, +) + 1
                var cut = 0
                while cut < kept.count, total + Limits.envelopeBytes > Limits.totalBytes { total -= sizes[cut]; cut += 1 }
                kept.removeFirst(cut); dropped += cut
            }
            result = FeedbackDiagnostics(state: kept.isEmpty ? .unavailable : .attached, reason: kept.isEmpty ? Reason.invalid : nil,
                                         windowStart: windowStart, windowEnd: windowEnd, dropped: dropped, droppedAttrs: droppedAttrs, entries: kept)
        }
        if let delivery, delivery.queued >= 0 {
            result.setDelivery(Delivery(queued: delivery.queued, lastResult: FeedbackDiagnosticsAttrs.deliveryResults.contains(delivery.lastResult) ? delivery.lastResult : "unknown"))
        }
        return result
    }

    /// Checks a stored or caller-built value against the contract, including the 64 KiB limit.
    public func validate() throws {
        guard v == 1, let start = timestamp(windowStart), let end = timestamp(windowEnd), start <= end,
              lines == entries.count, bytes == Self.entriesBytes(entries), dropped >= 0, droppedAttrs >= 0,
              entries.count <= Limits.entries, (state == .attached) == !entries.isEmpty,
              reason.map(isToken) ?? true,
              delivery.map({ $0.queued >= 0 && FeedbackDiagnosticsAttrs.deliveryResults.contains($0.lastResult) && state != .left_out }) ?? true,
              state != .left_out || (dropped == 0 && droppedAttrs == 0) else { throw FramebriarError.invalidInput }
        var scrubber = TokenScrubber()
        for entry in entries {
            var strays = 0
            guard let clean = Self.sanitized(entry, droppedAttrs: &strays, scrubber: &scrubber), clean == entry, strays == 0 else { throw FramebriarError.invalidInput }
        }
        guard try JSONEncoder().encode(self).count <= Limits.totalBytes else { throw FramebriarError.invalidInput }
    }

    private static func closed(_ value: String, _ allowed: Set<String>, else fallback: String) -> String { allowed.contains(value) ? value : fallback }

    /// UTF-8 length of `JSON.stringify(entries)`, the way the server recomputes it.
    private static func entriesBytes(_ entries: [Entry]) -> Int { entries.isEmpty ? 0 : (try? JSONEncoder().encode(entries).count) ?? 0 }

    private static func sanitized(_ entry: Entry, droppedAttrs: inout Int, scrubber: inout TokenScrubber) -> Entry? {
        guard isCanonicalTimestamp(entry.at), let ns = scrubber.scrub(entry.ns), let event = scrubber.scrub(entry.event) else { return nil }
        var attrs: [String: Value] = [:]
        for (key, value) in entry.attrs ?? [:] {
            if let clean = FeedbackDiagnosticsAttrs.normalize(key, value, scrubber: &scrubber) { attrs[key] = clean } else { droppedAttrs += 1 }
        }
        return Entry(at: entry.at, level: entry.level, ns: ns, event: event, attrs: attrs.isEmpty ? nil : attrs)
    }
}

/// A valid token unchanged, one `redact` would rewrite as `redacted` (as the server does), a malformed
/// one nil. Names repeat heavily across entries, so each distinct token runs the patterns only once.
struct TokenScrubber {
    private var seen: [String: String] = [:]
    mutating func scrub(_ value: String) -> String? {
        guard isToken(value) else { return nil }
        if let known = seen[value] { return known }
        let clean = redact(value) == value ? value : "redacted"
        seen[value] = clean
        return clean
    }
}

/// The frozen v1 attribute allowlist. Unknown keys and out-of-contract values are dropped and counted;
/// an unknown `failure` becomes `unknown`.
enum FeedbackDiagnosticsAttrs {
    static let numbers: Set<String> = ["attempt", "backoffMs", "snapshotBytes", "webSocketMessageLimitBytes", "transportFrameLimitBytes",
                                              "durationMs", "count", "bytes", "responseBytes", "requestBytes", "connectMs", "tlsMs", "firstByteMs"]
    static let links: Set<String> = ["mtls", "bearer", "unknown"]
    static let failures: Set<String> = ["timeout", "tls", "dns", "refused", "closed", "oversize", "overflow", "busy", "storage",
                                               "auth", "protocol", "cancelled", "server", "offline", "unknown"]

    static func normalize(_ key: String, _ value: FeedbackDiagnostics.Value, scrubber: inout TokenScrubber) -> FeedbackDiagnostics.Value? {
        if numbers.contains(key) {
            guard case .number(let n) = value, n.isFinite, n >= 0, n <= maxSafeInteger else { return nil }
            return value
        }
        switch key {
        case "statusCode": return integer(value, in: 100...599)
        case "exitCode": return integer(value, in: 0...255)
        case "closeCode": return integer(value, in: 1000...4999)
        case "failure":
            if case .string(let s) = value, failures.contains(s) { return value }
            return .string("unknown")
        case "link":
            if case .string(let s) = value, links.contains(s) { return value }
            return .string("unknown")
        case "fromState", "toState", "reason", "provider", "driver":
            guard case .string(let s) = value, isShortToken(s), let clean = scrubber.scrub(s) else { return nil }
            return .string(clean)
        case "peerRef", "agentRef":
            // Exact: unlike the IDs below, these aren't lowercased for the caller.
            guard case .string(let s) = value, isHex(s.utf8, 16) else { return nil }
            return value
        case "operation":
            guard case .string(let s) = value, let clean = scrubber.scrub(s) else { return nil }
            return .string(clean)
        case "connectionId", "attemptId": return identifier(value) { isUUID($0) }
        case "traceId": return identifier(value) { isHex($0, 32) || isUUID($0) }
        case "spanId": return identifier(value) { isHex($0, 16) }
        default: return nil
        }
    }
    static let deliveryResults: Set<String> = failures.union(["ok", "none"])
    private static func integer(_ value: FeedbackDiagnostics.Value, in range: ClosedRange<Double>) -> FeedbackDiagnostics.Value? {
        guard case .number(let n) = value, n == n.rounded(), range.contains(n) else { return nil }
        return value
    }
    private static func identifier(_ value: FeedbackDiagnostics.Value, _ valid: (String.UTF8View) -> Bool) -> FeedbackDiagnostics.Value? {
        guard case .string(let s) = value else { return nil }
        let lower = s.lowercased()
        return valid(lower.utf8) ? .string(lower) : nil
    }
}

// Hand-written checks: a provider may hand over hundreds of entries on the main actor as a composer opens.
/// `^[A-Za-z0-9_.:+-]{1,64}$`
private func isToken(_ value: String) -> Bool {
    let bytes = value.utf8
    guard (1...64).contains(bytes.count) else { return false }
    return bytes.allSatisfy { b in
        (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || [95, 46, 58, 43, 45].contains(b)
    }
}
/// `^[a-z0-9][a-z0-9_.-]{0,31}$`
private func isShortToken(_ value: String) -> Bool {
    let bytes = value.utf8
    guard (1...32).contains(bytes.count), let first = bytes.first, (48...57).contains(first) || (97...122).contains(first) else { return false }
    return bytes.allSatisfy { b in (48...57).contains(b) || (97...122).contains(b) || [95, 46, 45].contains(b) }
}
private func isHexDigit(_ b: UInt8) -> Bool { (48...57).contains(b) || (97...102).contains(b) }
private func isHex(_ bytes: String.UTF8View, _ count: Int) -> Bool { bytes.count == count && bytes.allSatisfy(isHexDigit) }
private func isUUID(_ bytes: String.UTF8View) -> Bool {
    guard bytes.count == 36 else { return false }
    return bytes.enumerated().allSatisfy { i, b in [8, 13, 18, 23].contains(i) ? b == 45 : isHexDigit(b) }
}
/// `YYYY-MM-DDTHH:MM:SS.mmmZ`. Fixed width, so these strings sort by time.
private func isCanonicalTimestamp(_ value: String) -> Bool {
    let bytes = value.utf8
    guard bytes.count == 24 else { return false }
    return bytes.enumerated().allSatisfy { i, b in
        switch i {
        case 4, 7: b == 45
        case 10: b == 84
        case 13, 16: b == 58
        case 19: b == 46
        case 23: b == 90
        default: (48...57).contains(b)
        }
    }
}

private let maxSafeInteger = 9_007_199_254_740_991.0

// ISO8601DateFormatter is documented as thread-safe.
nonisolated(unsafe) private let millisFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func isoMillis(_ date: Date) -> String {
    guard date.timeIntervalSince1970.isFinite else { return "" }
    return millisFormatter.string(from: date)
}
private func timestamp(_ value: String) -> Date? {
    guard isCanonicalTimestamp(value) else { return nil }
    return parseDate(value)
}
