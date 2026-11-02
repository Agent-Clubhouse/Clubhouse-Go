import Foundation

/// Insets participate in the scrollable range, including when the content is shorter than the viewport.
struct CompanionScrollMetrics: Equatable, Sendable {
    var offset: Double
    var contentHeight: Double
    var containerHeight: Double
    var topInset: Double = 0
    var bottomInset: Double = 0
    var normalizedOffset: Double { offset + topInset }
    var maximumOffset: Double { max(0, contentHeight + topInset + bottomInset - containerHeight) }
    var isAtLatest: Bool { normalizedOffset >= maximumOffset - 16 }
    var isAtTrueBottom: Bool { normalizedOffset >= maximumOffset - 1 }
    func didReachTop(from old: Self) -> Bool {
        old.containerHeight == containerHeight && old.topInset == topInset && old.bottomInset == bottomInset
            && old.maximumOffset > 0 && abs(contentHeight - old.contentHeight) < containerHeight
            && normalizedOffset < old.normalizedOffset && normalizedOffset <= 1
    }
}

extension CompanionScrollMetrics {
    /// SwiftUI's available container height already excludes its content insets. Convert it to full bounds before
    /// applying the scroll-range formula, otherwise keyboard/composer insets are counted twice at the bottom.
    init(offset: Double, contentHeight: Double, availableHeight: Double, topInset: Double, bottomInset: Double) {
        self.init(offset: offset, contentHeight: contentHeight, containerHeight: availableHeight + topInset + bottomInset,
                  topInset: topInset, bottomInset: bottomInset)
    }
}

/// Measure a gesture cumulatively: a slow drag can move over a point through many subpixel geometry samples.
struct CompanionReadingGesture {
    private var highestOffset: Double?
    mutating func begin(at offset: Double) { highestOffset = offset }
    mutating func begin(at current: CompanionScrollMetrics, last: CompanionScrollMetrics?, beforeLast: CompanionScrollMetrics?) {
        // Geometry and phase callbacks can arrive in either order. Retain the first pan delta in both cases.
        let before = last == current ? beforeLast : last
        if let before, before.contentHeight == current.contentHeight, before.containerHeight == current.containerHeight,
           before.topInset == current.topInset, before.bottomInset == current.bottomInset {
            begin(at: max(before.normalizedOffset, current.normalizedOffset))
        } else { begin(at: current.normalizedOffset) }
    }
    mutating func movedUp(to offset: Double) -> Bool {
        guard let highestOffset else { begin(at: offset); return false }
        self.highestOffset = max(highestOffset, offset)
        return offset < highestOffset - 1
    }
    mutating func end() { highestOffset = nil }
}

/// Content coordinates avoid depending on estimates of row heights. One visible entry and its pixel offset survive
/// prepends, grouping changes above it, and keyboard/composer resizing. Stored per conversation outside snapshots.
struct CompanionReadingPosition: Equatable, Sendable {
    var followsLatest = true
    var entryID: String?
    var distanceFromEntry: Double = 0
    var offset: Double = 0
    var shownEntries = CompanionTimelineWindow.pageSize

    func showsLatestButton(_ metrics: CompanionScrollMetrics) -> Bool { !followsLatest && !metrics.isAtTrueBottom }

    mutating func capture(offset: Double, frames: [String: ClosedRange<Double>]) {
        self.offset = offset
        var first: (key: String, value: ClosedRange<Double>)?
        for entry in frames where entry.value.upperBound > offset {
            if first == nil || entry.value.lowerBound < first!.value.lowerBound { first = entry }
        }
        if let first {
            entryID = first.key
            distanceFromEntry = offset - first.value.lowerBound
        }
    }
    func restoredOffset(frames: [String: ClosedRange<Double>]) -> Double {
        guard let entryID, let frame = frames[entryID] else { return offset }
        return max(0, frame.lowerBound + distanceFromEntry)
    }
}

enum CompanionAssistantNavigation {
    static func targets(in entries: [CompanionTimelineEntry]) -> [String] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            let message: CompanionMessage
            switch entry {
            case .row(.item(.question)): return entry.id
            case .row(.item(.message(let value))), .slice(let value, _): message = value
            default: return nil
            }
            guard message.isUserFacingAssistant, case .you = message.display,
                  !CompanionMessageRouting.stripTaskMarker(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(message.id).inserted else { return nil }
            return entry.id
        }
    }
    static func destination(in targets: [String], frames: [String: ClosedRange<Double>], viewportTop: Double, forward: Bool) -> String? {
        if forward { return targets.first { (frames[$0]?.lowerBound ?? -.infinity) > viewportTop + 1 } }
        return targets.last { (frames[$0]?.lowerBound ?? .infinity) < viewportTop - 1 }
    }

    static func previous(in targets: [String], before current: String?) -> String? {
        guard let current, let index = targets.firstIndex(of: current) else { return targets.last }
        return index > 0 ? targets[index - 1] : nil
    }
    static func next(in targets: [String], after current: String?) -> String? {
        guard let current, let index = targets.firstIndex(of: current) else { return nil }
        return index + 1 < targets.count ? targets[index + 1] : nil
    }
}

@MainActor final class CompanionReadingBookmark {
    var position = CompanionReadingPosition()
    var hasMounted = false
}
