import XCTest

final class FramebriarShakeUITests: ReliableUITestCase {
    @MainActor private func revealSwitch(_ toggle: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollTo(toggle, in: app, maxSwipes: 5))
        // A clipped row can be hittable while its actual switch center is below the window.
        for _ in 0..<3 {
            if app.windows.firstMatch.frame.contains(toggle.frame) { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(toggle.frame))
    }
    @MainActor func testShakeOpensComposerWithoutSendingAndWorksOverSheets() throws {
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
        let remove = app.buttons["framebriar-remove-attachment"]
        scrollTo(remove, in: app, maxSwipes: 3)
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists)
        remove.tap()
        XCTAssertFalse(attachment.waitForExistence(timeout: 1))
        XCTAssertFalse(remove.exists)
        let chooseScreenshot = app.buttons["Add screenshot"]
        scrollUntilExists(chooseScreenshot, in: app, maxSwipes: 3, wait: 0.5)
        XCTAssertTrue(chooseScreenshot.exists, "The image can still be chosen from Photos")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
        let toggle = app.switches["Shake to open feedback"]
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 5)
        revealSwitch(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        // The Settings route remains accessible when shake is disabled.
        XCTAssertTrue(scrollTo(app.buttons["Send feedback"], in: app, up: false, maxSwipes: 4))
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        shake.tap()
        XCTAssertFalse(app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5))
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 5)
        revealSwitch(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Disabling shake must survive presentation and view reconstruction")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].tap()
        waitAndTap(app.buttons["Present other screen"], until: app.staticTexts["Another presentation"], timeout: 5)
        app.buttons["Simulate shake while presented"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5), "The SDK callback opens over an ordinary sheet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Another presentation"].waitForExistence(timeout: 5), "Closing feedback returns to the underlying sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        // A presentation boundary has a two-second debounce; wait through that intentional interval.
        _ = app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5)
        shake.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    /// A pre-attached screenshot is never saved by opening or cancelling; only Send queues it.
    @MainActor func testShakeScreenshotIsQueuedOnlyOnSend() throws {
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
        let included = app.staticTexts["framebriar-included"]
        XCTAssertTrue(included.waitForExistence(timeout: 5))
        XCTAssertTrue(included.label.contains("screenshot"))
        XCTAssertFalse(app.buttons["Review feedback"].exists, "One intentional Send replaces Review then Submit")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(counters.label.hasPrefix("Queued: 0"), "Cancel must not queue: \(counters.label)")

        _ = composer.waitForExistence(timeout: 2.5)
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        let send = app.buttons["framebriar-send"]
        XCTAssertTrue(send.isHittable, "Send stays in the top bar")
        send.tap()
        let result = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Saved, will send when online", "A local save is never called Sent")
        app.buttons["framebriar-done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(counters.label.hasPrefix("Queued: 1"))
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
        XCTAssertTrue(app.navigationBars["Fixture settings"].waitForExistence(timeout: 5))
        revealSwitch(toggle, in: app)
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
        XCTAssertFalse(app.buttons["framebriar-remove-attachment"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }
}
