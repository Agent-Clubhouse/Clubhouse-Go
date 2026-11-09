import XCTest

/// Feedback entry points that don't depend on a shake (#181): the offer after an iOS screenshot and the
/// Send feedback menu items. The fixture posts `userDidTakeScreenshotNotification` as iOS does.
final class FeedbackTriggersUITests: ReliableUITestCase {
    @MainActor func testSettingsFromHomeToolbarAttachesCaptureOrOffersPhotos() throws {
        for failed in [false, true] {
            let app = launchApp(["--companion-preview", "--companion-preview-feedback", "--companion-preview-start-home",
                                 "--framebriar-wire-ui-testing"] + (failed ? ["--feedback-capture-failure"] : []))
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
            waitAndTap(app.buttons["Settings"], until: app.navigationBars["Settings"], timeout: 5)
            let send = app.buttons["Send feedback"]
            XCTAssertTrue(scrollTo(send, in: app, maxSwipes: 6)); send.tap()
            XCTAssertTrue(app.textViews["framebriar-notes"].waitForExistence(timeout: 5))
            if failed {
                XCTAssertFalse(app.images["framebriar-attachment"].exists)
                let add = app.buttons["Add screenshot"]
                XCTAssertTrue(scrollTo(add, in: app, maxSwipes: 4)); add.tap()
                let photos = app.navigationBars["Photos"]
                XCTAssertTrue(photos.waitForExistence(timeout: 20)); photos.buttons["Cancel"].tap()
                XCTAssertTrue(app.staticTexts["framebriar-screenshot-unavailable"].exists)
            } else {
                XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Replace screenshot"].exists)
            }
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            app.terminate()
        }
    }

    /// Both Go's modal enrollment route and Settings expose clearing without enrollment or a send.
    @MainActor func testClearQueuedFeedbackIsReachableFromEnrollmentSheetAndSettings() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-shake-unenrolled"])
        let shake = app.buttons["fixture-shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        shake.tap()
        let explainer = app.alerts["Feedback enrollment required"]
        XCTAssertTrue(explainer.waitForExistence(timeout: 5))
        explainer.buttons["Set up feedback"].tap()
        XCTAssertTrue(app.navigationBars["Feedback enrollment"].waitForExistence(timeout: 5))
        let clear = app.buttons["Clear queued feedback"]
        XCTAssertTrue(scrollTo(clear, in: app, maxSwipes: 6))
        clear.tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear queued feedback"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["framebriar-status"].label, "Queued reports cleared from this device.")
        app.buttons["Done"].tap()

        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 5)
        XCTAssertTrue(scrollTo(clear, in: app, maxSwipes: 4))
        clear.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear queued feedback"].tap()
        XCTAssertTrue(app.staticTexts["feedback-queue-status"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    @MainActor func testHeldReportsRequireConfirmationAndCanBeClearedWhileUnenrolled() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-held-ui-testing"])
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        let summary = app.staticTexts["feedback-held-summary"]
        XCTAssertTrue(scrollTo(summary, in: app, maxSwipes: 5))
        XCTAssertTrue(summary.label.hasPrefix("2 reports were saved under a previous enrollment"))
        let release = app.buttons["feedback-release-held"]
        XCTAssertTrue(scrollTo(release, in: app, maxSwipes: 3))
        release.tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts["Send 2 reports saved under a previous enrollment with this one?"].exists)
        // Compact iOS 26 confirmation popovers omit an automatic Cancel row. An outside
        // tap is their native cancel action; keep the same retained-report assertions.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Fixture settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertFalse(confirmation.waitForExistence(timeout: 1))
        XCTAssertTrue(summary.exists, "Cancel retains the held reports")
        release.tap()
        confirmation.buttons["Send"].tap()
        let result = app.staticTexts["feedback-queue-status"]
        XCTAssertTrue(scrollTo(result, in: app, maxSwipes: 3))
        XCTAssertEqual(result.label, "2 will send with this enrollment. They aren't confirmed sent yet.")
        XCTAssertFalse(summary.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.hasPrefix("Queued: 2"), "Offline release queues; it isn't delivery")

        app.terminate()
        app.launchArguments = ["--framebriar-shake-ui-testing", "--framebriar-held-ui-testing", "--framebriar-shake-unenrolled"]
        app.launch()
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        let clear = app.buttons["feedback-clear-held"]
        XCTAssertTrue(scrollTo(clear, in: app, maxSwipes: 5))
        XCTAssertFalse(app.buttons["feedback-release-held"].exists, "No release token while unenrolled")
        clear.tap()
        confirmation.buttons["Clear held reports"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "2 cleared from this device. They weren't sent.")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    @MainActor func testShakeOpensOverSettingsAndClosesBackToSettings() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        app.buttons["Simulate shake in Settings"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Fixture settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

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
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        scrollTo(toggle, in: app, maxSwipes: 3)
        // isHittable can be true for the visible top of a clipped row while its switch is
        // below the window. Reveal the entire row before choosing a control coordinate.
        for _ in 0..<3 {
            if app.windows.firstMatch.frame.contains(toggle.frame) { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(toggle.frame))
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
        XCTAssertTrue(app.images["framebriar-attachment"].exists, "The underlying screen starts attached for review")
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
        XCTAssertTrue(app.images["framebriar-attachment"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
    }
}
