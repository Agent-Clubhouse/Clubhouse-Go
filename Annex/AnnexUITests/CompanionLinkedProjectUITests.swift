import XCTest

@MainActor
final class CompanionLinkedProjectUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-linked-projects", "--companion-preview-start-home"]

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHomeAndProjectPageMergeMachinesAndUnlinkSplitsThem() {
        let app = launchApp(arguments, attempts: 1)
        let project = element(app, "open-project-preview-studio-clubhouse")
        let secondProject = element(app, "open-project-preview-laptop-notes")
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        XCTAssertFalse(secondProject.exists, "The linked group has exactly one project entry")
        XCTAssertTrue(element(app, "project-machine-preview-studio-clubhouse").exists)
        XCTAssertTrue(scrollUntilExists(element(app, "project-machine-preview-laptop-notes"), in: app))
        screenshot(app, "Linked projects on Home")
        XCTAssertTrue(scrollTo(project, in: app, up: false))
        waitAndTap(project, until: element(app, "project-page-machine-preview-studio"))
        XCTAssertTrue(element(app, "agent-preview-studio-cedar").exists)
        let laptop = element(app, "project-page-machine-preview-laptop")
        XCTAssertTrue(scrollUntilExists(laptop, in: app) && scrollTo(laptop, in: app))
        XCTAssertTrue(scrollUntilExists(element(app, "agent-preview-laptop-river"), in: app))
        screenshot(app, "Linked project page with machine sections")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollTo(app.buttons["Settings"], in: app, up: false))
        waitAndTap(app.buttons["Settings"], until: app.buttons["Report projects unlinked"])
        app.buttons["Report projects unlinked"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(scrollUntilExists(project, in: app))
        XCTAssertTrue(scrollUntilExists(secondProject, in: app), "The empty desktop replacement splits both projects")
        screenshot(app, "Unlinked projects split on Home")
    }

    func testSpawningRequiresChoosingTheMachine() {
        let app = launchApp(arguments, attempts: 1)
        let newAgent = app.buttons.matching(NSPredicate(format: "label == %@", "New agent in Clubhouse")).firstMatch
        XCTAssertTrue(scrollUntilExists(newAgent, in: app) && scrollTo(newAgent, in: app))
        waitAndTap(newAgent, until: element(app, "spawn-machine-picker"))
        XCTAssertFalse(app.buttons["Start agent"].exists, "No concrete machine has been chosen")
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        XCTAssertEqual(element(app, "spawn-project-picker").label, "Run on Clubhouse")
        let machine = element(app, "spawn-machine-picker")
        waitAndTap(machine, until: app.buttons["Travel MacBook"])
        app.buttons["Travel MacBook"].tap()
        let prompt = app.textFields["Agent task"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(machine.label.contains("Travel MacBook") || (machine.value as? String)?.contains("Travel MacBook") == true)
        prompt.tap()
        prompt.typeText("Check the linked project on this machine")
        XCTAssertTrue(app.buttons["Start agent"].isEnabled)
        screenshot(app, "Spawn requires an explicit machine")
        app.buttons["Start agent"].tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
    }

    func testDisconnectedMemberKeepsItsPlaceWithoutShowingCachedAgents() {
        let app = launchApp(arguments + ["--companion-preview-dispatcher-controls"], attempts: 1)
        let cedar = element(app, "agent-preview-studio-cedar")
        XCTAssertTrue(scrollUntilExists(cedar, in: app) && scrollTo(cedar, in: app))
        waitAndTap(app.buttons["Settings"], until: app.buttons["Disconnect desktop"])
        app.buttons["Disconnect desktop"].tap()
        app.buttons["Done"].tap()
        let studio = element(app, "project-machine-preview-studio-clubhouse")
        XCTAssertTrue(scrollUntilExists(studio, in: app) && scrollTo(studio, in: app))
        XCTAssertTrue(waitFor(studio, NSPredicate(format: "label CONTAINS %@", "Offline"), timeout: 5))
        XCTAssertFalse(cedar.exists, "The offline machine's cached agent tree is not live Home content")
        let laptop = element(app, "project-machine-preview-laptop-notes")
        XCTAssertTrue(scrollUntilExists(laptop, in: app))
        XCTAssertTrue(scrollUntilExists(element(app, "agent-preview-laptop-river"), in: app))
        XCTAssertFalse(element(app, "open-project-preview-laptop-notes").exists, "Disconnecting does not unlink the group")
        screenshot(app, "Linked Home retains offline member without stale agents")
    }

    func testProjectOptionsDisambiguateTwoProjectsOnTheSameMachine() {
        let app = launchApp(arguments + ["--companion-preview-linked-projects-same-machine"], attempts: 1)
        let menu = element(app, "project-menu-preview-studio-clubhouse")
        XCTAssertTrue(scrollUntilExists(menu, in: app) && scrollTo(menu, in: app))
        waitAndTap(menu, until: app.buttons["Studio Mac · Clubhouse"])
        XCTAssertTrue(app.buttons["Studio Mac · Docs"].exists)
        XCTAssertTrue(app.buttons["Travel MacBook"].exists)
        app.buttons["Studio Mac · Docs"].tap()
        XCTAssertTrue(app.buttons["Pin project"].waitForExistence(timeout: 5))
        screenshot(app, "Project options distinguish same-machine members")
    }

    func testNeedsYouUsesOneProjectHeadingWithMachineLabels() {
        let app = launchApp(arguments, attempts: 1)
        app.tabBars.buttons["Needs you"].tap()
        let heading = element(app, "needs-you-project-preview-studio-clubhouse")
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "needs-you-project-preview-laptop-notes").exists)
        XCTAssertTrue(app.staticTexts["Studio Mac"].firstMatch.exists)
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Travel MacBook"].firstMatch, in: app))
        screenshot(app, "Needs you groups linked projects and labels machines")
    }
}
