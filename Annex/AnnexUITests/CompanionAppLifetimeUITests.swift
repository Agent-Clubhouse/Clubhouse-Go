import XCTest

@MainActor final class CompanionAppLifetimeUITests: ReliableUITestCase {
    func testLaunchCanOpenCancelAndReopenPairingWithoutConnecting() {
        let app = launchApp(["--companion-root-ui-testing"])
        let home = app.buttons["Pair a desktop"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            XCTAssertTrue(scrollTo(home, in: app, maxSwipes: 3))
            home.tap()
            let sheet = app.navigationBars["Pair a desktop"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            sheet.buttons["Cancel"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
    }

    func testRootSettingsActionCanOpenCloseAndReopen() {
        let app = launchApp(["--companion-root-ui-testing"])
        for _ in 0..<2 {
            let settings = app.navigationBars["Settings"]
            waitAndTap(app.buttons["Settings"], until: settings, timeout: 10)
            settings.buttons["Done"].tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        }
    }
}
