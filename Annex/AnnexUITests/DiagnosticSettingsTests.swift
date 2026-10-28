import XCTest

@MainActor final class DiagnosticSettingsTests: XCTestCase {
    func testCaptureDefaultsOffAndExportRequiresReview() {
        continueAfterFailure = false
        let app = launchReadyApplication(arguments: ["--diagnostics-ui-testing"])
        let capture = app.descendants(matching: .any).matching(identifier: "diagnostics.capture").firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Off"].exists)
        XCTAssertTrue(app.staticTexts["Remote export disabled"].exists)
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        app.buttons["This session"].tap()
        app.buttons["Review diagnostic export"].tap()
        XCTAssertTrue(app.navigationBars["Review export"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Clear captured diagnostics"].tap()
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        app.buttons["Off"].tap()
        app.terminate()
    }
}
