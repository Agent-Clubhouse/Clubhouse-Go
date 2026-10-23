import XCTest

final class FramebriarShakeUITests: XCTestCase {
    @MainActor func testShakeOpensReviewWithoutSubmittingAndRespectsToggleAndPresentation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--framebriar-shake-ui-testing"]
        app.launch()
        let shake = app.buttons["fixture-shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        app.buttons["Simulate repeated shake"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Feedback notes"].exists)
        XCTAssertEqual(app.textViews["Feedback notes"].value as? String, "")
        XCTAssertTrue(app.buttons["Choose screenshot to review"].exists)
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists)
        XCTAssertFalse(app.buttons["Remove attachment"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
        app.buttons["Settings"].tap()
        let toggle = app.switches["Shake to open feedback"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        // The Settings route remains accessible when shake is disabled.
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        shake.tap()
        XCTAssertFalse(app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5))
        app.buttons["Settings"].tap(); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        app.buttons["Done"].tap()
        app.buttons["Present other screen"].tap()
        XCTAssertTrue(app.staticTexts["Another presentation"].waitForExistence(timeout: 5))
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
