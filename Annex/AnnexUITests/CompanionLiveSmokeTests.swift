import XCTest

/// Integration owner launches the app with a memory-only verified invitation
/// while this test waits. No PIN or pairing credential enters the test bundle.
@MainActor
final class CompanionLiveSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_LIVE_SMOKE"] == "1",
                          "Requires the isolated memory-only Annex fixture harness")
    }

    func testPinnedSessionPairingAndFixtureChatRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-durable_sprint_fixture")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 60), "Launch the isolated app with its verified memory-only invitation")
        fixture.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("hello")
        let send = app.buttons["companion-send"]
        XCTAssertTrue(send.isEnabled, "Verified host and live chat capabilities must enable send")
        send.tap()
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 20), "The real desktop runtime must stream the scripted CLI response back to iOS")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pinned TLS session pairing and fixture chat"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        composer.tap()
        composer.typeText("tool")
        send.tap()
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 15), "Desktop pending permission must render offered option IDs")
        if ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_QUEUE_SMOKE"] == "1" {
            composer.tap()
            composer.typeText("cancel this queued follow-up")
            send.tap()
            let remove = app.buttons["Remove from queue"]
            XCTAssertTrue(remove.waitForExistence(timeout: 15), "Authoritative pending queue IDs must expose removal")
            remove.tap()
            XCTAssertTrue(app.staticTexts["Removed from queue"].waitForExistence(timeout: 15), "Desktop queue removal must be acknowledged before resolving the active turn")
            let queueScreenshot = XCTAttachment(screenshot: app.screenshot())
            queueScreenshot.name = "Authoritative follow-up removed while approval waits"
            queueScreenshot.lifetime = .keepAlways
            add(queueScreenshot)
        }
        if !deny.isHittable { app.swipeDown() }
        deny.tap()
        let denied = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "denied:")).firstMatch
        XCTAssertTrue(denied.waitForExistence(timeout: 15), "Denial must reach the scripted desktop CLI")

        composer.tap()
        composer.typeText("ask")
        send.tap()
        let sqlite = app.buttons["SQLite"]
        XCTAssertTrue(sqlite.waitForExistence(timeout: 15), "Structured question options must arrive from desktop")
        if !sqlite.isHittable { app.swipeUp() }
        sqlite.tap()
        let answers = app.buttons["Send answers"]
        if !answers.isHittable { app.swipeUp() }
        answers.tap()
        let answered = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "answers:", "SQLite")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 15), "The selected answer must reach the desktop CLI")
        let richScreenshot = XCTAttachment(screenshot: app.screenshot())
        richScreenshot.name = "Live permission and structured question"
        richScreenshot.lifetime = .keepAlways
        add(richScreenshot)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("tool")
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let reconnected = app.buttons["Deny"]
        XCTAssertTrue(reconnected.waitForExistence(timeout: 20), "Foreground reconnection must receive a fresh streamed tool request")
        reconnected.tap()
        XCTAssertTrue(denied.waitForExistence(timeout: 15))

        app.buttons["Conversation actions"].tap()
        app.buttons["Conversation archive"].tap()
        XCTAssertTrue(app.navigationBars["Conversation archive"].waitForExistence(timeout: 10))
        let archivedHello = app.staticTexts["hello"].firstMatch
        XCTAssertTrue(archivedHello.waitForExistence(timeout: 15), "The desktop must list the recorded fixture session")
        guard let visibleSession = app.staticTexts.matching(identifier: "hello").allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("A recorded fixture session must be visible in the archive sheet"); return
        }
        visibleSession.tap()
        XCTAssertTrue(app.navigationBars["hello"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Approval recorded in this session"].waitForExistence(timeout: 15))
        XCTAssertTrue(answered.waitForExistence(timeout: 15), "Archived history must contain the actual structured answer round trip")
        let archiveScreenshot = XCTAttachment(screenshot: app.screenshot())
        archiveScreenshot.name = "Live archived fixture transcript"
        archiveScreenshot.lifetime = .keepAlways
        add(archiveScreenshot)
        app.navigationBars["hello"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        if !app.buttons["Settings"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["Settings"].tap()
        app.descendants(matching: .any).matching(identifier: "Connection details").firstMatch.tap()
        let endSession = app.buttons["End session pairing"].firstMatch
        XCTAssertTrue(endSession.waitForExistence(timeout: 10), "Desktop capability must advertise scoped session revocation")
        endSession.tap()
        XCTAssertTrue(app.staticTexts["End this session pairing?"].waitForExistence(timeout: 5),
                      "The scoped-revoke action must present its own confirmation")
        XCTAssertFalse(app.buttons["Forget desktop"].exists,
                       "Tapping revoke must not also activate a sibling List-row action")
        let confirmations = app.buttons.matching(identifier: "End session pairing")
        guard let confirmation = confirmations.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The visible confirmation must be tappable"); return
        }
        confirmation.tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: app.staticTexts["Sprint Fixture Desktop"])
        waitForExpectations(timeout: 15)
        let revokedScreenshot = XCTAttachment(screenshot: app.screenshot())
        revokedScreenshot.name = "Session pairing revoked on desktop and removed locally"
        revokedScreenshot.lifetime = .keepAlways
        add(revokedScreenshot)
    }
}
