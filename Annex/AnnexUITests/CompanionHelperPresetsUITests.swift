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
    func testFiveLevelsAndResetRestoresInheritance() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-presets", "--companion-preview-helper-preset-edits"])
        openPresets(app)
        for level in ["minimum", "easy", "medium", "hard", "maximum"] {
            let row = element(app, "helper-preset-codex-cli-\(level)")
            XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app), level)
            XCTAssertTrue(row.label.contains(level.capitalized), row.label)
            if level == "minimum" { XCTAssertTrue(row.label.contains("Same as Easy"), row.label) }
            if level == "maximum" { XCTAssertTrue(row.label.contains("Same as Hard"), row.label) }
        }
        let minimum = element(app, "helper-preset-codex-cli-minimum")
        XCTAssertTrue(scrollUntilExists(minimum, in: app, up: false) && scrollTo(minimum, in: app, up: false))
        waitAndTap(minimum, until: app.buttons["helper-preset-save"])
        XCTAssertTrue(element(app, "helper-preset-inheritance").label == "Same as Easy")
        XCTAssertFalse(app.buttons["helper-preset-reset"].exists)
        waitAndTap(app.buttons["helper-preset-save"], until: app.buttons["helper-preset-reset"])
        XCTAssertTrue(element(app, "helper-preset-saved").exists)
        XCTAssertFalse(element(app, "helper-preset-inheritance").exists)
        waitAndTap(app.buttons["helper-preset-reset"], until: element(app, "helper-preset-inheritance"))
        XCTAssertTrue(element(app, "helper-preset-inheritance").label == "Same as Easy")
        XCTAssertFalse(element(app, "helper-preset-saved").exists)
        XCTAssertFalse(app.buttons["helper-preset-reset"].exists)
        capture(app, "Helper presets - reset inherits Easy (preview)")
    }

    func testCopilotIsPresetOnlyAndNoEffortModelHasNoPicker() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-presets"])
        openPresets(app)
        let footer = element(app, "helper-preset-only-copilot-cli")
        XCTAssertTrue(scrollUntilExists(footer, in: app) && scrollTo(footer, in: app))
        XCTAssertTrue(footer.label.contains("Preset only. Auto doesn’t choose this provider."), footer.label)
        let easy = element(app, "helper-preset-copilot-cli-easy")
        XCTAssertTrue(scrollUntilExists(easy, in: app, up: false) && scrollTo(easy, in: app, up: false))
        XCTAssertTrue(easy.label.contains("claude-haiku-4.5") && !easy.label.contains("effort"), easy.label)
        waitAndTap(easy, until: app.buttons["helper-preset-model"])
        XCTAssertTrue(element(app, "helper-preset-no-effort").exists)
        XCTAssertFalse(app.buttons["helper-preset-effort"].exists)
        XCTAssertTrue(app.buttons["helper-preset-save"].isEnabled)
        capture(app, "Helper presets - Copilot with no effort levels (preview)")
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
        waitAndTap(app.buttons["Done"], untilGone: element(app, "agent-settings-summary"))
        let tab = app.tabBars.buttons["Needs you"]
        // iOS can keep the tab bar minimized after scrolling the settings sheet.
        // Tapping the selected Home tab expands it before choosing another tab.
        if !tab.exists { waitAndTap(app.tabBars.buttons["Home"], until: tab) }
        let request = element(app, "helper-request-routing")
        waitAndTap(tab, until: request)
        XCTAssertTrue(scrollUntilExists(request, in: app) && scrollTo(request, in: app))
        XCTAssertTrue(request.label == "codex-cli · hard")
        capture(app, "Held start - requested routing (preview)")
    }
}
