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
        app.launchArguments = ["--reset-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Clubhouse Go"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your agents, everywhere"].exists)
        XCTAssertTrue(app.staticTexts["Tap anywhere to continue"].exists)
    }

    // MARK: - Tab Structure

    @MainActor
    func testAllFourTabsExist() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Dashboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Clubhouses"].exists)
        XCTAssertTrue(app.tabBars.buttons["Projects"].exists)
        XCTAssertTrue(app.tabBars.buttons["Agents"].exists)
    }

    @MainActor
    func testDashboardTabExists() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let dashboardTab = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboardTab.waitForExistence(timeout: 5))
    }

    // MARK: - Dashboard

    @MainActor
    func testDashboardShowsStats() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Stats were simplified to a single tappable "Agents" tile + Projects tile (#84).
        XCTAssertTrue(app.buttons["stat-card-agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stat-card-projects"].exists)
    }

    @MainActor
    func testDashboardAgentsTileSwitchesToAgentsTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let agentsTile = app.buttons["stat-card-agents"]
        XCTAssertTrue(agentsTile.waitForExistence(timeout: 5))
        agentsTile.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 3),
                      "Tapping the Agents tile should switch to the Agents tab")
    }

    @MainActor
    func testDashboardShowsPermissionSection() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let permText = app.staticTexts["1 Permission Waiting"]
        XCTAssertTrue(permText.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDashboardTabHasBadge() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let dashboardTab = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboardTab.waitForExistence(timeout: 5))
        let badgeValue = dashboardTab.value as? String
        XCTAssertNotNil(badgeValue)
    }

    // MARK: - Clubhouses Tab

    @MainActor
    func testNavigateToClubhousesTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Clubhouses"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouses"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testClubhousesTabShowsInstances() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Clubhouses"].tap()

        // Should show mock instance names
        XCTAssertTrue(app.staticTexts["Mason's Desktop"].waitForExistence(timeout: 5))
    }

    // MARK: - Projects Tab

    @MainActor
    func testNavigateToProjectsTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
    }

    // MARK: - Agents Tab

    @MainActor
    func testNavigateToAgentsTab() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentsTabShowsAgents() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // faithful-urchin is a running agent in mock data
        XCTAssertTrue(app.staticTexts["faithful-urchin"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentsTabDefaultsToCardView() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        // The Agents tab now defaults to swipe-card mode (#93); the toolbar
        // toggle therefore offers switching back to the list.
        XCTAssertTrue(
            app.buttons["List View"].waitForExistence(timeout: 5),
            "Agents tab should default to card mode, exposing a 'List View' toggle"
        )
    }

    // Note: the running-agent "Message" action is covered by unit tests
    // (PtyInputSubmitMessageTests) rather than a UI test. An XCUITest that
    // launched the app, opened the swipe card, and presented the Send Message
    // sheet proved unstable on CI (app failed to terminate, cascading into the
    // whole UI job timing out), and the UI suite is already near the CI budget.

    // MARK: - Settings

    @MainActor
    func testSettingsSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        let settingsButton = app.navigationBars.buttons["gearshape"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), "Settings button should exist")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3), "Settings sheet should open")
    }

    // MARK: - Actions

    @MainActor
    func testSpawnSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // The Dashboard bolt button was replaced by the Settings gear (#85);
        // spawning now lives in the "Spawn Agent" quick action.
        let spawnButton = app.buttons["Spawn Agent"]
        XCTAssertTrue(spawnButton.waitForExistence(timeout: 5), "Spawn Agent action should exist")
        spawnButton.tap()
        XCTAssertTrue(app.navigationBars["New Quick Agent"].waitForExistence(timeout: 3), "Spawn sheet should open")
    }

    @MainActor
    func testDashboardSettingsGearOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // The Dashboard top-right toolbar now hosts the Settings gear (#85).
        let settingsButton = app.navigationBars.buttons["gearshape"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings gear should exist on Dashboard")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3), "Settings sheet should open")
    }

    @MainActor
    func testPermissionReviewFlowOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let reviewButton = app.buttons["Review All"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5), "Review All button should exist")
        reviewButton.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3), "Permission review flow should open")
    }

    // MARK: - Persona Tap Navigation (issue #77)

    @MainActor
    func testDashboardRunningAgentTileNavigatesToDetail() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // faithful-urchin is a running agent in mock data (id: durable_1737000000000_abc123)
        let tile = app.buttons["running-agent-tile-durable_1737000000000_abc123"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Running agent tile should exist on Dashboard")
        tile.tap()

        // AgentDetailView sets navigationTitle to the agent's name
        XCTAssertTrue(
            app.navigationBars["faithful-urchin"].waitForExistence(timeout: 3),
            "Tapping the persona tile should navigate to the agent detail view"
        )
    }
}
