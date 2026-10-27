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
        let chooseScreenshot = app.buttons["Choose screenshot to review"]
        scrollUntilExists(chooseScreenshot, in: app, maxSwipes: 3, wait: 0.5)
        XCTAssertTrue(chooseScreenshot.exists)
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists)
        XCTAssertFalse(app.buttons["Remove attachment"].exists)
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
}
