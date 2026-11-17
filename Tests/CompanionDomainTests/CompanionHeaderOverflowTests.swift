import Foundation
import Testing

@testable import ClubhouseTransport
@testable import CompanionDomain

/// #554: the header overflow detector, its once-per-occurrence gate and the record it writes.
struct CompanionHeaderOverflowTests {
    /// A 440pt bar with Back: side span 109, so the identity gets 440 − 2·(109 + 16) = 190 and the sum is exact.
    private let fitting = CompanionHeaderOverflow.Layout(barWidth: 440, stateBarWidth: 440, leadingOrigin: 60, trailingInset: 20,
                                                         leadingReservation: 49, principalWidth: 190, trailingReservation: 89)
    private func extent(_ minX: Double, _ maxX: Double, bar: Double = 440) -> CompanionHeaderOverflow.Extent {
        .init(minX: minX, maxX: maxX, barWidth: bar)
    }

    @Test func anExactlyFilledBarIsNotAnOverflow() {
        #expect(fitting.total == 440)
        #expect(CompanionHeaderOverflow.detect(fitting) == nil)
        #expect(CompanionHeaderOverflow.detect(fitting, leading: extent(60, 109), principal: extent(125, 315),
                                               trailing: extent(331, 420)) == nil)
        // Rounding within half a point is not an overflow.
        var rounded = fitting; rounded.principalWidth += 0.4
        #expect(CompanionHeaderOverflow.detect(rounded) == nil)
    }

    @Test func aStaleBarWidthOverflowsTheSum() throws {
        var stale = fitting; stale.barWidth = 430
        let finding = try #require(CompanionHeaderOverflow.detect(stale))
        #expect(finding.kinds == [.sumExceedsBar])
        #expect(finding.overflow == 10)
    }

    @Test func itemsLeavingTheBarAreReportedWithTheLargestOverflow() throws {
        let finding = try #require(CompanionHeaderOverflow.detect(
            fitting, leading: extent(-2, 47), principal: extent(110, 330), trailing: extent(360, 452)))
        #expect(finding.kinds == [.leadingOutsideBar, .trailingOutsideBar])
        #expect(finding.overflow == 12)
        let clipped = try #require(CompanionHeaderOverflow.detect(fitting, principal: extent(-8, 182)))
        #expect(clipped.kinds == [.principalOutsideBar])
        #expect(clipped.overflow == 8)
    }

    @Test func noBarYetIsNeverAnOverflow() {
        var unmeasured = fitting; unmeasured.barWidth = 0
        #expect(CompanionHeaderOverflow.detect(unmeasured, trailing: extent(400, 600, bar: 0)) == nil)
    }

    @Test func anExtentFromAnotherBarWidthNeverCounts() {
        // After rotating to a 956pt bar, the trailing extent measured at 440 would sit "outside" a narrower bar.
        let rotatedBack = fitting
        #expect(CompanionHeaderOverflow.detect(rotatedBack, trailing: extent(860, 945, bar: 956)) == nil)
        #expect(CompanionHeaderOverflow.detect(rotatedBack, trailing: extent(360, 452)) != nil, "The same width still counts")
    }

    @Test func theGateLetsOneRecordThroughPerOccurrence() {
        var gate = CompanionHeaderOverflowGate()
        let overflow = CompanionHeaderOverflow(kinds: [.trailingOutsideBar], overflow: 12)
        let reports = [nil, overflow, overflow, overflow, nil, overflow].map { gate.shouldReport($0) }
        // One record at the start of each occurrence; a clean check ends it, so the next one reports again.
        #expect(reports == [false, true, false, false, false, true])
    }

    @Test func theRecordCarriesOnlyNumbersAndClosedEvents() throws {
        let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
        var stale = fitting; stale.barWidth = 430
        let finding = try #require(CompanionHeaderOverflow.detect(stale, trailing: extent(360, 452, bar: 430)))
        finding.record(stale, sampleAgeMs: 250, working: true, keyboardVisible: false, telemetry: telemetry)
        let record = try #require(telemetry.snapshot().records.last)
        #expect(record.operation == .headerOverflow)
        #expect(record.measurements["headerBarWidth"] == 430)
        #expect(record.measurements["headerStateBarWidth"] == 440)
        #expect(record.measurements["headerLeadingOrigin"] == 60)
        #expect(record.measurements["headerTrailingInset"] == 20)
        #expect(record.measurements["headerLeadingReservation"] == 49)
        #expect(record.measurements["headerPrincipalWidth"] == 190)
        #expect(record.measurements["headerTrailingReservation"] == 89)
        #expect(record.measurements["headerOverflow"] == 22)
        #expect(record.measurements["headerSampleAgeMs"] == 250)
        #expect(record.events == ["headerSumExceedsBar", "headerTrailingOutsideBar", "headerAfterResize", "headerWhileWorking"])
    }

    @Test func aSettledWidthIsNotTaggedAsAResize() throws {
        let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
        let finding = try #require(CompanionHeaderOverflow.detect(fitting, trailing: extent(360, 452)))
        finding.record(fitting, sampleAgeMs: 0, working: false, keyboardVisible: true, telemetry: telemetry)
        let record = try #require(telemetry.snapshot().records.last)
        #expect(record.events == ["headerTrailingOutsideBar", "headerKeyboardVisible"])
    }
}
