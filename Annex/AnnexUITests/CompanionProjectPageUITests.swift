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
        XCTAssertFalse(app.buttons["Pin to top of Home"].exists, "Linked pin semantics await desktop shared state")
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
}
