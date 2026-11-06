import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Service effects from the real hosted caller/callbacks. UI hit testing and copy have separate UI cases.
@MainActor final class CompanionRecoveryIntegrationTests: XCTestCase {
    private let alpha = CompanionRecoveryFixtureService.alpha
    private let beta = CompanionRecoveryFixtureService.beta
    private let gamma = CompanionRecoveryFixtureService.gamma

    private func host(_ scene: CompanionRecoveryFixtureScene) throws -> UIWindow {
        let screen = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: screen)
        window.frame = screen.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionRecoveryFixtureConversation(scene: scene))
        window.makeKeyAndVisible()
        return window
    }
    private func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), description)
    }
    /// Public accessibility activation invokes the actual SwiftUI callback, without a production dispatch seam.
    private func element(_ id: String, in root: NSObject) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == id { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = visit(child) { return found } }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { if let found = visit(child) { return found } }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = visit(child) { return found }
                }
            }
            return nil
        }
        return visit(root)
    }
    private func activate(_ id: String, in window: UIWindow) throws {
        let action = try XCTUnwrap(element(id, in: window), "The real recovery callback must be accessible: \(id)")
        XCTAssertTrue(action.accessibilityActivate(), "The actual SwiftUI action must handle accessibility activation")
    }
    private func close(_ window: UIWindow, scene: CompanionRecoveryFixtureScene) {
        scene.service.finishAll()
        window.isHidden = true; window.rootViewController = nil
    }

    func testFirstLoadHasOneRequestAndRecoveryDoesNotChangeStoreGating() async throws {
        let scene = CompanionRecoveryFixtureScene()
        scene.service.modes[alpha] = .held
        scene.store.drafts[alpha] = "Retained synthetic draft"
        let window = try host(scene)
        defer { close(window, scene: scene) }
        try await waitUntil("The normal caller starts one held history load") {
            scene.service.historyCalls[self.alpha] == 1 && scene.store.conversation(for: self.alpha).isLoading
        }
        XCTAssertFalse(scene.store.canOperate(alpha))
        XCTAssertEqual(scene.service.reconnectCalls.values.reduce(0, +), 0)
        scene.service.finish(alpha, as: .success)
        try await waitUntil("Success settles the original Store history path") { !scene.store.conversation(for: self.alpha).isLoading }
        XCTAssertEqual(scene.service.historyCalls[alpha], 1)
        XCTAssertTrue(scene.store.canOperate(alpha))
        XCTAssertFalse(scene.store.conversation(for: alpha).requiresResync)
        XCTAssertEqual(scene.store.conversation(for: alpha).items.count, 12)
        XCTAssertEqual(scene.store.drafts[alpha], "Retained synthetic draft")
    }

    func testQueuedRefreshRemainsBoundToOldAgentOnSameHost() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha); await scene.store.load(beta)
        scene.service.modes[alpha] = .failure
        await scene.store.load(alpha, force: true)
        let window = try host(scene)
        defer { close(window, scene: scene) }
        try await waitUntil("Initial normal view hook finishes before counting the explicit retry") {
            scene.service.historyCalls[self.alpha] == 3 && !scene.store.conversation(for: self.alpha).isLoading
                && self.element("companion-recovery-retry", in: window) != nil
        }
        let alphaBefore = scene.service.historyCalls[alpha] ?? 0
        let betaBefore = scene.service.historyCalls[beta] ?? 0
        scene.service.modes[alpha] = .held
        try activate("companion-recovery-retry", in: window)
        scene.target = beta // Before the callback's Task can resume on this actor.
        try await waitUntil("Only the presented Alpha action starts a request") { scene.service.historyCalls[self.alpha] == alphaBefore + 1 }
        XCTAssertEqual(scene.service.historyCalls[beta], betaBefore)
        XCTAssertFalse(scene.store.canOperate(alpha))
        XCTAssertTrue(scene.store.canOperate(beta))
        scene.service.finish(alpha, as: .success)
        try await waitUntil("Old target's result settles without retargeting") { !scene.store.conversation(for: self.alpha).isLoading }
        XCTAssertEqual(scene.service.reconnectCalls.values.reduce(0, +), 0)
    }

    func testDetailsDismissOnTargetSwitchAndRetriesStayWithTheirHost() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha); await scene.store.load(gamma)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError), hostID: alpha.hostID)
        let window = try host(scene)
        defer { close(window, scene: scene) }
        try await waitUntil("Failed connection exposes Details") { self.element("companion-recovery-details", in: window) != nil }
        try activate("companion-recovery-details", in: window)
        try await waitUntil("Details is actually presented") { window.rootViewController?.presentedViewController != nil }
        scene.target = gamma
        try await waitUntil("Changing target dismisses old-target Details") { window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(scene.service.reconnectCalls.isEmpty)

        scene.target = alpha
        try await waitUntil("Alpha retry returns") { self.element("companion-recovery-retry", in: window) != nil }
        try activate("companion-recovery-retry", in: window)
        scene.target = gamma
        try await waitUntil("Queued Alpha retry reconnects only Alpha's host") { scene.service.reconnectCalls[self.alpha.hostID] == 1 }
        XCTAssertNil(scene.service.reconnectCalls[gamma.hostID])

        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError), hostID: gamma.hostID)
        try await waitUntil("Gamma Details belongs to Gamma") { self.element("companion-recovery-details", in: window) != nil }
        try activate("companion-recovery-details", in: window)
        try await waitUntil("Details offers its actual retry callback") { self.element("companion-recovery-detail-retry", in: window) != nil }
        try activate("companion-recovery-detail-retry", in: window)
        scene.target = alpha
        try await waitUntil("Gamma's issued action does not become an Alpha reconnect") { scene.service.reconnectCalls[self.gamma.hostID] == 1 }
        XCTAssertEqual(scene.service.reconnectCalls[alpha.hostID], 1)
        XCTAssertEqual(scene.service.historyCalls[alpha], 1)
        XCTAssertEqual(scene.service.historyCalls[gamma], 1)
    }

    func testRetainedInactivePageDismissesDetailsWithoutResettingReadingOrDraft() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha)
        scene.store.drafts[alpha] = "Retained page draft"
        let bookmark = scene.store.readingBookmark(for: alpha)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError))
        let window = try host(scene)
        defer { close(window, scene: scene) }
        try await waitUntil("Retained page has Details") { self.element("companion-recovery-details", in: window) != nil }
        try activate("companion-recovery-details", in: window)
        try await waitUntil("Details opens") { window.rootViewController?.presentedViewController != nil }
        scene.isActive = false // Same showsActions transition used by a retained Review page.
        try await waitUntil("Inactive page cannot keep its old Details presented") { window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(scene.store.readingBookmark(for: alpha) === bookmark)
        XCTAssertEqual(scene.store.drafts[alpha], "Retained page draft")
        XCTAssertEqual(scene.service.historyCalls[alpha], 1)
        XCTAssertTrue(scene.service.reconnectCalls.isEmpty)
    }
}
