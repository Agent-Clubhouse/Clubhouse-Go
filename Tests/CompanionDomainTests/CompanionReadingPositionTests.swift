import Testing
@testable import CompanionDomain

struct CompanionReadingPositionTests {
    @Test @MainActor func bookmarkOwnsOneViewportWhileGeometryResetsOnUnmount() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        let bookmark = store.readingBookmark(for: target)
        let viewport = bookmark.viewport
        bookmark.position = .init(followsLatest: false, entryID: "message:anchor", distanceFromEntry: 8, offset: 400, shownEntries: 300)
        for _ in 0..<20 { #expect(store.readingBookmark(for: target).viewport === viewport) }
        viewport.frames = ["message:anchor": 392...500]
        viewport.hasInitialized = true
        viewport.nativeMetrics = .init(offset: 400, contentHeight: 1_000, containerHeight: 500)
        viewport.metrics = .init(offset: 400, contentHeight: 1_000, containerHeight: 500)
        viewport.clearGeometry()
        #expect(viewport.frames.isEmpty && viewport.metrics == nil && !viewport.hasInitialized)
        #expect(viewport.nativeMetrics == nil)
        #expect(bookmark.position.entryID == "message:anchor" && bookmark.position.offset == 400)
        #expect(bookmark.position.shownEntries == 300 && !bookmark.position.followsLatest)
    }
    @Test func swiftUIAvailableViewportDoesNotCountComposerAndKeyboardInsetsTwice() {
        let bottom = CompanionScrollMetrics(offset: 500, contentHeight: 1_000, availableHeight: 500, topInset: 0, bottomInset: 166)
        #expect(bottom.maximumOffset == 500 && bottom.isAtTrueBottom)
        #expect(!CompanionReadingPosition(followsLatest: false).showsLatestButton(bottom))
        let keyboard = CompanionScrollMetrics(offset: 800, contentHeight: 1_000, availableHeight: 200, topInset: 0, bottomInset: 466)
        #expect(keyboard.isAtTrueBottom)
    }
    @Test func slowUpwardGestureAccumulatesFractionalSamples() {
        var gesture = CompanionReadingGesture()
        gesture.begin(at: 500)
        let first = gesture.movedUp(to: 499.6)
        let second = gesture.movedUp(to: 499.2)
        let third = gesture.movedUp(to: 498.8)
        #expect(!first && !second && third)
        gesture.end()
        gesture.begin(at: 500)
        let down = gesture.movedUp(to: 510)
        let reversed = gesture.movedUp(to: 508.5)
        #expect(!down && reversed, "Changing direction is measured from the gesture's highest offset")
    }
    @Test func firstPanDeltaSurvivesBothGeometryAndPhaseDeliveryOrders() {
        let before = CompanionScrollMetrics(offset: 500, contentHeight: 1_000, containerHeight: 500)
        let current = CompanionScrollMetrics(offset: 497, contentHeight: 1_000, containerHeight: 500)
        for last in [before, current] {
            var gesture = CompanionReadingGesture()
            gesture.begin(at: current, last: last, beforeLast: before)
            let paused = gesture.movedUp(to: 497)
            #expect(paused)
        }
        var keyboard = current; keyboard.containerHeight = 300
        var gesture = CompanionReadingGesture()
        gesture.begin(at: keyboard, last: before, beforeLast: nil)
        let paused = gesture.movedUp(to: 497)
        #expect(!paused, "A layout change is not itself an upward gesture")
    }
    @Test func nativeScrollToTopRecognizesTheFinalSubpixelAnimationStep() {
        let old = CompanionScrollMetrics(offset: -99.2, contentHeight: 5_000, containerHeight: 500, topInset: 100)
        let top = CompanionScrollMetrics(offset: -100, contentHeight: 5_000, containerHeight: 500, topInset: 100)
        #expect(top.didScrollUp(from: old))
        var keyboard = top; keyboard.containerHeight = 300
        #expect(!keyboard.didScrollUp(from: old))
        var initialLayout = old; initialLayout.contentHeight = 0
        #expect(!top.didScrollUp(from: initialLayout))
    }
    @Test func nativeUpwardScrollPausesBeforeReachingTopIncludingDuringGrowth() {
        let bottom = CompanionScrollMetrics(offset: 4_500, contentHeight: 5_000, containerHeight: 500)
        for height in [5_000.0, 5_100, 8_000] {
            let underway = CompanionScrollMetrics(offset: 4_400, contentHeight: height, containerHeight: 500)
            #expect(underway.didScrollUp(from: bottom))
            #expect(underway.normalizedOffset > 1, "Do not wait for the end of the native animation")
        }
    }
    @Test func streamedLayoutRollbackDoesNotPauseButANativeJumpStillDoes() {
        // Recorded iPad stream-on startup: publish the new bottom, briefly
        // restore the preceding offset, then settle at the new bottom again.
        let before = CompanionScrollMetrics(offset: 812.5, contentHeight: 1_680.5, containerHeight: 868)
        let bottom = CompanionScrollMetrics(offset: 831.5, contentHeight: 1_699.5, containerHeight: 868)
        var rollback = bottom; rollback.offset = before.offset
        #expect(!rollback.didScrollUp(from: bottom, beforeLast: before))
        var underway = bottom; underway.offset = 730
        #expect(underway.didScrollUp(from: bottom, beforeLast: before))
        var largeGrowth = bottom; largeGrowth.contentHeight = 5_000; largeGrowth.offset = 4_132
        var largeJump = largeGrowth; largeJump.offset -= 400
        #expect(largeJump.didScrollUp(from: largeGrowth, beforeLast: before), "Growth must not hide a genuine first native step")
    }
    @Test(arguments: [
        CompanionScrollMetrics(offset: 3_118.67, contentHeight: 3_372, containerHeight: 421.67, topInset: 8, bottomInset: 168.33),
        CompanionScrollMetrics(offset: 3_118.67, contentHeight: 3_372, containerHeight: 732.67, topInset: 28, bottomInset: 168.33),
        CompanionScrollMetrics(offset: 3_118.67, contentHeight: 3_372, containerHeight: 732.67, topInset: 8, bottomInset: 479.33)
    ]) func deferredViewportOrInsetRollbackIsNotUserIntent(pinned: CompanionScrollMetrics) {
        // First case is main's recorded 311pt keyboard adjustment, rounded to hundredths.
        let before = CompanionScrollMetrics(offset: 2_807.67, contentHeight: 3_372, containerHeight: 732.67,
                                            topInset: 8, bottomInset: 168.33)
        var rollback = pinned
        rollback.offset = before.normalizedOffset - rollback.topInset
        #expect(!rollback.didScrollUp(from: pinned, beforeLast: before))
        var nativeJump = rollback
        nativeJump.offset -= 100
        #expect(nativeJump.didScrollUp(from: pinned, beforeLast: before),
                "A different upward move is not explained by that layout rollback")
        #expect(rollback.didScrollUp(from: pinned, beforeLast: pinned),
                "Once dimensions are stable, the same movement still recognizes non-pan user scrolling")
        #expect(rollback.didScrollUp(from: pinned, beforeLast: pinned, currentViewport: rollback),
                "Stable UIKit geometry must preserve non-pan intent, not disable the fallback")
        #expect(!rollback.didScrollUp(from: pinned, beforeLast: pinned, currentViewport: before),
                "A duplicate pinned sample cannot erase UIKit's concurrent layout change")
    }
    @Test func layoutChangesAndFollowingAStreamAreNotUpwardScrolling() {
        let bottom = CompanionScrollMetrics(offset: 4_500, contentHeight: 5_000, containerHeight: 500)
        let up = CompanionScrollMetrics(offset: 4_400, contentHeight: 5_000, containerHeight: 500)
        var keyboard = up; keyboard.containerHeight = 300
        var topInset = up; topInset.topInset = 20
        var bottomInset = up; bottomInset.bottomInset = 200
        var shrink = up; shrink.contentHeight = 4_900
        let unchanged = bottom
        let waitingForLayout = CompanionScrollMetrics(offset: 4_500, contentHeight: 5_100, containerHeight: 500)
        let following = CompanionScrollMetrics(offset: 4_600, contentHeight: 5_100, containerHeight: 500)
        for metrics in [keyboard, topInset, bottomInset, shrink, unchanged, waitingForLayout, following] {
            #expect(!metrics.didScrollUp(from: bottom))
        }
    }
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

    @Test(arguments: [400.0, 740]) func nextResumesFollowingForAVisibleOrClampedDestination(offset: Double) {
        let metrics = CompanionScrollMetrics(offset: offset, contentHeight: 1_000, containerHeight: 300, topInset: 20, bottomInset: 40)
        let targets = ["a", "b", "c"]
        let frames: [String: ClosedRange<Double>] = ["a": 0...500, "b": 600...650, "c": 900...950]
        #expect(CompanionAssistantNavigation.destination(in: targets, frames: frames, viewportTop: metrics.normalizedOffset, forward: true) != nil)
        #expect(CompanionAssistantNavigation.nextDestination(in: targets, frames: frames, metrics: metrics) == nil)
    }

    @Test func nextStillTargetsAnOffscreenMessage() {
        let metrics = CompanionScrollMetrics(offset: 100, contentHeight: 1_000, containerHeight: 300, topInset: 20, bottomInset: 40)
        #expect(CompanionAssistantNavigation.nextDestination(in: ["a", "b"], frames: ["a": 0...100, "b": 600...650], metrics: metrics) == "b")
    }
}
