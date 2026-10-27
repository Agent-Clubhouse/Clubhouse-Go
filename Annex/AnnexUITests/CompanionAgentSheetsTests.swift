import XCTest

/// The New agent sheet (#131) and the agent settings sheet (#132) against the preview desktop, which offers
/// durable create and settings. Preview commands never reach a desktop, so Create and every edit must fail visibly.
@MainActor
final class CompanionAgentSheetsTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNewAgentDefaultsToDurableAndChecksTheName() {
        let app = launch()
        let newAgent = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(newAgent.waitForExistence(timeout: 15))
        newAgent.tap()

        XCTAssertTrue(app.navigationBars["New agent"].waitForExistence(timeout: 10), "A desktop that creates durable agents gets the full sheet")
        let kind = element(app, "new-agent-kind")
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        XCTAssertTrue(kind.buttons["Durable"].isSelected, "Durable is the default, as on the desktop")
        XCTAssertTrue(app.staticTexts["Keeps its name, settings and history. You start it and talk to it whenever you like."].exists)

        let name = element(app, "new-agent-name")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "The form loads from the desktop's create options")
        XCTAssertEqual(name.value as? String, "brave-otter", "The name starts as the desktop's suggestion")
        XCTAssertTrue(element(app, "agent-color-indigo").isSelected, "Indigo is the default colour")
        screenshot(app, "New durable agent")

        // A space can't be in a folder or branch name.
        name.tap()
        name.typeText(" two")
        let problem = element(app, "new-agent-name-error")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "Use only letters, digits, - and _ in the agent name.")
        let create = app.buttons["new-agent-create"]
        XCTAssertFalse(create.isEnabled, "An invalid name can't be created")

        app.buttons["new-agent-randomize"].tap()
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5), "Randomize gives a valid name")
        XCTAssertNotEqual(name.value as? String, "brave-otter two")

        element(app, "agent-color-teal").tap()
        XCTAssertTrue(element(app, "agent-color-teal").isSelected)

        // Form rows load as they scroll into view.
        let worktree = app.switches["new-agent-worktree"]
        for _ in 0..<4 where !worktree.exists { app.swipeUp() }
        XCTAssertTrue(worktree.exists, "A git project offers its own worktree")
        XCTAssertEqual(worktree.value as? String, "1", "On by default")

        // Preview never pretends the desktop created anything. The refusal shows at the top of the form.
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let error = element(app, "new-agent-error")
        for _ in 0..<5 where !error.exists { app.swipeDown() }
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].exists)

        // Quick keeps the mission-first flow.
        for _ in 0..<4 where !kind.isHittable { app.swipeDown() }
        kind.buttons["Quick"].tap()
        XCTAssertTrue(app.textFields["Agent task"].waitForExistence(timeout: 5) || app.textViews["Agent task"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Runs one mission, reports back, and finishes."].exists)
    }

    func testAwakeAgentSettingsAreLockedExceptAutoSleep() {
        let app = launch()
        let river = element(app, "agent-preview-studio-river")
        for _ in 0..<4 where !river.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(river.waitForExistence(timeout: 15))
        river.tap()
        let actions = app.buttons["Conversation actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        let settings = app.buttons["Agent settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "The chat header offers the agent's settings")
        settings.tap()

        let hint = element(app, "agent-settings-locked-hint")
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "An awake agent says why its settings are locked")
        XCTAssertTrue(app.staticTexts["Sleep the agent to change these"].exists)
        XCTAssertTrue(app.staticTexts["Chat · Claude Code · Opus · Sleeps after 30 min"].exists, "The summary uses the desktop's words")
        XCTAssertFalse(app.buttons["agent-settings-model"].isEnabled, "Model waits for the agent to sleep")
        XCTAssertFalse(app.textFields["agent-settings-name"].isEnabled, "Name waits for the agent to sleep")
        let autoSleep = app.buttons["agent-settings-auto-sleep"]
        for _ in 0..<4 where !autoSleep.isHittable { app.swipeUp() }
        XCTAssertTrue(autoSleep.isEnabled, "Auto-sleep can change at any time")
        let freeAgent = element(app, "agent-settings-free-agent-mode")
        for _ in 0..<4 where !freeAgent.isHittable { app.swipeUp() }
        XCTAssertTrue(freeAgent.exists, "Free Agent Mode is shown, read-only")
        XCTAssertTrue(app.staticTexts["Free Agent Mode can only be changed on the desktop."].exists)
        screenshot(app, "Awake agent settings")

        // Preview edits fail visibly and put the control back.
        autoSleep.tap()
        let never = app.buttons["Never"]
        XCTAssertTrue(never.waitForExistence(timeout: 5))
        never.tap()
        for _ in 0..<4 where !element(app, "agent-settings-error").exists { app.swipeDown() }
        XCTAssertTrue(element(app, "agent-settings-error").waitForExistence(timeout: 5))
    }

    func testSleepingAgentSettingsOpenFromLongPressAndAreEditable() {
        let app = launch()
        let juniper = element(app, "agent-preview-studio-juniper")
        for _ in 0..<4 where !juniper.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(juniper.waitForExistence(timeout: 15))
        juniper.press(forDuration: 1.2)
        let settings = app.buttons["Agent settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "The agent row's long-press menu offers its settings")
        settings.tap()

        let name = app.textFields["agent-settings-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Juniper")
        XCTAssertTrue(name.isEnabled, "A sleeping agent's settings can change")
        XCTAssertTrue(app.buttons["agent-settings-model"].isEnabled)
        XCTAssertFalse(element(app, "agent-settings-locked-hint").exists, "Nothing is locked while it sleeps")
        screenshot(app, "Sleeping agent settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }
}
