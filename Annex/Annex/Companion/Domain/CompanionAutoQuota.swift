import Foundation

/// Saved Auto policy and the desktop's authoritative result. No precedence is calculated on the phone.
nonisolated struct CompanionHelperAuto: Sendable, Equatable {
    enum Value: Sendable, Equatable, Hashable { case enabled(Bool), off, inherit }
    struct Scope: Sendable, Equatable {
        var value: Value
        var editable: Bool
        var choices: [Value]
    }
    var effective: Bool
    var source: String
    var reason: String?
    var scopes: [String: Scope]
    func sourceText(labels: CompanionHelperRouting.Labels) -> String { CompanionHelperRouting.label(labels, family: "autoSource", code: source) }
    func reasonText(labels: CompanionHelperRouting.Labels) -> String? {
        reason.map { CompanionHelperRouting.label(labels, family: "autoOff", code: $0) }
    }
}

/// A plan reading, or a saved reading in a routing decision. Source and quotaBasis are diagnostic only.
nonisolated struct CompanionHelperQuota: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var usedPercent: Double?
        var resetsAt: Date?
    }
    struct ModelWindow: Sendable, Equatable {
        var name: String
        var window: Window
    }
    var state: String
    var unknownReason: String?
    var asOf: Date?
    var limitingWindow: String?
    var resetsAt: Date?
    var weekly: Window?
    var fiveHour: Window?
    var unreadableWindows: [String] = []
    var modelWindows: [ModelWindow] = []
    var refreshAfterSeconds: Double?

    static func nextRefreshDelay(_ quotas: [Self]) -> Double? {
        quotas.compactMap(\.refreshAfterSeconds).filter { $0.isFinite && $0 >= 0 }.min().map { max(5, $0) }
    }
    /// The server's clock plus elapsed continuous time; the phone's wall clock never determines freshness.
    static func age(asOf: Date?, serverTime: Date?, elapsed: Duration) -> TimeInterval? {
        guard let asOf, let serverTime else { return nil }
        let parts = elapsed.components
        return max(0, serverTime.timeIntervalSince(asOf) + Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}

/// The server supplies the words. An unrecognized code still has a readable informational message.
nonisolated struct CompanionHelperStartWarning: Sendable, Equatable {
    var code: String
    var asOf: Date?
    var message: String
    var knownAtText: String {
        asOf.map { "Known at \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Time not provided"
    }
}
