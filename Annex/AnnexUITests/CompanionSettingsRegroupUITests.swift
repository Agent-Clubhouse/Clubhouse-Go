import XCTest

@MainActor final class CompanionSettingsRegroupUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func open(_ arguments: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-start-home", "--companion-preview-helper-presets",
                             "--companion-preview-dispatcher", "--companion-preview-feedback"] + arguments, allowance: 360, attempts: 1)
        waitAndTap(app.buttons["Settings"], until: app.buttons["settings-close"])
        return app
    }
    private func appearance(_ name: String, _ arguments: [String]) {
        let app = open(arguments)
        let desktop = app.buttons["settings-desktop-preview-studio"]
        XCTAssertTrue(desktop.exists)
        XCTAssertTrue(desktop.label.contains("Connected"), desktop.label)
        XCTAssertFalse(app.staticTexts["Start screen"].exists)
        XCTAssertFalse(app.switches["Shake to open feedback"].exists, "Shortcuts belong on Feedback options")
        capture(app, "451 Settings top - \(name)")
        waitAndTap(desktop, until: app.navigationBars["Studio Mac"])
        XCTAssertTrue(app.staticTexts["Verified desktop identity"].exists)
        if name == "accessibility XXXL" { capture(app, "451 Desktop identity - \(name)") }
        let retry = app.buttons["desktop-connection-retry"]
        XCTAssertTrue(scrollTo(retry, in: app, maxSwipes: 10))
        XCTAssertTrue(retry.isEnabled && retry.isHittable && retry.frame.height >= 44)
        let forget = app.buttons["desktop-connection-forget"]
        XCTAssertTrue(scrollTo(forget, in: app))
        XCTAssertTrue(forget.isEnabled && forget.isHittable && forget.frame.height >= 44)
        capture(app, "451 Desktop detail - \(name)")
        app.navigationBars.buttons.firstMatch.tap()
        let options = app.buttons["settings-feedback-options"]
        XCTAssertTrue(scrollTo(options, in: app, maxSwipes: 18))
        capture(app, "451 Settings groups - \(name)")
        waitAndTap(options, until: app.navigationBars["Feedback options"])
        let enrollment = app.buttons["Invitation & enrollment"]
        XCTAssertTrue(enrollment.waitForExistence(timeout: 5))
        let disclosure = element(app, "feedback-telemetry-disclosure")
        XCTAssertTrue(disclosure.exists && disclosure.label.hasPrefix("Feedback shares the notes and optional image you choose to submit"))
        capture(app, "451 Feedback options - \(name)")
        let shortcut = app.switches["Shake to open feedback"]
        XCTAssertTrue(scrollTo(shortcut, in: app, maxSwipes: 24))
        XCTAssertTrue(shortcut.isEnabled)
        if name == "accessibility XXXL" { capture(app, "451 Feedback shortcuts - \(name)") }
    }
    func testLight() { appearance("light", ["--companion-preview-light"]) }
    func testDark() { appearance("dark", ["--companion-preview-dark"]) }
    func testLatte() { appearance("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]) }
    func testMocha() { appearance("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]) }
    func testAccessibilityXXXL() {
        appearance("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
    func testDesktopForgetRequiresConfirmationAndCancelRetainsIt() {
        let app = open()
        let desktop = app.buttons["settings-desktop-preview-studio"]
        waitAndTap(desktop, until: app.buttons["desktop-connection-retry"])
        let forget = app.buttons["desktop-connection-forget"]
        XCTAssertTrue(scrollTo(forget, in: app))
        waitAndTap(forget, until: app.buttons["Forget desktop"])
        XCTAssertTrue(app.staticTexts["Forget Studio Mac?"].exists)
        XCTAssertFalse(app.staticTexts["Desktop removed"].exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { waitAndTap(app.otherElements["PopoverDismissRegion"], untilGone: app.buttons["Forget desktop"]) }
        XCTAssertTrue(app.staticTexts["Verified desktop identity"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(desktop.waitForExistence(timeout: 5), "Cancel retains the paired desktop")
        app.buttons["settings-close"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
    }
    func testPhoneAndIdleSettingsKeepTheirSavedValuesAcrossNavigation() {
        let app = open()
        let idle = app.buttons["settings-idle-projects"]
        XCTAssertTrue(scrollTo(idle, in: app, maxSwipes: 8))
        waitAndTap(idle, until: app.navigationBars["Fold idle projects"])
        app.buttons["Never"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(idle.label.contains("Never"))
        let name = app.buttons["settings-phone-name"]
        XCTAssertTrue(scrollTo(name, in: app))
        let field = app.textFields["companion.deviceName"]
        waitAndTap(name, until: field)
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Settings test phone\n")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(name.label.contains("Settings test phone"))
        waitAndTap(name, until: field)
        XCTAssertEqual(field.value as? String, "Settings test phone")
    }
}
