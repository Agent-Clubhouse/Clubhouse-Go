import Testing
@testable import CompanionDomain

struct CompanionReadingPositionTests {
    @Test func latestIndicatorStaysHiddenWhenDragOrKeyboardLeavesUsAtBottom() {
        // A drag pauses following before geometry changes. The indicator must use actual geometry too.
        let bookmark = CompanionReadingPosition(followsLatest: false)
        let bottom = CompanionScrollMetrics(offset: 540, contentHeight: 1_000, containerHeight: 500, bottomInset: 40)
        #expect(!bookmark.showsLatestButton(bottom))
    }
    @Test func latestTracksKeyboardAndSafeArea() {
        #expect(CompanionScrollMetrics(offset: 540, contentHeight: 1_000, containerHeight: 500, bottomInset: 40).isAtLatest)
        #expect(!CompanionScrollMetrics(offset: 100, contentHeight: 1_000, containerHeight: 500, bottomInset: 40).isAtLatest)
        #expect(CompanionScrollMetrics(offset: 840, contentHeight: 1_000, containerHeight: 200, bottomInset: 40).isAtLatest)
    }
    @Test func bookmarkSurvivesPrependAndResizeAboveVisibleEntry() {
        var bookmark = CompanionReadingPosition(followsLatest: false)
        bookmark.capture(offset: 110, frames: ["a": 0...100, "b": 100...200, "c": 200...300])
        #expect(bookmark.entryID == "b")
        #expect(bookmark.restoredOffset(frames: ["b": 500...600]) == 510)
        #expect(bookmark.restoredOffset(frames: [:]) == 110)
    }
    @Test func navigationOnlyTargetsUserFacingAssistantRepliesOncePerMessage() {
        let rows: [CompanionTimelineRow] = [
            .item(.message(.init(id: "user", role: .user, text: "Hello"))),
            .item(.message(.init(id: "reply", role: .assistant, text: String(repeating: "Reply.\n\n", count: 200)))),
            .item(.message(.init(id: "system", role: .system, text: "Thinking"))),
            .item(.message(.init(id: "helper", role: .user, text: "[FROM:Builder] Hi", source: "mcp"))),
            .item(.message(.init(id: "empty", role: .assistant, text: ""))),
            .item(.message(.init(id: "last", role: .assistant, text: "Done")))
        ]
        let targets = CompanionAssistantNavigation.targets(in: CompanionTimelineEntry.entries(for: rows, budget: 100))
        #expect(targets.count == 2)
        #expect(CompanionAssistantNavigation.previous(in: targets, before: nil) == targets.last)
        #expect(CompanionAssistantNavigation.previous(in: targets, before: targets.first) == nil)
        #expect(CompanionAssistantNavigation.next(in: targets, after: targets.first) == targets.last)
        #expect(CompanionAssistantNavigation.next(in: targets, after: targets.last) == nil)
    }
}
