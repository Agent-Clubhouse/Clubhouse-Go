import Foundation
import ClubhouseTransport

/// #554 instrumentation. The chat header is laid out with zero slack: leading reservation, identity and trailing
/// reservation fill the bar exactly, which is what keeps the identity screen-centred. On iOS 27.2 the name was seen
/// clipped at its leading edge with the actions pill pushed off screen, which the iOS 26.0 simulator never shows.
/// This notices when the header overflows the bar, so one record with the numbers reaches the existing diagnostics
/// (and a feedback report's log) when it happens on a device.
struct CompanionHeaderOverflow: Equatable, Sendable {
    /// The bar's own measurements and the widths the header asked for, in points.
    struct Layout: Equatable, Sendable {
        var barWidth: Double
        var leadingOrigin: Double
        var trailingInset: Double
        var leadingReservation: Double
        var principalWidth: Double
        var trailingReservation: Double
        /// The native title clearance on each side of the identity.
        static let titleClearance = 16.0
        var total: Double {
            leadingOrigin + leadingReservation + 2 * Self.titleClearance + principalWidth + trailingReservation + trailingInset
        }
    }

    /// An item's horizontal extent in the bar's coordinates.
    struct Extent: Equatable, Sendable {
        var minX: Double
        var maxX: Double
    }

    enum Kind: CaseIterable, Sendable {
        case sumExceedsBar, leadingOutsideBar, principalOutsideBar, trailingOutsideBar
        var event: AnnexDiagnosticEvent {
            switch self {
            case .sumExceedsBar: .headerSumExceedsBar
            case .leadingOutsideBar: .headerLeadingOutsideBar
            case .principalOutsideBar: .headerPrincipalOutsideBar
            case .trailingOutsideBar: .headerTrailingOutsideBar
            }
        }
    }

    var kinds: Set<Kind>
    /// The largest amount by which anything exceeds the bar, in points.
    var overflow: Double

    /// Half a point absorbs rounding; the layout is exact by construction otherwise.
    static let tolerance = 0.5

    /// Nil when the header fits. Extents are optional: each is checked only when it has been observed.
    static func detect(_ layout: Layout, leading: Extent? = nil, principal: Extent? = nil, trailing: Extent? = nil) -> Self? {
        guard layout.barWidth > 0 else { return nil }
        var kinds: Set<Kind> = [], overflow = 0.0
        func check(_ amount: Double, _ kind: Kind) {
            guard amount > tolerance else { return }
            kinds.insert(kind); overflow = max(overflow, amount)
        }
        check(layout.total - layout.barWidth, .sumExceedsBar)
        if let leading { check(-leading.minX, .leadingOutsideBar) }
        if let principal { check(max(-principal.minX, principal.maxX - layout.barWidth), .principalOutsideBar) }
        if let trailing { check(trailing.maxX - layout.barWidth, .trailingOutsideBar) }
        return kinds.isEmpty ? nil : Self(kinds: kinds, overflow: overflow)
    }

    /// One `headerOverflow` record: the layout, the overflow, how old the side samples are, and what was going on.
    func record(_ layout: Layout, sampleAgeMs: Double, working: Bool, keyboardVisible: Bool,
                telemetry: AnnexTelemetry = .shared) {
        let span = telemetry.begin(.headerOverflow)
        span.number(.headerBarWidth, layout.barWidth)
        span.number(.headerLeadingOrigin, layout.leadingOrigin)
        span.number(.headerTrailingInset, layout.trailingInset)
        span.number(.headerLeadingReservation, layout.leadingReservation)
        span.number(.headerPrincipalWidth, layout.principalWidth)
        span.number(.headerTrailingReservation, layout.trailingReservation)
        span.number(.headerOverflow, overflow)
        span.number(.headerSampleAgeMs, sampleAgeMs)
        for kind in Kind.allCases where kinds.contains(kind) { span.event(kind.event) }
        if working { span.event(.headerWhileWorking) }
        if keyboardVisible { span.event(.headerKeyboardVisible) }
        span.end()
    }
}

/// Lets one record through per occurrence: the first overflowing check after a clean one.
struct CompanionHeaderOverflowGate: Sendable {
    private var reported = false

    mutating func shouldReport(_ finding: CompanionHeaderOverflow?) -> Bool {
        guard finding != nil else { reported = false; return false }
        defer { reported = true }
        return !reported
    }
}
