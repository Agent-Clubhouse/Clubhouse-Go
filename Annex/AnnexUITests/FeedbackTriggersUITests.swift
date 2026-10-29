import XCTest

/// Feedback entry points that don't depend on a shake (#181): the offer after an iOS screenshot and the
/// Send feedback menu items. The fixture posts `userDidTakeScreenshotNotification` as iOS does.
final class FeedbackTriggersUITests: ReliableUITestCase {
    @MainActor func testScreenshotPromptOpensComposerWithTheScreenAttached() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        let screenshot = app.buttons["fixture-screenshot"]
        let prompt = app.buttons["screenshot-feedback-prompt"]
        let composer = app.navigationBars["Send feedback"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "An enrolled screenshot offers feedback")
        XCTAssertEqual(prompt.label, "Send feedback with this screenshot?")
        prompt.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        sleep(2); print("DUMP-BEGIN\n\(app.debugDescription)\nDUMP-END")
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5), "The screen is pre-attached for review")
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists, "Opening never submits")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))

        // The prompt can be dismissed, and goes away by itself.
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        app.buttons["screenshot-feedback-dismiss"].tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 1))
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: prompt)
        waitForExpectations(timeout: 12)
        XCTAssertFalse(composer.exists)

        // No prompt while a password field is in use.
        let password = app.secureTextFields["Fixture password"]
        scrollTo(password, in: app, maxSwipes: 3)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2), "A focused password field suppresses the prompt and capture")
    }

    @MainActor func testScreenshotPromptSettingTurnsItOff() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        let toggle = app.switches["Offer feedback when you take a screenshot"]
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 10)
        scrollTo(toggle, in: app, maxSwipes: 3)
        XCTAssertEqual(toggle.value as? String, "1", "On by default")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].tap()
        let screenshot = app.buttons["fixture-screenshot"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].waitForExistence(timeout: 2))
    }

    /// Unenrolled: the enrollment explainer, once per session, so ordinary screenshots aren't nagged.
    @MainActor func testUnenrolledScreenshotExplainsEnrollmentOnce() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-shake-unenrolled"])
        let screenshot = app.buttons["fixture-screenshot"]
        let explainer = app.alerts["Feedback enrollment required"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(explainer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].exists)
        explainer.buttons["Not now"].tap()
        XCTAssertFalse(explainer.waitForExistence(timeout: 1))
        screenshot.tap()
        XCTAssertFalse(explainer.waitForExistence(timeout: 2), "Explained once per session")
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].exists)
    }

    @MainActor func testSendFeedbackInHomeAndChatMenus() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-feedback"])
        let composer = app.navigationBars["Send feedback"]
        let more = app.buttons["home-more-menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        waitAndTap(more, until: app.buttons["Send feedback"], timeout: 5)
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Home's menu opens the feedback form")
        XCTAssertFalse(app.images["framebriar-attachment"].exists, "A menu entry attaches nothing on its own")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(composer.waitForExistence(timeout: 2))

        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app, maxSwipes: 4)
        XCTAssertTrue(scrollTo(agent, in: app, maxSwipes: 4))
        let actions = app.buttons["Conversation actions"]
        waitAndTap(agent, until: actions, timeout: 15)
        waitAndTap(actions, until: app.buttons["Send feedback"], timeout: 5)
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "The chat ⋯ menu opens the feedback form")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
    }
}
