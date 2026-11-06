import XCTest

/// Synthetic full conversation UI screenshots; RootView/tab integration has separate coverage.
@MainActor final class CompanionChatHeaderVisualUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // These are synthetic-only test attachments. Original feedback captures never enter the test bundle.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Header synthetic \(Int(app.frame.width))pt — \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func focus(_ app: XCUIApplication) {
        let composer = element(app, "companion-composer")
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3)); show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        composer.typeText("Synthetic header draft")
    }

    func testDarkWorkingKeyboardDownAndUp() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["companion-chat-activity"].exists)
        XCTAssertFalse(element(app, "companion-chat-details").exists)
        capture(app, "dark Working keyboard down")
        tapChatStatusBar(in: app)
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker 1.")).firstMatch
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 5), "Native top must reach the oldest fixture entry")
        capture(app, "dark Working native top keyboard down")
        focus(app)
        capture(app, "dark Working keyboard up")
        waitAndTap(app.buttons["companion-chat-header"], until: element(app, "companion-chat-details"))
        capture(app, "dark Working expanded keyboard up")
    }

    func testLightLongNameAccessibilityExpandedWithKeyboard() {
        let app = launch(["--companion-header-light", "--companion-header-long-name",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        focus(app)
        let details = element(app, "companion-chat-details")
        waitAndTap(app.buttons["companion-chat-header"], until: details)
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(app.buttons["companion-context-usage"].isHittable)
        capture(app, "light AX Large long name expanded keyboard up")
        waitAndTap(app.buttons["companion-chat-header"], untilGone: details)
        capture(app, "light AX Large long name collapsed keyboard up")
    }

    func testIdleFallbackCustomImageVersionAndContextQuota() {
        let app = launch(["--companion-header-idle"])
        XCTAssertFalse(app.staticTexts["companion-chat-activity"].exists)
        capture(app, "idle fallback")
        for version in 1...2 {
            waitAndTap(app.buttons["header-fixture-menu"], until: app.buttons["header-fixture-image"])
            waitAndTap(app.buttons["header-fixture-image"], untilGone: app.buttons["header-fixture-image"])
            XCTAssertTrue(waitFor(app.buttons["header-fixture-menu"],
                                  NSPredicate(format: "value == %@", "Synthetic profile image version \(version)"), timeout: 5))
            capture(app, "idle synthetic custom image version \(version)")
        }
        waitAndTap(app.buttons["companion-context-usage"], until: element(app, "companion-context-reading-note"))
        capture(app, "context editor with desktop quota route")
        waitAndTap(app.buttons["companion-context-plan-limits"], until: app.navigationBars["Plan limits"])
        XCTAssertTrue(element(app, "plan-limits-preview-studio-claude-code").waitForExistence(timeout: 10))
        capture(app, "desktop plan limits")
    }
}
