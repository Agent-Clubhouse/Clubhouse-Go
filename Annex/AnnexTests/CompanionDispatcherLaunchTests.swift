import XCTest
import UIKit
@testable import ClubhouseGo

@MainActor final class CompanionDispatcherLaunchTests: XCTestCase {
    func testInitialCatalogIsUnknownButAnActualEmptyReportIsKnown() {
        let store = CompanionStore(service: CompanionLiveService())
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertFalse(store.hasReceivedHostReport)
        store.apply(.hosts([]))
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertTrue(store.hasReceivedHostReport, "A known empty report must still reconcile authority")
        store.shutdown()
    }

    func testColdAndWarmShortcutUseOneRetainedHandoffAndUnknownActionsDoNothing() {
        let inbox = CompanionDispatcherLaunchInbox()
        XCTAssertFalse(inbox.handleQuickAction("unknown"))
        XCTAssertNil(inbox.pending)
        XCTAssertTrue(inbox.handleQuickAction(CompanionDispatcherLaunchInbox.quickActionType))
        let first = try! XCTUnwrap(inbox.pending)
        XCTAssertEqual(first.source, .quickAction)
        XCTAssertTrue(inbox.handleQuickAction(CompanionDispatcherLaunchInbox.quickActionType))
        let second = try! XCTUnwrap(inbox.pending)
        XCTAssertNotEqual(first.id, second.id)
        inbox.consume(first.id)
        XCTAssertEqual(inbox.pending, second, "A delayed consumer cannot discard a newer external invocation")
        inbox.consume(second.id)
        XCTAssertNil(inbox.pending)
    }

    func testColdConnectionShortcutWaitsForRestoreBeforeItsRequestCanBeConsumed() throws {
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let previous = inbox.pending { inbox.consume(previous.id) }
        CompanionLaunchSceneDelegate.captureColdShortcut(UIApplicationShortcutItem(
            type: CompanionDispatcherLaunchInbox.quickActionType, localizedTitle: "Message Dispatcher"))
        let request = try XCTUnwrap(inbox.pending)
        XCTAssertEqual(CompanionDispatcherLaunchResolution.resolve(desktops: [], pairedHostIDs: nil,
            restorationComplete: false, hosts: []), .waiting)
        XCTAssertEqual(inbox.pending?.id, request.id, "Connection-options delivery survives before SwiftUI/runtime restoration")
        XCTAssertEqual(CompanionDispatcherLaunchResolution.resolve(desktops: [], pairedHostIDs: [],
            restorationComplete: true, hosts: []), .unavailable)
        inbox.consume(request.id)
        XCTAssertNil(inbox.pending)
    }

    func testForegroundIntentUsesTheSameHandoffWithoutSending() async throws {
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let request = inbox.pending { inbox.consume(request.id) }
        _ = try await MessageDispatcherIntent().perform()
        let request = try XCTUnwrap(inbox.pending)
        XCTAssertEqual(request.source, .appIntent)
        inbox.consume(request.id)
    }

    func testWarmSceneDelegateUsesTheSamePendingRequest() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let inbox = CompanionDispatcherLaunchInbox.shared
        let handled = await CompanionLaunchSceneDelegate().windowScene(scene,
            performActionFor: UIApplicationShortcutItem(type: CompanionDispatcherLaunchInbox.quickActionType, localizedTitle: "Message Dispatcher"))
        XCTAssertTrue(handled)
        let request = try XCTUnwrap(inbox.pending)
        XCTAssertEqual(request.source, .quickAction)
        inbox.consume(request.id)
    }

    func testSwiftUISceneDelegateConfigurationKeepsTheExistingWindowScene() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let configuration = CompanionLaunchAppDelegate.sceneConfiguration(role: scene.session.role)
        XCTAssertEqual(configuration.role, scene.session.role)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(configuration.delegateClass)), ObjectIdentifier(CompanionLaunchSceneDelegate.self))
        XCTAssertNotNil(scene.windows.first?.rootViewController, "The adaptor leaves SwiftUI's existing window ownership intact")
        XCTAssertNil(configuration.storyboard)
    }
}
