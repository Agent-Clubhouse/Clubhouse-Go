import XCTest

@MainActor final class CompanionOfflineBannerUITests: ReliableUITestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSingleOfflineDesktopKeepsOneLineAndAnExplicitRetry() {
        let app = launchApp(["--companion-preview"], attempts: 1)
        let title = app.staticTexts["home-connection-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Travel MacBook is offline")
        XCTAssertLessThanOrEqual(title.frame.height, 30, "Standard-size copy remains one line")
        let retry = app.buttons["home-retry-preview-laptop"]
        assertMinimumTarget(retry, "Retry Travel MacBook")
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(title.exists, "The preview records no invented connection success")
        capture(app, "Home single offline desktop compact banner")
    }

    func testReconnectingUsesTheSameBannerWithoutAnotherRetry() {
        let app = launchApp(["--companion-preview", "--companion-preview-needs-you"],
                            environment: ["COMPANION_NEEDS_YOU_SCENARIO": "progress"], attempts: 1)
        let title = app.staticTexts["home-connection-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Reconnecting… · Studio Mac and Travel MacBook")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-retry-'")).count, 0)
        capture(app, "Home reconnecting compact banner")
        app.tabBars.buttons["Needs you"].tap()
        XCTAssertTrue(app.staticTexts["needs-you-connection-title"].waitForExistence(timeout: 5))
        capture(app, "Needs you reconnecting compact banner")
    }

    func testCombinedBannerAppearanceMatrixAndReadableXXXL() {
        let variants: [(String, [String], Bool)] = [
            ("light", ["--companion-preview-light"], false),
            ("dark", ["--companion-preview-dark"], false),
            ("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"], false),
            ("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"], false),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], true)
        ]
        for (name, flags, accessibility) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-home-five-desktops"] + flags, allowance: 360, attempts: 1)
            for (tab, prefix) in [("Home", "home"), ("Needs you", "needs-you")] {
                if tab != "Home" { app.tabBars.buttons[tab].tap() }
                let title = app.staticTexts["\(prefix)-connection-title"]
                XCTAssertTrue(scrollUntilExists(title, in: app) && scrollTo(title, in: app))
                XCTAssertEqual(title.label, "Travel MacBook and Workshop Mac aren't connected")
                XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
                if accessibility {
                    XCTAssertGreaterThan(title.frame.width, app.frame.width * 0.65, "XXXL uses full-width wrapping instead of a narrow column beside Retry")
                    XCTAssertGreaterThan(title.frame.height, 44)
                }
                let retry = app.buttons["\(prefix)-retry-all"]
                XCTAssertTrue(scrollUntilExists(retry, in: app) && scrollTo(retry, in: app))
                assertMinimumTarget(retry, "Retry disconnected desktops")
                XCTAssertTrue(retry.isHittable)
                capture(app, "\(tab) combined offline banner \(name)")
            }
            app.terminate()
        }
    }
}
