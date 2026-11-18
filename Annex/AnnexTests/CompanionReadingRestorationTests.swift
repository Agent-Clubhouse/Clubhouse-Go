import Testing
import Foundation
@testable import ClubhouseGo

@MainActor struct CompanionReadingRestorationTests {
    private func metrics(_ offset: Double = 8_000, height: Double = 10_000) -> CompanionScrollMetrics {
        .init(offset: offset, contentHeight: height, availableHeight: 1_000, topInset: 0, bottomInset: 0)
    }
    private func step(_ value: inout CompanionReadingRestoration, now: Double = 0,
                      revision: UUID? = nil, follows: Bool = false, offset: Double = 8_000,
                      height: Double = 10_000, proposed: Double = 1_200,
                      lower: Double? = 1_000) -> CompanionReadingRestoration.Step {
        value.next(now: now, revision: revision ?? value.revision, followsLatest: follows,
            metrics: metrics(offset, height: height), frameContentHeight: height, proposedOffset: proposed,
            entryLowerBound: lower)
    }

    @Test func droppedDeliveryRetriesButStreamingCannotChangeItsTarget() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200)) // Simulate the framework losing this command.
        #expect(step(&value, now: 0.05, height: 20_000, proposed: 1_800, lower: 1_000) == .scroll(1_200))
        #expect(step(&value, now: 0.1, offset: 1_200, height: 21_000) == .finish(.arrived))
        #expect(value.attempts == 2)
    }

    @Test func prefixShiftRetargetsBeforeStaleNumericArrival() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(step(&value, now: 0.05, offset: 1_200, proposed: 1_103.333, lower: 903.333) == .scroll(1_103.333))
        #expect(step(&value, now: 0.1, offset: 1_103.333, proposed: 1_103.333, lower: 903.333) == .finish(.arrived))
        #expect(value.attempts == 2)
    }

    @Test func prependIncreasesTheTargetByTheMeasuredEntryShift() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(step(&value, now: 0.05, offset: 1_200, proposed: 1_800, lower: 1_600) == .scroll(1_800))
        #expect(step(&value, now: 0.1, offset: 1_800, proposed: 1_800, lower: 1_600) == .finish(.arrived))
    }

    @Test func halfPointNoiseAndMissingEntryMeasurementsDoNotRetarget() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(step(&value, now: 0.05, proposed: 1_200.5, lower: 1_000.5) == .scroll(1_200))
        #expect(step(&value, now: 0.1, proposed: 1_800, lower: nil) == .scroll(1_200))
        #expect(step(&value, now: 0.15, offset: 1_200, proposed: 1_200.5, lower: 1_000.5) == .finish(.arrived))
        var fallback = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&fallback, lower: nil) == .scroll(1_200))
        #expect(step(&fallback, now: 0.05, proposed: 1_800, lower: nil) == .scroll(1_200))
    }

    @Test func inconsistentGeometryCannotRepinTheTarget() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(value.next(now: 0.05, revision: value.revision, followsLatest: false,
            metrics: metrics(1_200), frameContentHeight: 9_000, proposedOffset: 1_100,
            entryLowerBound: 900) == .wait)
        #expect(value.offset == 1_200)
        #expect(step(&value, now: 0.1, offset: 1_200, proposed: 1_100, lower: 900) == .scroll(1_100))
    }

    @Test func severalEntryShiftsConvergeWithinTheOriginalBudget() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        var offset = 1_200.0
        for (index, lower) in [900.0, 850, 875].enumerated() {
            #expect(step(&value, now: Double(index + 1) * 0.05, offset: offset,
                         proposed: lower + 200, lower: lower) == .scroll(lower + 200))
            offset = lower + 200
        }
        #expect(step(&value, now: 0.2, offset: offset, proposed: offset, lower: 875) == .finish(.arrived))
        #expect(value.startedAt == 0)
        #expect(value.attempts == 4)
    }

    @Test func continuousEntryShiftsExhaustTheUnchangedAttemptAndTimeLimits() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        for index in 0..<CompanionReadingRestoration.maximumAttempts {
            let lower = 1_000.0 + Double(index) * 10
            #expect(step(&value, now: Double(index) * 0.05, proposed: lower + 200, lower: lower) == .scroll(lower + 200))
        }
        #expect(step(&value, now: 1.1, proposed: 1_500, lower: 1_300) == .finish(.exhausted))
        #expect(value.startedAt == 0)
        #expect(value.attempts == 20)
        var deadline = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&deadline) == .scroll(1_200))
        #expect(step(&deadline, now: 1.99, proposed: 1_400, lower: 1_200) == .scroll(1_400))
        #expect(step(&deadline, now: 2, proposed: 1_600, lower: 1_400) == .finish(.exhausted))
        #expect(deadline.startedAt == 0)
    }

    @Test(arguments: [CompanionReadingRestoration.Outcome.touch, .scrollPhase, .navigation, .unmounted])
    func userAndNavigationCancellationPreventEveryLateReissue(outcome: CompanionReadingRestoration.Outcome) {
        let viewport = CompanionReadingViewport()
        viewport.restoration = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        viewport.isRestoring = true
        #expect(step(&viewport.restoration!) == .scroll(1_200))
        // The same cancellation used on touch-down and on the first scroll phase.
        viewport.finishRestoration(outcome, now: 0.01)
        #expect(!viewport.isRestoring)
        #expect(viewport.restoreOffset == nil)
        #expect(step(&viewport.restoration!, now: 0.05, offset: 2_400, proposed: 1_400, lower: 1_200) == .finish(outcome))
        #expect(viewport.restoration?.attempts == 1, "A drag's chosen position cannot receive a late restore")
    }

    @Test func generationAndLatestPreventReissue() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(step(&value, now: 0.05, revision: UUID(), proposed: 1_400, lower: 1_200) == .finish(.generation))
        #expect(step(&value, now: 0.05, follows: true, proposed: 1_400, lower: 1_200) == .finish(.navigation))
        #expect(value.attempts == 1)
    }

    @Test func attemptAndTimeBoundsEndRestoringEvenWithoutAnyGeometry() {
        let viewport = CompanionReadingViewport()
        viewport.restoration = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        viewport.isRestoring = true
        for index in 0..<CompanionReadingRestoration.maximumAttempts {
            #expect(step(&viewport.restoration!, now: Double(index) * 0.05) == .scroll(1_200))
        }
        #expect(step(&viewport.restoration!, now: 1.1) == .finish(.exhausted))
        viewport.finishRestoration(.exhausted, now: 1.1)
        #expect(viewport.preserveBookmarkUntilUserAction)
        #expect(!viewport.isRestoring)
        #expect(viewport.restoreOffset == nil)
        var noLayout = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(noLayout.next(now: 2, revision: noLayout.revision, followsLatest: false,
            metrics: nil, frameContentHeight: nil, proposedOffset: nil) == .finish(.exhausted))
        #expect(noLayout.attempts == 0)
    }
}
