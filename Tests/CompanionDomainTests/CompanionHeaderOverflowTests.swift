import Foundation
import Testing

@testable import ClubhouseTransport
@testable import CompanionDomain

/// #554: the header overflow detector, its once-per-occurrence gate and the record it writes.
struct CompanionHeaderOverflowTests {
    /// A 440pt bar with Back: side span 109, so the identity gets 440 − 2·(109 + 16) = 190 and the sum is exact.
    private let fitting = CompanionHeaderOverflow.Layout(barWidth: 440, leadingOrigin: 60, trailingInset: 20,
                                                         leadingReservation: 49, principalWidth: 190, trailingReservation: 89)

    @Test func anExactlyFilledBarIsNotAnOverflow() {
        #expect(fitting.total == 440)
        #expect(CompanionHeaderOverflow.detect(fitting) == nil)
        #expect(CompanionHeaderOverflow.detect(fitting, leading: .init(minX: 60, maxX: 109), principal: .init(minX: 125, maxX: 315),
                                               trailing: .init(minX: 331, maxX: 420)) == nil)
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
            fitting, leading: .init(minX: -2, maxX: 47), principal: .init(minX: 110, maxX: 330), trailing: .init(minX: 360, maxX: 452)))
        #expect(finding.kinds == [.leadingOutsideBar, .trailingOutsideBar])
        #expect(finding.overflow == 12)
        let clipped = try #require(CompanionHeaderOverflow.detect(fitting, principal: .init(minX: -8, maxX: 182)))
        #expect(clipped.kinds == [.principalOutsideBar])
        #expect(clipped.overflow == 8)
    }

    @Test func noBarYetIsNeverAnOverflow() {
        var unmeasured = fitting; unmeasured.barWidth = 0
        #expect(CompanionHeaderOverflow.detect(unmeasured, trailing: .init(minX: 400, maxX: 600)) == nil)
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
        let finding = try #require(CompanionHeaderOverflow.detect(stale, trailing: .init(minX: 360, maxX: 452)))
        finding.record(stale, sampleAgeMs: 250, working: true, keyboardVisible: false, telemetry: telemetry)
        let record = try #require(telemetry.snapshot().records.last)
        #expect(record.operation == .headerOverflow)
        #expect(record.measurements["headerBarWidth"] == 430)
        #expect(record.measurements["headerLeadingOrigin"] == 60)
        #expect(record.measurements["headerTrailingInset"] == 20)
        #expect(record.measurements["headerLeadingReservation"] == 49)
        #expect(record.measurements["headerPrincipalWidth"] == 190)
        #expect(record.measurements["headerTrailingReservation"] == 89)
        #expect(record.measurements["headerOverflow"] == 22)
        #expect(record.measurements["headerSampleAgeMs"] == 250)
        #expect(record.events == ["headerSumExceedsBar", "headerTrailingOutsideBar", "headerWhileWorking"])
    }
}
