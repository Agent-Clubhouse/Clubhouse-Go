import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Exercise the actual pinned Dispatcher row and routed sender view, including a decodable image.
/// Domain tests assert the chosen content and snapshot invalidation; this smoke catches rendering failures.
@MainActor final class CompanionAvatarRenderingTests: XCTestCase {
    func testDispatcherCustomColourEmojiAndImageRenderInRowAndSender() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        var host = CompanionPreviewService.hosts(now: Date(), dispatcher: true)[0]
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        XCTAssertNotNil(CompanionIconCache.image(for: icon), "The image case must actually decode")
        for appearance in ["Colour", "Emoji", "Image"] {
            var agent = try XCTUnwrap(host.dispatcher?.liveAgent)
            agent.color = "rose"
            agent.emoji = appearance == "Emoji" ? "🧭" : nil
            agent.iconData = appearance == "Colour" ? nil : icon
            host.dispatcher?.agent = agent
            let message = CompanionMessage(id: "dispatcher-appearance", role: .user, text: "Update from the Dispatcher.", source: "mcp",
                                           routed: [.init(sender: .init(agentID: agent.id.agentID, name: "Dispatcher"), text: "Update from the Dispatcher.")])
            let content = VStack(alignment: .leading, spacing: 20) {
                CompanionDispatcherRow(store: store, host: host)
                CompanionMessageView(message: message, canRetry: false, retry: {}, expansion: CompanionTranscriptExpansion())
                    .environment(\.companionSenderResolver, CompanionSenderResolver(agents: host.allAgents))
            }
            .padding().frame(width: 360)
            .companionTheme(.clubhouse)
            .environment(\.colorScheme, .light)
            // Host the navigation row in UIKit. ImageRenderer cannot reliably rasterize NavigationLink.
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 220))
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { context in
                hosting.view.layer.render(in: context.cgContext)
            }
            window.isHidden = true
            XCTAssertGreaterThan(image.size.width, 0, "\(appearance) must render both row and sender")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Dispatcher custom \(appearance.lowercased()): pinned row and sender"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
