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
    @Test func incomingRowsAndStreamingSlicesCannotEvictTheReadingAnchor() {
        let rows = (1...200).map { CompanionTimelineRow.item(.message(.init(id: "m\($0)", role: .assistant, text: "Reply \($0)"))) }
        let pinned = CompanionTimelineWindow(rows: rows, limit: 10, retaining: "message:m150:slice:0")
        // Short replies use the timeline row id as their first slice id.
        let anchorID = CompanionTimelineEntry.entries(for: [rows[149]])[0].id
        let window = CompanionTimelineWindow(rows: rows, limit: 10, retaining: anchorID)
        #expect(window.entries.contains { $0.id == anchorID })
        #expect(window.entries.count >= 51)
        #expect(pinned.hiddenCount == 190, "An absent bookmark must not prepare hidden history")
    }
    @Test func bounceTinyScrollAndKeyboardRecomputeActualBottom() {
        for offset in [540.0, 545, 539, 525] {
            let metrics = CompanionScrollMetrics(offset: offset, contentHeight: 1_000, containerHeight: 500, bottomInset: 40)
            #expect(metrics.isAtLatest)
            #expect(CompanionReadingPosition(followsLatest: false).showsLatestButton(metrics) == !metrics.isAtTrueBottom)
        }
        #expect(!CompanionScrollMetrics(offset: 523, contentHeight: 1_000, containerHeight: 500, bottomInset: 40).isAtLatest)
        #expect(CompanionScrollMetrics(offset: -100, contentHeight: 200, containerHeight: 800, topInset: 100, bottomInset: 50).isAtLatest)
    }
    @Test func navigationUsesViewportTopAndIncludesStructuredQuestions() {
        let entries: [CompanionTimelineEntry] = [.row(.item(.question(.init(id: "q", prompts: []))))]
        #expect(CompanionAssistantNavigation.targets(in: entries) == ["question:q"])
        let targets = ["a", "b", "c"]
        let frames: [String: ClosedRange<Double>] = ["a": 0...100, "b": 100...200, "c": 200...300]
        #expect(CompanionAssistantNavigation.destination(in: targets, frames: frames, viewportTop: 110, forward: false) == "b")
        #expect(CompanionAssistantNavigation.destination(in: targets, frames: frames, viewportTop: 100, forward: false) == "a")
        #expect(CompanionAssistantNavigation.destination(in: targets, frames: frames, viewportTop: 110, forward: true) == "c")
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
