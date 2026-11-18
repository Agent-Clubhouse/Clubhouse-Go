#if DEBUG
import SwiftUI

/// Opt-in test observation only. No transcript text, State writes, timers or production callback.
@MainActor enum CompanionReadingOpeningProbe {
    enum Phase: String { case body, geometry, frames, historyTask, scroll, jump }
    struct Sample {
        let phase: Phase
        let mountID: UUID
        let target: CompanionTarget
        let requestID: UUID?
        let followsLatest: Bool
        let shownEntries: Int
        let requestedEntryID: String?
        let requestedBottom: Bool
        let pointY: Double?
        let windowFirstID: String?
        let historyRevision: UUID
        let offset: Double?
        let entryLowerBound: Double?
        let latestVisible: Bool
    }
    static var record: ((Sample) -> Void)?
}
#endif
