import XCTest

@MainActor final class CompanionManagedSpawnUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func open(_ flags: [String] = [], colors: [String: String] = [:], managed: Bool = true) throws -> XCUIApplication {
        let theme = String(decoding: try JSONEncoder().encode(colors), as: UTF8.self)
        let arguments = ["--companion-preview", managed ? "--companion-preview-managed-create" : "--companion-preview-managed-options-only"] + flags
        let app = launchApp(arguments, environment: colors.isEmpty ? [:] : ["CLUBHOUSE_PREVIEW_THEME": theme], attempts: 1)
        XCTAssertTrue(app.navigationBars.buttons["New agent"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["New agent"].tap()
        XCTAssertTrue(app.textFields["new-agent-name"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Managed new agent — \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testManagedCreationRequiresAnExplicitChoiceAndBlankIsLocal() throws {
        let app = try open(["--companion-preview-light"])
        XCTAssertEqual(app.switches["new-agent-managed"].value as? String, "1")
        XCTAssertFalse(app.buttons["new-agent-create"].isEnabled)
        let instruction = app.staticTexts["Choose Blank or a template to continue."]
        XCTAssertTrue(scrollTo(instruction, in: app, maxSwipes: 4), "An accessible instruction explains the disabled Create action")
        capture(app, "no selection")
        let blank = app.buttons["new-agent-template-blank"]
        XCTAssertTrue(scrollTo(blank, in: app, maxSwipes: 4))
        XCTAssertFalse(blank.isSelected)
        XCTAssertTrue(blank.label.contains("Identity and Clubhouse tools only"))
        blank.tap()
        XCTAssertTrue(blank.isSelected)
        XCTAssertTrue(app.buttons["new-agent-create"].isEnabled)
        XCTAssertFalse(element(app, "new-agent-access").exists)
        XCTAssertFalse(element(app, "new-agent-workspace-tools").exists)
        XCTAssertFalse(app.buttons["Customize"].exists)
        capture(app, "Blank selected")
    }

    func testTemplateOrderingFillsRuntimeAndPlainFieldsStayAvailableWhenManagedIsOff() throws {
        let app = try open()
        let lead = app.buttons["new-agent-template-user-lead"]
        XCTAssertTrue(scrollTo(lead, in: app, maxSwipes: 5))
        let blank = app.buttons["new-agent-template-blank"]
        let helper = app.buttons["new-agent-template-builtin-template-helper"]
        XCTAssertTrue(blank.exists)
        XCTAssertTrue(helper.exists)
        XCTAssertLessThan(blank.frame.minY, helper.frame.minY)
        XCTAssertLessThan(helper.frame.minY, lead.frame.minY)
        lead.tap()
        XCTAssertTrue(lead.isSelected)
        let cli = app.buttons["new-agent-orchestrator"]
        XCTAssertTrue(scrollTo(cli, in: app, up: false, maxSwipes: 5))
        XCTAssertTrue(cli.label.contains("Claude Code"))
        let model = app.buttons["new-agent-model"]
        XCTAssertTrue(model.label.contains("Opus"))
        model.tap()
        XCTAssertTrue(app.buttons["Default"].waitForExistence(timeout: 5))
        app.buttons["Default"].tap()
        XCTAssertTrue(model.label.contains("Default"))
        let managed = app.switches["new-agent-managed"]
        XCTAssertTrue(scrollTo(managed, in: app, up: false, maxSwipes: 4))
        managed.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(managed.value as? String, "0")
        let workspace = app.buttons["new-agent-workspace-tools"]
        XCTAssertTrue(scrollTo(workspace, in: app, maxSwipes: 4))
        XCTAssertTrue(element(app, "new-agent-access").exists)
        XCTAssertTrue(workspace.exists)
        XCTAssertTrue(app.buttons["new-agent-create"].isEnabled)
    }

    func testAbsentCapabilityHidesManagedRowsEvenWhenOptionsContainTemplates() throws {
        let app = try open(managed: false)
        XCTAssertFalse(element(app, "new-agent-managed-unavailable").exists)
        XCTAssertFalse(app.switches["new-agent-managed"].exists)
        let workspace = app.buttons["new-agent-workspace-tools"]
        XCTAssertTrue(scrollTo(workspace, in: app, maxSwipes: 5))
        XCTAssertTrue(element(app, "new-agent-access").exists)
        XCTAssertTrue(app.buttons["new-agent-create"].isEnabled)
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.buttons["new-agent-template-blank"].exists)
        XCTAssertFalse(app.buttons["new-agent-template-user-lead"].exists)
        XCTAssertFalse(app.staticTexts["Your templates"].exists)
    }

    private func appearance(_ name: String, flags: [String], colors: [String: String] = [:]) throws {
        let app = try open(flags, colors: colors)
        let lead = app.buttons["new-agent-template-user-lead"]
        XCTAssertTrue(scrollTo(lead, in: app, maxSwipes: 6))
        // At XXXL, hittable can mean only a sliver is visible above the home indicator.
        // Put the complete row in the content viewport before tapping its checked center.
        for _ in 0..<6 {
            let frame = lead.frame
            if frame.minY >= app.navigationBars.firstMatch.frame.maxY + 12,
               frame.maxY <= app.frame.maxY - 40 { break }
            app.swipeUp(velocity: .slow)
        }
        let frame = lead.frame
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, app.frame.maxY - 40)
        lead.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(lead.isSelected)
        XCTAssertTrue(app.buttons["new-agent-create"].isEnabled)
        capture(app, "\(name) templates")
        XCTAssertTrue(scrollTo(element(app, "new-agent-kind"), in: app, up: false, maxSwipes: 6))
        capture(app, "\(name) form")
        if name == "accessibility XXXL" {
            XCTAssertTrue(scrollTo(app.buttons["new-agent-model"], in: app, maxSwipes: 6))
            capture(app, "\(name) runtime")
            app.swipeUp()
            XCTAssertTrue(app.buttons["new-agent-model"].isHittable)
            capture(app, "\(name) model")
        }
    }

    func testLightAppearance() throws { try appearance("light", flags: ["--companion-preview-light"]) }
    func testDarkAppearance() throws { try appearance("dark", flags: ["--companion-preview-dark"]) }
    func testAccessibilityAppearance() throws {
        try appearance("accessibility XXXL", flags: ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
    func testSolarizedDarkAppearance() throws {
        try appearance("Solarized Dark", flags: ["--companion-preview-dark"], colors: [
            "base": "#002b36", "mantle": "#00212b", "crust": "#001b24", "text": "#839496", "subtext0": "#657b83",
            "surface0": "#073642", "surface1": "#0a4050", "accent": "#268bd2", "accent2": "#2aa198",
            "warning": "#b58900", "error": "#ec6b63", "success": "#859900", "info": "#4ea0db"
        ])
    }
    func testCatppuccinLatteAppearance() throws {
        try appearance("Catppuccin Latte", flags: ["--companion-preview-light"], colors: [
            "base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85",
            "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "accent2": "#209fb5",
            "warning": "#7e5700", "error": "#c4122f", "success": "#347d22", "info": "#1659d1"
        ])
    }
}
