import Foundation

/// Client limits from docs/telemetry.md "SDK rules", matching the browser/Node emitters.
public enum TelemetryLimits {
    public static let flushInterval: TimeInterval = 60
    public static let flushItems = 200
    public static let flushBytes = 64 * 1024
    public static let bufferBytes = 1024 * 1024
    public static let batchBytes = 248 * 1024
    public static let itemBytes = 32 * 1024
    public static let attributes = 32
    public static let keyChars = 128
    public static let valueChars = 1024
    public static let bodyChars = 4096
    public static let nameChars = 128
    public static let events = 32
    public static let eventAttributes = 16
    public static let series = 100
    public static let totalSeries = 1000
    public static let instruments = 200
    public static let histogramScale = 8
    public static let histogramBuckets = 160
    public static let maxBackoff: TimeInterval = 600
    public static let maxRetryAfter: TimeInterval = 3600
    public static let ringWindow: TimeInterval = 300
    public static let ringLogs = 200
    public static let ringSpans = 200
}

/// Typed attribute value. Strings should come from closed sets (enum raw values, fixed names);
/// they are still scrubbed for URLs, emails, credentials and home-directory paths.
public enum TelemetryValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                            ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String), int(Int), double(Double), bool(Bool)
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Preferred for strings: a value from a closed enumeration.
    public static func enumeration<E: RawRepresentable>(_ value: E) -> TelemetryValue where E.RawValue == String { .string(value.rawValue) }
}

public typealias TelemetryAttributes = [String: TelemetryValue]

struct OTLPValue: Encodable, Sendable, Equatable {
    let value: TelemetryValue
    enum Keys: String, CodingKey { case stringValue, intValue, doubleValue, boolValue }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch value {
        case .string(let s): try c.encode(s, forKey: .stringValue)
        case .int(let i): try c.encode(String(i), forKey: .intValue)
        case .double(let d): try c.encode(d, forKey: .doubleValue)
        case .bool(let b): try c.encode(b, forKey: .boolValue)
        }
    }
}
struct KeyValue: Encodable, Sendable, Equatable {
    let key: String
    let value: OTLPValue
    init(_ key: String, _ value: TelemetryValue) { self.key = key; self.value = OTLPValue(value: value) }
}

private let secretKey = #"(?i)pass(word|phrase)?|secret|token|auth|cookie|session[_-]?key|api[_-]?key|credential|invitation|e-?mail"#
// LLM token timings and counts are numbers, not credentials (e.g. `firstTokenMs`, `tokens.count`).
private let tokenMetric = #"(?i)^(?!.*(?:pass|secret|auth|cookie|credential|invitation|mail|access|refresh|bearer|api)).*(?:first[_.-]?token|tokens?[_.-]?(?:count|ms|duration|per|in|out)|tokens$)"#

