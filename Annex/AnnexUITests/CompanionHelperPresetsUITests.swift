import XCTest

/// Preview-only: presentation and refused actions. No live desktop, provider login, or routing is exercised.
@MainActor final class CompanionHelperPresetsUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openPresets(_ app: XCUIApplication) {
        let link = element(app, "helper-presets-preview-studio")
        waitAndTap(app.buttons["Settings"], until: link)
        waitAndTap(link, until: element(app, "helper-preset-codex-cli-easy"))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testEffectiveCustomStaleAndUnverifiedPresetsAndResetRefusal() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-presets"])
        openPresets(app)
        XCTAssertTrue(element(app, "helper-preset-codex-cli-easy").label.contains("Built-in"))
        let hard = element(app, "helper-preset-codex-cli-hard")
        XCTAssertTrue(scrollTo(hard, in: app))
        XCTAssertTrue(hard.label.contains("gpt-6.1-sol") && hard.label.contains("No longer offered"), hard.label)
        let medium = element(app, "helper-preset-codex-cli-medium")
        XCTAssertTrue(scrollTo(medium, in: app))
        XCTAssertTrue(medium.label.contains("Couldn’t be checked"), medium.label)
        XCTAssertFalse(app.switches["Auto"].exists)
        capture(app, "Helper presets - states (preview)")
        XCTAssertTrue(scrollTo(hard, in: app))
        waitAndTap(hard, until: app.buttons["helper-preset-reset"])
        XCTAssertTrue(element(app, "helper-preset-saved").label.contains("gone, high effort"), element(app, "helper-preset-saved").label)
        capture(app, "Helper presets - stale saved choice (preview)")
        let reset = app.buttons["helper-preset-reset"]
        XCTAssertTrue(scrollTo(reset, in: app))
        reset.tap()
        let error = app.staticTexts["helper-presets-error"]
        XCTAssertTrue(scrollUntilExists(error, in: app, up: false) && error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Preview only"))
        XCTAssertTrue(element(app, "helper-preset-saved").label.contains("gone, high effort"), element(app, "helper-preset-saved").label)
    }
    func testOnlyOfferedModelAndEffortChoicesAndRefusedSave() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-presets"])
        openPresets(app)
        waitAndTap(element(app, "helper-preset-codex-cli-easy"), until: app.buttons["helper-preset-model"])
        let picker = app.buttons["helper-preset-model"]
        waitAndTap(picker, until: app.buttons["Terra"])
        XCTAssertTrue(app.buttons["Sol"].exists && app.buttons["Luna"].exists)
        XCTAssertFalse(app.buttons["Default"].exists || app.buttons["gone"].exists)
        app.buttons["Terra"].tap()
        let effort = app.buttons["helper-preset-effort"]
        waitAndTap(effort, until: app.buttons["high"])
        XCTAssertTrue(app.buttons["CLI default"].exists && app.buttons["low"].exists && app.buttons["medium"].exists)
        app.buttons["high"].tap()
        let save = app.buttons["helper-preset-save"]
        XCTAssertTrue(scrollTo(save, in: app))
        save.tap()
        let error = app.staticTexts["helper-presets-error"]
        XCTAssertTrue(scrollUntilExists(error, in: app, up: false) && error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Preview only"))
        capture(app, "Helper presets - refused change (preview)")
    }
    func testHelperSettingsAndHeldStartShowTheirOwnRouting() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-presets"])
        let row = element(app, "agent-preview-studio-juniper")
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settings)
        waitAndTap(settings, until: element(app, "agent-settings-summary"))
        let summary = element(app, "helper-routing-summary")
        XCTAssertTrue(scrollUntilExists(summary, in: app) && scrollTo(summary, in: app))
        XCTAssertTrue(summary.label == "gpt-6.1-sol, high effort. From the helper settings for this difficulty.")
        XCTAssertTrue(element(app, "helper-routing-reason").label == "From the helper settings for this difficulty")
        capture(app, "Helper settings - routing explanation (preview)")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Needs you"].tap()
        let request = element(app, "helper-request-routing")
        XCTAssertTrue(scrollUntilExists(request, in: app) && scrollTo(request, in: app))
        XCTAssertTrue(request.label == "codex-cli · hard")
        capture(app, "Held start - requested routing (preview)")
    }
}
