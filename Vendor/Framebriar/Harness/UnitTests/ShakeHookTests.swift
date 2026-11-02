import Framebriar
@testable import FramebriarUI
@testable import FramebriarHarness
import UIKit
import XCTest

/// Hosted in the harness app, so real UIWindows and scenes. Calls `motionEnded` directly: this tests the
/// hook and the routing, not iOS motion delivery. ShakeUITests covers delivery, on the simulator only.
private final class CountingNext: UIResponder {
    var calls = 0
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) { calls += 1 }
}
private final class InheritingWindow: UIWindow {
    let tail = CountingNext()
    override var next: UIResponder? { tail }
}
private class OverridingBase: UIWindow {
    var calls = 0
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) { calls += 1 }
}
private final class NonKeyWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

@MainActor final class ShakeHookTests: XCTestCase {
    private var scene: UIWindowScene { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first! }
    private var keyWindow: UIWindow { scene.windows.first { $0.isKeyWindow }! }

    func testAddingToAClassThatInheritsChainsTheOriginalExactlyOnce() {
        var hook = 0
        XCTAssertTrue(ShakeWindowHook.wrap(InheritingWindow.self) { _ in hook += 1 })
        let window = InheritingWindow(windowScene: scene)
        window.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(hook, 1)
        XCTAssertEqual(window.tail.calls, 1, "UIResponder's implementation ran and forwarded along the chain once")
    }

    func testWrappingAnExistingOverrideStillCallsItExactlyOnce() {
        var hook = 0
        XCTAssertTrue(ShakeWindowHook.wrap(OverridingBase.self) { _ in hook += 1 })
        let window = OverridingBase(windowScene: scene)
        window.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(hook, 1)
        XCTAssertEqual(window.calls, 1)
    }

    func testOtherMotionsPassThroughWithoutTheHook() {
        var hook = 0
        final class Local: UIWindow { let tail = CountingNext(); override var next: UIResponder? { tail } }
        ShakeWindowHook.wrap(Local.self) { _ in hook += 1 }
        let window = Local(windowScene: scene)
        window.motionEnded(.none, with: nil)
        XCTAssertEqual(hook, 0)
        XCTAssertEqual(window.tail.calls, 1)
    }

    func testInstallIsIdempotentAndSafeFromManyThreads() {
        DispatchQueue.concurrentPerform(iterations: 32) { _ in ShakeWindowHook.install() }
        let tail = CountingNext()
        final class Probe: UIWindow { var tail: UIResponder?; override var next: UIResponder? { tail } }
        let window = Probe(windowScene: scene); window.tail = tail
        window.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(tail.calls, 1, "However many installs ran, the original is chained once")
    }

    func testRouterRejectsNonKeyAndInactiveAndRepeatsOfOneEvent() {
        XCTAssertTrue(ShakeRouter.accepts(isKeyWindow: true, sceneActive: true, alreadyRouted: false))
        XCTAssertFalse(ShakeRouter.accepts(isKeyWindow: false, sceneActive: true, alreadyRouted: false))
        XCTAssertFalse(ShakeRouter.accepts(isKeyWindow: true, sceneActive: false, alreadyRouted: false))
        XCTAssertFalse(ShakeRouter.accepts(isKeyWindow: true, sceneActive: true, alreadyRouted: true), "One shake, however many windows forward it")
    }

    // MARK: coordinators, with real windows

    private func coordinator(enrolled: Bool = true, onNotEnrolled: (@MainActor () -> Void)? = nil, perform: @escaping @MainActor (FeedbackShakeEvent) -> Void) async throws -> (ShakeCoordinator, FeedbackModel) {
        let model = try await makeHarnessModel(offline: true, enrolled: enrolled)
        let coordinator = ShakeCoordinator()
        coordinator.model = model; coordinator.scene = scene; coordinator.enabled = true
        coordinator.perform = perform; coordinator.onNotEnrolled = onNotEnrolled
        return (coordinator, model)
    }

