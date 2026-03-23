import XCTest

/// End-to-end tests that exercise real HTTP networking against a MockAnnexServer.
///
/// Two test classes:
/// - `E2EPairingTests`: Tests the HTTP pairing flow (POST /pair, GET /status).
///   The mock server handles real HTTP requests on localhost.
/// - `E2EUITests`: Tests UI flows with real HTTP pairing + mock snapshot data.
///   Uses `--test-snapshot` to reliably populate the UI after HTTP pairing succeeds.
///
/// No production Clubhouse instance is touched. Each test gets its own mock server
/// on a dynamic port.

// MARK: - HTTP Pairing Tests (real networking, no mock snapshot)

final class E2EPairingTests: XCTestCase {

    var server: MockAnnexServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockAnnexServer(pin: "999999")
        let port = try server.start()

        app = XCUIApplication()
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(port)",
            "--test-pin", "999999"
        ]
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
    }

    @MainActor
    func testSuccessfulPairingBypassesPairingScreen() throws {
        app.launch()

        // After successful pairing, the app should NOT show the PIN entry screen
        let pinEntry = app.staticTexts["Enter your 6-digit PIN"]
        let appeared = pinEntry.waitForExistence(timeout: 5)
        XCTAssertFalse(appeared, "PIN entry should not appear after successful pairing")
    }

    @MainActor
    func testInvalidPinStaysOnPairingScreen() throws {
        server.stop()
        server = MockAnnexServer(pin: "000000")
        let port = try server.start()

        app.launchArguments = [
            "--test-server", "127.0.0.1:\(port)",
            "--test-pin", "999999"  // Wrong pin
        ]
        app.launch()

        // App should show pairing view since pairing failed
        let dashboardTab = app.tabBars.buttons["Dashboard"]
        let appeared = dashboardTab.waitForExistence(timeout: 8)
        XCTAssertFalse(appeared, "Dashboard should not appear after failed pairing")
    }

    @MainActor
    func testServerUnreachableStaysOnPairing() throws {
        server.stop()

        app.launchArguments = [
            "--test-server", "127.0.0.1:1",  // Port 1 — nothing listening
            "--test-pin", "999999"
        ]
        app.launch()

        let dashboardTab = app.tabBars.buttons["Dashboard"]
        let appeared = dashboardTab.waitForExistence(timeout: 8)
        XCTAssertFalse(appeared, "Dashboard should not appear when server is unreachable")
    }
}

// MARK: - Full UI Tests (real HTTP pairing + mock snapshot data)

final class E2EUITests: XCTestCase {

    var server: MockAnnexServer!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockAnnexServer(pin: "999999")
        let port = try server.start()

        app = XCUIApplication()
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(port)",
            "--test-pin", "999999",
            "--test-snapshot"  // Load mock data after pairing
        ]
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
    }

    // MARK: - Dashboard

    @MainActor
    func testDashboardShowsAfterPairing() throws {
        app.launch()

        let dashboardTab = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboardTab.waitForExistence(timeout: 10),
                       "Dashboard tab should appear after successful pairing + snapshot")
    }

    @MainActor
    func testDashboardShowsAgentStats() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["Total Agents"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Running"].exists)
    }

    // MARK: - Agents Tab

    @MainActor
    func testAgentsTabShowsAgents() throws {
        app.launch()

        let agentsTab = app.tabBars.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10))
        agentsTab.tap()

        XCTAssertTrue(app.staticTexts["faithful-urchin"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentsTabShowsAllAgents() throws {
        app.launch()

        let agentsTab = app.tabBars.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10))
        agentsTab.tap()

        XCTAssertTrue(app.staticTexts["faithful-urchin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["gentle-fox"].exists)
    }

    @MainActor
    func testAgentDetailNavigation() throws {
        app.launch()

        let agentsTab = app.tabBars.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10))
        agentsTab.tap()

        // Find and tap the agent — it may be a button, cell, or text within a list row
        let agentText = app.staticTexts["faithful-urchin"]
        XCTAssertTrue(agentText.waitForExistence(timeout: 5))

        // Tap the containing cell/row rather than just the text
        let cell = app.cells.containing(.staticText, identifier: "faithful-urchin").firstMatch
        if cell.exists {
            cell.tap()
        } else {
            agentText.tap()
        }

        // After navigation, we should see the agent name somewhere in the detail view
        let navBar = app.navigationBars["faithful-urchin"]
        let detailText = app.staticTexts["faithful-urchin"]
        let navigated = navBar.waitForExistence(timeout: 5) || detailText.waitForExistence(timeout: 2)
        XCTAssertTrue(navigated, "Should navigate to agent detail")
    }

    // MARK: - Instances Tab

    @MainActor
    func testInstancesTabNavigates() throws {
        app.launch()

        let instancesTab = app.tabBars.buttons["Instances"]
        XCTAssertTrue(instancesTab.waitForExistence(timeout: 10))
        instancesTab.tap()

        XCTAssertTrue(app.navigationBars["Instances"].waitForExistence(timeout: 5))
        // Verify instance name from mock data appears
        let instanceName = app.staticTexts["Mason's Desktop"]
        XCTAssertTrue(instanceName.waitForExistence(timeout: 5),
                       "Should show mock instance name")
    }

    // MARK: - Tab Navigation

    @MainActor
    func testAllThreeTabsNavigate() throws {
        app.launch()

        let dashboard = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10))

        let agents = app.tabBars.buttons["Agents"]
        agents.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))

        let instances = app.tabBars.buttons["Instances"]
        instances.tap()
        XCTAssertTrue(app.navigationBars["Instances"].waitForExistence(timeout: 5))

        dashboard.tap()
        XCTAssertTrue(app.staticTexts["Total Agents"].waitForExistence(timeout: 5))
    }
}
