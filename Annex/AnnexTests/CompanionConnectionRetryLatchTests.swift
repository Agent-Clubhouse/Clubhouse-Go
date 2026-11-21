#if DEBUG
import XCTest
import SwiftUI
import UIKit
import Vision
@testable import ClubhouseGo

@MainActor final class CompanionConnectionRetryLatchTests: XCTestCase {
    func testDoubleTapIssuesOneReconnectUntilTheAttemptFinishes() async throws {
        try await withBanner(hosts: hosts("one")) { store, service, window, observed in
            let button = try XCTUnwrap(observed())
            button.retry()
            button.retry() // Before SwiftUI has rendered the disabled state.
            try await self.waitUntil { service.calls["one"] == 1 && observed()?.retryDisabled == true }
            XCTAssertEqual(service.pendingCount, 1)
            self.capture(window, "Retry is disabled while one reconnect is held")
            service.finishFirst("one")
            try await self.waitUntil { observed()?.retryDisabled == false }
            try XCTUnwrap(observed()).retry()
            try await self.waitUntil { service.calls["one"] == 2 }
            XCTAssertEqual(service.pendingCount, 1)
        }
    }

    func testReportedStateClearsTheLatchAndAnOldCompletionCannotClearANewerAttempt() async throws {
        try await withBanner(hosts: hosts("one")) { store, service, window, observed in
            try XCTUnwrap(observed()).retry()
            try await self.waitUntil { service.calls["one"] == 1 && observed()?.retryDisabled == true }
            self.report(.reconnecting, hostID: "one", store: store)
            try await self.waitUntil { observed()?.retryHostIDs.isEmpty == true }
            self.report(.offline, hostID: "one", store: store)
            try await self.waitUntil { observed()?.retryHostIDs == ["one"] && observed()?.retryDisabled == false }
            try XCTUnwrap(observed()).retry()
            try await self.waitUntil { service.calls["one"] == 2 && observed()?.retryDisabled == true }
            service.finishFirst("one") // Completion from before the reported connection transitions.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(observed()?.retryDisabled == true, "The second held attempt owns the latch")
            XCTAssertEqual(service.pendingCount, 1)
            service.finishFirst("one")
            try await self.waitUntil { observed()?.retryDisabled == false }
        }
    }

    func testCombinedRetryLatchesEachHostWithoutBlockingANewOfflineHost() async throws {
        var initial = hosts("one", "two", "three")
        initial[2].connection = .connected
        try await withBanner(hosts: initial) { store, service, window, observed in
            let button = try XCTUnwrap(observed())
            button.retry()
            button.retry()
            try await self.waitUntil { service.calls["one"] == 1 && service.calls["two"] == 1 && observed()?.retryDisabled == true }
            XCTAssertNil(service.calls["three"])
            self.report(.offline, hostID: "three", store: store)
            try await self.waitUntil { observed()?.retryDisabled == false }
            let updated = try XCTUnwrap(observed())
            updated.retry()
            updated.retry()
            try await self.waitUntil { service.calls["three"] == 1 && observed()?.retryDisabled == true }
            XCTAssertEqual(service.calls, ["one": 1, "two": 1, "three": 1])
            XCTAssertEqual(service.pendingCount, 3)
        }
    }

    /// #624: a bordered style padded its 44pt label into a ~68×56pt near-circle that filled the card.
    /// Binds the actual Retry: its hit frame and the card frame come from the mounted banner, and its painted
    /// pixels come from rendering one layout with Retry shown and hidden, so neither style nor color is assumed.
    /// The recognized "Retry" label must lie inside that painted region. Native 44pt checks stay in the UI tests.
    func testRetryVisibleControlIsTextSizedInsideItsTargetAndCard() async throws {
        try await assertRetryGeometry(size: .large, name: "default")
    }

    func testRetryVisibleControlKeepsCardClearanceAtAccessibilitySize() async throws {
        try await assertRetryGeometry(size: .accessibility5, name: "accessibility XXXL")
    }

