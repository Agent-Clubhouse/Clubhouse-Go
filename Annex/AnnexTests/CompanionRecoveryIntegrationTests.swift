import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Production callback effects and actual mounted-sheet lifetime. Direct callbacks do not establish AX reachability.
@MainActor final class CompanionRecoveryIntegrationTests: XCTestCase {
    private let alpha = CompanionRecoveryFixtureService.alpha
    private let beta = CompanionRecoveryFixtureService.beta
    private let gamma = CompanionRecoveryFixtureService.gamma
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
        func run() async throws {
            defer {
                scene.service.beginTeardown()
                window.isHidden = true; window.rootViewController = nil
                scene.store.stop()
                originalKeyWindow?.makeKey()
            }
            try await body(window)
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
        if let bodyError { throw bodyError }
    }
    private func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let satisfied = predicate()
        XCTAssertTrue(satisfied, description)
        if !satisfied { throw PrerequisiteFailure(reason: description) }
    }
    /// A passive fixture onChange acknowledges the changed input; it never writes the sheet's State.
    /// This control must finish before a target/visibility change can establish identity-driven dismissal.
    private func presentedDetailsSurvivesClearedSeed(_ scene: CompanionRecoveryFixtureScene, in window: UIWindow) async throws -> UIViewController {
        try await waitUntil("The actual recovery component presents its seeded Details") {
            guard let presented = window.rootViewController?.presentedViewController else { return false }
            return !presented.isBeingPresented && !presented.isBeingDismissed && presented.viewIfLoaded?.window === window
        }
        let root = try XCTUnwrap(window.rootViewController)
        let presented = try XCTUnwrap(root.presentedViewController)
        let targetBefore = scene.target, activeBefore = scene.isActive
        let observationsBefore = scene.recoveryDetailsSeedObservationCount
        let originalSeed = scene.initiallyShowsRecoveryDetails
        XCTAssertTrue(originalSeed)
        if !originalSeed { throw PrerequisiteFailure(reason: "The stable-input control requires an original true seed") }
        scene.initiallyShowsRecoveryDetails = false
        try await waitUntil("The fixture observes the false input in an actual SwiftUI update") {
            scene.observedRecoveryDetailsSeed == false && scene.recoveryDetailsSeedObservationCount > observationsBefore
        }
        XCTAssertEqual(scene.recoveryDetailsSeedObservationCount, observationsBefore + 1)
        XCTAssertEqual(scene.target, targetBefore)
        XCTAssertEqual(scene.isActive, activeBefore)
        let retained = window.rootViewController === root && root.presentedViewController === presented
            && !presented.isBeingDismissed && presented.viewIfLoaded?.window === window
        XCTAssertTrue(retained, "Changing only the initial input must retain the same actually presented controller")
        let controlSucceeded = originalSeed && scene.observedRecoveryDetailsSeed == false
            && scene.recoveryDetailsSeedObservationCount == observationsBefore + 1
            && scene.target == targetBefore && scene.isActive == activeBefore && retained
        if !controlSucceeded { throw PrerequisiteFailure(reason: "The stable-input control failed after a witnessed update") }
        return presented
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
        try await withHost(scene) { _ in
            try await waitUntil("Initial normal view hook finishes before counting the explicit retry") {
                scene.service.historyCalls[self.alpha] == 3 && !scene.store.conversation(for: self.alpha).isLoading
            }
            let alphaBefore = scene.service.historyCalls[alpha] ?? 0
            let betaBefore = scene.service.historyCalls[beta] ?? 0
            XCTAssertEqual(alphaBefore, 3)
            XCTAssertEqual(betaBefore, 1)
            let retryAlpha = CompanionConversationView(store: scene.store, agent: try XCTUnwrap(scene.store.agent(for: alpha))).recoveryRetryAction
            scene.service.modes[alpha] = .held
            retryAlpha(.refreshConversation)
            scene.target = beta // Before the callback's Task can resume on this actor.
            try await waitUntil("Only the presented Alpha action starts a request") { scene.service.historyCalls[self.alpha] == alphaBefore + 1 }
            XCTAssertEqual(scene.service.historyCalls[beta], betaBefore)
            XCTAssertTrue(scene.store.conversation(for: alpha).isLoading)
            XCTAssertEqual(scene.service.pendingHistoryCount, 1)
            XCTAssertFalse(scene.store.canOperate(alpha))
            XCTAssertTrue(scene.store.canOperate(beta))
            scene.service.finish(alpha, as: .success)
            try await waitUntil("Old target's result settles without retargeting") { !scene.store.conversation(for: self.alpha).isLoading }
            XCTAssertEqual(scene.service.pendingHistoryCount, 0)
            XCTAssertTrue(scene.store.canOperate(alpha))
            XCTAssertFalse(scene.store.conversation(for: alpha).requiresResync)
            XCTAssertEqual(scene.service.historyCalls, [alpha: alphaBefore + 1, beta: betaBefore])
            XCTAssertEqual(scene.service.reconnectCalls.values.reduce(0, +), 0)
        }
    }

    func testDetailsDismissOnTargetSwitchAndRetriesStayWithTheirHost() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha); await scene.store.load(gamma)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError), hostID: alpha.hostID)
        scene.initiallyShowsRecoveryDetails = true
        try await withHost(scene) { window in
            let root = try XCTUnwrap(window.rootViewController)
            let presented = try await presentedDetailsSurvivesClearedSeed(scene, in: window)
            let retryAlpha = CompanionConversationView(store: scene.store, agent: try XCTUnwrap(scene.store.agent(for: alpha))).recoveryRetryAction
            scene.target = gamma
            try await waitUntil("Changing target dismisses old-target Details") {
                window.rootViewController?.presentedViewController == nil && presented.presentingViewController == nil
            }
            XCTAssertTrue(window.rootViewController === root)
            XCTAssertNil(presented.presentingViewController)
            XCTAssertTrue(scene.service.reconnectCalls.isEmpty)
            XCTAssertEqual(scene.service.historyCalls, [alpha: 1, gamma: 1])

            scene.target = alpha
            retryAlpha(.reconnect)
            scene.target = gamma
            try await waitUntil("Queued Alpha retry reconnects only Alpha's host") { scene.service.reconnectCalls[self.alpha.hostID] == 1 }
            XCTAssertNil(scene.service.reconnectCalls[gamma.hostID])

            scene.connection(.failed(CompanionRecoveryFixtureService.connectionError), hostID: gamma.hostID)
            // The component forwards this same production callback to Details. No button activation is claimed here.
            let retryGamma = CompanionConversationView(store: scene.store, agent: try XCTUnwrap(scene.store.agent(for: gamma))).recoveryRetryAction
            retryGamma(.reconnect)
            scene.target = alpha
            try await waitUntil("Gamma's issued action does not become an Alpha reconnect") { scene.service.reconnectCalls[self.gamma.hostID] == 1 }
            XCTAssertEqual(scene.service.reconnectCalls[alpha.hostID], 1)
            XCTAssertEqual(scene.service.historyCalls[alpha], 1)
            XCTAssertEqual(scene.service.historyCalls[gamma], 1)
            XCTAssertEqual(scene.service.historyCalls, [alpha: 1, gamma: 1])
            XCTAssertEqual(scene.service.reconnectCalls, [alpha.hostID: 1, gamma.hostID: 1])
        }
    }

    func testRetainedInactivePageDismissesDetailsWithoutResettingReadingOrDraft() async throws {
        let scene = CompanionRecoveryFixtureScene()
        await scene.store.load(alpha)
        scene.store.drafts[alpha] = "Retained page draft"
        let bookmark = scene.store.readingBookmark(for: alpha)
        let transcript = scene.store.conversation(for: alpha)
        scene.connection(.failed(CompanionRecoveryFixtureService.connectionError))
        scene.initiallyShowsRecoveryDetails = true
        try await withHost(scene) { window in
            let root = try XCTUnwrap(window.rootViewController)
            let presented = try await presentedDetailsSurvivesClearedSeed(scene, in: window)
            scene.isActive = false // Same showsActions transition used by a retained Review page.
            try await waitUntil("Inactive page cannot keep its old Details presented") {
                window.rootViewController?.presentedViewController == nil && presented.presentingViewController == nil
            }
            XCTAssertTrue(window.rootViewController === root)
            XCTAssertNil(presented.presentingViewController)
            XCTAssertTrue(scene.store.readingBookmark(for: alpha) === bookmark)
            XCTAssertEqual(scene.store.drafts[alpha], "Retained page draft")
            XCTAssertEqual(scene.service.historyCalls[alpha], 1)
            XCTAssertEqual(scene.service.historyCalls, [alpha: 1])
            XCTAssertEqual(scene.store.conversation(for: alpha), transcript)
            XCTAssertFalse(scene.store.canOperate(alpha), "The failed connection gate is unchanged by presentation")
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
