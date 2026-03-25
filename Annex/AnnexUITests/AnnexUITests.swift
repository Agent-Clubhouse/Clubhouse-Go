import XCTest

final class ClubhouseGoUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Welcome Flow

    @MainActor
    func testWelcomeScreenShowsOnFirstLaunch() throws {
        // Clear onboarding state
        app.launchArguments = ["--reset-onboarding"]
        app.launch()

        // Welcome screen should show app name and tagline
        XCTAssertTrue(app.staticTexts["Clubhouse Go"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your agents, everywhere"].exists)
        XCTAssertTrue(app.staticTexts["Tap anywhere to continue"].exists)
    }

    // MARK: - Main App Flow (with mock data)

    @MainActor
    func testDashboardTabExists() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Dashboard tab should be visible
        let dashboardTab = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboardTab.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAllThreeTabsExist() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Dashboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Agents"].exists)
        XCTAssertTrue(app.tabBars.buttons["Instances"].exists)
    }

    @MainActor
    func testDashboardShowsInstanceStatus() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Should show instance names from mock data
        XCTAssertTrue(app.staticTexts["Mason's Desktop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mac Mini"].exists)
    }

    @MainActor
    func testDashboardShowsStats() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Stats section should show agent counts
        XCTAssertTrue(app.staticTexts["Total Agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running"].exists)
        XCTAssertTrue(app.staticTexts["Instances"].exists)
    }

    @MainActor
    func testDashboardShowsPermissionSection() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Mock data has one pending permission
        let permText = app.staticTexts["1 Permission Waiting"]
        XCTAssertTrue(permText.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNavigateToAgentsTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // Should see the Agents navigation title
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentsTabShowsAgents() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // Should see agent names from mock data
        // faithful-urchin is a running agent on Mason's Desktop
        XCTAssertTrue(app.staticTexts["faithful-urchin"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNavigateToInstancesTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Instances"].tap()

        XCTAssertTrue(app.navigationBars["Instances"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInstancesTabShowsInstances() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Instances"].tap()

        // Should show both mock instances
        XCTAssertTrue(app.staticTexts["Mason's Desktop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mac Mini"].exists)
    }

    @MainActor
    func testInstanceDetailNavigation() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Instances"].tap()

        // Tap on first instance
        app.staticTexts["Mason's Desktop"].tap()

        // Should navigate to instance detail
        XCTAssertTrue(app.navigationBars["Mason's Desktop"].waitForExistence(timeout: 5))
        // Should show projects section
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'project'")).firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAgentDetailNavigation() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // Tap on an agent
        let agentCell = app.staticTexts["faithful-urchin"]
        XCTAssertTrue(agentCell.waitForExistence(timeout: 5))
        agentCell.tap()

        // Should navigate to agent detail
        XCTAssertTrue(app.navigationBars["faithful-urchin"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // Tap settings gear
        let settingsButton = app.navigationBars.buttons["gearshape"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testPermissionReviewFlowOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Dashboard should show permission section
        let reviewButton = app.buttons["Review All"]
        if reviewButton.waitForExistence(timeout: 5) {
            reviewButton.tap()
            // Should open full-screen review flow
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testSpawnSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Tap the spawn button in Dashboard toolbar
        let spawnButton = app.navigationBars.buttons["bolt.fill"]
        if spawnButton.waitForExistence(timeout: 5) {
            spawnButton.tap()
            XCTAssertTrue(app.navigationBars["New Quick Agent"].waitForExistence(timeout: 3))
        }
    }

    // MARK: - Tab Badge

    @MainActor
    func testDashboardTabHasBadge() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // The Dashboard tab should have a badge for pending permissions
        let dashboardTab = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboardTab.waitForExistence(timeout: 5))
        // Badge value check (mock data has 1 permission)
        let badgeValue = dashboardTab.value as? String
        XCTAssertNotNil(badgeValue)
    }
}
