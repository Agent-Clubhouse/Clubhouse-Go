import XCTest

/// Preview-only presentation coverage. No provider CLI, plan, catalog or live desktop is exercised.
@MainActor final class CompanionContextWindowUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openSettings(_ app: XCUIApplication, rowID: String, sleeping: Bool = false) {
        let row = element(app, rowID)
        if sleeping {
            expandFold(element(app, "fold-sleeping-preview-studio-clubhouse"), revealing: row, in: app)
        }
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settings)
        waitAndTap(settings, until: element(app, "agent-settings-summary"))
    }

    func testSleepingAgentShowsPendingChoiceAndResetRefusal() {
        let app = launchApp(["--companion-preview", "--companion-preview-context-window"])
        openSettings(app, rowID: "agent-preview-studio-juniper", sleeping: true)
        let picker = app.buttons["agent-settings-context-window"]
        XCTAssertTrue(scrollTo(picker, in: app) && picker.isEnabled)
        XCTAssertTrue(picker.label.contains("Working context") && picker.label.contains("500K"), picker.label)
        XCTAssertTrue(app.staticTexts["Applies the next time the agent starts. Also applies when resuming a session."].exists)
        let reset = app.buttons["agent-settings-context-window-reset"]
        XCTAssertTrue(scrollTo(reset, in: app) && reset.isEnabled)
        // SwiftUI can call a partially clipped form control hittable; keep this action inside the viewport.
        for _ in 0..<4 {
            if reset.frame.maxY < app.windows.firstMatch.frame.maxY - 120 { break }
            app.swipeUp()
        }
        XCTAssertLessThan(reset.frame.maxY, app.windows.firstMatch.frame.maxY - 120)
        screenshot(app, "Context - sleeping agent pending choice (preview)")
        reset.tap()
        let error = app.staticTexts["agent-settings-error"]
        XCTAssertTrue(scrollUntilExists(error, in: app, up: false) && error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Preview only"))
        XCTAssertTrue(scrollTo(picker, in: app) && picker.label.contains("500K"), "A refused reset keeps the saved choice")
    }

    func testDispatcherPendingChoiceCanChangeWithoutSleeping() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window"])
        openSettings(app, rowID: "dispatcher-row-preview-studio")
        let picker = app.buttons["agent-settings-context-window"]
        XCTAssertTrue(scrollTo(picker, in: app) && picker.isEnabled)
        screenshot(app, "Context - Dispatcher next-start choice (preview)")
        waitAndTap(picker, until: app.buttons["300K"])
        XCTAssertTrue(app.buttons["Auto"].exists && app.buttons["500K"].exists)
        screenshot(app, "Context - Dispatcher server choices (preview)")
        app.buttons["300K"].tap()
        let error = app.staticTexts["agent-settings-error"]
        XCTAssertTrue(scrollUntilExists(error, in: app, up: false) && error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Preview only"))
    }

    func testReportedContextIsReadOnlyAndAwakePendingChoiceIsLocked() {
        let app = launchApp(["--companion-preview", "--companion-preview-context-window"])
        let row = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollTo(row, in: app))
        let report = element(app, "companion-context-report")
        waitAndTap(row, until: report)
        XCTAssertTrue(report.label.contains("Effective context:") && report.label.contains("Auto-compaction at:") && report.label.contains("Reserved:"), report.label)
        screenshot(app, "Context - current reported limits (preview)")
        let actions = app.buttons["Conversation actions"]
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings)
        waitAndTap(settings, until: element(app, "agent-settings-summary"))
        let picker = app.buttons["agent-settings-context-window"]
        XCTAssertTrue(scrollTo(picker, in: app))
        XCTAssertFalse(picker.isEnabled)
        XCTAssertFalse(app.buttons["agent-settings-context-window-reset"].isEnabled)
        screenshot(app, "Context - awake pending choice locked (preview)")
    }
}
