import XCTest

@MainActor final class DiagnosticSettingsTests: XCTestCase {
    /// Exercise the actual settings callbacks and reviewed JSON, including returning from a child sheet.
    /// A local mapper-only test could pass while these controls emitted nothing, or double-counted onAppear.
    func testExplicitDiagnosticsActionsAreCountedOnceWithoutAppearanceEvents() throws {
        continueAfterFailure = false
        let app = launchReadyApplication(arguments: ["--diagnostics-ui-testing"])
        let capture = app.descendants(matching: .any).matching(identifier: "diagnostics.capture").firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        capture.tap()
        app.buttons["This session"].tap()
        // Turning capture on cannot record the preceding tap while capture was off.
        // The real Refresh callback seeds an intent without requiring any desktop or network.
        app.buttons["Refresh"].tap()
        let review = app.buttons["Review diagnostic export"]
        XCTAssertTrue(review.isEnabled)
        review.tap()
        let first = try exportedActions(app)
        XCTAssertEqual(first, ["connectionDiagnostics.refresh": 1, "connectionDiagnostics.openDiagnosticExport": 1])
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
        review.tap()
        let second = try exportedActions(app)
        XCTAssertEqual(second, ["connectionDiagnostics.refresh": 1, "connectionDiagnostics.openDiagnosticExport": 2,
                                "diagnosticsExport.done": 1],
                       "Returning from Review export does not fabricate another Refresh or opening intent")
        app.buttons["Done"].tap()
        capture.tap()
        app.buttons["Off"].tap()
        XCTAssertFalse(review.isEnabled, "Off still clears captured intents")
        app.terminate()
    }

    /// Uses the production AppRoot/Settings sheet, not the standalone diagnostics fixture.
    /// Returning from a NavigationLink must not fabricate a Settings open or a legacy settings event.
    func testRootTabIntentsAndSettingsReturnDoNotRefireOpening() throws {
        continueAfterFailure = false
        let app = launchReadyApplication(arguments: ["--companion-root-ui-testing", "--ui-testing-fast"])
        let settings = app.navigationBars["Settings"]
        let diagnostics = app.navigationBars["Diagnostics"]
        func openSettings() {
            app.buttons["Settings"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
        }
        func openDiagnostics() {
            let link = app.buttons["settings-connection-diagnostics"]
            for _ in 0..<6 {
                if link.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(link.isHittable)
            link.tap()
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        }
        openSettings()
        openDiagnostics()
        let capture = app.descendants(matching: .any).matching(identifier: "diagnostics.capture").firstMatch
        capture.tap()
        app.buttons["This session"].tap()
        app.buttons["Clear captured diagnostics"].tap() // Discard the capture-mode configuration event.
        diagnostics.buttons["Settings"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["settings-close"].tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        for title in ["Search", "Needs you", "Home"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.tap()
            XCTAssertTrue(tab.isSelected)
        }
        openSettings()
        for _ in 0..<2 {
            let name = app.buttons["settings-phone-name"]
            for _ in 0..<4 {
                if name.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(name.isHittable)
            name.tap()
            let child = app.navigationBars["Name on desktops"]
            XCTAssertTrue(child.waitForExistence(timeout: 5))
            child.buttons["Settings"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        openDiagnostics()
        app.buttons["Review diagnostic export"].tap()
        let actions = try exportedActions(app)
        XCTAssertEqual(actions["home.openSettings"], 1, "Only the explicit Settings opening counts")
        XCTAssertEqual(actions["home.searchTab"], 1)
        XCTAssertEqual(actions["search.needsYouTab"], 1)
        XCTAssertEqual(actions["needsYou.homeTab"], 1)
        let records = try exportedRecords(app)
        XCTAssertFalse(records.contains { $0["operation"] as? String == "settings" },
                       "Returning from Settings subpages cannot emit legacy appearance events")
        app.buttons["Done"].tap()
        capture.tap()
        app.buttons["Off"].tap()
        app.terminate()
    }

    private func exportedRecords(_ app: XCUIApplication) throws -> [[String: Any]] {
        let text = app.staticTexts["diagnostics-export-json"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let data = try XCTUnwrap(text.label.data(using: .utf8))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(snapshot["records"] as? [[String: Any]])
    }

    private func exportedActions(_ app: XCUIApplication) throws -> [String: Int] {
        let records = try exportedRecords(app)
        var counts: [String: Int] = [:]
        for record in records where record["operation"] as? String == "uiAction" {
            let action = try XCTUnwrap(record["uiAction"] as? [String: String])
            XCTAssertEqual(Set(action.keys), ["screen", "control"], "Only the closed vocabulary crosses the UI boundary")
            XCTAssertEqual((record["identifiers"] as? [String: String])?.count, 0)
            let key = try XCTUnwrap(action["screen"]) + "." + XCTUnwrap(action["control"])
            counts[key, default: 0] += 1
        }
        return counts
    }

    func testCaptureDefaultsOffAndExportRequiresReview() {
        continueAfterFailure = false
        let app = launchReadyApplication(arguments: ["--diagnostics-ui-testing"])
        let capture = app.descendants(matching: .any).matching(identifier: "diagnostics.capture").firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Off"].exists)
        XCTAssertTrue(app.staticTexts["Remote export disabled"].exists)
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        app.buttons["This session"].tap()
        app.buttons["Review diagnostic export"].tap()
        XCTAssertTrue(app.navigationBars["Review export"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Clear captured diagnostics"].tap()
        XCTAssertFalse(app.buttons["Review diagnostic export"].isEnabled)
        capture.tap()
        app.buttons["Off"].tap()
        app.terminate()
    }
}
