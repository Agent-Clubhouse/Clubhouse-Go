import XCTest
import SwiftUI
@testable import ClubhouseGo

/// Layout-only fixtures: no store, service, transport, provider, or feedback calls.
/// These sizeThatFits checks do not prove hit targets, accessibility selectors, sheet
/// presentation, or retry routing. Those need the integrated synthetic UI fixture.
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
            XCTAssertGreaterThanOrEqual(measured.height, 44, "Row retains the minimum action-height budget")
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

    func testRecoveryCardsLeaveBackgroundVisibleAtBothEdges() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 100)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        for dark in [false, true] {
            for connection in [CompanionConnection.offline, .reconnecting, .connected] {
                let status = CompanionRecoveryStatus(connection: connection, isLoading: false, requiresResync: true, error: nil)
                let controller = UIHostingController(rootView:
                    CompanionRecoveryStatusView(status: status, onRetry: { _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .magenta))
                        .companionTheme(.clubhouse)
                        .environment(\.colorScheme, dark ? .dark : .light))
                window.rootViewController = controller; window.makeKeyAndVisible()
                window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let cgImage = try XCTUnwrap(image.cgImage)
                let width = cgImage.width, height = cgImage.height
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                for x in [2, width - 3] {
                    let index = (height / 2 * width + x) * 4
                    XCTAssertGreaterThan(bytes[index], 250)
                    XCTAssertLessThan(bytes[index + 1], 5, "Recovery must not paint a full-width tinted band (\(status.phase), dark: \(dark))")
                    XCTAssertGreaterThan(bytes[index + 2], 250)
                }
            }
        }
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
