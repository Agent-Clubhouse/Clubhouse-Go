import XCTest

/// Synthetic preview inputs exercise the production sheet, quota renderer and settings navigation.
@MainActor final class CompanionContextLimitsUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func open(_ flags: [String] = [], unknown: Bool = false) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-context-sheet-fixture"] + flags, attempts: 1)
        let context = app.buttons[unknown ? "companion-context-settings" : "companion-context-usage"]
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        XCTAssertTrue(context.isHittable)
        waitAndTap(context, until: app.navigationBars["Context and limits"], attempts: 1)
        let close = app.buttons["companion-context-close"]
        XCTAssertTrue(close.isHittable)
        assertMinimumTarget(close, "Context close")
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Context and limits — \(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let row = element(app, id)
        XCTAssertTrue(scrollUntilExists(row, in: app, maxSwipes: 5, wait: 1) && scrollTo(row, in: app))
        return row
    }

    func testContextAndOwnProviderWindowsAcrossAppearances() {
        let appearances: [(String, [String])] = [
            ("light", ["--companion-header-light"]), ("dark", []),
            ("latte", ["--companion-header-latte", "--companion-header-light"]),
            ("mocha", ["--companion-header-mocha"]),
            ("AX3", ["--companion-header-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in appearances {
            let app = open(flags)
            XCTAssertEqual(element(app, "companion-context-token-count").label, "84k of 200k tokens")
            XCTAssertTrue(element(app, "companion-context-reading-note").label.hasPrefix("Reported "))
            capture(app, "\(name) medium summary")
            let plan = reveal("plan-limits-preview-studio-claude-code", in: app)
            XCTAssertTrue(plan.label.contains("Weekly"), plan.label)
            XCTAssertTrue(plan.label.lowercased().contains("5-hour") || plan.label.lowercased().contains("five-hour"), plan.label)
            XCTAssertFalse(element(app, "plan-limits-preview-studio-codex-cli").exists)
            XCTAssertFalse(element(app, "plan-limits-preview-studio-copilot-cli").exists)
            XCTAssertFalse(element(app, "plan-limits-preview-work-claude-code").exists)
            capture(app, "\(name) own provider windows")
            let footer = reveal("companion-context-plan-limits-footer", in: app)
            XCTAssertEqual(footer.label, "Every desktop and provider: Settings › Plan limits.")
            app.buttons["companion-context-close"].tap()
            XCTAssertTrue(app.buttons["companion-context-usage"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testUnknownContextAndUndatedReadingsRemainExplicit() {
        let app = open(["--companion-context-unknown"], unknown: true)
        XCTAssertTrue(app.staticTexts["Context usage unknown"].exists)
        XCTAssertEqual(element(app, "companion-context-reading-note").label, "Report time unknown")
        XCTAssertFalse(element(app, "companion-context-token-count").exists)
        _ = reveal("plan-limits-preview-studio-claude-code", in: app)
        capture(app, "unknown context with available own plan")
        app.terminate()
        let undated = open(["--companion-context-undated"])
        XCTAssertEqual(element(undated, "companion-context-token-count").label, "84k of 200k tokens")
        XCTAssertEqual(element(undated, "companion-context-reading-note").label, "Report time unknown")
        capture(undated, "known counts without report time")
    }

    func testOfflineDesktopAndUnknownQuotaKeepTheirExistingStates() {
        let app = open(["--companion-header-offline"])
        XCTAssertTrue(element(app, "companion-context-offline-note").exists)
        let unavailable = reveal("plan-limits-unavailable-preview-studio", in: app)
        XCTAssertEqual(unavailable.label, "Studio Mac is offline")
        XCTAssertFalse(element(app, "plan-limits-preview-studio-claude-code").exists)
        capture(app, "offline desktop")
        app.terminate()
        let unknown = open(["--companion-context-quota-unknown"])
        let plan = reveal("plan-limits-preview-studio-copilot-cli", in: unknown)
        XCTAssertTrue(plan.label.contains("Unknown"), plan.label)
        XCTAssertFalse(element(unknown, "plan-limits-preview-studio-claude-code").exists)
        capture(unknown, "own provider unknown quota")
    }

    func testContextSettingsRetainsTheExistingEditor() {
        let app = open()
        let settings = reveal("companion-context-settings-row", in: app)
        XCTAssertTrue(settings.isHittable)
        assertMinimumTarget(settings, "Context settings", width: 0)
        waitAndTap(settings, until: app.buttons["agent-settings-context-window"], attempts: 1)
        XCTAssertTrue(element(app, "companion-context-report").exists)
        XCTAssertTrue(app.buttons["agent-settings-context-window"].isHittable)
        XCTAssertTrue(app.buttons["companion-context-close"].isHittable)
    }
}
