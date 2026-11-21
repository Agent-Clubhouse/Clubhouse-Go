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
    /// The 44pt target itself stays covered by the native `assertMinimumTarget` Retry checks.
    func testRetryCapsuleStaysTextSizedInsideItsTarget() async throws {
        try await withBanner(hosts: hosts("one")) { _, _, window, _ in
            let image = self.capture(window, "Retry capsule at the default text size")
            let capsule = try self.region(matching: CompanionPalette(theme: .clubhouse, dark: false).tintSoft, in: image)
            XCTAssertGreaterThanOrEqual(capsule.area, 200, "The Retry capsule must be drawn: \(capsule)")
            XCTAssertLessThanOrEqual(capsule.bounds.height, 36, "Visible Retry capsule stays text-sized: \(capsule)")
            XCTAssertGreaterThanOrEqual(capsule.bounds.width / max(capsule.bounds.height, 1), 1.6, "Retry reads as a pill, not a circle: \(capsule)")
        }
    }

    /// Bounds and filled area, in points, of the opaque pixels within 4/255 of `color`.
    private func region(matching color: CompanionRGB, in image: UIImage) throws -> (bounds: CGRect, area: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let target = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard bytes[offset + 3] >= 252, (0..<3).allSatisfy({ abs(Int(bytes[offset + $0]) - target[$0]) <= 4 }) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
            }
        }
        let scale = CGFloat(width) / image.size.width
        guard count > 0 else { return (.zero, 0) }
        // The bitmap's origin is top-left in row order, matching UIKit points.
        return (CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                       width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale),
                CGFloat(count) / (scale * scale))
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

#endif
