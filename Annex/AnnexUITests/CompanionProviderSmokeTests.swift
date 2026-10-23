import XCTest

/// Opt-in real-provider test. An owned harness supplies an ephemeral verified invitation.
@MainActor
final class CompanionProviderSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_PROVIDER_SMOKE"] == "1",
                          "Requires an isolated ephemeral Codex provider runtime with existing login")
    }

    func testRealCodexResponseFollowUpAndForegroundReconnect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_provider")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60))
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let send = app.buttons["companion-send"]
        func message(_ text: String, response: String) {
            composer.tap()
            composer.typeText(text)
            let enabled = NSPredicate(format: "enabled == true")
            expectation(for: enabled, evaluatedWith: send)
            waitForExpectations(timeout: 20)
            send.tap()
            XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 120), "A real provider answer must arrive through the desktop and mobile transport")
        }
        message("No tools. Reply exactly: Mobile provider connection verified.", response: "Mobile provider connection verified.")
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "Real Codex response through pinned Annex"
        first.lifetime = .keepAlways
        add(first)
        message("No tools. As a follow-up, reply exactly: Mobile follow-up verified.", response: "Mobile follow-up verified.")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        message("No tools. After reconnect, reply exactly: Mobile reconnect verified.", response: "Mobile reconnect verified.")
        let final = XCTAttachment(screenshot: app.screenshot())
        final.name = "Real Codex follow-up and foreground reconnect"
        final.lifetime = .keepAlways
        add(final)
    }
}
