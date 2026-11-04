import XCTest

@MainActor final class CompanionAppLifetimeUITests: ReliableUITestCase {
    func testLaunchCanOpenCancelAndReopenPairingWithoutConnecting() {
        let app = launchApp([])
        let welcome = app.buttons["Pair your Mac"]
        let home = app.buttons["Pair a desktop"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10) || home.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            let pair = welcome.exists ? welcome : home
            XCTAssertTrue(scrollTo(pair, in: app, maxSwipes: 3))
            pair.tap()
            let sheet = app.navigationBars["Pair a desktop"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            sheet.buttons["Cancel"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
    }
}
