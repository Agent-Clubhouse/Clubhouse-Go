import XCTest

@MainActor final class CompanionToolbarUITests: ReliableUITestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func checkToolbars(_ appearance: String, flags: [String]) {
        let app = launchApp(["--companion-preview", "--companion-preview-start-home"] + flags, allowance: 360, attempts: 1)
        let settings = app.buttons["Settings"]
        let newAgent = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertTrue(newAgent.isHittable && newAgent.isEnabled)
        XCTAssertFalse(app.buttons["home-more-menu"].exists)
        capture(app, "Toolbar Home \(appearance)")

        newAgent.tap()
        XCTAssertTrue(app.buttons["new-agent-create"].waitForExistence(timeout: 10))
        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable, "The close glyph retains its Cancel accessibility label")
        capture(app, "Toolbar New agent \(appearance)")
        cancel.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let actions = app.buttons["Conversation actions"]
        waitAndTap(river, until: actions, timeout: 15, attempts: 1)
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(context.isHittable)
        capture(app, "Toolbar Chat \(appearance)")
        context.tap()
        let closeContext = app.navigationBars.buttons["Done"]
        XCTAssertTrue(closeContext.waitForExistence(timeout: 5))
        capture(app, "Toolbar Context sheet \(appearance)")
        closeContext.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        waitAndTap(actions, until: app.buttons["Agent settings"], timeout: 5, attempts: 1)
        app.buttons["Agent settings"].tap()
        let confirm = app.buttons["agent-settings-done"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        capture(app, "Toolbar Agent settings \(appearance)")
        confirm.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
    }

    func testLight() { checkToolbars("light", flags: ["--companion-preview-light"]) }
    func testDark() { checkToolbars("dark", flags: ["--companion-preview-dark"]) }
    func testLatte() { checkToolbars("Latte", flags: ["--companion-preview-light", "--companion-preview-theme-latte"]) }
    func testMocha() { checkToolbars("Mocha", flags: ["--companion-preview-dark", "--companion-preview-theme-mocha"]) }
}
