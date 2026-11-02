import XCTest

/// Preview-only presentation and refused edits. No real Auto start or desktop provider reading is exercised.
@MainActor final class CompanionAutoQuotaUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openPresets(_ app: XCUIApplication) {
        let link = element(app, "helper-presets-preview-studio")
        waitAndTap(app.buttons["Settings"], until: link)
        waitAndTap(link, until: element(app, "helper-auto-effective"))
    }
    private func project(_ app: XCUIApplication, _ id: String) {
        let link = element(app, "helper-auto-project-\(id)")
        XCTAssertTrue(scrollUntilExists(link, in: app) && scrollTo(link, in: app))
        waitAndTap(link, until: element(app, "helper-auto-scope-project"))
    }
    private func agent(_ app: XCUIApplication, _ id: String) {
        let link = element(app, "helper-auto-agent-\(id)")
        XCTAssertTrue(scrollUntilExists(link, in: app) && scrollTo(link, in: app))
        waitAndTap(link, until: element(app, "helper-auto-scope-agent"))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAutoAppScopeAndQuotaKeepDesktopWordsAndRefusedEdit() {
        let app = launchApp(["--companion-preview", "--companion-preview-auto-quota"])
        openPresets(app)
        XCTAssertTrue(element(app, "helper-auto-effective").label.contains("On"))
        XCTAssertEqual(element(app, "helper-auto-source").label, "Set for the whole app")
        app.buttons["helper-auto-change-off"].tap()
        let error = element(app, "helper-presets-error")
        XCTAssertTrue(error.waitForExistence(timeout: 10) && error.label.contains("Preview only"))
        XCTAssertTrue(element(app, "helper-auto-effective").label.contains("On"))
        let claude = element(app, "helper-quota-claude-code")
        XCTAssertTrue(scrollTo(claude, in: app))
        claude.tap()
        let modelWindow = app.staticTexts["Fable: 99% used"]
        XCTAssertTrue(scrollUntilExists(modelWindow, in: app) && scrollTo(modelWindow, in: app))
        XCTAssertTrue(element(app, "helper-quota-state-known").exists)
        capture(app, "Auto and model-specific limits (preview)")
        let stale = app.staticTexts["Last checked too long ago"]
        XCTAssertTrue(scrollUntilExists(stale, in: app) && scrollTo(stale, in: app))
        XCTAssertTrue(element(app, "helper-quota-codex-cli").label.contains("Unknown"))
        XCTAssertFalse(app.staticTexts["Healthy"].exists)
        capture(app, "Unknown stale quota (preview)")
    }
    func testProjectOffAndPersonaOffPreserveSavedAgentOn() {
        let app = launchApp(["--companion-preview", "--companion-preview-auto-quota"])
        openPresets(app)
        project(app, "website")
        XCTAssertEqual(element(app, "helper-auto-reason").label, "This project turned it off")
        XCTAssertFalse(app.buttons["helper-auto-change-on"].exists)
        XCTAssertTrue(app.buttons["helper-auto-change-inherit"].isEnabled)
        capture(app, "Project override (preview)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        project(app, "clubhouse")
        agent(app, "juniper")
        XCTAssertTrue(element(app, "helper-auto-scope-agent").label.contains("On"))
        XCTAssertTrue(element(app, "helper-auto-effective").label.contains("Off"))
        XCTAssertEqual(element(app, "helper-auto-reason").label, "This agent’s persona turned it off")
        XCTAssertTrue(app.buttons["helper-auto-change-inherit"].isEnabled)
        capture(app, "Persona off with agent on (preview)")
    }
    func testMCPOffAllowsOffAndClearButDisablesOn() {
        let app = launchApp(["--companion-preview", "--companion-preview-auto-quota", "--companion-preview-mcp-off"])
        openPresets(app)
        project(app, "clubhouse")
        agent(app, "juniper")
        XCTAssertEqual(element(app, "helper-auto-reason").label, "Clubhouse MCP is off for this agent")
        XCTAssertFalse(app.buttons["helper-auto-change-on"].isEnabled)
        XCTAssertTrue(app.buttons["helper-auto-change-off"].isEnabled)
        XCTAssertTrue(app.buttons["helper-auto-change-inherit"].isEnabled)
        capture(app, "MCP off keeps clear and off editable (preview)")
    }
    func testHeldAndSavedWarningsAreHistoricalInformation() {
        let app = launchApp(["--companion-preview", "--companion-preview-auto-quota"])
        let row = element(app, "agent-preview-studio-juniper")
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settings)
        waitAndTap(settings, until: element(app, "agent-settings-summary"))
        let saved = element(app, "helper-routing-warning")
        XCTAssertTrue(scrollUntilExists(saved, in: app) && scrollTo(saved, in: app))
        XCTAssertTrue(saved.label.contains("Warning saved with this start") && saved.label.contains("Known at"))
        capture(app, "Saved start warning (preview)")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Needs you"].tap()
        let request = app.staticTexts.matching(identifier: "helper-request-routing").matching(NSPredicate(format: "label == %@", "auto · hard")).firstMatch
        XCTAssertTrue(scrollUntilExists(request, in: app) && scrollTo(request, in: app))
        XCTAssertEqual(request.label, "auto · hard")
        let warning = element(app, "helper-request-warning")
        XCTAssertTrue(scrollUntilExists(warning, in: app) && scrollTo(warning, in: app))
        XCTAssertTrue(warning.label.contains("Warning when requested") && warning.label.contains("started on it anyway"))
        XCTAssertTrue(app.buttons.matching(identifier: "helper-request-approve").firstMatch.isEnabled)
        capture(app, "Request-time warning (preview)")
    }
    func testDispatcherAutoScopesAreReadOnly() {
        let app = launchApp(["--companion-preview", "--companion-preview-auto-quota", "--companion-preview-dispatcher"])
        let row = element(app, "dispatcher-row-preview-studio")
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        waitAndTap(row, until: element(app, "companion-chat-header"))
        let settings = app.buttons["Agent settings"]
        waitAndTap(app.navigationBars.buttons["Conversation actions"], until: settings)
        waitAndTap(settings, until: element(app, "agent-settings-helper-auto"))
        waitAndTap(element(app, "agent-settings-helper-auto"), until: element(app, "helper-auto-effective"))
        XCTAssertEqual(element(app, "helper-auto-reason").label, "The Dispatcher doesn’t start helpers")
        XCTAssertFalse(app.buttons["helper-auto-change-on"].exists || app.buttons["helper-auto-change-off"].exists || app.buttons["helper-auto-change-inherit"].exists)
        capture(app, "Dispatcher Auto policy is read-only (preview)")
    }

}
