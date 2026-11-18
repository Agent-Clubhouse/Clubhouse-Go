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

    @Test func pausedBookmarkBoundaryAndExactMessageIdentitySurviveSeeding() {
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
        let canonical = try #require(seed.entryID)
        let window = try #require(CompanionTimelineWindow(rows: rows, startingAt: canonical))
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

    @Test func pausedWindowStartsAtItsCanonicalBookmarkAndRetainsEveryLaterEntry() throws {
        let rows = (0..<40).map { CompanionTimelineRow.item(.message(.init(id: "row-\($0)", role: .user, text: "Row \($0)"))) }
        let position = CompanionReadingPosition(followsLatest: false, entryID: rows[24].id, shownEntries: 150)
        let seed = opening(position, rows: rows)
        let canonical = try #require(seed.entryID)
        let window = try #require(CompanionTimelineWindow(rows: rows, startingAt: canonical))
        #expect(window.entries.first?.id == seed.entryID,
                "User-approved #582 contract: a paused remount starts WITH its canonical bookmark")
        #expect(window.hiddenCount > 0)
        #expect(window.entries.map(\.id) == rows[24...].map(\.id))
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
    @Test func startingInsideAReplyAndThenExpandingRecoversItsBeginningAndPriorHistory() throws {
        let row = CompanionTimelineRow.item(.message(.init(id: "long", role: .assistant,
            text: String(repeating: "A paragraph of reply text.\n\n", count: 500))))
        let rows: [CompanionTimelineRow] = [.item(.notice(id: "older", text: "Older history")), row,
            .item(.notice(id: "tail", text: "Tail"))]
        let slices = CompanionTimelineEntry.entries(for: [row])
        let selected = try #require(slices.dropFirst(2).first)
        let window = try #require(CompanionTimelineWindow(rows: rows, startingAt: selected.id))
        #expect(window.entries.first?.id == selected.id && window.hiddenCount > 0)
        let earlier = try #require(CompanionTimelineWindow.precedingStart(in: rows, before: selected.id))
        let expanded = try #require(CompanionTimelineWindow(rows: rows, startingAt: earlier))
        #expect(expanded.entries.contains { $0.id == slices.first?.id })
        #expect(expanded.entries == CompanionTimelineEntry.entries(for: rows))
        #expect(expanded.hiddenCount == 0)
    }

    @Test func deepBookmarkDoesNotPrepareTheHiddenPrefixAndTailGrowthKeepsItsBoundary() throws {
        let rows = (0..<2_000).map { CompanionTimelineRow.item(.notice(id: "row-\($0)", text: "Row \($0)")) }
        let window = try #require(CompanionTimelineWindow(rows: rows, startingAt: rows[1_000].id))
        #expect(window.preparedRowCount == 1_000 && window.hiddenCount == 1_000)
        let grown = try #require(CompanionTimelineWindow(rows: rows + [.item(.notice(id: "new-tail", text: "New tail"))],
                                                         startingAt: rows[1_000].id))
        #expect(grown.entries.first?.id == window.entries.first?.id)
        #expect(Array(grown.entries.dropLast()) == window.entries)
        let earlier = try #require(CompanionTimelineWindow.precedingStart(in: rows, before: rows[1_000].id))
        let expanded = try #require(CompanionTimelineWindow(rows: rows, startingAt: earlier))
        #expect(expanded.entries.count == window.entries.count + CompanionTimelineWindow.pageSize)
        #expect(Array(expanded.entries.suffix(window.entries.count)) == window.entries)
    }

    @Test func missingExactWindowBoundaryFailsInsteadOfPretendingItsFirstRowIsCanonical() {
        let rows: [CompanionTimelineRow] = [.item(.message(.init(id: "current", role: .assistant, text: "Current")))]
        #expect(CompanionTimelineWindow(rows: rows, startingAt: "message:old-session") == nil)
        #expect(CompanionTimelineWindow(rows: rows, startingAt: "message:current#999") == nil)
    }

}
