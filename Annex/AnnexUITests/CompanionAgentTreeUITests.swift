import XCTest

@MainActor
final class CompanionAgentTreeUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-helper-tree"]
    private var completedMilestones: [String] = []

    private func requireMilestones(_ milestones: [String], caseID: String = #function) {
        completedMilestones = []
        addTeardownBlock { @MainActor [self] in
            XCTAssertEqual(completedMilestones, milestones, "\(caseID) must complete every behavior phase")
        }
    }

    private func completeMilestone(_ phase: String) {
        completedMilestones.append(phase)
        XCTContext.runActivity(named: "AgentTree completed: \(phase)") { _ in }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testNestedRowsCollapseRollupRelaunchAndNeedsYouNavigation() {
        requireMilestones(["initial tree assertions", "persisted tree assertions", "Needs you navigation and return"])
        let app = launchApp(arguments, attempts: 1)
        let parent = element(app, "helpers-toggle-preview-studio-cedar")
        let child = element(app, "helpers-toggle-preview-studio-river")
        let nested = element(app, "agent-preview-studio-juniper")
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Expanded")
        XCTAssertGreaterThanOrEqual(parent.frame.width, 44)
        XCTAssertGreaterThanOrEqual(parent.frame.height, 44)
        XCTAssertTrue(child.exists && nested.exists, "An awake helper keeps sleeping Cedar out of the sleeping fold")
        XCTAssertTrue(scrollTo(nested, in: app))
        XCTAssertEqual(nested.value as? String, "Helper of River")
        XCTAssertGreaterThan(app.staticTexts["Juniper"].firstMatch.frame.minX, app.staticTexts["Cedar"].firstMatch.frame.minX)
        shot(app, "Home nested helpers expanded")
        parent.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 5))
        XCTAssertFalse(nested.exists)
        XCTAssertEqual(parent.value as? String, "Collapsed")
        let row = element(app, "agent-preview-studio-cedar")
        XCTAssertTrue(app.staticTexts["Cedar"].firstMatch.exists, "The rollup leaves the agent name readable")
        XCTAssertTrue(row.label.contains("2 helpers") && row.label.localizedCaseInsensitiveContains("needs you"), row.label)
        shot(app, "Home collapsed parent with helper rollup")

        let sleeping = element(app, "fold-sleeping-preview-studio-clubhouse")
        let moss = element(app, "agent-preview-studio-moss")
        expandFold(sleeping, revealing: moss, in: app)
        let finished = element(app, "fold-finished-preview-studio-clubhouse")
        let quick = element(app, "agent-preview-studio-quick-willow")
        expandFold(finished, revealing: quick, in: app)
        completeMilestone("initial tree assertions")
        app.terminate()
        app.launchArguments = arguments + ["--ui-testing-fast", "--companion-preview-keep-preferences"]
        app.launch()
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Collapsed")
        XCTAssertFalse(child.exists)
        XCTAssertTrue(scrollUntilExists(moss, in: app))
        XCTAssertTrue(scrollUntilExists(quick, in: app))
        completeMilestone("persisted tree assertions")

        // Needs you is a flat destination and still opens River while Cedar is folded.
        let river = element(app, "agent-preview-studio-river")
        let composer = element(app, "companion-composer")
        XCTAssertTrue(scrollTo(river, in: app, up: false))
        tapVisibleRow(river, in: app, until: composer)
        XCTAssertTrue(app.navigationBars["River"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Collapsed", "Direct navigation preserves disclosure")
        completeMilestone("Needs you navigation and return")
    }
    func testProjectUsesSameTreeAndCrossProjectCaption() {
        requireMilestones(["project tree assertions", "shared disclosure and cross-project caption"])
        let app = launchApp(arguments, attempts: 1)
        let project = element(app, "open-project-preview-studio-clubhouse")
        let toggle = element(app, "helpers-toggle-preview-studio-cedar")
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        waitAndTap(project, until: element(app, "project-new-agent"))
        XCTAssertTrue(scrollUntilExists(toggle, in: app) && scrollTo(toggle, in: app))
        XCTAssertTrue(element(app, "agent-preview-studio-juniper").exists)
        shot(app, "Project nested helpers expanded")
        toggle.tap()
        XCTAssertTrue(element(app, "helpers-toggle-preview-studio-river").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "agent-preview-studio-cedar").label.contains("2 helpers"))
        completeMilestone("project tree assertions")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed", "Home and project share disclosure")
        let agents = app.buttons.matching(identifier: "Agents").firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        let maple = element(app, "agent-preview-studio-maple")
        XCTAssertTrue(scrollUntilExists(maple, in: app) && scrollTo(maple, in: app))
        XCTAssertTrue(maple.label.contains("Helper of Cedar in Clubhouse"), maple.label)
        completeMilestone("shared disclosure and cross-project caption")
    }
}
