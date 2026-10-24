import XCTest

/// Opt-in real-provider test. An owned harness supplies an ephemeral verified invitation.
@MainActor
final class CompanionAdditionalProviderTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_ADDITIONAL_PROVIDER_SMOKE"] == "1",
                          "Requires an isolated Claude or Copilot provider runtime with existing login")
    }

    private func scrollToLatest(_ app: XCUIApplication) {
        let latest = app.buttons["Latest"]
        guard latest.exists else { return }
        let frame = latest.frame
        guard !frame.isEmpty, app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
        // During streaming SwiftUI can invalidate the AX activation point even
        // though the visible button frame remains valid. Tap its observed center.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    func testProviderWakeResponseFollowUpReconnectAndFilePreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_provider")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60))
        agent.tap()
        if ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_STARTS_ASLEEP"] == "1" {
            let wake = app.buttons["companion-wake"]
            XCTAssertTrue(wake.waitForExistence(timeout: 20))
            wake.tap()
        }
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let send = app.buttons["companion-send"]
        func message(_ text: String, response: String) {
            composer.tap()
            composer.typeText(text)
            let enabled = NSPredicate(format: "enabled == true")
            expectation(for: enabled, evaluatedWith: send)
            waitForExpectations(timeout: 20)
            send.tap()
            XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 120), "A real provider answer must arrive through the desktop and mobile transport")
        }
        message("No tools. Reply exactly: Mobile provider connection verified.", response: "Mobile provider connection verified.")
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "Real provider response through pinned Annex"
        first.lifetime = .keepAlways
        add(first)
        message("No tools. As a follow-up, reply exactly: Mobile follow-up verified.", response: "Mobile follow-up verified.")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        message("No tools. After reconnect, reply exactly: Mobile reconnect verified.", response: "Mobile reconnect verified.")
        composer.tap()
        composer.typeText("No tools. Reply exactly: Preview `src/mobile-preview.txt` and `src/mobile-preview.png`")
        send.tap()
        let file = app.buttons["src/mobile-preview.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 120))
        if !file.isHittable { app.swipeUp() }
        file.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "MOBILE_PROVIDER_PREVIEW")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        let picture = app.buttons["src/mobile-preview.png"]
        XCTAssertTrue(picture.waitForExistence(timeout: 15))
        if !picture.isHittable { app.swipeUp() }; picture.tap()
        XCTAssertTrue(app.buttons["Copy image"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        let final = XCTAttachment(screenshot: app.screenshot())
        final.name = "Real provider follow-up and foreground reconnect"
        final.lifetime = .keepAlways
        add(final)
    }

    func testProviderActiveGenerationControl() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_provider")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60))
        agent.tap()
        if ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_STARTS_ASLEEP"] == "1" {
            let wake = app.buttons["companion-wake"]
            XCTAssertTrue(wake.waitForExistence(timeout: 20))
            wake.tap()
        }
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let send = app.buttons["companion-send"]
        composer.tap()
        composer.typeText("No tools. Write 500 lines. Each line must be Stream check N, with N from 1 to 500. Output all lines.")
        send.tap()
        let streaming = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "Stream check ", "No tools.")).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 120), "Actual provider output must begin before attempting to steer")
        let interrupt = app.buttons["Interrupt"]
        XCTAssertTrue(interrupt.exists, "The provider must still be generating")
        composer.tap()
        let expected = ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_CLIENT_QUEUE"] == "1" ? "Mobile queued follow-up verified." : "Mobile in-flight steering verified."
        composer.typeText("Stop the list now and reply exactly: " + expected)
        XCTAssertTrue(interrupt.exists, "A completed-turn follow-up does not establish in-flight steering")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        scrollToLatest(app)
        if ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_CLIENT_QUEUE"] == "1" {
            let queued = app.staticTexts["Queued for the next turn"]
            XCTAssertTrue(queued.waitForExistence(timeout: 15), "ACP must truthfully queue while a turn is running")
            interrupt.tap()
            let confirm = app.buttons.matching(identifier: "Interrupt turn").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(confirm)
            confirm?.tap()
        }
        let changed = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@ AND NOT label BEGINSWITH %@", expected, "Stop the list")).firstMatch
        // Long streaming messages may leave the user scrolled above the latest
        // reply. Inspect provider events separately to distinguish a same-turn
        // steer from Claude's next-boundary delivery or ACP's queued follow-up.
        for _ in 0..<90 {
            if changed.waitForExistence(timeout: 1) { break }
            scrollToLatest(app)
        }
        XCTAssertTrue(changed.exists, "The real provider must eventually apply the new direction")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_CLIENT_QUEUE"] == "1" ? "Copilot queued follow-up after interruption" : "Claude active-generation steering"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClaudeStructuredQuestionAndApprovalDenial() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_INTERACTIONS"] == "1", "Requires the isolated Claude interaction fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_provider")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60)); agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let send = app.buttons["companion-send"]
        composer.tap()
        composer.typeText("Use AskUserQuestion to ask: Which demo color? Offer Blue and Green. After the answer reply exactly: Mobile question verified.")
        send.tap()
        let blue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Blue")).firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout: 90))
        if !blue.isHittable { app.swipeDown() }; blue.tap()
        let answer = app.buttons["Send answers"]
        if !answer.isHittable { app.swipeUp() }; answer.tap()
        XCTAssertTrue(app.staticTexts["Mobile question verified."].waitForExistence(timeout: 90))
        composer.tap()
        composer.typeText("Request Bash to run printf MOBILE_APPROVAL_TEST. Wait for permission. If denied, do not retry or use another tool; reply exactly: Mobile denial verified.")
        send.tap()
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 90))
        if !deny.isHittable { app.swipeDown() }; deny.tap()
        XCTAssertTrue(app.staticTexts["Mobile denial verified."].waitForExistence(timeout: 90))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Real Claude structured answer and tool denial"
        shot.lifetime = .keepAlways; add(shot)
    }

    func testProviderApprovalDenial() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_INTERACTIONS"] == "1", "Requires the isolated approval fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        let agent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_provider")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 60)); agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("Use the shell tool only to run node -e \"process.stdout.write('MOBILE_APPROVAL_TEST')\". Do not read or write files, use the network or any other tool. Wait for permission. If denied, do not retry; reply exactly: Mobile denial verified.")
        app.buttons["companion-send"].tap()
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 60))
        if !deny.isHittable { app.swipeDown() }; deny.tap()
        if ProcessInfo.processInfo.environment["CLUBHOUSE_PROVIDER_CLIENT_QUEUE"] == "1" {
            // Copilot cancels the operation on denial without another model turn.
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Operation cancelled by user")).firstMatch.waitForExistence(timeout: 60))
        } else {
            XCTAssertTrue(app.staticTexts["Mobile denial verified."].waitForExistence(timeout: 60))
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Real provider tool denial"
        shot.lifetime = .keepAlways; add(shot)
    }

}
