import XCTest

/// Integration tests that launch a mock Annex server and verify the app
/// can pair, connect, and receive data through the real networking stack.
final class IntegrationTests: XCTestCase {

    var server: MockAnnexServer!
    var app: XCUIApplication!
    var ports: (pairingPort: UInt16, mainPort: UInt16)!

    override func setUpWithError() throws {
        continueAfterFailure = false

        server = MockAnnexServer()
        ports = try server.start()

        XCTAssertTrue(ports.pairingPort > 0, "Pairing port should be assigned")
        XCTAssertTrue(ports.mainPort > 0, "Main port should be assigned")

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        server.stop()
    }

    // MARK: - Pairing Tests

    @MainActor
    func testAppLaunchesWithTestServer() throws {
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(ports.mainPort):\(ports.pairingPort)",
            "--test-pin", "000000"
        ]
        app.launch()

        // App should skip onboarding and show main navigation
        let dashboard = app.tabBars.buttons["Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10),
                      "Dashboard tab should appear after connecting to test server")
    }

    @MainActor
    func testMockServerServesStatus() throws {
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(ports.mainPort):\(ports.pairingPort)",
            "--test-pin", "000000"
        ]
        app.launch()

        // After pairing + connection, the Clubhouses tab should show "Mock Clubhouse"
        let clubhouses = app.tabBars.buttons["Clubhouses"]
        if clubhouses.waitForExistence(timeout: 10) {
            clubhouses.tap()
            let serverName = app.staticTexts["Mock Clubhouse"]
            XCTAssertTrue(serverName.waitForExistence(timeout: 5),
                          "Should show server name from mock /api/v1/status")
        }
    }

    @MainActor
    func testMockServerDeliversSnapshot() throws {
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(ports.mainPort):\(ports.pairingPort)",
            "--test-pin", "000000"
        ]
        app.launch()

        // After snapshot delivery, Projects tab should show "Mock Project"
        let projects = app.tabBars.buttons["Projects"]
        if projects.waitForExistence(timeout: 10) {
            projects.tap()
            let projectName = app.staticTexts["Mock Project"]
            XCTAssertTrue(projectName.waitForExistence(timeout: 5),
                          "Should show project from mock snapshot")
        }
    }

    @MainActor
    func testMockServerDeliversAgent() throws {
        app.launchArguments = [
            "--test-server", "127.0.0.1:\(ports.mainPort):\(ports.pairingPort)",
            "--test-pin", "000000"
        ]
        app.launch()

        // After snapshot delivery, Agents tab should show "test-agent"
        let agents = app.tabBars.buttons["Agents"]
        if agents.waitForExistence(timeout: 10) {
            agents.tap()
            let agentName = app.staticTexts["test-agent"]
            XCTAssertTrue(agentName.waitForExistence(timeout: 5),
                          "Should show agent from mock snapshot")
        }
    }
}
