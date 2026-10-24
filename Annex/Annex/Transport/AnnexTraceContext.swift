import Foundation
@preconcurrency import OpenTelemetryApi

/// Validated W3C version-00 context from an authenticated, pinned host only.
/// No baggage. Vendor state is syntax-checked then discarded until an approved
/// exporter defines a vendor-key allowlist; opaque values may contain secrets.
nonisolated public struct AnnexTraceContext: Sendable, Equatable {
    public let traceparent: String
    public let tracestate: String? = nil
    let context: SpanContext
    public init?(traceparent: String, tracestate: String? = nil) {
        guard traceparent.utf8.count == 55 else { return nil }
        let bytes = Array(traceparent.utf8)
        guard bytes[0] == 48, bytes[1] == 48,
              bytes[2] == 45, bytes[35] == 45, bytes[52] == 45 else { return nil }
        for index in bytes.indices where index != 2 && index != 35 && index != 52 {
            guard (48...57).contains(bytes[index]) || (97...102).contains(bytes[index]) else { return nil }
        }
        let trace = String(decoding: bytes[3..<35], as: UTF8.self)
        let span = String(decoding: bytes[36..<52], as: UTF8.self)
        guard trace != String(repeating: "0", count: 32), span != String(repeating: "0", count: 16),
              Self.validState(tracestate) else { return nil }
        self.traceparent = traceparent
        context = .createFromRemoteParent(traceId: TraceId(fromHexString: trace), spanId: SpanId(fromHexString: span),
            traceFlags: TraceFlags(fromHexString: String(decoding: bytes[53..<55], as: UTF8.self)), traceState: TraceState())
    }
    public static func from(_ value: AnnexJSON?) -> Self? {
        guard let parent = value?["traceparent"]?.string else { return nil }
        if let state = value?["tracestate"], state != .null, state.string == nil { return nil }
        return Self(traceparent: parent, tracestate: value?["tracestate"]?.string)
    }
    static func validState(_ state: String?) -> Bool {
        guard let state else { return true }
        guard !state.isEmpty, state.utf8.count <= 512 else { return false }
        let members = state.split(separator: ",", omittingEmptySubsequences: false)
        guard members.count <= 32 else { return false }
        var keys = Set<String>()
        for member in members {
            let pair = member.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let key = String(pair[0]); let value = Array(pair[1].utf8)
            guard !key.isEmpty, key.utf8.count <= 256, keys.insert(key).inserted,
                  !value.isEmpty, value.count <= 256, value.last != 32,
                  value.allSatisfy({ (32...126).contains($0) && $0 != 44 && $0 != 61 }) else { return false }
            let components = key.split(separator: "@", omittingEmptySubsequences: false)
            guard components.count <= 2 else { return false }
            for (index, component) in components.enumerated() {
                let chars = Array(component.utf8)
                guard let first = chars.first,
                      (97...122).contains(first) || (index == 0 && components.count == 2 && (48...57).contains(first)),
                      chars.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [95,45,42,47].contains($0) }) else { return false }
                if components.count == 2 && chars.count > (index == 0 ? 241 : 14) { return false }
            }
        }
        return true
    }
}
