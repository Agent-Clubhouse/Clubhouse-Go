import XCTest

final class FramebriarShakeUITests: ReliableUITestCase {
    @MainActor func testShakeOpensReviewWithoutSubmittingAndRespectsToggleAndPresentation() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        let shake = app.buttons["fixture-shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        app.buttons["Simulate repeated shake"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Feedback notes"].exists)
        XCTAssertEqual(app.textViews["Feedback notes"].value as? String, "")
        // The screen that was showing is pre-attached for review, and can be removed.
        let attachment = app.images["framebriar-attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), "A shake pre-attaches a screenshot")
        XCTAssertTrue(app.staticTexts["framebriar-captured-screen-note"].exists)
        let remove = app.buttons["Remove attachment"]
        scrollTo(remove, in: app, maxSwipes: 3)
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists)
        remove.tap()
        XCTAssertFalse(attachment.waitForExistence(timeout: 1))
        XCTAssertFalse(remove.exists)
        let chooseScreenshot = app.buttons["Choose screenshot to review"]
        scrollUntilExists(chooseScreenshot, in: app, maxSwipes: 3, wait: 0.5)
        XCTAssertTrue(chooseScreenshot.exists, "The image can still be chosen from Photos")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
        let toggle = app.switches["Shake to open feedback"]
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 5)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        // The Settings route remains accessible when shake is disabled.
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        shake.tap()
        XCTAssertFalse(app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5))
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 5)
        XCTAssertEqual(toggle.value as? String, "0", "Disabling shake must survive presentation and view reconstruction")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].tap()
        waitAndTap(app.buttons["Present other screen"], until: app.staticTexts["Another presentation"], timeout: 5)
        app.buttons["Simulate shake while presented"].tap()
        XCTAssertFalse(app.navigationBars["Send feedback"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        // A presentation boundary has a two-second debounce; wait through that intentional interval.
        _ = app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5)
        shake.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    /// A pre-attached screenshot is never saved by reviewing or cancelling; only Submit queues a report.
    @MainActor func testShakeScreenshotIsQueuedOnlyOnSubmit() throws {
        executionTimeAllowance = 240
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--framebriar-shake-ui-testing"]
        app.launch()
        let shake = app.buttons["fixture-shake"]
        let counters = app.staticTexts["fixture-counters"]
        let composer = app.navigationBars["Send feedback"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        let review = app.buttons["Review feedback"]
        scrollTo(review, in: app, maxSwipes: 3)
        review.tap()
        let submit = app.buttons["Submit reviewed feedback"]
        scrollTo(submit, in: app, maxSwipes: 4)
        XCTAssertTrue(submit.exists, "Review shows the Submit step")
        XCTAssertTrue(app.staticTexts["The image shown above will be attached."].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(counters.label.hasPrefix("Queued: 0"), "Reviewing and cancelling must not queue: \(counters.label)")

        // Wait through the presentation-boundary debounce, then submit for real.
        _ = composer.waitForExistence(timeout: 2.5)
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        scrollTo(review, in: app, maxSwipes: 3)
        review.tap()
        scrollTo(submit, in: app, maxSwipes: 4)
        submit.tap()
        // A successful local save dismisses the composer.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: composer)
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Queued: 1"), evaluatedWith: counters)
        waitForExpectations(timeout: 10)
    }

    /// With "Attach a screenshot when you shake" off, the composer opens without an attachment.
    @MainActor func testScreenshotToggleOffOpensWithoutAttachment() throws {
        executionTimeAllowance = 240
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--framebriar-shake-ui-testing"]
        app.launch()
        let shake = app.buttons["fixture-shake"]
        let composer = app.navigationBars["Send feedback"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let toggle = app.switches["Attach a screenshot when you shake"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "Screenshot capture defaults on")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        _ = composer.waitForExistence(timeout: 2.5)
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["framebriar-attachment"].waitForExistence(timeout: 2), "No screenshot with the toggle off")
        XCTAssertFalse(app.buttons["Remove attachment"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }
}
