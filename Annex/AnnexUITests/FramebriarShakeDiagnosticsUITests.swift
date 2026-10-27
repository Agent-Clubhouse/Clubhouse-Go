import XCTest

/// Covers the shake states the original fixture did not: an unenrolled user and the
/// Companion layout (split view, searchable sidebar, focused composer). `fixture-responder`
/// reports which responder UIKit would hand a real shake to.
final class FramebriarShakeDiagnosticsUITests: ReliableUITestCase {
    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = launchApp(["--framebriar-shake-ui-testing"] + arguments)
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        return app
    }

    /// Root cause: while unenrolled the SDK receiver never takes first responder, so a shake
    /// reached no responder and nothing happened. The app now explains and offers enrollment.
    @MainActor func testUnenrolledShakeExplainsEnrollmentInsteadOfDoingNothing() throws {
        let app = launch(["--framebriar-shake-unenrolled"])
        let shake = app.buttons["fixture-shake"]
        let prompt = app.alerts["Feedback enrollment required"]
        shake.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "Shake while unenrolled must not be silently dropped")
        XCTAssertNotEqual(app.staticTexts["fixture-responder"].label, "Responder: none")
        XCTAssertFalse(app.navigationBars["Send feedback"].exists, "Unenrolled users cannot open the composer")
        prompt.buttons["Set up feedback"].tap()
        XCTAssertTrue(app.navigationBars["Feedback enrollment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["Invitation"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))

        // The receiver is reclaimed after the enrollment sheet closes.
        shake.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.buttons["Not now"].tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 1))

        // Settings states the requirement next to the toggle.
        waitAndTap(app.buttons["Settings"], until: app.staticTexts["shake-enrollment-required"], timeout: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))

        // Turning shake off from the prompt is honored.
        shake.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.buttons["Turn off shake"].tap()
        XCTAssertTrue(shake.waitForExistence(timeout: 5))
        shake.tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2))
        let toggle = app.switches["Shake to open feedback"]
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 5)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    /// Enrolled shake keeps working across the Companion split view, navigation and keyboard;
    /// it is intentionally suppressed only while the composer holds first responder.
    @MainActor func testCompanionLayoutShakeAcrossNavigationAndComposerFocus() throws {
        let app = launch(["--framebriar-shake-companion-layout"])
        let composer = app.navigationBars["Send feedback"]
        func waitDebounce() { _ = composer.waitForExistence(timeout: 2.5) }
        waitDebounce()
        app.buttons["fixture-shake"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        let shake = app.buttons["Simulate shake in conversation"]
        let responder = app.staticTexts["fixture-detail-responder"]
        waitAndTap(app.buttons["Fixture conversation"], until: shake, timeout: 5)
        waitDebounce()
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Shake after pushing a conversation; responder: \(responder.label)")
        app.buttons["Cancel"].tap()

        waitDebounce()
        app.textFields["Fixture composer"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        shake.tap()
        XCTAssertEqual(responder.label, "Responder: UITextField")
        XCTAssertFalse(composer.waitForExistence(timeout: 2), "Active text input is not displaced by design")

        app.buttons["Dismiss keyboard"].tap()
        waitDebounce()
        shake.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Shake after dismissing the keyboard; responder: \(responder.label)")
        app.buttons["Cancel"].tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 5))
        waitDebounce()
        app.buttons["fixture-shake"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts["Feedback enrollment required"].exists, "Enrolled users never see the enrollment prompt")
    }
}
