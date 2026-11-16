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

    func testSelectedDesktopConstrainsBothNewAgentEntriesAndAllKeepsChooser() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects"], attempts: 1)
        XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
        select("preview-laptop", in: app)
        let projectPlus = app.buttons.matching(NSPredicate(format: "label == 'New agent in Clubhouse'")).firstMatch
        XCTAssertTrue(scrollUntilExists(projectPlus, in: app) && scrollTo(projectPlus, in: app))
        projectPlus.tap()
        let prompt = app.textFields["Agent task"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "The selected Laptop copy opens its real Quick form without a machine detour")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "spawn-machine-picker").firstMatch.exists)
        let projectPicker = app.buttons["spawn-project-picker"]
        projectPicker.tap()
        XCTAssertTrue(app.buttons["Clubhouse · Travel MacBook"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Clubhouse · Studio Mac"].exists, "The sheet must not widen Home's explicit launch scope")
        capture(app, "Home Laptop scoped New agent exposes only Laptop")
        app.buttons["Clubhouse · Travel MacBook"].tap()
        app.navigationBars.buttons["Cancel"].tap()
        let toolbarPlus = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(toolbarPlus.waitForExistence(timeout: 5))
        toolbarPlus.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "The toolbar + carries the same explicit host scope")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "spawn-machine-picker").firstMatch.exists)
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["desktop-chip-all"].tap()
        toolbarPlus.tap()
        let machine = app.descendants(matching: .any).matching(identifier: "spawn-machine-picker").firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: 10), "All retains the linked machine chooser")
        XCTAssertFalse(prompt.exists)
        machine.tap()
        XCTAssertTrue(app.buttons["Studio Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Travel MacBook"].exists)
        capture(app, "Home All New agent retains both machine choices")
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
            let retry = app.buttons["home-retry-preview-laptop"]
            XCTAssertTrue(scrollUntilExists(retry, in: app) && scrollTo(retry, in: app))
            XCTAssertTrue(retry.isHittable)
            assertMinimumTarget(retry, "Scoped offline Retry")
            capture(app, "Home offline scoped Retry \(name)")
            let offline = app.staticTexts["home-project-unavailable-preview-laptop-notes"]
            XCTAssertTrue(scrollUntilExists(offline, in: app) && scrollTo(offline, in: app))
            XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-studio-river").firstMatch.exists)
            XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists, "Cached offline work cannot appear live")
            capture(app, "Home offline desktop scope \(name)")
            app.terminate()
        }
    }
}
