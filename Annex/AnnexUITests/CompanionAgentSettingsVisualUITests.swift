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
        XCTAssertTrue(usage.label.contains("84k of 200k"), usage.label)
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
    func testAccessibility() throws { try capture("accessibility XXXL", appearance: "light", accessibility: true) }
}
