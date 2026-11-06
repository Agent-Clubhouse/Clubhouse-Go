import XCTest

@MainActor final class CompanionNeedsYouUITests: ReliableUITestCase {
    private func open(_ scenario: String, largeText: Bool = false) -> XCUIApplication {
        var arguments = ["--companion-preview", "--companion-preview-needs-you"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        let app = launchApp(arguments,
                            environment: ["COMPANION_NEEDS_YOU_SCENARIO": scenario])
        waitAndTap(app.tabBars.buttons["Needs you"], until: app.navigationBars["Needs you"], timeout: 15)
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testOfflineNoticeKeepsReachableRequestAndScopedRetry() {
        let app = open("one-offline")
        let request = app.staticTexts["Needs permission to use Bash"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "Reachable requests appear before availability notices")
        let retry = app.buttons["needs-you-retry-preview-laptop"]
        XCTAssertTrue(scrollUntilExists(retry, in: app))
        XCTAssertEqual(retry.label, "Retry Travel MacBook")
        XCTAssertTrue(app.staticTexts["Travel MacBook is offline"].exists)
        XCTAssertTrue(app.staticTexts["Pending items are unknown until this desktop is ready."].exists)
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        scrollUntilExists(request, in: app, up: false)
        XCTAssertTrue(request.exists, "The reachable desktop's request remains in the flat list")
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you with one offline desktop")
    }

    func testNoReachableDesktopsQualifiesEmptyStateAndKeepsBothRetries() {
        let app = open("all-unavailable", largeText: true)
        let empty = app.staticTexts["No requests to show"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        attach(app, "Needs you unavailable empty state — AccessibilityL")
        let studio = app.buttons["needs-you-retry-preview-studio"]
        XCTAssertTrue(scrollUntilExists(studio, in: app) && scrollTo(studio, in: app))
        XCTAssertEqual(studio.label, "Retry Studio Mac")
        attach(app, "Needs you first unavailable desktop — AccessibilityL")
        let laptop = app.buttons["needs-you-retry-preview-laptop"]
        XCTAssertTrue(scrollUntilExists(laptop, in: app) && scrollTo(laptop, in: app))
        XCTAssertEqual(laptop.label, "Retry Travel MacBook")
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you second unavailable desktop — AccessibilityL")
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
