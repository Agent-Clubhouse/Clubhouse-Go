import XCTest

@MainActor final class DiagnosticSettingsTests: XCTestCase {
    func testCaptureDefaultsOffAndExportRequiresReview() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--diagnostics-ui-testing"]
        app.launch()
        let capture = app.switches["diagnostics.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        XCTAssertEqual(capture.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Remote export disabled"].exists)
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        XCTAssertEqual(capture.value as? String, "1")
        app.buttons["Review diagnostic export"].tap()
        XCTAssertTrue(app.navigationBars["Review export"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Clear captured diagnostics"].tap()
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        XCTAssertEqual(capture.value as? String, "0")
        app.terminate()
    }
}
