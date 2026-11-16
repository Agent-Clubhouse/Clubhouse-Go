import XCTest

@MainActor final class CompanionHomeDesktopScopeUITests: ReliableUITestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func select(_ hostID: String, in app: XCUIApplication) {
        let chip = app.buttons["desktop-chip-host-\(hostID)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        let chips = app.scrollViews["desktop-chips"]
        for _ in 0..<4 where !chip.isHittable { chips.swipeLeft() }
        XCTAssertTrue(chip.isHittable)
        assertMinimumTarget(chip, "Desktop chip")
        chip.tap()
        XCTAssertTrue(chip.isSelected)
    }

    func testLinkedCopiesStayScopedAcrossTabsAndRemovedSelectionRestoresAll() {
        let arguments = ["--companion-preview", "--companion-preview-linked-projects", "--companion-preview-home-scope-controls"]
        let app = launchApp(arguments, attempts: 1)
        XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
        select("preview-laptop", in: app)
        XCTAssertTrue(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-studio-river").firstMatch.exists, "Identically named Studio agent must not leak into Travel scope")
        XCTAssertTrue(app.staticTexts["home-summary"].label.contains("0 working"))
        capture(app, "Home selected desktop contains only its linked copy")
        app.tabBars.buttons["Needs you"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["desktop-chip-host-preview-laptop"].isSelected, "Scope lasts across tab switches")
        app.buttons["Settings"].tap()
        let remove = app.buttons["Report Travel desktop removed"]
        XCTAssertTrue(scrollUntilExists(remove, in: app) && scrollTo(remove, in: app))
        remove.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "agent-preview-studio-river").firstMatch.waitForExistence(timeout: 10), "The chip owner must reconcile even as its row disappears")
        XCTAssertFalse(app.buttons["desktop-chip-all"].exists)
        XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Studio Mac' OR label CONTAINS 'Travel MacBook'")).firstMatch.exists, "One paired desktop needs no machine labels on Home")
        capture(app, "Home one desktop has no machine labels after removal")
        app.terminate()
        let relaunched = launchApp(arguments, attempts: 1)
        XCTAssertTrue(relaunched.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
        XCTAssertTrue(relaunched.buttons["desktop-chip-all"].isSelected, "A new launch starts on All")
        XCTAssertTrue(relaunched.buttons.matching(identifier: "agent-preview-studio-river").firstMatch.exists)
        XCTAssertTrue(relaunched.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists)
    }

    func testFiveDesktopAppearanceMatrixAndOfflineScope() {
        let variants: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-home-five-desktops"] + flags, allowance: 360, attempts: 1)
            XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["home-summary"].label.contains("3 of 5 desktops connected"))
            capture(app, "Home desktop chips All \(name)")
            select("preview-laptop", in: app)
            XCTAssertTrue(waitFor(app.staticTexts["home-summary"], NSPredicate(format: "label CONTAINS '0 working' AND label CONTAINS '0 need you'"), timeout: 5))
            let offline = app.staticTexts["home-project-unavailable-preview-laptop-notes"]
            XCTAssertTrue(scrollUntilExists(offline, in: app) && scrollTo(offline, in: app))
            XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-studio-river").firstMatch.exists)
            XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists, "Cached offline work cannot appear live")
            XCTAssertTrue(app.buttons["home-retry-preview-laptop"].exists)
            capture(app, "Home offline desktop scope \(name)")
            app.terminate()
        }
    }
}
