#if DEBUG
import SwiftUI

/// Opt-in test observation only. No transcript text, State writes, timers or production callback.
@MainActor enum CompanionReadingOpeningProbe {
    enum Phase: String { case body, geometry, frames, historyTask, scroll, handoff, arrived, cancelled, unmounted, saved, phaseChanged, jump }
    struct Sample {
        let phase: Phase
        let mountID: UUID
        let target: CompanionTarget
        let requestID: UUID?
        let detail: String?
        let followsLatest: Bool
        let shownEntries: Int
        let requestedEntryID: String?
        let requestedBottom: Bool
        let requestedTop: Bool
        let windowStartID: String?
        let savedDistanceFromEntry: Double
        let pointY: Double?
        let positionedByUser: Bool
        let windowFirstID: String?
        let historyRevision: UUID
        let offset: Double?
        let entryLowerBound: Double?
        let latestVisible: Bool
    }
    static var record: ((Sample) -> Void)?
    static var didComputeSeed: ((CompanionTarget) -> Void)?
}
#endif