    func testOneEventActsOnceAcrossWindowsAndInstalledCoordinators() async throws {
        var events: [FeedbackShakeEvent] = []
        let (first, m1) = try await coordinator { events.append($0) }
        let (second, m2) = try await coordinator { events.append($0) }
        let router = ShakeRouter()
        router.add(first); router.add(second)
        let key = keyWindow
        router.route(window: key)
        XCTAssertEqual(events.count, 1, "The first coordinator to act ends the walk")
        router.route(window: key)
        XCTAssertEqual(events.count, 1, "The same shake seen again in this turn is ignored")
        XCTAssertTrue(events[0].window === key)
        withExtendedLifetime((m1, m2)) {}
    }

    func testALaterShakeIsNotMistakenForTheSameOne() async throws {
        var events = 0
        let (coordinator, model) = try await self.coordinator { _ in events += 1 }
        let router = ShakeRouter(); router.add(coordinator)
        router.route(window: keyWindow)
        XCTAssertEqual(events, 1)
        coordinator.resetCooldownForTesting()
        try await Task.sleep(nanoseconds: 50_000_000) // the next run-loop turn
        router.route(window: keyWindow)
        XCTAssertEqual(events, 2)
        withExtendedLifetime(model) {}
    }

    func testANonKeyPassthroughWindowInTheSameSceneNeverActs() async throws {
        var events = 0
        let (coordinator, model) = try await self.coordinator { _ in events += 1 }
        let router = ShakeRouter(); router.add(coordinator)
        let overlay = NonKeyWindow(windowScene: scene)
        overlay.isHidden = false; overlay.windowLevel = .alert
        defer { overlay.isHidden = true }
        XCTAssertTrue(keyWindow !== overlay, "It can't take key")
        router.route(window: overlay)
        XCTAssertEqual(events, 0)
        router.route(window: keyWindow)
        XCTAssertEqual(events, 1, "Its presence doesn't get in the way of the key window")
        withExtendedLifetime(model) {}
    }

    func testAWindowFromAnotherSceneDoesNotReachThisCoordinator() async throws {
        var events = 0
        let (coordinator, model) = try await self.coordinator { _ in events += 1 }
        coordinator.scene = nil
        XCTAssertFalse(coordinator.handle(keyWindow))
        XCTAssertEqual(events, 0)
        withExtendedLifetime(model) {}
    }

    func testTheEventCarriesItsWindowAndACaptureFromThatWindow() async throws {
        var received: FeedbackShakeEvent?
        let (coordinator, model) = try await self.coordinator { received = $0 }
        XCTAssertTrue(coordinator.handle(keyWindow))
        XCTAssertTrue(received?.window === keyWindow)
        let png = try XCTUnwrap(received?.screenshotPNG)
        XCTAssertNotNil(ShakeScreenshot.validatedAttachment(png))
        withExtendedLifetime(model) {}
    }

    func testCaptureOffGivesNoImage() async throws {
        var received: FeedbackShakeEvent?
        let (coordinator, model) = try await self.coordinator { received = $0 }
        coordinator.captureScreen = false
        XCTAssertTrue(coordinator.handle(keyWindow))
        XCTAssertNotNil(received)
        XCTAssertNil(received?.screenshotPNG)
        withExtendedLifetime(model) {}
    }

    func testNotEnrolledCallsItsOwnRouteOnly() async throws {
        var opened = 0, explained = 0
        let (coordinator, model) = try await self.coordinator(enrolled: false, onNotEnrolled: { explained += 1 }) { _ in opened += 1 }
        XCTAssertTrue(coordinator.handle(keyWindow))
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(explained, 1)
        withExtendedLifetime(model) {}
    }

    func testAnOpenComposerSuppressesTheShake() async throws {
        var opened = 0
        let (coordinator, model) = try await self.coordinator { _ in opened += 1 }
        model.composerAppeared()
        XCTAssertFalse(coordinator.handle(keyWindow))
        model.composerDisappeared()
        XCTAssertEqual(opened, 0)
    }

    func testDocumentedCaveatASubclassThatSkipsSuperHidesTheEvent() {
        class Base: UIWindow {}
        final class Swallowing: Base { override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {} }
        var hook = 0
        ShakeWindowHook.wrap(Base.self) { _ in hook += 1 }
        Swallowing(windowScene: scene).motionEnded(.motionShake, with: nil)
        XCTAssertEqual(hook, 0)
        Base(windowScene: scene).motionEnded(.motionShake, with: nil)
        XCTAssertEqual(hook, 1)
    }
}
