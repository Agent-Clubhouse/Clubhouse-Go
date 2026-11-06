import XCTest

/// #246: opening Wake must permit typing without a field tap. Keep presentation animations enabled:
/// `launchApp` adds --ui-testing-fast, which would remove the lifecycle boundary under investigation.
@MainActor
final class CompanionWakeSheetUITests: ReliableUITestCase {
    private var app: XCUIApplication?
    private var measuresFocus: Bool { ProcessInfo.processInfo.environment["CLUBHOUSE_WAKE_FOCUS_MEASUREMENTS"] == "1" }

    override func tearDown() {
        if let app, app.state == .runningForeground {
            record(app, "Wake final state")
        }
        app = nil
        super.tearDown()
    }

    func testDirectTypeWithoutTap() {
        let app = launchProject()
        let message = openWake(in: app)
        record(app, "Wake before direct typing")

        // No keyboard wait, field tap, or rescue refocus before this input.
        message.typeText("Draft the release notes")
        assertValue("Draft the release notes", of: message)
        XCTAssertTrue(app.buttons["wake-send"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        record(app, "Wake after direct typing")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
    }

    func testDirectTypeWithoutTapAfterCancel() {
        let app = launchProject()
        let first = openWake(in: app)
        // Whitespace can be entered, but cannot wake an agent.
        first.typeText(" \n")
        assertValue(" \n", of: first)
        XCTAssertFalse(app.buttons["wake-send"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))

        let message = openWake(in: app)
        record(app, "Wake reopened before direct typing")
        let draft = " Keep the first line\nAnd the second line "
        message.typeText(draft)
        assertValue(draft, of: message)
        let send = app.buttons["wake-send"]
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        // Return remains a newline; only this explicit action sends, to the preview service.
        XCTAssertTrue(app.navigationBars["Wake with a message"].exists)
        record(app, "Wake reopened with exact multiline draft")
        send.tap()
        XCTAssertTrue(app.navigationBars["Juniper"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 10))
    }

    /// A separate, explicitly selected control. Failed direct-entry tests never call this as a rescue.
    func testMeasuredTappedEntryControl() throws {
        guard measuresFocus else { throw XCTSkip("Opt-in synthetic Wake lifecycle measurements only") }
        let app = launchProject()
        let message = openWake(in: app)
        record(app, "Measured tap control before tap")
        message.tap()
        message.typeText("Measured tap control")
        assertValue("Measured tap control", of: message)
        record(app, "Measured tap control after entry")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
    }

    private func launchProject() -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = 240
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["--companion-preview"]
        if measuresFocus { app.launchArguments.append("--wake-focus-measurements") }
        app.launch()
        let header = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(header, in: app))
        XCTAssertTrue(scrollTo(header, in: app))
        waitAndTap(header, until: app.buttons["project-wake"], "The fixture project must open")
        return app
    }

    private func openWake(in app: XCUIApplication) -> XCUIElement {
        let wake = app.buttons["project-wake"]
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        XCTAssertTrue(wake.isEnabled)
        let message = app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch
        waitAndTap(wake, until: message, "Wake must present its message field")
        XCTAssertFalse(app.buttons["wake-send"].isEnabled, "A new sheet has an empty draft")
        XCTAssertTrue(app.buttons["wake-agent-picker"].label.contains("Juniper"))
        return message
    }

    private func assertValue(_ value: String, of message: XCUIElement) {
        XCTAssertTrue(waitFor(message, NSPredicate(format: "value == %@", value), timeout: 5),
                      "The entire direct-typed draft must remain in the field")
        XCTAssertEqual(message.value as? String, value)
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
