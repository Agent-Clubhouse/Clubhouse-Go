import XCTest

@MainActor final class CompanionAgentSettingsVisualUITests: ReliableUITestCase {
    private func capture(_ name: String, appearance: String, colors: [String: String] = [:], accessibility: Bool = false) throws {
        var arguments = ["--companion-preview", "--companion-preview-\(appearance)"]
        if accessibility { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let theme = String(decoding: try JSONEncoder().encode(colors), as: UTF8.self)
        let app = launchApp(arguments, environment: colors.isEmpty ? [:] : ["CLUBHOUSE_PREVIEW_THEME": theme], attempts: 1)
        let row = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollTo(row, in: app, maxSwipes: 6))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settings)
        let summary = app.descendants(matching: .any).matching(identifier: "agent-settings-summary").firstMatch
        waitAndTap(settings, until: summary, attempts: 1)
        XCTAssertTrue(summary.label.contains("Claude Code · Opus · Needs you"), summary.label)
        XCTAssertTrue(app.buttons["agent-settings-done"].exists)
        screenshot(app, "Settings identity — \(name)")
        let model = app.buttons["agent-settings-model"]
        XCTAssertTrue(scrollTo(model, in: app, maxSwipes: 16))
        XCTAssertFalse(model.isEnabled)
        screenshot(app, "Settings runtime — \(name)")
        let usage = app.descendants(matching: .any).matching(identifier: "agent-settings-context-usage").firstMatch
        XCTAssertTrue(scrollTo(usage, in: app, maxSwipes: 20))
        XCTAssertTrue(app.staticTexts["84k of 200k"].exists)
        screenshot(app, "Settings context — \(name)")
        let sleep = app.buttons["agent-sleep"]
        XCTAssertTrue(scrollTo(sleep, in: app, maxSwipes: 24))
        XCTAssertTrue(sleep.isEnabled)
        screenshot(app, "Settings sleep footer — \(name)")
        app.buttons["agent-settings-done"].tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5))
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
