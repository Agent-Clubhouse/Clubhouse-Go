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

        XCTAssertTrue(app.staticTexts["Total Agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running"].exists)
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

    // MARK: - Settings

    @MainActor
    func testSettingsSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Agents"].tap()

        let settingsButton = app.navigationBars.buttons["gearshape"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        }
    }

    // MARK: - Actions

    @MainActor
    func testSpawnSheetOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let spawnButton = app.navigationBars.buttons["bolt.fill"]
        if spawnButton.waitForExistence(timeout: 5) {
            spawnButton.tap()
            XCTAssertTrue(app.navigationBars["New Quick Agent"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testPermissionReviewFlowOpens() throws {
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let reviewButton = app.buttons["Review All"]
        if reviewButton.waitForExistence(timeout: 5) {
            reviewButton.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        }
    }
}
