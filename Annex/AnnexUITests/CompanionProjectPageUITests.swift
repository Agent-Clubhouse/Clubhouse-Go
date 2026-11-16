import XCTest

@MainActor final class CompanionProjectPageUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openProject(linked: Bool) -> XCUIApplication {
        var arguments = ["--companion-preview", "--companion-preview-start-home"]
        if linked { arguments.append("--companion-preview-linked-projects") }
        let app = launchApp(arguments, attempts: 1)
        let project = element(app, "open-project-preview-studio-clubhouse")
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        waitAndTap(project, until: app.buttons["project-page-options"], attempts: 1)
        return app
    }

    func testAllRequiresAnExplicitWakeMachineAndASelectedDesktopActsDirectly() {
        let app = openProject(linked: true)
        XCTAssertTrue(element(app, "desktop-chip-all").exists)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(river.waitForExistence(timeout: 5))
        XCTAssertTrue(river.label.contains("Studio Mac"), "All linked copies must identify every agent's desktop")
        XCTAssertFalse(app.buttons["project-changes"].exists)
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["project-wake"], attempts: 1)
        XCTAssertTrue(app.buttons["Project info"].exists)
        waitAndTap(app.buttons["project-wake"], until: app.navigationBars["Choose a desktop"], attempts: 1)
        XCTAssertFalse(element(app, "wake-message").exists, "All never silently chooses a machine")
        let studio = app.buttons["project-machine-choice-preview-studio-clubhouse"]
        let laptop = app.buttons["project-machine-choice-preview-laptop-notes"]
        XCTAssertTrue(studio.isEnabled)
        XCTAssertFalse(laptop.isEnabled, "A desktop without sleeping agents cannot receive Wake")
        waitAndTap(studio, until: element(app, "wake-message"), attempts: 1)
        XCTAssertTrue(app.buttons["wake-agent-picker"].label.contains("Juniper"))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(element(app, "wake-message").waitForNonExistence(timeout: 5))
        XCTAssertTrue(scrollTo(element(app, "desktop-chip-host-preview-studio"), in: app, up: false))
        element(app, "desktop-chip-host-preview-studio").tap()
        XCTAssertTrue(waitFor(river, NSPredicate(format: "NOT (label CONTAINS %@)", "Studio Mac"), timeout: 5),
                      "The selected desktop makes the repeated row badge redundant")
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["project-wake"], attempts: 1)
        waitAndTap(app.buttons["project-wake"], until: element(app, "wake-message"), attempts: 1)
        XCTAssertFalse(app.navigationBars["Choose a desktop"].exists)
        app.buttons["Cancel"].tap()
    }

    func testAllTerminalChoosesOneMachineAndOpensOnlyItsShell() {
        let app = openProject(linked: true)
        let terminal = app.buttons["project-terminal"]
        XCTAssertTrue(terminal.isEnabled)
        waitAndTap(terminal, until: app.navigationBars["Choose a desktop"], attempts: 1)
        XCTAssertFalse(element(app, "terminal-output").exists)
        let studio = app.buttons["project-machine-choice-preview-studio-clubhouse"]
        XCTAssertTrue(studio.isEnabled)
        waitAndTap(studio, until: element(app, "terminal-output"), attempts: 1)
        XCTAssertTrue(waitFor(element(app, "terminal-output"), NSPredicate(format: "value CONTAINS %@", "clubhouse %"), timeout: 10))
        element(app, "terminal-done").tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5))
    }

    func testSingleProjectMenuKeepsPinInactiveAndReadOnlyInfo() {
        let app = openProject(linked: false)
        XCTAssertFalse(element(app, "desktop-chips").exists)
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["Pin to top of Home"], attempts: 1)
        XCTAssertTrue(app.buttons["Mark inactive"].exists)
        XCTAssertTrue(app.buttons["Project info"].exists)
        app.buttons["Pin to top of Home"].tap()
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["Unpin from Home"], attempts: 1)
        XCTAssertFalse(app.buttons["Mark inactive"].exists, "Pinned projects stay active under the existing policy")
        app.buttons["Unpin from Home"].tap()
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["Mark inactive"], attempts: 1)
        app.buttons["Mark inactive"].tap()
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["Mark active"], attempts: 1)
        XCTAssertTrue(app.buttons["Project info"].exists)
        waitAndTap(app.buttons["Project info"], until: app.navigationBars["Project info"], attempts: 1)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.switches.count, 0)
    }
    private func openLinkedStateProject(_ flags: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-start-home",
            "--companion-preview-linked-projects", "--companion-preview-linked-project-state"] + flags, attempts: 1)
        let project = element(app, "open-project-preview-studio-clubhouse")
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        waitAndTap(project, until: app.buttons["project-page-options"], attempts: 1)
        return app
    }

    private func stateMenu(_ app: XCUIApplication, showing name: String) {
        waitAndTap(app.buttons["project-page-options"], until: app.buttons[name], attempts: 1)
        XCTAssertEqual(app.buttons.matching(identifier: name).count, 1)
    }

    private func captureState(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLinkedToolbarUsesSharedPinAndInactiveEvenInASelectedDesktopScope() {
        let app = openLinkedStateProject()
        element(app, "desktop-chip-host-preview-laptop").tap()
        stateMenu(app, showing: "Pin project")
        XCTAssertTrue(app.buttons["Pin project"].isEnabled)
        XCTAssertTrue(app.buttons["Mark inactive"].isEnabled)
        captureState(app, "Project linked shared-state menu in Laptop scope")
        app.buttons["Pin project"].tap()
        stateMenu(app, showing: "Unpin project")
        XCTAssertFalse(app.buttons["Mark inactive"].exists, "A pinned linked group remains active")
        app.buttons["Unpin project"].tap()
        stateMenu(app, showing: "Mark inactive")
        app.buttons["Mark inactive"].tap()
        stateMenu(app, showing: "Mark active")
        app.buttons["Mark active"].tap()
        stateMenu(app, showing: "Mark inactive")
        XCTAssertTrue(app.buttons["Pin project"].isEnabled)
    }

    func testLinkedToolbarMixedVersionDisablesSharedChangesAndShowsConnectionHint() {
        let app = openLinkedStateProject(["--companion-preview-linked-state-mixed-version"])
        stateMenu(app, showing: "Pin project")
        XCTAssertFalse(app.buttons["Pin project"].isEnabled)
        XCTAssertFalse(app.buttons["Mark inactive"].isEnabled)
        let hint = app.buttons["Connect Studio Mac for shared changes."]
        XCTAssertTrue(hint.exists)
        XCTAssertFalse(hint.isEnabled)
        XCTAssertFalse(app.buttons["Studio Mac"].exists, "Unavailable shared authority must not fall back to per-copy changes")
        captureState(app, "Project linked mixed-version shared changes unavailable")
    }

    func testLinkedToolbarOldHostsRetainPerCopyStateFallback() {
        let app = openProject(linked: true)
        stateMenu(app, showing: "Studio Mac")
        waitAndTap(app.buttons["Studio Mac"], until: app.buttons["Pin to top of Home"], attempts: 1)
        XCTAssertTrue(app.buttons["Pin to top of Home"].isEnabled)
        app.buttons["Pin to top of Home"].tap()
        stateMenu(app, showing: "Studio Mac")
        waitAndTap(app.buttons["Studio Mac"], until: app.buttons["Unpin from Home"], attempts: 1)
        XCTAssertFalse(app.buttons["Mark inactive"].exists)
        captureState(app, "Project old-host per-copy state fallback")
    }

}
