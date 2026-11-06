import XCTest

@MainActor final class CompanionNeedsYouUITests: ReliableUITestCase {
    private func open(_ scenario: String) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-needs-you"],
                            environment: ["COMPANION_NEEDS_YOU_SCENARIO": scenario])
        waitAndTap(app.tabBars.buttons["Needs you"], until: app.navigationBars["Needs you"], timeout: 15)
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testOfflineNoticeKeepsReachableRequestAndScopedRetry() {
        let app = open("one-offline")
        let retry = app.buttons["needs-you-retry-preview-laptop"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(retry.label, "Retry Travel MacBook")
        XCTAssertTrue(app.staticTexts["Travel MacBook is offline"].exists)
        XCTAssertTrue(app.staticTexts["Pending items are unknown until this desktop is ready."].exists)
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        let request = app.staticTexts["Needs permission to use Bash"]
        scrollUntilExists(request, in: app)
        XCTAssertTrue(request.exists, "The reachable desktop's request remains in the flat list")
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you with one offline desktop")
    }

    func testNoReachableDesktopsQualifiesEmptyStateAndKeepsBothRetries() {
        let app = open("all-unavailable")
        XCTAssertTrue(app.buttons["needs-you-retry-preview-studio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["needs-you-retry-preview-laptop"].exists)
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        let empty = app.staticTexts["No requests to show"]
        scrollUntilExists(empty, in: app)
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you with both desktops unavailable")
    }

    func testConnectionInProgressShowsUnknownWithoutDuplicateRetry() {
        let app = open("progress")
        XCTAssertTrue(app.staticTexts["Looking for Studio Mac…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connecting to Travel MacBook…"].exists)
        XCTAssertFalse(app.buttons["needs-you-retry-preview-studio"].exists)
        XCTAssertFalse(app.buttons["needs-you-retry-preview-laptop"].exists)
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you while desktops reconnect")
    }

    func testBothOnlineCanShowKnownEmptyState() {
        let app = open("online-empty")
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Nothing is waiting on you."].exists)
        XCTAssertFalse(element(app, "needs-you-unavailable-preview-studio").exists)
        XCTAssertFalse(element(app, "needs-you-unavailable-preview-laptop").exists)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
