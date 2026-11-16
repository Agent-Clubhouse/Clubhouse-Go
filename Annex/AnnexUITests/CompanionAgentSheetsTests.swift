import XCTest

/// The New agent sheet (#131) and the agent settings sheet (#132) against the preview desktop, which offers
/// durable create and settings. Preview commands never reach a desktop, so Create and every edit must fail visibly.
@MainActor
final class CompanionAgentSheetsTests: ReliableUITestCase {
    private func launch() -> XCUIApplication { launchApp(["--companion-preview"], attempts: 1) }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Finish the name edit before navigating. The old inline form scrolled past the name;
    /// the workspace page returns to it, and XCTest can hit a picker through the keyboard.
    private func finishNameEditing(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let submit = keyboard.buttons["Return"]
        XCTAssertTrue(submit.exists, "The name field offers the keyboard's Return key")
        submit.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Finish editing the name before opening form options")
        XCTAssertTrue(app.navigationBars["New agent"].exists, "Submitting the name keeps the new-agent sheet open")
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
        // The value is right aligned; target its trailing text so the space is internal.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        name.typeText(" two")
        XCTAssertEqual(name.value as? String, "brave-otter two")
        let problem = element(app, "new-agent-name-error")
        scrollTo(problem, in: app, maxSwipes: 3)
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "Use only letters, digits, - and _ in the agent name.")
        let create = app.buttons["new-agent-create"]
        XCTAssertFalse(create.isEnabled, "An invalid name can't be created")

