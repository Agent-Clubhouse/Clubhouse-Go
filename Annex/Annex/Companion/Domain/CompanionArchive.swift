import Foundation
import Observation

struct CompanionSessionSummary: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var lastActiveAt: Date?
    var provider: String?
}

struct CompanionArchivePage: Sendable {
    var items: [CompanionTimelineItem]
    var nextBeforeSequence: Int64?
}

@MainActor protocol CompanionArchiveReading: AnyObject {
    /// Returns the accumulated, deduplicated transcript through this page.
    func load(before: Int64?) async throws -> CompanionArchivePage
}

@MainActor @Observable final class CompanionArchiveTranscript {
    private(set) var items: [CompanionTimelineItem] = []
    private(set) var isLoading = false
    private(set) var isLoaded = false
    private(set) var nextBeforeSequence: Int64?
    private(set) var error: String?
    private let reader: any CompanionArchiveReading

    init(reader: any CompanionArchiveReading) { self.reader = reader }

    func loadEarlier() async {
        guard !isLoading, !isLoaded || nextBeforeSequence != nil else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let page = try await reader.load(before: nextBeforeSequence)
            items = page.items
            nextBeforeSequence = page.nextBeforeSequence
            isLoaded = true
        } catch { self.error = error.localizedDescription }
    }
}
