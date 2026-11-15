import XCTest

@MainActor final class CompanionSearchUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSearch(_ extra: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-start-agents"] + extra, attempts: 1)
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 15), "Legacy Agents restoration lands in Search")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Agents"].exists)
        return app
    }

    func testRestingFiltersUseTheExistingAgentStatuses() {
        let app = openSearch()
        let cedar = element(app, "agent-preview-studio-cedar")
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(river.waitForExistence(timeout: 5))
        app.buttons["Working"].tap()
        XCTAssertTrue(cedar.waitForExistence(timeout: 5))
        XCTAssertFalse(river.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "agent-preview-studio-maple").waitForExistence(timeout: 5))
        XCTAssertFalse(cedar.exists)
        let chips = app.scrollViews["companion-search-filters"]
        chips.swipeLeft()
        app.buttons["Asleep"].tap()
        XCTAssertTrue(element(app, "agent-preview-studio-juniper").waitForExistence(timeout: 5))
        XCTAssertFalse(cedar.exists)
        chips.swipeRight()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Needs you'")).firstMatch.tap()
        XCTAssertTrue(river.waitForExistence(timeout: 5))
        XCTAssertFalse(cedar.exists)
    }

    func testOpenedAgentsAppearInRecentAndSurviveProcessRelaunch() {
        let app = openSearch()
        for id in ["maple", "cedar", "river"] {
            let row = element(app, "agent-preview-studio-\(id)")
            XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
            waitAndTap(row, until: element(app, "companion-composer"), attempts: 1)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launchArguments = ["--companion-preview", "--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 15))
        let river = element(app, "search-recent-preview-studio-river")
        let cedar = element(app, "search-recent-preview-studio-cedar")
        let maple = element(app, "search-recent-preview-studio-maple")
        XCTAssertTrue(river.waitForExistence(timeout: 5) && cedar.exists && maple.exists)
        XCTAssertLessThan(river.frame.minY, cedar.frame.minY)
        XCTAssertLessThan(cedar.frame.minY, maple.frame.minY)
        screenshot(app, "Recent agents restored newest first")
    }

    func testTypingStillFindsAgentNamesTasksAndProjects() {
        let app = openSearch()
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("River")
        XCTAssertTrue(element(app, "agent-preview-studio-river").waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "Investigate reconnect")
        XCTAssertTrue(element(app, "agent-preview-studio-cedar").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "agent-preview-studio-river").exists)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 21) + "Website")
        XCTAssertTrue(app.staticTexts["Website"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "agent-preview-studio-cedar").exists)
    }

    func testSearchAppearanceMatrix() {
        let variants: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in variants {
            let app = openSearch(["--companion-preview-search-recents"] + flags)
            XCTAssertTrue(element(app, "search-recent-preview-studio-cedar").waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["All"].isHittable)
            screenshot(app, "Search \(name) resting")
            app.terminate()
        }
    }
}