    private func assertRetryGeometry(size: DynamicTypeSize, name: String) async throws {
        let service = HeldReconnectService()
        let store = CompanionStore(service: service)
        store.apply(.hosts(hosts("one")))
        let toggle = RetryVisibility()
        var retryFrame: CGRect?, cardFrame: CGRect?
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: RetryGeometryHost(store: store, toggle: toggle, size: size,
            retryFrame: { retryFrame = $0 }, cardFrame: { cardFrame = $0 }))
        window.makeKeyAndVisible()
        defer {
            service.beginTeardown()
            window.isHidden = true
            window.rootViewController = nil
            store.stop()
            original?.makeKey()
        }
        try await waitUntil { retryFrame != nil && cardFrame != nil }
        try await Task.sleep(for: .milliseconds(150))
        let shown = capture(window, "Retry shown, \(name)")
        let hit = try XCTUnwrap(retryFrame), card = try XCTUnwrap(cardFrame)
        toggle.hidden = true
        try await Task.sleep(for: .milliseconds(150))
        let hidden = capture(window, "Retry hidden at the same layout, \(name)")
        XCTAssertEqual(retryFrame, hit, "Hiding Retry must not move it")
        XCTAssertEqual(cardFrame, card, "Hiding Retry must not resize the card")
        let shownImage = try XCTUnwrap(shown.cgImage)
        let scale = CGFloat(shownImage.width) / shown.size.width
        let visible = BannerActionGeometry.visibleBounds(shown: shownImage, hidden: try XCTUnwrap(hidden.cgImage), scale: scale, within: hit)
        let label = try visible.flatMap { try recognizedText("Retry", in: shownImage, scale: scale, within: $0) }
        let metrics = visible.map { BannerActionGeometry.Metrics(visible: $0, hit: hit, card: card, label: label, defaultSize: !size.isAccessibilitySize) }
        print("RETRY_GEOMETRY \(name) visible=\(visible.map { "\($0)" } ?? "none") label=\(label.map { "\($0)" } ?? "none") hit=\(hit) card=\(card)")
        let failures = BannerActionGeometry.failures(metrics)
        XCTAssertTrue(failures.isEmpty, "\(name): " + failures.joined(separator: "; "))
        XCTAssertEqual(service.calls, [:], "Measuring must not reconnect")
    }

    /// The window-point bounds of `text` recognized inside `region` of the rendered window.
    private func recognizedText(_ text: String, in image: CGImage, scale: CGFloat, within region: CGRect) throws -> CGRect? {
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop).perform([request])
        guard let box = request.results?.first(where: { $0.topCandidates(1).first?.string == text })?.boundingBox else { return nil }
        // Vision boxes are normalized with a bottom-left origin.
        let width = CGFloat(crop.width), height = CGFloat(crop.height)
        return CGRect(x: (pixels.minX + box.minX * width) / scale, y: (pixels.minY + (1 - box.maxY) * height) / scale,
                      width: box.width * width / scale, height: box.height * height / scale)
    }

    private func hosts(_ ids: String...) -> [CompanionHost] {
        ids.map { .init(id: $0, name: $0.capitalized + " Mac", endpoint: "Fixture only", connection: .offline, projects: []) }
    }

    private func report(_ connection: CompanionConnection, hostID: String, store: CompanionStore) {
        var hosts = store.hosts
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return XCTFail("Fixture host must exist") }
        hosts[index].connection = connection
        store.apply(.hosts(hosts))
    }

    private func withBanner(hosts: [CompanionHost], body: (CompanionStore, HeldReconnectService, UIWindow, () -> CompanionDesktopConnectionBanner.HostedTestSeam?) async throws -> Void) async throws {
        let service = HeldReconnectService()
        let store = CompanionStore(service: service)
        store.apply(.hosts(hosts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        var observed: CompanionDesktopConnectionBanner.HostedTestSeam?
        let controller = UIHostingController(rootView: VStack {
            CompanionDesktopConnectionBanner(store: store, identifierPrefix: "test", hostedTestSeam: { observed = $0 })
            Spacer()
        }.padding(16).dynamicTypeSize(.large).companionTheme(.clubhouse).environment(\.colorScheme, .light))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        var failure: Error?
        do {
            let expected = hosts.filter { !$0.connection.canOperate }.map(\.id)
            try await waitUntil { observed?.retryHostIDs == expected }
            try await Task.sleep(for: .milliseconds(150))
            let text = try renderedText(window, "Initial mounted Retry banner")
            XCTAssertTrue(text.contains("Retry"), "The real Retry control must be rendered: \(text)")
            XCTAssertTrue(text.contains("One Mac"), "The real offline banner must be rendered: \(text)")
            try await body(store, service, window, { observed })
        } catch {
            capture(window, "Retry hosted setup failure")
            failure = error
        }
        observed = nil
        service.beginTeardown()
        window.isHidden = true
        window.rootViewController = nil
        store.stop()
        original?.makeKey()
        await Task.yield()
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNil(window.rootViewController)
        if let failure { throw failure }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else {
            XCTFail("The actual hosted banner must reach the requested state")
            throw NSError(domain: "Retry latch fixture", code: 1)
        }
    }

    private func renderedText(_ window: UIWindow, _ name: String) throws -> String {
        let image = capture(window, name)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
    }

    @discardableResult private func capture(_ window: UIWindow, _ name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

@Observable @MainActor private final class RetryVisibility { var hidden = false }

private struct RetryGeometryHost: View {
    let store: CompanionStore
    let toggle: RetryVisibility
    let size: DynamicTypeSize
    let retryFrame: (CGRect) -> Void
    let cardFrame: (CGRect) -> Void
    var body: some View {
        VStack {
            CompanionDesktopConnectionBanner(store: store, identifierPrefix: "test",
                geometrySeam: .init(hidesRetry: toggle.hidden, retryFrame: retryFrame, cardFrame: cardFrame))
            Spacer()
        }
        .padding(16).dynamicTypeSize(size).companionTheme(.clubhouse).environment(\.colorScheme, .light)
    }
}

@MainActor private final class HeldReconnectService: CompanionService {
    var calls: [String: Int] = [:]
    private var pending: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var isTearingDown = false
    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }
    func reconnect(hostID: String) async {
        calls[hostID, default: 0] += 1
        guard !isTearingDown else { return }
        await withCheckedContinuation { pending[hostID, default: []].append($0) }
    }
    func finishFirst(_ hostID: String) {
        guard var waiting = pending[hostID], !waiting.isEmpty else { return }
        let first = waiting.removeFirst()
        pending[hostID] = waiting.isEmpty ? nil : waiting
        first.resume()
    }
    func beginTeardown() {
        isTearingDown = true
        let held = pending.values.flatMap { $0 }
        pending.removeAll()
        for continuation in held { continuation.resume() }
    }
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { throw CompanionServiceError.unavailable("Fixture only") }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
}

// BEGIN BannerActionGeometry: CoreGraphics only, so its oracle can be exercised off-device.
/// What a control alone draws: pixels that differ between two renders of one layout, shown and hidden, that are
/// 8-connected to a changed pixel inside the control's own frame. Unrelated content is identical in both renders,
/// and changed pixels that never touch the control's frame are ignored, whatever their color.
enum BannerActionGeometry {
    struct Metrics: Equatable {
        var visible: CGRect
        var hit: CGRect
        var card: CGRect
        /// The recognized label, in the same window coordinates.
        var label: CGRect?
        /// The absolute height ceiling applies only at the default text size; other limits are text-relative.
        var defaultSize: Bool
    }
    static let minimumTarget: CGFloat = 44
    static let maximumDefaultHeight: CGFloat = 36
    static let maximumHeightPerLabelHeight: CGFloat = 2.6
    static let minimumAspect: CGFloat = 1.6
    static let minimumClearance: CGFloat = 4

    static func failures(_ metrics: Metrics?) -> [String] {
        guard let m = metrics else { return ["Retry drew nothing inside its own frame"] }
        var result: [String] = []
        guard let label = m.label else { return ["the Retry label was not recognized inside its painted region"] }
        if !m.visible.insetBy(dx: -0.5, dy: -0.5).contains(label) { result.append("label \(label) lies outside the painted control \(m.visible)") }
        if m.hit.width < minimumTarget || m.hit.height < minimumTarget { result.append("hit target \(m.hit.size) is below 44×44pt") }
        if !m.hit.insetBy(dx: -0.5, dy: -0.5).contains(m.visible) { result.append("painted control \(m.visible) extends past its hit target \(m.hit)") }
        if m.visible.height >= m.hit.height { result.append("painted control fills its whole hit target height") }
        if m.defaultSize && m.visible.height > maximumDefaultHeight { result.append("painted control is \(m.visible.height)pt tall, above \(maximumDefaultHeight)pt") }
        if m.visible.height > label.height * maximumHeightPerLabelHeight {
            result.append("painted control is \(m.visible.height)pt tall for a \(label.height)pt label")
        }
        if m.visible.width < m.visible.height * minimumAspect { result.append("painted control \(m.visible.size) reads as round, not a pill") }
        if m.visible.minY - m.card.minY < minimumClearance { result.append("painted control is \(m.visible.minY - m.card.minY)pt from the card top") }
        if m.card.maxY - m.visible.maxY < minimumClearance { result.append("painted control is \(m.card.maxY - m.visible.maxY)pt from the card bottom") }
        return result
    }

    static func visibleBounds(shown: CGImage, hidden: CGImage, scale: CGFloat, within frame: CGRect, threshold: Int = 8) -> CGRect? {
        guard shown.width == hidden.width, shown.height == hidden.height,
              let a = rgba(shown), let b = rgba(hidden) else { return nil }
        let width = shown.width, height = shown.height
        var changed = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            changed[index] = (0..<4).contains { abs(Int(a[offset + $0]) - Int(b[offset + $0])) > threshold }
        }
        let seed = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !seed.isNull, !seed.isEmpty else { return nil }
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        for y in Int(seed.minY)..<Int(seed.maxY) {
            for x in Int(seed.minX)..<Int(seed.maxX) where changed[y * width + x] {
                visited[y * width + x] = true; queue.append(y * width + x)
            }
        }
        guard !queue.isEmpty else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1, head = 0
        while head < queue.count {
            let index = queue[head]; head += 1
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let next = ny * width + nx
                    if changed[next] && !visited[next] { visited[next] = true; queue.append(next) }
                }
            }
        }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Top row first, in sRGB, matching UIKit point coordinates.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}
// END BannerActionGeometry

#endif
