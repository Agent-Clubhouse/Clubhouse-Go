import XCTest

@MainActor final class CompanionLinkedProjectStateUITests: ReliableUITestCase {
    private func open(_ flags: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-linked-projects", "--companion-preview-linked-project-state"] + flags, attempts: 1)
    }
    private func menu(_ app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons["project-menu-preview-studio-clubhouse"]
        XCTAssertTrue(scrollUntilExists(menu, in: app) && scrollTo(menu, in: app))
        return menu
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func appearance(_ flags: [String], name: String) {
        let app = open(flags)
        waitAndTap(menu(app), until: app.buttons["Pin project"], attempts: 1)
        XCTAssertEqual(app.buttons.matching(identifier: "Pin project").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "Mark inactive").count, 1)
        XCTAssertFalse(app.buttons["Studio Mac"].exists)
        XCTAssertFalse(app.buttons["Travel MacBook"].exists)
        XCTAssertTrue(app.buttons["Pin project"].isEnabled && app.buttons["Pin project"].isHittable)
        capture(app, "Linked shared project menu — \(name)")
    }
    func testLight() { appearance(["--companion-preview-light"], name: "light") }
    func testDark() { appearance(["--companion-preview-dark"], name: "dark") }
    func testLatte() { appearance(["--companion-preview-light", "--companion-preview-theme-latte"], name: "Catppuccin Latte") }
    func testMocha() { appearance(["--companion-preview-dark", "--companion-preview-theme-mocha"], name: "Catppuccin Mocha") }
    func testAccessibilityXXXL() {
        appearance(["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], name: "accessibility XXXL")
    }
    func testPartiallyOfflineGroupCanPinThroughItsConnectedCopy() {
        let app = open(["--companion-preview-linked-state-partially-offline"])
        waitAndTap(menu(app), until: app.buttons["Pin project"], attempts: 1)
        XCTAssertTrue(app.buttons["Pin project"].isEnabled)
        app.buttons["Pin project"].tap()
        waitAndTap(menu(app), until: app.buttons["Unpin project"], attempts: 1)
        XCTAssertFalse(app.buttons["Mark inactive"].exists, "Pinned is never inactive")
        capture(app, "Linked group pinned through connected Laptop, Studio offline")
    }
    func testMixedVersionGroupShowsDisabledSharedControlsAndExplains() {
        let app = open(["--companion-preview-linked-state-mixed-version"])
        waitAndTap(menu(app), until: app.buttons["Pin project"], attempts: 1)
        XCTAssertFalse(app.buttons["Pin project"].isEnabled)
        XCTAssertFalse(app.buttons["Mark inactive"].isEnabled)
        let hint = app.buttons["Connect Studio Mac for shared changes."]
        XCTAssertTrue(hint.exists)
        XCTAssertFalse(hint.isEnabled)
        capture(app, "Linked group needs a capable connected desktop")
    }
    func testOldHostDaysIdleMemberOffersMarkActiveWithoutAnExplicitInactiveMark() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects", "--companion-preview-linked-state-local-idle"], attempts: 1)
        waitAndTap(menu(app), until: app.buttons["Studio Mac"], attempts: 1)
        waitAndTap(app.buttons["Studio Mac"], until: app.buttons["Mark active"], attempts: 1)
        XCTAssertTrue(app.buttons["Pin project"].exists)
        XCTAssertTrue(app.buttons["Mark active"].isEnabled)
        capture(app, "Old-host days-idle copy offers Mark active")
    }

}
