import XCTest

/// A decision probe, not rollout evidence: native labels/traits/default actions and callback cardinality.
@MainActor final class CompanionNativeActionSpikeUITests: ReliableUITestCase {
    private func launch() -> XCUIApplication {
        launchApp(["--native-action-hook-spike"], attempts: 1)
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func sameAX(_ candidate: XCUIElement, _ baseline: XCUIElement) {
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        XCTAssertTrue(baseline.exists)
        XCTAssertEqual(candidate.elementType, baseline.elementType)
        XCTAssertEqual(candidate.label, baseline.label)
        XCTAssertEqual(candidate.isEnabled, baseline.isEnabled)
        XCTAssertTrue(candidate.isHittable && baseline.isHittable)
        XCTAssertEqual(candidate.frame.height, baseline.frame.height, accuracy: 1)
    }
    private func assertCounts(_ app: XCUIApplication, _ value: String) {
        XCTAssertEqual(element(app, "native-hook-counts").label, value)
    }
    func testMenuKeepsNativeActivationAndRecordsOnlyTheOpening() {
        let app = launch()
        let native = element(app, "native-menu"), candidate = element(app, "candidate-menu")
        sameAX(candidate, native)
        native.tap()
        XCTAssertTrue(app.buttons["Choose item"].waitForExistence(timeout: 5))
        app.buttons["Choose item"].tap()
        assertCounts(app, "Menu: 0 · Link: 0 · Item: 1")
        candidate.tap()
        XCTAssertTrue(app.buttons["Choose item"].waitForExistence(timeout: 5), "The candidate must still open the native menu")
        app.buttons["Choose item"].tap()
        assertCounts(app, "Menu: 1 · Link: 0 · Item: 2")
        candidate.tap()
        XCTAssertTrue(app.buttons["Choose item"].waitForExistence(timeout: 5))
        app.buttons["Choose item"].tap()
        assertCounts(app, "Menu: 2 · Link: 0 · Item: 3")
        XCTAssertFalse(element(app, "candidate-disabled").isEnabled)
    }
    func testNavigationLinkKeepsNativePushBackAndOneActionPerActivation() {
        let app = launch()
        let native = element(app, "native-link"), candidate = element(app, "candidate-link")
        sameAX(candidate, native)
        native.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        app.navigationBars["Details"].buttons.firstMatch.tap()
        assertCounts(app, "Menu: 0 · Link: 0 · Item: 0")
        for expected in 1...2 {
            candidate.tap()
            XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), "The style must trigger the original native Link action")
            app.navigationBars["Details"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Native hook spike"].waitForExistence(timeout: 5))
            assertCounts(app, "Menu: 0 · Link: \(expected) · Item: 0")
        }
        XCTAssertFalse(element(app, "candidate-disabled").isEnabled)
    }
}
