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
        let clock = ContinuousClock()
        let origin = clock.now
        let elapsed = { origin.duration(to: clock.now) }
        var rowArea: CGFloat = 0, senderArea: CGFloat = 0
        let poll = try await AvatarProfilePoll.run(budget: .seconds(2), elapsed: elapsed, capture: { snapshot(view) }, passes: { image in
            rowArea = try profilePixelArea(in: image, panel: rowPanel)
            senderArea = try profilePixelArea(in: image, panel: senderPanel)
            return rowArea >= 100 && senderArea >= 100
        }, sleep: { try await Task.sleep(for: .milliseconds(10)) }) // Await both visible cached-image tasks.
        print("AVATAR_PROFILE_PIXELS rowPointArea=\(rowArea) senderPointArea=\(senderArea)")
        print(poll.trace.summary)
        if !poll.passed {
            for step in poll.trace.steps { print(step.line) }
        }
        XCTAssertGreaterThanOrEqual(rowArea, 100, "Pinned row must render the cyan profile image over its emoji", file: file, line: line)
        XCTAssertGreaterThanOrEqual(senderArea, 100, "Routed sender must render the cyan profile image over its emoji", file: file, line: line)
        return poll.value
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

// BEGIN AvatarProfilePoll: pure and clock-injected, so its timing boundaries can be exercised off-device.
/// The original acceptance, unchanged: `repeat { capture; analyse; stop if it passes; sleep } while now < deadline`.
/// The returned value is the last analysed capture. The trace only records elapsed offsets for diagnosis.
enum AvatarProfilePoll {
    struct Step {
        var index: Int
        var preCapture: Duration, postCapture: Duration, postAnalysis: Duration
        var sleep: (start: Duration, end: Duration)?
        var passed: Bool
        var line: String {
            let wait = sleep.map { " sleep=\(AvatarProfilePoll.ms($0.start))-\(AvatarProfilePoll.ms($0.end))ms" } ?? ""
            return "AVATAR_PROFILE_SAMPLE \(index) capture=\(AvatarProfilePoll.ms(preCapture))-\(AvatarProfilePoll.ms(postCapture))ms "
                + "analysis=\(AvatarProfilePoll.ms(postCapture))-\(AvatarProfilePoll.ms(postAnalysis))ms passed=\(passed)" + wait
        }
    }
    struct Trace {
        var budget: Duration
        var steps: [Step] = []
        /// Elapsed time when the loop condition was last read, if it was read.
        var lastCheck: Duration?
        var summary: String {
            let captures = steps.map { $0.postCapture - $0.preCapture }
            let analyses = steps.map { $0.postAnalysis - $0.postCapture }
            let sleeps = steps.compactMap { $0.sleep.map { $0.end - $0.start } }
            let finalSleep = steps.last?.sleep.map { "\(AvatarProfilePoll.ms($0.start))-\(AvatarProfilePoll.ms($0.end))ms" } ?? "none"
            return "AVATAR_PROFILE_POLL samples=\(steps.count) sleeps=\(sleeps.count) budget=\(AvatarProfilePoll.ms(budget))ms "
                + "lastCheck=\(lastCheck.map { AvatarProfilePoll.ms($0) + "ms" } ?? "none") "
                + "maxCapture=\(AvatarProfilePoll.ms(captures.max() ?? .zero))ms maxAnalysis=\(AvatarProfilePoll.ms(analyses.max() ?? .zero))ms "
                + "maxSleep=\(AvatarProfilePoll.ms(sleeps.max() ?? .zero))ms finalSleep=\(finalSleep)"
        }
    }
    static func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
    @MainActor static func run<Value>(budget: Duration, elapsed: () -> Duration, capture: () throws -> Value,
                           passes: (Value) throws -> Bool, sleep: () async throws -> Void) async throws
        -> (value: Value, passed: Bool, trace: Trace) {
        let deadline = elapsed() + budget
        var trace = Trace(budget: budget)
        var value: Value
        var passed = false
        var check: Duration
        repeat {
            let pre = elapsed()
            value = try capture()
            let post = elapsed()
            passed = try passes(value)
            trace.steps.append(Step(index: trace.steps.count + 1, preCapture: pre, postCapture: post,
                                    postAnalysis: elapsed(), sleep: nil, passed: passed))
            if passed { break }
            let start = elapsed()
            try await sleep()
            check = elapsed()
            trace.steps[trace.steps.count - 1].sleep = (start, check)
            trace.lastCheck = check
        } while check < deadline
        return (value, passed, trace)
    }
}
// END AvatarProfilePoll
