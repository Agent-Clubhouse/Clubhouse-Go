import XCTest

@MainActor final class CompanionCompactComposerUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testIdleControlsStayCollapsedBeforeAndAfterTyping() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        assertRow(app, working: false, state: "idle empty unfocused")
        let controls = app.buttons["companion-level-menu"]
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"])
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        XCTAssertTrue(app.buttons["companion-effort-menu"].exists)
        // Dismiss the menu through the field; then type through the actual editor.
        composer.tap()
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        assertRow(app, working: false, state: "idle typed focused")
    }

    func testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation() {
        workingRow(largestText: false)
    }

    func testLargestTextWorkingAttachmentRowFits() {
        workingRow(largestText: true)
    }

    private func workingRow(largestText: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard", "--companion-sample-images"]
                            + (largestText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []))
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        XCTAssertFalse(app.buttons["companion-send"].isEnabled, "An empty draft cannot steer")
        assertRow(app, working: true, state: "working empty unfocused")
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Approval stays pinned")
        waitAndTap(app.buttons["companion-attach"], until: element(app, "companion-attachment-thumbnail"))
        XCTAssertTrue(app.buttons["companion-send"].isEnabled, "An image-only draft can steer")
        assertRow(app, working: true, state: "working image-only unfocused")
        composer.tap()
        composer.typeText("Keep this direction")
        XCTAssertEqual(composer.value as? String, "Keep this direction")
        XCTAssertTrue(app.buttons["companion-send"].isEnabled)
        XCTAssertTrue(app.buttons["companion-dismiss-keyboard"].exists)
        assertRow(app, working: true, state: "working typed focused")
        XCTAssertFalse(app.staticTexts["Your direction will be sent to the running agent."].exists)
        let interrupt = app.buttons["companion-interrupt"]
        waitAndTap(interrupt, until: app.buttons["Interrupt turn"])
        XCTAssertTrue(app.staticTexts["Interrupt this turn?"].exists)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists,
                       "Opening confirmation must not issue a command")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this direction")
        if app.buttons["companion-dismiss-keyboard"].exists { app.buttons["companion-dismiss-keyboard"].tap() }
        assertRow(app, working: true, state: "working typed unfocused")
    }

    private func assertRow(_ app: XCUIApplication, working: Bool, state: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        let controls = app.buttons["companion-level-menu"]
        let send = app.buttons["companion-send"]
        XCTAssertTrue(controls.label.contains("Chat controls"), state, file: file, line: line)
        let buttons = [controls, send] + (working ? [app.buttons["companion-interrupt"]] : [])
        for button in buttons {
            XCTAssertTrue(button.exists, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX, state, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX, state, file: file, line: line)
            XCTAssertEqual(button.frame.midY, send.frame.midY, accuracy: 3, state, file: file, line: line)
        }
        XCTAssertLessThan(controls.frame.maxX, send.frame.minX, state, file: file, line: line)
        if working {
            let interrupt = app.buttons["companion-interrupt"]
            let attach = app.buttons["companion-attach"]
            let composer = element(app, "companion-composer")
            XCTAssertTrue(attach.isHittable, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(attach.frame.width, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(composer.frame.width, 44, "The editor retains usable width: \(state)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(interrupt.frame.minX, composer.frame.maxX - 2, state, file: file, line: line)
            XCTAssertLessThanOrEqual(interrupt.frame.maxX, send.frame.minX, state, file: file, line: line)
            XCTAssertLessThanOrEqual(send.frame.minX - interrupt.frame.maxX, 16, state, file: file, line: line)
            XCTAssertTrue(interrupt.isHittable, state, file: file, line: line)
        } else {
            XCTAssertFalse(app.buttons["companion-interrupt"].exists, state, file: file, line: line)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact composer \(state)"; shot.lifetime = .keepAlways; add(shot)
    }
}
