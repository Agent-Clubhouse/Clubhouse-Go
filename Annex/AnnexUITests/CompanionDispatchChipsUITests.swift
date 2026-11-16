import XCTest

@MainActor final class CompanionDispatchChipsUITests: ReliableUITestCase {
    private func open(_ flags: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
            "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"] + flags, attempts: 1)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func appearance(_ flags: [String], _ name: String) {
        let app = open(flags)
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        let echo = app.buttons["dispatcher-desktop-preview-laptop"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15) && echo.exists)
        XCTAssertEqual(navi.label, "Navi")
        XCTAssertEqual(echo.label, "Echo")
        XCTAssertTrue(navi.isHittable && navi.frame.height >= 44)
        XCTAssertTrue(echo.isHittable && echo.frame.height >= 44)
        XCTAssertFalse(app.buttons["dispatcher-desktop-switcher"].exists)
        XCTAssertFalse(app.buttons["Settings"].exists)
        capture(app, "444 Dispatch chips - \(name)")
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(navi.isSelected)
    }
    func testLight() { appearance(["--companion-preview-light"], "light") }
    func testDark() { appearance(["--companion-preview-dark"], "dark") }
    func testLatte() { appearance(["--companion-preview-light", "--companion-preview-theme-latte"], "Catppuccin Latte") }
    func testMocha() { appearance(["--companion-preview-dark", "--companion-preview-theme-mocha"], "Catppuccin Mocha") }
    func testAccessibilityXXXL() {
        appearance(["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "accessibility XXXL")
    }
    func testCachedReplyDotsAndStreamingStackCanExpandWithReduceMotion() {
        let app = open(["--companion-preview-dispatch-reports", "--companion-preview-dispatch-reduce-motion"])
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        let echo = app.buttons["dispatcher-desktop-preview-laptop"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15))
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        echo.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 5))
        XCTAssertFalse(navi.label.contains("New reply"), "Initial cached history is the baseline")
        app.buttons["dispatcher-preview-other-reply"].tap()
        XCTAssertTrue(waitFor(navi, NSPredicate(format: "label CONTAINS %@", "New reply"), timeout: 5))
        capture(app, "444 Cached new reply")
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(navi, NSPredicate(format: "NOT (label CONTAINS %@)", "New reply"), timeout: 5))
        app.buttons["dispatcher-preview-start-reply"].tap()
        let stack = app.buttons["dispatcher-desktop-switcher"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["dispatcher-chips"].exists, "Streaming uses no chip-row reading space")
        capture(app, "444 Streaming stack - Reduce Motion")
        waitAndTap(stack, until: app.buttons["dispatcher-expand-chips"], attempts: 1)
        app.buttons["dispatcher-expand-chips"].tap()
        XCTAssertTrue(navi.waitForExistence(timeout: 5))
        app.buttons["Collapse Dispatchers"].tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        app.buttons["dispatcher-preview-finish-reply"].tap()
        XCTAssertTrue(navi.waitForExistence(timeout: 5), "Resting returns to discoverable chips")
    }
    func testLastDispatcherRestoresIndependentlyOfHomeSelection() {
        let args = ["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
            "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"]
        let app = launchApp(args, attempts: 1)
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15)); navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        let otherAgent = app.buttons["agent-preview-laptop-river"]
        XCTAssertTrue(scrollTo(otherAgent, in: app, maxSwipes: 12))
        otherAgent.tap()
        XCTAssertTrue(app.navigationBars["River"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = args + ["--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-studio"].isSelected)
        capture(app, "444 Saved Dispatcher restored after Home selection")
        // A connected report with no Dispatchers is authoritative and clears the saved choice.
        app.terminate()
        // This existing fixture makes both desktops connected, so neither has an unknown offline catalog.
        app.launchArguments = ["--companion-preview", "--companion-preview-needs-you-multiple-desktops",
            "--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Dispatch"].waitForNonExistence(timeout: 15))
        // Existing cold-launch mirroring may change the legacy host before that report arrives.
        // Set H after removal: cleared D gives Laptop/Echo, while stale Studio D would give Navi.
        XCTAssertTrue(scrollTo(otherAgent, in: app, maxSwipes: 12))
        otherAgent.tap()
        XCTAssertTrue(app.navigationBars["River"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = args + ["--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        // A known-empty cache stays on Home; enter the newly available tab before checking its saved choice.
        let dispatch = app.tabBars.buttons["Dispatch"]
        XCTAssertTrue(dispatch.waitForExistence(timeout: 15))
        XCTAssertTrue(dispatch.isHittable)
        dispatch.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 15), "A cleared choice uses the independent Home-host fallback")
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-laptop"].isSelected)
        capture(app, "444 Removed Dispatcher preference falls back safely")
    }
}
