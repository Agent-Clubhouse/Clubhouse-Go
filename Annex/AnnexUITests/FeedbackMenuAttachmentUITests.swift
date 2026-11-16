import XCTest

/// Real composed chat toolbar, after the separate Settings feedback route has opened and closed.
@MainActor final class FeedbackMenuAttachmentUITests: ReliableUITestCase {
    private func openSettings(_ app: XCUIApplication) {
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Settings"], timeout: 15, attempts: 1)
    }
    private func openSettingsFeedback(_ app: XCUIApplication) {
        let send = app.buttons["Send feedback"]
        XCTAssertTrue(scrollTo(send, in: app, maxSwipes: 6))
        send.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5),
                      "Settings retains the pre-sheet screenshot for review")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
    func testSettingsFeedbackReopensWithItsPreSettingsScreenshot() {
        let app = launchApp(["--companion-preview", "--companion-preview-feedback"], attempts: 1)
        openSettings(app)
        openSettingsFeedback(app)
        openSettingsFeedback(app)
    }
    func testChatMenuAttachesAfterSettingsFeedbackDismisses() {
        let app = launchApp(["--companion-preview", "--companion-preview-feedback"], attempts: 1)
        openSettings(app)
        openSettingsFeedback(app)
        app.buttons["settings-close"].tap()
        let river = app.buttons["agent-preview-studio-river"]
        XCTAssertTrue(scrollUntilExists(river, in: app, maxSwipes: 4))
        XCTAssertTrue(scrollTo(river, in: app, maxSwipes: 4))
        let actions = app.buttons["conversation-actions-menu"]
        waitAndTap(river, until: actions, timeout: 15, attempts: 1)
        waitAndTap(actions, until: app.buttons["Send feedback"], timeout: 5, attempts: 1)
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5),
                      "The composed toolbar must freeze the chat before its menu opens")
        XCTAssertFalse(app.buttons["Add screenshot"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
    }
}
