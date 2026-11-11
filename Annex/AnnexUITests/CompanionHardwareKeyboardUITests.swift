import XCTest

@MainActor final class CompanionHardwareKeyboardUITests: ReliableUITestCase {
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
    }

    func testHardwareReturnInvokesTheGuardedSendPath() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], attempts: 1)
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Hardware Return fixture")
        XCTAssertTrue(app.buttons["companion-send"].isEnabled)
        let refusal = app.staticTexts["Preview only. This action does not contact a desktop."]
        XCTAssertFalse(refusal.exists)
        input.typeKey("\r", modifierFlags: [])
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("XCUI can't inject hardware Return on the iOS 26.0 simulator; see #366", options: options) {
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
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("XCUI can't inject hardware Return on the iOS 26.0 simulator; see #366", options: options) {
            XCTAssertTrue(waitFor(input, NSPredicate(format: "value == %@", "First line\n"), timeout: 5))
            input.typeText("Second line")
            XCTAssertEqual(input.value as? String, "First line\nSecond line")
        }
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        XCTAssertTrue(input.debugDescription.contains("Keyboard Focused"))
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
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        XCTAssertTrue(input.debugDescription.contains("Keyboard Focused"))
    }
}
