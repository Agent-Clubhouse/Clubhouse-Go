import XCTest

/// Uses the integration owner's loopback-only, memory-only production Annex
/// service with a scripted CLI. It never discovers or controls user instances.
@MainActor final class CompanionPhoneWorkflowTests: XCTestCase {
    func testWakeImageFilePreviewAndFeedbackSettings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_LIVE_SMOKE"] == "1", "Requires the isolated phone fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_MANUAL_SMOKE"] == "1" {
            XCTAssertTrue(app.navigationBars["Pair a desktop"].waitForExistence(timeout: 60))
            let pair = app.navigationBars["Pair a desktop"].buttons["Pair"]
            XCTAssertFalse(pair.isEnabled, "A fixture address and PIN must not grant trust automatically")
            let inspect = app.buttons["Inspect desktop"]
            if !inspect.isHittable { app.swipeUp() }
            inspect.tap()
            let certificate = app.textViews["TLS certificate fingerprint (SHA-256)"]
            expectation(for: NSPredicate(format: "value != %@ AND value != %@", "", "TLS certificate fingerprint (SHA-256)"), evaluatedWith: certificate)
            waitForExpectations(timeout: 15)
            let trust = app.switches["These fingerprints match my desktop"]
            if !trust.isHittable { app.swipeUp() }
            trust.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: pair)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(pair.isEnabled)
            pair.tap()
        }
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_fixture")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60))
        agent.tap()
        let wake = app.buttons["companion-wake"]
        XCTAssertTrue(wake.waitForExistence(timeout: 15), "Desktop must explicitly authorize waking the sleeping durable")
        XCTAssertTrue(wake.isEnabled)
        wake.tap()
        let send = app.buttons["companion-send"]
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap(); composer.typeText("media")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 15)
        send.tap()
        let image = app.buttons["View image"]
        XCTAssertTrue(image.waitForExistence(timeout: 20), "The production runtime must preserve its stored image reference")
        if !image.isHittable { app.swipeDown() }
        image.tap()
        XCTAssertTrue(app.buttons["Copy image"].waitForExistence(timeout: 15), "Pinned Annex bytes must decode into a native image")
        let imageShot = XCTAttachment(screenshot: app.screenshot()); imageShot.name = "Authenticated experimental image preview"; imageShot.lifetime = .keepAlways; add(imageShot)
        app.buttons["Done"].tap()
        let file = app.buttons["src/phone-preview.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        if !file.isHittable { app.swipeUp() }
        file.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PHONE_PREVIEW_CONFIRMED")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Copy preview"].exists)
        let textShot = XCTAttachment(screenshot: app.screenshot()); textShot.name = "Authenticated bounded local file preview"; textShot.lifetime = .keepAlways; add(textShot)
        app.buttons["Done"].tap()
        if !app.buttons["Settings"].isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.buttons["Settings"].tap()
        let feedback = app.staticTexts["Feedback is not configured for this build or local storage is unavailable."]
        for _ in 0..<5 where !feedback.isHittable { app.swipeUp() }
        XCTAssertTrue(feedback.exists, "Unconfigured Framebriar must remain inactive and explain its status")
        let feedbackShot = XCTAttachment(screenshot: app.screenshot()); feedbackShot.name = "Feedback remains opt-in and unconfigured"; feedbackShot.lifetime = .keepAlways; add(feedbackShot)
    }
}
