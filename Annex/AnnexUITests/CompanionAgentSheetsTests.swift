import XCTest

/// The New agent sheet (#131) and the agent settings sheet (#132) against the preview desktop, which offers
/// durable create and settings. Preview commands never reach a desktop, so Create and every edit must fail visibly.
@MainActor
final class CompanionAgentSheetsTests: ReliableUITestCase {
    private func launch() -> XCUIApplication { launchApp(["--companion-preview"]) }

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
        let kind = element(app, "new-agent-kind")
        waitAndTap(newAgent, until: kind, timeout: 10)

        XCTAssertTrue(app.navigationBars["New agent"].waitForExistence(timeout: 10), "A desktop that creates durable agents gets the full sheet")
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
        scrollUntilExists(worktree, in: app, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(worktree.exists, "A git project offers its own worktree")
        XCTAssertEqual(worktree.value as? String, "1", "On by default")
        let freeAgent = app.switches["new-agent-free-agent-mode"]
        scrollTo(freeAgent, in: app, maxSwipes: 4)
        XCTAssertTrue(freeAgent.isEnabled, "A desktop that takes Free Agent Mode offers it for a CLI with permission support")
        XCTAssertEqual(freeAgent.value as? String, "0", "Off by default")
        XCTAssertTrue(app.staticTexts["Skips every permission prompt. Off unless you trust this agent with the project."].exists, "The desktop's help text")

        // Preview never pretends the desktop created anything. The refusal shows at the top of the form.
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let error = element(app, "new-agent-error")
        scrollUntilExists(error, in: app, up: false, maxSwipes: 5, wait: 0.5)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].exists)

        // Quick keeps the mission-first flow.
        scrollTo(kind, in: app, up: false, maxSwipes: 4)
        kind.buttons["Quick"].tap()
        XCTAssertTrue(app.textFields["Agent task"].waitForExistence(timeout: 5) || app.textViews["Agent task"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Runs one mission, reports back, and finishes."].exists)
    }

    func testAwakeAgentSettingsAreLockedExceptAutoSleep() {
        let app = launch()
        let river = element(app, "agent-preview-studio-river")
        scrollUntilExists(river, in: app)
        XCTAssertTrue(river.waitForExistence(timeout: 15))
        let actions = app.buttons["Conversation actions"]
        waitAndTap(river, until: actions, timeout: 10)
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings, timeout: 5, "The chat header offers the agent's settings")

        let hint = element(app, "agent-settings-locked-hint")
        waitAndTap(settings, until: hint, timeout: 10, "An awake agent says why its settings are locked")
        XCTAssertTrue(app.staticTexts["Sleep the agent to change these"].exists)
        XCTAssertTrue(app.staticTexts["Chat · Claude Code · Opus · Sleeps after 30 min"].exists, "The summary uses the desktop's words")
        XCTAssertFalse(app.buttons["agent-settings-model"].isEnabled, "Model waits for the agent to sleep")
        XCTAssertFalse(app.textFields["agent-settings-name"].isEnabled, "Name waits for the agent to sleep")
        let autoSleep = app.buttons["agent-settings-auto-sleep"]
        scrollTo(autoSleep, in: app, maxSwipes: 4)
        XCTAssertTrue(autoSleep.isEnabled, "Auto-sleep can change at any time")
        let freeAgent = element(app, "agent-settings-free-agent-mode")
        scrollTo(freeAgent, in: app, maxSwipes: 4)
        XCTAssertTrue(freeAgent.exists, "Free Agent Mode is a toggle on a desktop that takes it")
        XCTAssertFalse(freeAgent.isEnabled, "It's a spawn setting, so it waits for the agent to sleep")
        XCTAssertTrue(app.staticTexts["Sleep the agent to change these. Skips every permission prompt. Off unless you trust this agent with the project."].exists)
        screenshot(app, "Awake agent settings")

        // Preview edits fail visibly and put the control back.
        let never = app.buttons["Never"]
        waitAndTap(autoSleep, until: never, timeout: 5)
        never.tap()
        scrollUntilExists(element(app, "agent-settings-error"), in: app, up: false, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(element(app, "agent-settings-error").waitForExistence(timeout: 5))
    }

    func testSleepingAgentSettingsOpenFromLongPressAndAreEditable() {
        let app = launch()
        // Juniper sleeps, so it's in its project's "1 sleeping" fold, as on the desktop.
        let fold = element(app, "fold-sleeping-preview-studio-clubhouse")
        let juniper = element(app, "agent-preview-studio-juniper")
        scrollUntilExists(fold, in: app)
        expandFold(fold, revealing: juniper, in: app)
        XCTAssertTrue(juniper.waitForExistence(timeout: 15))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(juniper, shows: settings, "The agent row's long-press menu offers its settings")

        let name = app.textFields["agent-settings-name"]
        waitAndTap(settings, until: name, timeout: 10)
        XCTAssertEqual(name.value as? String, "Juniper")
        XCTAssertTrue(name.isEnabled, "A sleeping agent's settings can change")
        XCTAssertTrue(app.buttons["agent-settings-model"].isEnabled)
        XCTAssertFalse(element(app, "agent-settings-locked-hint").exists, "Nothing is locked while it sleeps")
        screenshot(app, "Sleeping agent settings")

        // Turning Free Agent Mode on is confirmed first; preview then refuses it visibly.
        let freeAgent = element(app, "agent-settings-free-agent-mode")
        scrollTo(freeAgent, in: app, maxSwipes: 4)
        XCTAssertTrue(freeAgent.isEnabled, "A sleeping agent's Free Agent Mode can change")
        XCTAssertTrue(app.staticTexts["Skips every permission prompt. Off unless you trust this agent with the project."].exists)
        freeAgent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let confirm = app.buttons["Turn on Free Agent Mode"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Turning it on asks first")
        screenshot(app, "Free Agent Mode confirmation")
        confirm.tap()
        scrollUntilExists(element(app, "agent-settings-error"), in: app, up: false, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(element(app, "agent-settings-error").waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }
}
