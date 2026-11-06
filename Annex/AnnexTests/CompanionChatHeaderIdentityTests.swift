import XCTest
import SwiftUI
import UIKit
import Observation
@testable import ClubhouseGo

@MainActor @Observable private final class HeaderIdentityFixture {
    var agent: CompanionAgent
    init(agent: CompanionAgent) { self.agent = agent }
    nonisolated deinit {}
}

@MainActor private struct HeaderIdentityFixtureView: View {
    @Bindable var fixture: HeaderIdentityFixture
    var body: some View {
        CompanionConversationIdentityButton(agent: fixture.agent, isExpanded: .constant(false),
                                            accessibilityLabel: fixture.agent.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .environment(\.colorScheme, .light)
    }
}

/// Synthetic pixels exercise the header's actual canonical avatar, including async image-version updates.
/// No paired host, network image, screenshot attachment or recorded user asset is involved.
@MainActor final class CompanionChatHeaderIdentityTests: XCTestCase {
    func testHeaderRendersCustomImageUpdatesAndAbsentImageFallback() async throws {
        let hostID = "header-identity-\(UUID().uuidString)"
        var agent = CompanionAgent(id: .init(hostID: hostID, projectID: "fixture", agentID: "header"),
                                   name: "Header fixture", subtitle: "", status: .idle, model: nil,
                                   capabilities: [])
        agent.color = "indigo"
        let fixture = HeaderIdentityFixture(agent: agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 88)
        let controller = UIHostingController(rootView: HeaderIdentityFixtureView(fixture: fixture))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func pixels() throws -> (magenta: Int, green: Int, indigo: Int) {
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let image = try XCTUnwrap(rendered.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var magenta = 0, green = 0, indigo = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let r = bytes[index], g = bytes[index + 1], b = bytes[index + 2]
                if r > 200, g < 50, b > 200 { magenta += 1 }
                if r < 50, g > 200, b < 50 { green += 1 }
                if (70...130).contains(r), (70...130).contains(g), b > 200 { indigo += 1 }
            }
            return (magenta, green, indigo)
        }
        func waitForPixels(_ condition: ((magenta: Int, green: Int, indigo: Int)) -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(try pixels()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(condition(try pixels()), "The canonical header avatar must display the expected image version")
        }
        func icon(_ color: UIColor) async throws -> CompanionIconReference {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            let key = await CompanionIconStore.shared.ingest(dataURL: "data:image/png;base64," + data.base64EncodedString(),
                                                            host: hostID, kind: .agent, id: agent.id.agentID)
            return try XCTUnwrap(key)
        }

        try await Task.sleep(for: .milliseconds(100))
        let fallback = try pixels()
        XCTAssertEqual(fallback.magenta, 0); XCTAssertEqual(fallback.green, 0)
        XCTAssertGreaterThan(fallback.indigo, 100, "An absent image renders the canonical identity colour/initials")

        let first = try await icon(.magenta)
        fixture.agent.icon = first
        try await waitForPixels { $0.magenta > 100 && $0.green == 0 }
        let updated = try await icon(.green)
        XCTAssertNotEqual(first.version, updated.version)
        fixture.agent.icon = updated
        try await waitForPixels { $0.green > 100 && $0.magenta == 0 }

        fixture.agent.icon = nil
        try await waitForPixels { $0.magenta == 0 && $0.green == 0 && $0.indigo > 100 }
        await CompanionIconStore.shared.remove(host: hostID)
    }
}
