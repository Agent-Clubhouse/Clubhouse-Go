import XCTest
import UIKit
@testable import ClubhouseGo

@MainActor final class CompanionDispatcherLaunchTests: XCTestCase {
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

    func testForegroundIntentUsesTheSameHandoffWithoutSending() async throws {
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let request = inbox.pending { inbox.consume(request.id) }
        _ = try await MessageDispatcherIntent().perform()
        let request = try XCTUnwrap(inbox.pending)
        XCTAssertEqual(request.source, .appIntent)
        inbox.consume(request.id)
    }

    func testSwiftUISceneDelegateConfigurationKeepsTheExistingWindowScene() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let configuration = CompanionLaunchAppDelegate().application(UIApplication.shared,
            configurationForConnecting: scene.session, options: UIScene.ConnectionOptions())
        XCTAssertEqual(configuration.role, scene.session.role)
        XCTAssertTrue(configuration.delegateClass === CompanionLaunchSceneDelegate.self)
        XCTAssertNil(configuration.storyboard)
    }
}
