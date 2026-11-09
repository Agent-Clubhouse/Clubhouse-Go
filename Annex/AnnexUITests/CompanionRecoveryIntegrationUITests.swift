import XCTest

/// Actual row/Details interaction and deduplication; service call counts live in hosted integration tests.
@MainActor final class CompanionRecoveryIntegrationUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    /// Runs one synthetic fixture action from its list sheet.
    private func fixture(_ app: XCUIApplication, _ action: String) {
        let button = app.buttons["recovery-fixture-\(action)"]
        waitAndTap(app.buttons["recovery-fixture-menu"], until: app.buttons["recovery-fixture-fail"], attempts: 1)
        XCTAssertTrue(scrollTo(button, in: app, maxSwipes: 4), "Fixture action \(action) is reachable")
        waitAndTap(button, untilGone: button, attempts: 1)
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-recovery-fixture"] + extra, attempts: 1)
    }
    /// The old full-height loading and failure panels never come back alongside the compact row.
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

    /// Status rows (recovery, and the wrong-machine notice in the same place) start below the floating identity.
    private func assertClearOfHeader(_ text: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let identity = app.buttons["companion-chat-header"].frame
        XCTAssertGreaterThanOrEqual(pixelAligned(text.frame.minY), pixelAligned(identity.maxY),
                                    "\(text.label) is not under the floating header: \(text.frame), header \(identity)", file: file, line: line)
    }

    func testFirstLoadProgressFailureDetailsRetryAndRecovery() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Refreshing conversation…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Refreshing conversation…")).count, 1)
        XCTAssertFalse(app.buttons["companion-recovery-retry"].exists, "Progress offers no retry")
        assertClearOfHeader(app.staticTexts["Refreshing conversation…"], in: app)
        assertNoLargeRecovery(app)
        capture(app, "compact first-load progress")
        fixture(app, "fail")
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["companion-recovery-retry"].label, "Refresh conversation")
        assertNoLargeRecovery(app)
        capture(app, "history failure")
        fixture(app, "next-success")
        let details = app.buttons["companion-recovery-details"]
        assertMinimumTarget(details, "Details")
        assertMinimumTarget(app.buttons["companion-recovery-retry"], "Refresh")
        waitAndTap(details, until: element(app, "companion-recovery-explanation"), attempts: 1)
        let explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic history failure.\nThe response was incomplete.\nNo real desktop was contacted."))
        XCTAssertTrue(explanation.label.contains("Target: alpha on recovery-one."))
        capture(app, "full failure Details")
        let retry = app.buttons["companion-recovery-detail-retry"]
        XCTAssertTrue(scrollTo(retry, in: app, maxSwipes: 3), "Details offers the retry")
        capture(app, "full failure Details retry visible")
        assertMinimumTarget(retry, "Details retry")
        waitAndTap(retry, untilGone: explanation, attempts: 1)
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
        assertClearOfHeader(app.staticTexts["Connection issue"], in: app)
        let warning = app.staticTexts["Synthetic operation warning stays separate."]
        XCTAssertTrue(warning.exists)
        let retry = app.buttons["companion-recovery-retry"]
        XCTAssertEqual(retry.label, "Retry connection")
        XCTAssertTrue(retry.isHittable)
        assertMinimumTarget(retry, "Retry")
        capture(app, "AX warning and connection retry")
        retry.tap() // Synthetic reconnect records intent; no invented connection success follows.
        XCTAssertTrue(app.staticTexts["Connection issue"].exists)
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"), attempts: 1)
        var explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic connection failure."))
        XCTAssertTrue(explanation.label.contains("Synthetic history failure."), "The conversation error survives the connection failure")
        capture(app, "AX full connection and history Details")
        waitAndTap(app.navigationBars.buttons["Done"], untilGone: explanation, attempts: 1)
        fixture(app, "progress")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists, "Automatic recovery offers no retry")
        XCTAssertTrue(warning.exists, "Operation warnings remain separate during automatic recovery")
        assertNoLargeRecovery(app)
        capture(app, "AX reconnecting")
        fixture(app, "select-gamma")
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(app.buttons["companion-chat-header"], NSPredicate(format: "label BEGINSWITH %@", "Gamma"), timeout: 5))
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"), attempts: 1)
        explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Target: gamma on recovery-two."))
        XCTAssertFalse(explanation.label.contains("Target: alpha"))
    }
}
