import XCTest
import SwiftUI
@testable import ClubhouseGo

/// Layout-only fixtures: no store, service, transport, provider, or feedback calls.
@MainActor final class CompanionRecoveryStatusViewTests: XCTestCase {
    private func size(status: CompanionRecoveryStatus, width: CGFloat = 320,
                      typeSize: DynamicTypeSize = .large) -> CGSize {
        let host = UIHostingController(rootView: CompanionRecoveryStatusView(status: status, onRetry: { _ in })
            .dynamicTypeSize(typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testAutomaticRecoveryUsesCompactRowDespiteResync() {
        for connection in [CompanionConnection.connecting, .reconnecting, .synchronizing, .connected] {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: true, requiresResync: true, error: nil)
            let measured = size(status: status, width: 390)
            XCTAssertLessThanOrEqual(measured.width, 390)
            XCTAssertGreaterThanOrEqual(measured.height, 44, "Details target remains at least 44 points")
            XCTAssertLessThanOrEqual(measured.height, 60, "Automatic recovery stays a single compact row at standard text size")
        }
    }

    func testEveryUnavailableStateFitsNarrowWidthAndRetainsActionSpace() {
        for connection in [CompanionConnection.offline, .failed("Synthetic TLS problem"), .connected] {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: false, requiresResync: true,
                                                 error: "Synthetic history problem")
            XCTAssertNotNil(status.retryAction)
            let measured = size(status: status)
            XCTAssertLessThanOrEqual(measured.width, 320)
            XCTAssertGreaterThanOrEqual(measured.height, 44)
            XCTAssertLessThan(measured.height, 180)
        }
    }

    func testAccessibilityTextGrowsVerticallyWithoutWidthOverflowOrFontCap() {
        for connection in [CompanionConnection.reconnecting, .failed("Synthetic failure"), .connected] {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: false, requiresResync: true, error: nil)
            let standard = size(status: status)
            let accessible = size(status: status, typeSize: .accessibility5)
            XCTAssertLessThanOrEqual(accessible.width, 320)
            XCTAssertGreaterThan(accessible.height, standard.height)
        }
    }

    func testCleanConnectedStatusTakesNoLayoutSpace() {
        let status = CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: false, error: nil)
        XCTAssertEqual(size(status: status).height, 0)
    }

    func testFullErrorDetailsCanBeHostedAtAccessibilitySize() {
        let error = String(repeating: "Synthetic history error with full explanation.\n", count: 40)
        let status = CompanionRecoveryStatus(connection: .failed("Synthetic connection error"), isLoading: false,
                                             requiresResync: true, error: error)
        let host = UIHostingController(rootView: CompanionRecoveryStatusDetails(status: status, onRetry: { _ in })
            .dynamicTypeSize(.accessibility5))
        let measured = host.sizeThatFits(in: CGSize(width: 320, height: 600))
        XCTAssertLessThanOrEqual(measured.width, 320)
        XCTAssertGreaterThan(measured.height, 0)
        XCTAssertTrue(status.explanation.contains(error))
    }
}
