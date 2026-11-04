import Testing
import Foundation
@testable import ClubhouseGo

@MainActor struct CompanionReadingRestorationTests {
    private func metrics(_ offset: Double = 8_000, height: Double = 10_000) -> CompanionScrollMetrics {
        .init(offset: offset, contentHeight: height, availableHeight: 1_000, topInset: 0, bottomInset: 0)
    }
    private func step(_ value: inout CompanionReadingRestoration, now: Double = 0,
                      revision: UUID? = nil, follows: Bool = false, offset: Double = 8_000,
                      height: Double = 10_000, proposed: Double = 1_200) -> CompanionReadingRestoration.Step {
        value.next(now: now, revision: revision ?? value.revision, followsLatest: follows,
            metrics: metrics(offset, height: height), frameContentHeight: height, proposedOffset: proposed)
    }

    @Test func droppedDeliveryRetriesButStreamingCannotChangeItsTarget() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200)) // Simulate the framework losing this command.
        #expect(step(&value, now: 0.05, height: 20_000, proposed: 1_800) == .scroll(1_200))
        #expect(step(&value, now: 0.1, offset: 1_200, height: 21_000) == .finish(.arrived))
        #expect(value.attempts == 2)
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
        #expect(step(&viewport.restoration!, now: 0.05, offset: 2_400) == .finish(outcome))
        #expect(viewport.restoration?.attempts == 1, "A drag's chosen position cannot receive a late restore")
    }

    @Test func generationAndLatestPreventReissue() {
        var value = CompanionReadingRestoration(revision: UUID(), startedAt: 0)
        #expect(step(&value) == .scroll(1_200))
        #expect(step(&value, now: 0.05, revision: UUID()) == .finish(.generation))
        #expect(step(&value, now: 0.05, follows: true) == .finish(.navigation))
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
