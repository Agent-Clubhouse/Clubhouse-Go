import XCTest

@MainActor
final class CompanionAgentTreeUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-helper-tree"]
    private var completedMilestones: [String] = []
    private var phaseTimeline: [String] = []
    private var startedAt: TimeInterval = 0

    private func requireMilestones(_ milestones: [String], caseID: String = #function) {
        completedMilestones = []
        phaseTimeline = []
        startedAt = ProcessInfo.processInfo.systemUptime
        addTeardownBlock { @MainActor [self] in
            let attachment = XCTAttachment(string: phaseTimeline.joined(separator: "\n"))
            attachment.name = "AgentTree phase timeline"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(completedMilestones, milestones, "\(caseID) must complete every behavior phase")
        }
    }

    private func phase(_ name: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let entry = "\(String(format: "%.3f", elapsed))s \(name)"
        phaseTimeline.append(entry)
        // stdout survives an allowance-killed runner that cannot finish its attachments.
        print("AGENT_TREE_PHASE \(entry)")
        XCTContext.runActivity(named: "AgentTree phase: \(name)") { _ in }
    }

    private func completeMilestone(_ phase: String) {
        completedMilestones.append(phase)
        self.phase("completed: \(phase)")
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
        phase("initial launch")
        let app = launchApp(arguments, attempts: 1)
        phase("initial tree lookup and geometry")
        let parent = element(app, "helpers-toggle-preview-studio-cedar")
        let child = element(app, "helpers-toggle-preview-studio-river")
        let nested = element(app, "agent-preview-studio-juniper")
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Expanded")
        XCTAssertGreaterThanOrEqual(parent.frame.width, 44)
        XCTAssertGreaterThanOrEqual(parent.frame.height, 44)
        let parentNameX = app.staticTexts["Cedar"].firstMatch.frame.minX
        XCTAssertTrue(scrollUntilExists(child, in: app), "An awake helper keeps sleeping Cedar out of the sleeping fold")
        XCTAssertTrue(scrollUntilExists(nested, in: app), "Taller metadata rows may place the grandchild below the viewport")
        let permissionRow = element(app, "agent-preview-studio-river")
        XCTAssertTrue(permissionRow.label.contains("Needs permission"), permissionRow.label)
        XCTAssertFalse(permissionRow.label.contains("Needs you, Needs permission"), permissionRow.label)
        XCTAssertTrue(element(app, "agent-preview-studio-cedar").label.contains("Permissions: Auto"),
                      "VoiceOver retains access when it is different or the default is unknown")
        XCTAssertTrue(scrollTo(nested, in: app))
        XCTAssertEqual(nested.value as? String, "Helper of River")
        XCTAssertGreaterThan(app.staticTexts["Juniper"].firstMatch.frame.minX, parentNameX)
        shot(app, "Home nested helpers expanded")
        phase("collapse and helper rollup")
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
        phase("sleeping and finished folds")
        expandFold(sleeping, revealing: moss, in: app)
        let finished = element(app, "fold-finished-preview-studio-clubhouse")
        let quick = element(app, "agent-preview-studio-quick-willow")
        expandFold(finished, revealing: quick, in: app)
        completeMilestone("initial tree assertions")
        phase("terminate before preference relaunch")
        app.terminate()
        app.launchArguments = arguments + ["--ui-testing-fast", "--companion-preview-keep-preferences"]
        phase("preference relaunch")
        app.launch()
        phase("persisted tree lookup")
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Collapsed")
        XCTAssertFalse(child.exists)
        XCTAssertTrue(scrollUntilExists(moss, in: app))
        XCTAssertTrue(scrollUntilExists(quick, in: app))
        completeMilestone("persisted tree assertions")

        // Needs you is a flat destination and still opens River while Cedar is folded.
        phase("Needs you row lookup and navigation")
        let river = element(app, "agent-preview-studio-river")
        let composer = element(app, "companion-composer")
        XCTAssertTrue(scrollTo(river, in: app, up: false))
        tapVisibleRow(river, in: app, until: composer)
        XCTAssertTrue(app.navigationBars["River"].exists)
        phase("return from River and verify disclosure")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Collapsed", "Direct navigation preserves disclosure")
        completeMilestone("Needs you navigation and return")
    }
    func testProjectUsesSameTreeAndCrossProjectCaption() {
        requireMilestones(["project tree assertions", "shared disclosure and cross-project caption"])
        phase("initial launch")
        let app = launchApp(arguments, attempts: 1)
        phase("project navigation and tree lookup")
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
        phase("return home and verify shared disclosure")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed", "Home and project share disclosure")
        let search = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        phase("cross-project helper lookup")
        let maple = element(app, "agent-preview-studio-maple")
        XCTAssertTrue(scrollUntilExists(maple, in: app) && scrollTo(maple, in: app))
        XCTAssertTrue(maple.label.contains("Helper of Cedar in Clubhouse"), maple.label)
        completeMilestone("shared disclosure and cross-project caption")
    }
}
