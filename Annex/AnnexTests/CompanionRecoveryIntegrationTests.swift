import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Service effects from the real hosted caller/callbacks. UI hit testing and copy have separate UI cases.
@MainActor final class CompanionRecoveryIntegrationTests: XCTestCase {
    private let alpha = CompanionRecoveryFixtureService.alpha
    private let beta = CompanionRecoveryFixtureService.beta
    private let gamma = CompanionRecoveryFixtureService.gamma
    private var prerequisiteObservation: [String: String] = [:]
    private struct PrerequisiteFailure: Error { let reason: String }

    private func withHost(_ scene: CompanionRecoveryFixtureScene, body: (UIWindow) async throws -> Void) async throws {
        try await waitUntil("A foreground-active scene must host the synthetic window") {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive && $0 is UIWindowScene }
        }
        let screen = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let originalKeyWindow = screen.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: screen)
        window.frame = screen.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionRecoveryFixtureConversation(scene: scene))
        window.makeKeyAndVisible()
        prerequisiteObservation = [:]
        func run() async throws {
            defer {
                scene.service.beginTeardown()
                window.isHidden = true; window.rootViewController = nil
                scene.store.stop()
                originalKeyWindow?.makeKey()
            }
            do { try await body(window) }
            catch {
                CompanionRecoveryFailureEvidence.capture(window: window, scene: scene, reason: String(describing: error),
                                                         prerequisite: prerequisiteObservation)
                throw error
            }
        }
        var bodyError: Error?
        do { try await run() } catch { bodyError = error }
        // Let detached view tasks and already-issued callback Tasks finish against the closed-to-holds service.
        await Task.yield()
        try await waitUntil("Fixture teardown must drain held requests and Store loads") {
            scene.service.pendingHistoryCount == 0 && CompanionRecoveryFixtureService.targets.allSatisfy {
                !scene.store.conversation(for: $0).isLoading
            }
        }
        XCTAssertTrue(scene.service.isTearingDown)
        XCTAssertNil(window.rootViewController)
        XCTAssertTrue(window.isHidden)
        if let originalKeyWindow { XCTAssertTrue(originalKeyWindow.isKeyWindow) }
        print("RECOVERY_FIXTURE_DRAIN pending=\(scene.service.pendingHistoryCount) closedToHolds=\(scene.service.isTearingDown) historyCalls=\(scene.service.historyCalls.values.reduce(0, +))")
        if let bodyError { throw bodyError }
    }
    private func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
        prerequisiteObservation = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let satisfied = predicate()
        prerequisiteObservation["description"] = description
        prerequisiteObservation["satisfied"] = String(satisfied)
        XCTAssertTrue(satisfied, description)
        // Freeze the original failed observation before evidence collection; never re-query/activate after it.
        if !satisfied { throw PrerequisiteFailure(reason: description) }
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
        let activated = action.accessibilityActivate()
        XCTAssertTrue(activated, "The actual SwiftUI action must handle accessibility activation")
        if !activated { throw PrerequisiteFailure(reason: "Actual accessibility activation returned false: \(id)") }
    }
    func testFirstLoadHasOneRequestAndRecoveryDoesNotChangeStoreGating() async throws {
        let scene = CompanionRecoveryFixtureScene()
        scene.service.modes[alpha] = .held
        scene.store.drafts[alpha] = "Retained synthetic draft"
        try await withHost(scene) { _ in
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
    }

    func testQueuedRefreshRemainsBoundToOldAgentOnSameHost() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha); await scene.store.load(beta)
        scene.service.modes[alpha] = .failure
        await scene.store.load(alpha, force: true)
        try await withHost(scene) { window in
            try await waitUntil("Initial normal view hook finishes before counting the explicit retry") {
                let calls = scene.service.historyCalls[self.alpha] ?? 0
                let loading = scene.store.conversation(for: self.alpha).isLoading
                // Preserve the original conjunction/short-circuited leaf lookup; record which term was observed.
                let leaf = calls == 3 && !loading ? self.element("companion-recovery-retry", in: window) != nil : nil
                self.prerequisiteObservation = ["expectedCalls": "3", "actualCalls": String(calls),
                    "loading": String(loading), "leaf": leaf.map { String($0) } ?? "not evaluated (short circuit)"]
                return calls == 3 && !loading && leaf == true
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
    }

    func testDetailsDismissOnTargetSwitchAndRetriesStayWithTheirHost() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha); await scene.store.load(gamma)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError), hostID: alpha.hostID)
        try await withHost(scene) { window in
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
    }

    func testRetainedInactivePageDismissesDetailsWithoutResettingReadingOrDraft() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha)
        scene.store.drafts[alpha] = "Retained page draft"
        let bookmark = scene.store.readingBookmark(for: alpha)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError))
        try await withHost(scene) { window in
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

    func testTeardownClosesFutureHoldsBeforeDrainingPendingRequests() async throws {
        let service = CompanionRecoveryFixtureService()
        defer { service.beginTeardown() }
        service.modes[alpha] = .held
        let pending = Task { try await service.history(for: alpha) }
        try await waitUntil("One explicit held request is pending") { service.pendingHistoryCount == 1 }
        service.beginTeardown()
        service.modes[beta] = .held // A late queued mutation cannot reopen admission.
        let late = Task { try await service.history(for: beta) }
        let firstResult = try await pending.value
        let lateResult = try await late.value
        XCTAssertEqual(firstResult.items.count, 12)
        XCTAssertEqual(lateResult.items.count, 12)
        XCTAssertTrue(service.isTearingDown)
        XCTAssertEqual(service.pendingHistoryCount, 0)
    }
}