        app.buttons["new-agent-randomize"].tap()
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5), "Randomize gives a valid name")
        XCTAssertNotEqual(name.value as? String, "brave-otter two")
        let randomizedName = name.value as? String

        element(app, "agent-color-teal").tap()
        XCTAssertTrue(element(app, "agent-color-teal").isSelected)
        finishNameEditing(app)

        let workspace = app.buttons["new-agent-workspace-tools"]
        scrollTo(workspace, in: app, maxSwipes: 4)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        XCTAssertTrue(app.navigationBars["Workspace and tools"].waitForExistence(timeout: 5))
        // Workspace and tool options keep their defaults on their own page.
        let orchestrate = app.switches["new-agent-orchestrate"]
        scrollUntilExists(orchestrate, in: app, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(orchestrate.exists, "A desktop with orchestration offers it on create")
        XCTAssertEqual(orchestrate.value as? String, "0", "Off by default")
        XCTAssertFalse(element(app, "new-agent-persona").exists, "Personas were retired on the desktop")
        let worktree = app.switches["new-agent-worktree"]
        scrollUntilExists(worktree, in: app, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(worktree.exists, "A git project offers its own worktree")
        XCTAssertEqual(worktree.value as? String, "1", "On by default")
        XCTAssertTrue(app.switches["new-agent-orchestrate"].label.contains("Can start helpers"))
        screenshot(app, "Workspace and tools")
        app.navigationBars["Workspace and tools"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New agent"].waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, randomizedName, "Returning keeps the chosen identity")
        XCTAssertTrue(element(app, "agent-color-teal").isSelected)
        let access = app.buttons["new-agent-access"]
        scrollTo(access, in: app, maxSwipes: 4)
        XCTAssertTrue(access.isEnabled)
        XCTAssertTrue(access.label.contains("Ask first") || (access.value as? String) == "Ask first", "Starts at the desktop's default level")
        access.tap()
        for label in ["Plan", "Ask first", "Auto-accept edits", "Auto", "Full access"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Offers \(label)")
        }
        app.buttons["Auto"].tap()
        let confirmAuto = app.buttons["Use Auto"]
        XCTAssertTrue(confirmAuto.waitForExistence(timeout: 5), "Raising to Auto asks first")
        let popover = app.popovers.containing(.button, identifier: "Use Auto").firstMatch
        let confirmation = popover.exists ? popover : app.sheets.containing(.button, identifier: "Use Auto").firstMatch
        XCTAssertTrue(confirmation.exists)
        // Compact iOS 26 popovers omit Cancel; the sheet's toolbar Cancel closes the entire form.
        if confirmation.buttons["Cancel"].exists { confirmation.buttons["Cancel"].tap() }
        else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            let navigation = app.navigationBars["New agent"].frame
            // The region's center can also activate a form picker behind the dismissed popover.
            let point = CGPoint(x: navigation.minX + 8, y: navigation.maxY + 12)
            XCTAssertTrue(dismissRegion.frame.contains(point), "Dismiss inside the native background")
            XCTAssertFalse(confirmation.frame.contains(point), "Dismiss outside the Access confirmation")
            XCTContext.runActivity(named: "Dismiss Access in the form margin at \(point)") { _ in
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            }
        }
        XCTAssertTrue(confirmAuto.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New agent"].exists, "Cancelling Access keeps the new-agent sheet open")
        XCTAssertTrue(access.exists, "Cancelling Access keeps its picker")
        XCTAssertTrue(access.label.contains("Ask first") || (access.value as? String) == "Ask first", "Cancel keeps the desktop default")
        screenshot(app, "Access after cancelling Auto")
        access.tap()
        let fullAccess = app.buttons["Full access"]
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5), "The Access menu reopens after cancellation")
        fullAccess.tap()
        let confirmFull = app.buttons["Use Full access"]
        XCTAssertTrue(confirmFull.waitForExistence(timeout: 5))
        confirmFull.tap()
        XCTAssertTrue(access.label.contains("Full access") || (access.value as? String) == "Full access")

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
        screenshot(app, "Quick agent shared row style")
    }

    func testWorkspaceAndToolsPreservesChangesWhenReturningToTheForm() {
        let app = launch()
        waitAndTap(app.navigationBars.buttons["New agent"], until: element(app, "new-agent-name"), attempts: 1)
        let name = element(app, "new-agent-name")
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        name.typeText("-kept")
        XCTAssertEqual(name.value as? String, "brave-otter-kept")
        finishNameEditing(app)
        let workspace = app.buttons["new-agent-workspace-tools"]
        scrollTo(workspace, in: app, maxSwipes: 4)
        workspace.tap()
        let worktree = app.switches["new-agent-worktree"]
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        // Native Form switches expose the whole row; tap the control at its trailing edge.
        worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(worktree.value as? String, "0", "Worktree changed before leaving the page")
        let helpers = app.switches["new-agent-orchestrate"]
        helpers.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(helpers.value as? String, "1", "Helpers changed before leaving the page")
        let ado = app.switches["new-agent-mcp-ado"]
        scrollTo(ado, in: app, maxSwipes: 3)
        ado.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(ado.value as? String, "1", "MCP changed before leaving the page")
        app.navigationBars["Workspace and tools"].buttons.firstMatch.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.label.contains("Project folder"), workspace.label)
        XCTAssertTrue(workspace.label.contains("2 MCPs"), workspace.label)
        XCTAssertEqual(name.value as? String, "brave-otter-kept")

        let model = app.buttons["new-agent-model"]
        XCTAssertTrue(scrollTo(model, in: app, maxSwipes: 4))
        model.tap()
        XCTAssertTrue(app.buttons["Sonnet"].waitForExistence(timeout: 5))
        app.buttons["Sonnet"].tap()
        XCTAssertTrue(model.label.contains("Sonnet"))
        let access = app.buttons["new-agent-access"]
        XCTAssertTrue(scrollTo(access, in: app, maxSwipes: 4))
        access.tap()
        XCTAssertTrue(app.buttons["Plan"].waitForExistence(timeout: 5))
        app.buttons["Plan"].tap()
        XCTAssertTrue(access.label.contains("Plan"))
        XCTAssertEqual(name.value as? String, "brave-otter-kept")
        XCTAssertTrue(scrollTo(workspace, in: app, maxSwipes: 4))
        XCTAssertTrue(workspace.label.contains("Project folder"))
        XCTAssertTrue(workspace.label.contains("2 MCPs"))
        workspace.tap()
        XCTAssertEqual(worktree.value as? String, "0")
        XCTAssertEqual(helpers.value as? String, "1")
        XCTAssertEqual(ado.value as? String, "1")
        app.navigationBars["Workspace and tools"].buttons.firstMatch.tap()
        app.navigationBars["New agent"].buttons["Cancel"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        waitAndTap(app.navigationBars.buttons["New agent"], until: name, attempts: 1)
        XCTAssertEqual(name.value as? String, "brave-otter")
        XCTAssertTrue(scrollTo(workspace, in: app, maxSwipes: 4))
        XCTAssertTrue(workspace.label.contains("Worktree"))
        XCTAssertTrue(workspace.label.contains("1 MCP"))
        XCTAssertTrue(model.label.contains("Default"))
        XCTAssertTrue(access.label.contains("Ask first"))
        workspace.tap()
        XCTAssertEqual(worktree.value as? String, "1")
        XCTAssertEqual(helpers.value as? String, "0")
        XCTAssertEqual(ado.value as? String, "0")
    }

    func testAwakeAgentSettingsAreLockedExceptAutoSleep() {
        let app = launch()
        let river = element(app, "agent-preview-studio-river")
        scrollUntilExists(river, in: app)
        XCTAssertTrue(river.waitForExistence(timeout: 15))
        let actions = app.buttons["Conversation actions"]
        tapVisibleRow(river, in: app, until: actions)
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings, timeout: 5, "The chat header offers the agent's settings")

        let summary = element(app, "agent-settings-summary")
        waitAndTap(settings, until: summary, timeout: 10, "An awake agent shows its identity")
        XCTAssertTrue(summary.label.contains("Claude Code · Opus · Needs you"), "The identity uses the desktop's provider, model and status words")
        let name = app.textFields["agent-settings-name"]
        XCTAssertTrue(scrollTo(name, in: app, maxSwipes: 4))
        XCTAssertFalse(name.isEnabled, "Name waits for the agent to sleep")
        let model = app.buttons["agent-settings-model"]
        XCTAssertTrue(scrollTo(model, in: app, maxSwipes: 6))
        XCTAssertFalse(model.isEnabled, "Model waits for the agent to sleep")
        let access = app.buttons["agent-settings-access"]
        XCTAssertTrue(scrollTo(access, in: app, maxSwipes: 4))
        XCTAssertTrue(access.exists)
        XCTAssertFalse(access.isEnabled, "Saved Access is a spawn setting, so it waits for the agent to sleep")
        let applicationNote = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Applies at next start. Saving does not change the running session.")).firstMatch
        XCTAssertTrue(scrollTo(applicationNote, in: app, maxSwipes: 3), "The footer explains that saved Access waits for the next start")
        let hint = element(app, "agent-settings-locked-hint")
        XCTAssertTrue(scrollTo(hint, in: app, maxSwipes: 3), "One footer explains the sleeping-only lock")
        XCTAssertTrue(app.staticTexts["Sleep the agent to change these"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "agent-settings-locked-hint").count, 1)
        let autoSleep = app.buttons["agent-settings-auto-sleep"]
        XCTAssertTrue(scrollTo(autoSleep, in: app, maxSwipes: 4))
        XCTAssertTrue(autoSleep.isEnabled, "Auto-sleep can change at any time")
        screenshot(app, "Awake agent settings")

        // Preview edits fail visibly and put the control back.
        let never = app.buttons["Never"]
        waitAndTap(autoSleep, until: never, timeout: 5)
        never.tap()
        scrollUntilExists(element(app, "agent-settings-error"), in: app, up: false, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(element(app, "agent-settings-error").waitForExistence(timeout: 5))
    }

    func testCreateAccessIsSetByTheCLIWithoutPermissionSupport() {
        let app = launch()
        let newAgent = app.navigationBars.buttons["New agent"]
        waitAndTap(newAgent, until: element(app, "new-agent-name"), timeout: 15)
        let cli = app.buttons["new-agent-orchestrator"]
        scrollTo(cli, in: app)
        waitAndTap(cli, until: app.buttons["Codex"])
        app.buttons["Codex"].tap()
        let access = element(app, "new-agent-access")
        scrollTo(access, in: app, maxSwipes: 5)
        XCTAssertTrue(access.label.contains("Set by the CLI"), access.label)
        XCTAssertFalse(app.buttons["new-agent-access"].exists, "A CLI that sets its own Access has no picker")
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
        waitAndTap(settings, until: element(app, "agent-settings-summary"), timeout: 10)
        XCTAssertTrue(scrollTo(name, in: app, maxSwipes: 4))
        XCTAssertEqual(name.value as? String, "Juniper")
        XCTAssertTrue(name.isEnabled, "A sleeping agent's settings can change")
        let model = app.buttons["agent-settings-model"]
        XCTAssertTrue(scrollTo(model, in: app, maxSwipes: 6))
        XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(element(app, "agent-settings-locked-hint").exists, "Nothing is locked while it sleeps")
        screenshot(app, "Sleeping agent settings")

        let access = app.buttons["agent-settings-access"]
        scrollTo(access, in: app, maxSwipes: 4)
        XCTAssertTrue(access.isEnabled)
        access.tap()
        for label in ["Plan", "Ask first", "Auto-accept edits", "Auto", "Full access"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Offers \(label)")
        }
        app.buttons["Auto"].tap()
        let confirm = app.buttons["Use Auto"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Raising Access asks first")
        screenshot(app, "Saved Access confirmation")
        confirm.tap()
        scrollUntilExists(element(app, "agent-settings-error"), in: app, up: false, maxSwipes: 4, wait: 0.5)
        XCTAssertTrue(element(app, "agent-settings-error").waitForExistence(timeout: 5))
        scrollTo(access, in: app, maxSwipes: 4)
        XCTAssertTrue(access.label.contains("Ask first") || (access.value as? String) == "Ask first", "A refused change does not change saved Access")
        app.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }

    func testOrchestrateSectionShowsThePolicyAndToggles() {
        let app = launch()
        // Juniper orchestrates: the toggle is on and the policy shows in the desktop's words.
        let fold = element(app, "fold-sleeping-preview-studio-clubhouse")
        let juniper = element(app, "agent-preview-studio-juniper")
        scrollUntilExists(fold, in: app)
        expandFold(fold, revealing: juniper, in: app)
        XCTAssertTrue(juniper.waitForExistence(timeout: 15))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(juniper, shows: settings, "The agent row's long-press menu offers its settings")
        waitAndTap(settings, until: app.textFields["agent-settings-name"], timeout: 10)

        let orchestrate = app.switches["agent-settings-orchestrate"]
        scrollTo(orchestrate, in: app, maxSwipes: 6)
        XCTAssertTrue(orchestrate.exists, "A desktop with orchestration shows the Orchestrate section")
        XCTAssertEqual(orchestrate.value as? String, "1")
        XCTAssertTrue(orchestrate.isEnabled)
        let access = app.buttons["agent-settings-orchestrate-access"]
        scrollTo(access, in: app, maxSwipes: 3)
        XCTAssertTrue(access.exists, "Helpers get shows while it orchestrates")
        XCTAssertTrue(access.label.contains("Same as Juniper"), "The desktop's label: \(access.label)")
        let control = app.buttons["agent-settings-orchestrate-control"]
        scrollTo(control, in: app, maxSwipes: 3)
        XCTAssertTrue(control.exists, "Control shows while it orchestrates")
        XCTAssertTrue(control.label.contains("Ask before starting") || (control.value as? String)?.contains("Ask before starting") == true,
                      "The desktop's control label: \(control.label) \(String(describing: control.value))")
        let helpers = element(app, "agent-settings-orchestrate-max-helpers")
        scrollTo(helpers, in: app, maxSwipes: 3)
        XCTAssertTrue(helpers.exists, "Helpers at once is a stepper")
        let count = "\(helpers.label) \(String(describing: helpers.value))"
        XCTAssertTrue(count.contains("3"), "Juniper may run 3 helpers at once: \(count)")
        screenshot(app, "Orchestrate section")

        // Turning it off goes to the desktop; preview refuses visibly and the toggle and pickers come back.
        scrollTo(orchestrate, in: app, up: true, maxSwipes: 3)
        orchestrate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let error = element(app, "agent-settings-error")
        scrollUntilExists(error, in: app, up: false, maxSwipes: 6, wait: 0.5)
        XCTAssertTrue(error.waitForExistence(timeout: 5), "A refused change says so")
        scrollTo(orchestrate, in: app, maxSwipes: 6)
        XCTAssertEqual(orchestrate.value as? String, "1", "The toggle goes back to what the desktop has")
    }

    func testAwakeAgentCanTurnOnOrchestration() {
        let app = launch()
        let river = element(app, "agent-preview-studio-river")
        scrollUntilExists(river, in: app)
        XCTAssertTrue(river.waitForExistence(timeout: 15))
        let actions = app.buttons["Conversation actions"]
        tapVisibleRow(river, in: app, until: actions)
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings, timeout: 5)
        waitAndTap(settings, until: element(app, "agent-settings-summary"), timeout: 10)

        let orchestrate = app.switches["agent-settings-orchestrate"]
        scrollTo(orchestrate, in: app, maxSwipes: 6)
        XCTAssertTrue(orchestrate.exists)
        XCTAssertEqual(orchestrate.value as? String, "0", "River doesn't orchestrate")
        XCTAssertTrue(orchestrate.isEnabled, "Orchestration changes while the agent runs")
        XCTAssertFalse(app.buttons["agent-settings-orchestrate-access"].exists, "The policy hides while it's off")
        XCTAssertTrue(app.staticTexts["Turn this on to give River the tools to start, message and dispose of helper agents."].exists)
        orchestrate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let error = element(app, "agent-settings-error")
        scrollUntilExists(error, in: app, up: false, maxSwipes: 6, wait: 0.5)
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Preview refuses it visibly")
    }
}
