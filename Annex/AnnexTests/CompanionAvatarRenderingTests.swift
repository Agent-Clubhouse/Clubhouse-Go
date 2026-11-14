import XCTest
import SwiftUI
import UIKit
import ClubhouseTransport
@testable import ClubhouseGo

/// Exercise the actual pinned Dispatcher row and routed sender view, including a decodable image.
/// Domain tests cover selection; the image case separately asserts profile pixels in both consumers.
@MainActor final class CompanionAvatarRenderingTests: XCTestCase {
    func testDispatcherCustomColourEmojiAndImageSurviveIconOmittedSnapshot() async throws {
        let cacheHost = "dispatcher-avatar-test-" + UUID().uuidString
        do {
            try await checkDispatcherRendering(cacheHost: cacheHost)
        } catch {
            await CompanionIconStore.shared.remove(host: cacheHost)
            throw error
        }
        await CompanionIconStore.shared.remove(host: cacheHost)
    }

    private func checkDispatcherRendering(cacheHost: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "Requires a foreground-active hosted test scene")
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let store = CompanionStore(service: CompanionPreviewService())
        var host = CompanionPreviewService.hosts(now: Date(), dispatcher: true)[0]
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let agentID = try XCTUnwrap(host.dispatcher?.liveAgent?.id.agentID)
        let initialSnapshot = AnnexEnvelope(type: "snapshot", payload: .object([
            "agentIcons": .object([agentID: .string("data:image/png;base64," + icon.base64EncodedString())])
        ]))
        var catalog = await CompanionIconCatalog().applyingSnapshot(initialSnapshot, usesReferences: false, host: cacheHost, store: .shared)
        let reference = try XCTUnwrap(catalog.agents[agentID])
        let decoded = await CompanionIconStore.shared.image(for: reference, points: 32)
        XCTAssertNotNil(decoded, "The image case must actually decode through the bounded store")
        for appearance in ["Colour", "Emoji", "Image", "Icon-omitted snapshot"] {
            let showsImage = appearance == "Image" || appearance == "Icon-omitted snapshot"
            var agent = try XCTUnwrap(host.dispatcher?.liveAgent)
            if appearance == "Icon-omitted snapshot" {
                let omitted = AnnexEnvelope(type: "snapshot", payload: .object([
                    "agentIcons": .object([:]), "projectIcons": .object([:]),
                    "snapshotTruncated": .object([
                        "version": .integer(1), "reason": .string("frame_limit"), "bytes": .integer(9 * 1024 * 1024),
                        "omitted": .array([.string("agentIcons"), .string("projectIcons")])
                    ])
                ]))
                catalog = await catalog.applyingSnapshot(omitted, usesReferences: false, host: cacheHost, store: .shared)
                XCTAssertEqual(catalog.agents[agentID], reference, "The snapshot must not turn omitted icons into removed images")
            }
            agent.color = "rose"
            agent.emoji = appearance == "Colour" ? nil : "🧭" // Image also tests coexistence in both consumers.
            agent.icon = showsImage ? catalog.agents[agentID] : nil
            host.dispatcher?.agent = agent
            let message = CompanionMessage(id: "dispatcher-appearance", role: .user, text: "Update from the Dispatcher.", source: "mcp",
                                           routed: [.init(sender: .init(agentID: agent.id.agentID, name: "Dispatcher"), text: "Update from the Dispatcher.")])
            let content = VStack(alignment: .leading, spacing: 20) {
                CompanionDispatcherRow(store: store, host: host)
                    .frame(height: 64, alignment: .leading)
                CompanionMessageView(message: message, canRetry: false, retry: {}, expansion: CompanionTranscriptExpansion())
                    .environment(\.companionSenderResolver, CompanionSenderResolver(agents: host.allAgents))
                    .frame(height: 96, alignment: .topLeading)
            }
            .padding(16).frame(width: 360, height: 240, alignment: .topLeading)
            .companionTheme(.clubhouse)
            .environment(\.colorScheme, .light)
            .ignoresSafeArea()
            // Host the navigation row in UIKit. ImageRenderer cannot reliably rasterize NavigationLink.
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            defer {
                window.isHidden = true
                window.rootViewController = nil
                originalKeyWindow?.makeKey()
            }
            window.makeKeyAndVisible()
            let image: UIImage
            if showsImage {
                image = try await expectProfilePixels(in: hosting.view)
            } else {
                try await Task.sleep(for: .milliseconds(100))
                image = snapshot(hosting.view)
            }
            XCTAssertGreaterThan(image.size.width, 0, "\(appearance) must render both row and sender")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Dispatcher custom \(appearance.lowercased()): pinned row and sender"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func snapshot(_ view: UIView) -> UIImage {
        view.window?.layoutIfNeeded()
        view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private func expectProfilePixels(in view: UIView, file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        // These panels belong to this fixed-size fixture, not to production avatar coordinates.
        let rowPanel = CGRect(x: 16, y: 16, width: 328, height: 64)
        let senderPanel = CGRect(x: 16, y: 100, width: 328, height: 96)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var image: UIImage
        var rowArea: CGFloat = 0, senderArea: CGFloat = 0
        repeat {
            image = snapshot(view)
            rowArea = try profilePixelArea(in: image, panel: rowPanel)
            senderArea = try profilePixelArea(in: image, panel: senderPanel)
            if rowArea >= 100 && senderArea >= 100 { break }
            try await Task.sleep(for: .milliseconds(10)) // Await both visible cached-image tasks.
        } while ContinuousClock.now < deadline
        print("AVATAR_PROFILE_PIXELS rowPointArea=\(rowArea) senderPointArea=\(senderArea)")
        XCTAssertGreaterThanOrEqual(rowArea, 100, "Pinned row must render the cyan profile image over its emoji", file: file, line: line)
        XCTAssertGreaterThanOrEqual(senderArea, 100, "Routed sender must render the cyan profile image over its emoji", file: file, line: line)
        return image
    }

    /// Count only the synthetic image's opaque cyan pixels, in square points independent of display scale.
    private func profilePixelArea(in snapshot: UIImage, panel: CGRect) throws -> CGFloat {
        let image = try XCTUnwrap(snapshot.cgImage)
        let scaleX = CGFloat(image.width) / snapshot.size.width
        let scaleY = CGFloat(image.height) / snapshot.size.height
        let pixels = CGRect(x: panel.minX * scaleX, y: panel.minY * scaleY,
                            width: panel.width * scaleX, height: panel.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var matching = 0
        for offset in stride(from: 0, to: crop.width * crop.height * 4, by: 4) {
            if bytes[offset] <= 3 && bytes[offset + 1] >= 252 && bytes[offset + 2] >= 252 && bytes[offset + 3] >= 252 { matching += 1 }
        }
        return CGFloat(matching) / (scaleX * scaleY)
    }
}
