import XCTest

/// Actual row/Details interaction and deduplication; service call counts live in hosted integration tests.
@MainActor final class CompanionRecoveryIntegrationUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func fixture(_ app: XCUIApplication, _ action: String) {
        let button = app.buttons["recovery-fixture-\(action)"]
        waitAndTap(app.buttons["recovery-fixture-menu"], until: button)
        waitAndTap(button, untilGone: button)
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-recovery-fixture"] + extra)
    }
    private func assertNoLargeRecovery(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["Loading conversation…"].exists)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].exists)
        XCTAssertFalse(element(app, "companion-empty-conversation").exists)
    }
    private func capture(_ app: XCUIApplication, _ state: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recovery synthetic \(Int(app.frame.width))pt — \(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstLoadProgressFailureDetailsRetryAndRecovery() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Refreshing conversation…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Refreshing conversation…")).count, 1)
        XCTAssertFalse(app.buttons["companion-recovery-retry"].exists)
        assertNoLargeRecovery(app)
        capture(app, "compact first-load progress")
        fixture(app, "fail")
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        assertNoLargeRecovery(app)
        capture(app, "history failure")
        fixture(app, "next-success")
        let details = app.buttons["companion-recovery-details"]
        XCTAssertGreaterThanOrEqual(details.frame.width, 44)
        XCTAssertGreaterThanOrEqual(details.frame.height, 44)
        waitAndTap(details, until: element(app, "companion-recovery-explanation"))
        let explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic history failure.\nThe response was incomplete.\nNo real desktop was contacted."))
        XCTAssertTrue(explanation.label.contains("Target: alpha on recovery-one."))
        capture(app, "full failure Details")
        let retry = app.buttons["companion-recovery-detail-retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        waitAndTap(retry, untilGone: explanation)
        XCTAssertTrue(details.waitForNonExistence(timeout: 5), "Clean connected history success removes recovery")
        XCTAssertTrue(app.buttons["Read earlier messages in archive"].exists)
        XCTAssertTrue(element(app, "companion-composer").isHittable)
        capture(app, "recovered transcript")
    }

    func testLargeTextKeepsFullErrorsSeparateWarningAndTargetDetailsReachable() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons["companion-recovery-details"].waitForExistence(timeout: 10))
        fixture(app, "fail")
        fixture(app, "operation")
        fixture(app, "connection-failure")
        XCTAssertTrue(app.staticTexts["Connection issue"].waitForExistence(timeout: 5))
        let warning = app.staticTexts["Synthetic operation warning stays separate."]
        XCTAssertTrue(warning.exists)
        let retry = app.buttons["companion-recovery-retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        capture(app, "AX warning and connection retry")
        retry.tap() // Synthetic reconnect records intent; no invented connection success follows.
        XCTAssertTrue(app.staticTexts["Connection issue"].exists)
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"))
        var explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic connection failure."))
        XCTAssertTrue(explanation.label.contains("Synthetic history failure."))
        capture(app, "AX full connection and history Details")
        waitAndTap(app.navigationBars.buttons["Done"], untilGone: explanation)
        fixture(app, "progress")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(warning.exists, "Operation warnings remain separate during automatic recovery")
        assertNoLargeRecovery(app)
        fixture(app, "select-gamma")
        XCTAssertTrue(app.navigationBars["Gamma"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"))
        explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Target: gamma on recovery-two."))
        XCTAssertFalse(explanation.label.contains("Target: alpha"))
    }
}