/// Light client-side pass (the gateway redacts again, but the SDK must not rely on it).
public func scrubTelemetryText(_ value: String, max: Int = TelemetryLimits.valueChars) -> String {
    let patterns: [(String, String)] = [
        (#"(?i)\bfile://\S+"#, "[path]"),
        (#"(?i)\b(?:https?|wss?)://\S+"#, "[url]"),
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]"),
        (#"(?i)\b(?:Bearer\s+\S+|(?:token|password|secret|api[_-]?key|authorization|cookie)\s*[:=]\s*[^\s,;]+)"#, "[redacted]"),
        (#"\b(?:gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_.-]{20,})"#, "[credential]"),
        (#"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#, "[credential]"),
        (#"(?:\b[A-Za-z]:\\|/(?:Users|home|private|var/mobile|var/folders)/)[^\s:)]+"#, "[path]")
    ]
    let clean = patterns.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    return String(clean.prefix(max))
}

func sanitize(_ value: TelemetryValue) -> TelemetryValue? {
    switch value {
    case .string(let s): return .string(scrubTelemetryText(s))
    case .double(let d): return d.isFinite ? value : nil
    default: return value
    }
}
func validKey(_ key: String) -> Bool {
    !key.isEmpty && key.count <= TelemetryLimits.keyChars && !key.hasPrefix("framebriar.")
        && (key.range(of: secretKey, options: .regularExpression) == nil || key.range(of: tokenMetric, options: .regularExpression) != nil)
}
/// ≤32 attributes (sorted for determinism), keys ≤128 chars, strings ≤1 KiB, secret-looking keys dropped.
func telemetryAttributes(_ attributes: TelemetryAttributes, max: Int = TelemetryLimits.attributes) -> [KeyValue] {
    var out: [KeyValue] = []
    for key in attributes.keys.sorted() where out.count < max && validKey(key) {
        if let value = sanitize(attributes[key]!) { out.append(KeyValue(key, value)) }
    }
    return out
}
func setAttribute(_ list: inout [KeyValue], _ key: String, _ raw: TelemetryValue) {
    guard validKey(key), let value = sanitize(raw) else { return }
    if let i = list.firstIndex(where: { $0.key == key }) { list[i] = KeyValue(key, value) }
    else if list.count < TelemetryLimits.attributes { list.append(KeyValue(key, value)) }
}
func telemetryName(_ value: String, fallback: String) -> String {
    let clean = scrubTelemetryText(value, max: TelemetryLimits.nameChars)
    return clean.isEmpty ? fallback : clean
}
func nanos(_ date: Date) -> String {
    String(UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded())) * 1000)
}
func randomHex(bytes: Int) -> String {
    var value: String
    repeat { value = (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    while value.allSatisfy { $0 == "0" }
    return value
}

/// Delta exponential histogram (OTel definition: bucket i covers (base^i, base^(i+1)],
/// base = 2^(2^-scale)). Starts at scale 8 and downscales to keep at most 160 buckets per side.
struct ExponentialHistogram: Sendable {
    private(set) var scale: Int
    private(set) var count = 0
    private(set) var sum = 0.0
    private var zero = 0
    private var minimum = Double.infinity, maximum = -Double.infinity
    private var positive: [Int: Int] = [:], negative: [Int: Int] = [:]
    private let maxSize: Int
    init(maxScale: Int = TelemetryLimits.histogramScale, maxSize: Int = TelemetryLimits.histogramBuckets) {
        scale = maxScale; self.maxSize = maxSize
    }
    static func index(_ value: Double, scale: Int) -> Int {
        let exponent = log2(abs(value))
        if exponent == exponent.rounded() {
            let e = Int(exponent)
            return scale >= 0 ? e * (1 << scale) - 1 : (e - 1) >> -scale
        }
        return scale >= 0 ? Int((exponent * Double(1 << scale)).rounded(.up)) - 1 : Int(exponent.rounded(.down)) >> -scale
    }
    mutating func record(_ value: Double) {
        guard value.isFinite else { return }
        count += 1; sum += value; minimum = Swift.min(minimum, value); maximum = Swift.max(maximum, value)
        if value == 0 { zero += 1; return }
        let side = value > 0 ? positive : negative
        var index = Self.index(value, scale: scale)
        var lo = Swift.min(side.keys.min() ?? index, index), hi = Swift.max(side.keys.max() ?? index, index), shift = 0
        while hi - lo + 1 > maxSize { shift += 1; lo >>= 1; hi >>= 1 }
        if shift > 0 {
            positive = Dictionary(positive.map { ($0.key >> shift, $0.value) }, uniquingKeysWith: +)
            negative = Dictionary(negative.map { ($0.key >> shift, $0.value) }, uniquingKeysWith: +)
            scale -= shift; index = Self.index(value, scale: scale)
        }
        if value > 0 { positive[index, default: 0] += 1 } else { negative[index, default: 0] += 1 }
    }
    func point(attributes: [KeyValue], start: String, time: String) -> ExponentialPoint {
        func dense(_ map: [Int: Int]) -> ExponentialPoint.Buckets? {
            guard let lo = map.keys.min(), let hi = map.keys.max() else { return nil }
            return .init(offset: lo, bucketCounts: (lo...hi).map { String(map[$0] ?? 0) })
        }
        return ExponentialPoint(attributes: attributes, startTimeUnixNano: start, timeUnixNano: time, count: String(count),
                                sum: sum, scale: scale, zeroCount: String(zero), positive: dense(positive), negative: dense(negative),
                                min: count > 0 ? minimum : nil, max: count > 0 ? maximum : nil)
    }
}

// MARK: OTLP/HTTP JSON records (ExportTraceServiceRequest / Logs / Metrics subsets accepted by src/telemetry.mjs)

struct SpanEventRecord: Encodable, Sendable {
    let timeUnixNano: String
    let name: String
    var attributes: [KeyValue]
}
struct SpanStatusRecord: Encodable, Sendable {
    var code: Int
    var message: String?
}
struct SpanRecord: Encodable, Sendable {
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let name: String
    let kind: Int
    let startTimeUnixNano: String
    var endTimeUnixNano: String
    var attributes: [KeyValue]
    var events: [SpanEventRecord]?
    var status: SpanStatusRecord
}
struct LogBody: Encodable, Sendable { let stringValue: String }
struct LogRecordData: Encodable, Sendable {
    let timeUnixNano: String
    let observedTimeUnixNano: String
    let severityNumber: Int
    let severityText: String
    let body: LogBody
    var attributes: [KeyValue]
    let traceId: String?
    let spanId: String?
}
struct NumberPoint: Encodable, Sendable {
    let attributes: [KeyValue]
    let startTimeUnixNano: String
    let timeUnixNano: String
    let asDouble: Double
}
struct ExponentialPoint: Encodable, Sendable {
    struct Buckets: Encodable, Sendable { let offset: Int; let bucketCounts: [String] }
    let attributes: [KeyValue]
    let startTimeUnixNano: String
    let timeUnixNano: String
    let count: String
    let sum: Double
    let scale: Int
    let zeroCount: String
    let positive: Buckets?
    let negative: Buckets?
    let min: Double?
    let max: Double?
}
