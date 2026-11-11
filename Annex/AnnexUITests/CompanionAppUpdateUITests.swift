import XCTest

@MainActor final class CompanionAppUpdateUITests: ReliableUITestCase {
    func testIndicatorRequestAndExplicitModeBeforeAllowOnce() {
        let app = launchApp(["--companion-preview", "--companion-preview-app-update"])
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        waitAndTap(home, until: app.navigationBars["Clubhouse"])
        let indicator = app.buttons["app-update-preview-studio"]
        XCTAssertTrue(scrollTo(indicator, in: app))
        XCTAssertTrue(indicator.label.contains("Update ready on"))
        waitAndTap(indicator, until: app.navigationBars["Desktop update"])
        let request = app.buttons["app-update-request"]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Stopped agents will not resume")).firstMatch.exists)
        waitAndTap(alert.buttons["Request update"], untilGone: alert)
        XCTAssertTrue(app.buttons["app-update-cancel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let needsYou = app.tabBars.buttons["Needs you"]
        waitAndTap(needsYou, until: app.navigationBars["Needs you"])
        let allow = app.buttons["grant-request-allow"].firstMatch
        XCTAssertTrue(scrollTo(allow, in: app))
        XCTAssertFalse(allow.isEnabled, "An update's Allow once must not send a generic approval")
        let picker = app.buttons["app-update-mode"]
        XCTAssertTrue(scrollTo(picker, in: app))
        picker.tap()
        app.buttons["When idle"].tap()
        XCTAssertTrue(scrollTo(allow, in: app))
        XCTAssertTrue(allow.isEnabled)
        let summary = app.staticTexts["Update Clubhouse to 1.1.0"]
        waitAndTap(allow, untilGone: summary)
        XCTAssertFalse(app.buttons["grant-request-allow"].firstMatch.exists)
    }
}
