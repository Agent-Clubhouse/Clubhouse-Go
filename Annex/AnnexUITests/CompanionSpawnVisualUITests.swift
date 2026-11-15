import XCTest

/// Synthetic old-host creation flow across appearance, transported desktop themes and Dynamic Type.
@MainActor final class CompanionSpawnVisualUITests: ReliableUITestCase {
    private func capture(_ name: String, appearance: String, colors: [String: String] = [:], accessibility: Bool = false) throws {
        var arguments = ["--companion-preview", "--companion-preview-\(appearance)"]
        if accessibility { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let theme = String(decoding: try JSONEncoder().encode(colors), as: UTF8.self)
        let app = launchApp(arguments, environment: colors.isEmpty ? [:] : ["CLUBHOUSE_PREVIEW_THEME": theme], attempts: 1)
        let newAgent = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(newAgent.waitForExistence(timeout: 15))
        newAgent.tap()
        let nameField = app.textFields["new-agent-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["new-agent-managed"].exists, "Old hosts hide every managed row")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "New agent — \(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["new-agent-create"].isEnabled)
        let workspace = app.buttons["new-agent-workspace-tools"]
        XCTAssertTrue(scrollTo(workspace, in: app, maxSwipes: 5))
        workspace.tap()
        XCTAssertTrue(app.navigationBars["Workspace and tools"].waitForExistence(timeout: 5))
        let workspaceScreenshot = XCTAttachment(screenshot: app.screenshot())
        workspaceScreenshot.name = "Workspace and tools — \(name)"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)
    }

    func testLight() throws { try capture("light", appearance: "light") }
    func testDark() throws { try capture("dark", appearance: "dark") }
    func testAccessibility() throws { try capture("accessibility XXXL", appearance: "light", accessibility: true) }
    func testSolarizedDark() throws {
        try capture("Solarized Dark", appearance: "dark", colors: [
            "base": "#002b36", "mantle": "#00212b", "crust": "#001b24", "text": "#839496", "subtext0": "#657b83",
            "surface0": "#073642", "surface1": "#0a4050", "accent": "#268bd2", "accent2": "#2aa198",
            "warning": "#b58900", "error": "#ec6b63", "success": "#859900", "info": "#4ea0db"
        ])
    }
    func testCatppuccinLatte() throws {
        try capture("Catppuccin Latte", appearance: "light", colors: [
            "base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85",
            "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "accent2": "#209fb5",
            "warning": "#7e5700", "error": "#c4122f", "success": "#347d22", "info": "#1659d1"
        ])
    }
}
