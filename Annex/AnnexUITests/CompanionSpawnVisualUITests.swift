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
        if accessibility {
            XCTAssertTrue(scrollTo(app.buttons["new-agent-model"], in: app, maxSwipes: 8))
            let pickers = XCTAttachment(screenshot: app.screenshot())
            pickers.name = "New agent pickers — \(name)"
            pickers.lifetime = .keepAlways
            add(pickers)
        }
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
    func testAccessibility() throws { try capture("accessibility XXXL", appearance: "light", accessibility: true) }
}
