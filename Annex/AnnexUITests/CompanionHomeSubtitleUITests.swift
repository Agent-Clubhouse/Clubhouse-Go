import XCTest

@MainActor final class CompanionHomeSubtitleUITests: ReliableUITestCase {
    private func subtitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["home-summary"]
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSubtitleUpdatesAfterAgentAndConnectionReports() {
        let app = launchApp(["--companion-preview", "--companion-preview-home-summary-controls"], attempts: 1)
        let counts = subtitle(app)
        XCTAssertTrue(counts.waitForExistence(timeout: 15))
        XCTAssertTrue(counts.label.contains("1 needs you"))
        app.buttons["Settings"].tap()
        let report = app.buttons["Report two requests and no working agents"]
        XCTAssertTrue(scrollUntilExists(report, in: app) && scrollTo(report, in: app))
        report.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(counts, NSPredicate(format: "label CONTAINS '0 working' AND label CONTAINS '2 need you'"), timeout: 5))
        capture(app, "Home subtitle updates to plural attention count")
        app.buttons["Settings"].tap()
        let offline = app.buttons["Report Studio offline"]
        XCTAssertTrue(scrollUntilExists(offline, in: app) && scrollTo(offline, in: app))
        offline.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(counts, NSPredicate(format: "label CONTAINS '0 need you'"), timeout: 5))
    }

    func testHomeSubtitleAppearanceMatrixAndReadableXXXL() {
        let variants: [(String, [String], Bool)] = [
            ("light", ["--companion-preview-light"], false),
            ("dark", ["--companion-preview-dark"], false),
            ("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"], false),
            ("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"], false),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], true)
        ]
        for (name, flags, accessibility) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-home-five-desktops"] + flags, allowance: 360, attempts: 1)
            let counts = subtitle(app)
            XCTAssertTrue(counts.waitForExistence(timeout: 15))
            capture(app, "Home subtitle \(name)")
            XCTAssertTrue(counts.label.contains("1 working") && counts.label.contains("1 needs you"))
            XCTAssertTrue(counts.label.contains("3 of 5 desktops connected"))
            XCTAssertGreaterThanOrEqual(counts.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(counts.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(counts.frame.minY, app.navigationBars["Clubhouse"].frame.maxY,
                                        "The scrolling header must stay below the native navigation bar")
            XCTAssertLessThanOrEqual(counts.frame.maxY, app.tabBars.firstMatch.frame.minY,
                                     "All summary lines must fit in the visible content at XXXL")
            if accessibility {
                XCTAssertGreaterThanOrEqual(counts.frame.height, 100, "XXXL must give all subtitle lines room instead of clipping a single line")
            }
            if name == "light" {
                app.swipeUp()
                XCTAssertFalse(counts.isHittable, "The header must scroll away with the list")
            }
            app.terminate()
        }
    }

    func testSubtitleDoesNotLeakAcrossTabsAndRestoresAfterRelaunch() {
        let flags = ["--companion-preview", "--companion-preview-home-five-desktops"]
        let app = launchApp(flags, attempts: 1)
        XCTAssertTrue(subtitle(app).waitForExistence(timeout: 15))
        app.tabBars.buttons["Needs you"].tap()
        XCTAssertFalse(app.staticTexts["home-summary"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(subtitle(app).waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(subtitle(app).waitForExistence(timeout: 15))
        XCTAssertTrue(subtitle(app).label.contains("3 of 5 desktops connected"))
    }
}
