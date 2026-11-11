import XCTest

@MainActor final class CompanionHardwareKeyboardUITests: ReliableUITestCase {
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
    }

    private func sendRefusal(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "companion-operation-error").firstMatch
    }

    private func expectUnavailableHardwareReturn(_ assertion: () -> Void) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        XCTExpectFailure("XCUI can't inject hardware Return on the iOS 26.0 simulator; see #366", options: options, failingBlock: assertion)
    }

    func testSendButtonExposesTheSendRefusalSentinel() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], attempts: 1)
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Send sentinel control")
        XCTAssertFalse(sendRefusal(app).exists)
        app.buttons["companion-send"].tap()
        XCTAssertTrue(sendRefusal(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].exists)
    }

    func testHardwareReturnInvokesTheGuardedSendPath() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], attempts: 1)
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Hardware Return fixture")
        XCTAssertTrue(app.buttons["companion-send"].isEnabled)
        let refusal = sendRefusal(app)
        XCTAssertFalse(refusal.exists)
        input.typeKey("\r", modifierFlags: [])
        expectUnavailableHardwareReturn {
            XCTAssertTrue(refusal.waitForExistence(timeout: 5), "Real hardware Return must invoke the same preview refusal as Send")
        }
        XCTAssertEqual(input.value as? String, "Hardware Return fixture", "A refused Dispatcher send restores the draft")
        XCTAssertTrue(input.debugDescription.contains("Keyboard Focused"))
    }

    func testHardwareShiftReturnInsertsANewlineWithoutSending() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], attempts: 1)
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("First line")
        input.typeKey("\r", modifierFlags: .shift)
        expectUnavailableHardwareReturn {
            XCTAssertTrue(waitFor(input, NSPredicate(format: "value == %@", "First line\n"), timeout: 5))
        }
        let beforeTyping = input.value as? String
        XCTAssertTrue(beforeTyping == "First line" || beforeTyping == "First line\n",
                      "Only the unavailable injected newline may differ; the original draft must be preserved")
        input.typeText("Second line")
        XCTAssertEqual(input.value as? String, beforeTyping.map { $0 + "Second line" })
        XCTAssertTrue(input.debugDescription.contains("Keyboard Focused"))
        XCTAssertFalse(sendRefusal(app).exists)
    }

    func testOnScreenReturnStillInsertsANewline() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], attempts: 1)
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("On-screen first line")
        let returnKey = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "return")).firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5))
        returnKey.tap()
        input.typeText("Second line")
        XCTAssertEqual(input.value as? String, "On-screen first line\nSecond line")
        XCTAssertFalse(sendRefusal(app).exists)
        XCTAssertTrue(input.debugDescription.contains("Keyboard Focused"))
    }
}
