import Foundation
import Testing
@testable import CompanionDomain

@MainActor struct CompanionReadingOpeningTests {
    private func opening(_ position: CompanionReadingPosition, mounted: Bool = true,
                         rows: [CompanionTimelineRow] = []) -> CompanionReadingOpening {
        .init(position: position, hasMounted: mounted, initialLimit: 20, rows: rows)
    }

    @Test func freshAndLatestUseTheBottomFallbackWithoutBorrowingAPausedEntry() {
        let fresh = opening(.init(), mounted: false)
        #expect(fresh.followsLatest && fresh.shownEntries == 20 && fresh.entryID == nil)
        let latest = opening(.init(followsLatest: true, entryID: "message:old", shownEntries: 300))
        #expect(latest.followsLatest && latest.shownEntries == 300 && latest.entryID == nil)
    }

    @Test func expandedPausedWindowAndExactMessageIdentitySurviveSeeding() {
        let row = CompanionTimelineRow.item(.message(.init(id: "ordinary", role: .assistant, text: "A real reply")))
        let position = CompanionReadingPosition(followsLatest: false, entryID: row.id, distanceFromEntry: 40,
                                               offset: 900, shownEntries: 300)
        let seed = opening(position, rows: [row])
        #expect(!seed.followsLatest && seed.shownEntries == 300 && seed.entryID == row.id)
        #expect(position.offset == 900 && position.distanceFromEntry == 40,
                "An opening seed must not replace the later geometry-based pixel target")
    }

    @Test func groupedQuestionAliasUsesTheExistingVisibleGroupWithoutChangingTheBookmark() throws {
        let first = CompanionQuestion(id: "first", prompts: [])
        let later = CompanionQuestion(id: "later", prompts: [], hasUnreadablePrompts: true)
        let rows = CompanionTimelineFolding.rows(for: [.question(first), .question(later)], collapseDesktopQuestions: true)
        let position = CompanionReadingPosition(followsLatest: false, entryID: "question:later", shownEntries: 150)
        let seed = opening(position, rows: rows)
        let group = try #require(rows.first)
        #expect(group.id == "question:first" && seed.entryID == group.id)
        #expect(position.entryID == "question:later", "The semantic bookmark still names the authoritative request")
        let window = CompanionTimelineWindow(rows: rows, limit: seed.shownEntries, retaining: position.entryID)
        #expect(window.entries.contains { $0.id == seed.entryID })
    }

    @Test func absentGroupRemovedMessageAndOldSessionUseTheBottomFallback() {
        let current = CompanionTimelineRow.item(.message(.init(id: "new-session", role: .assistant, text: "Current history")))
        for missing in ["question:unloaded-group", "message:removed", "message:old-session"] {
            let seed = opening(.init(followsLatest: false, entryID: missing, offset: 800), rows: [current])
            #expect(!seed.followsLatest && seed.entryID == nil,
                    "No nonexistent initial ID request may silently leave the transcript at an unspecified position")
        }
    }

    @Test func pausedWindowRetainsAnEntryBelowItsFirstLoadedRow() throws {
        let rows = (0..<40).map { CompanionTimelineRow.item(.message(.init(id: "row-\($0)", role: .user, text: "Row \($0)"))) }
        let position = CompanionReadingPosition(followsLatest: false, entryID: rows[24].id, shownEntries: 150)
        let seed = opening(position, rows: rows)
        let window = CompanionTimelineWindow(rows: rows, limit: seed.shownEntries, retaining: position.entryID)
        #expect(window.entries.first?.id != seed.entryID,
                "An expanded window cannot be treated as though its top were the saved entry")
        #expect(window.entries.contains { $0.id == seed.entryID })
        #expect(seed.entryID == rows[24].id)
    }

    @Test func slicedEntryMustExistRatherThanOnlyShareTheMessagePrefix() throws {
        let message = CompanionMessage(id: "long", role: .assistant, text: String(repeating: "long reply ", count: 500))
        let row = CompanionTimelineRow.item(.message(message))
        let entries = CompanionTimelineEntry.entries(for: [row])
        let actual = try #require(entries.dropFirst().first)
        #expect(opening(.init(followsLatest: false, entryID: actual.id), rows: [row]).entryID == actual.id)
        #expect(opening(.init(followsLatest: false, entryID: row.id + "#999"), rows: [row]).entryID == nil)
    }
}
