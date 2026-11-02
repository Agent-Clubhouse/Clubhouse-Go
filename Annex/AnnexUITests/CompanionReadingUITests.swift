import XCTest

@MainActor final class CompanionReadingUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openRiver(_ app: XCUIApplication) {
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-composer"))
    }
    private func marker(_ app: XCUIApplication, _ number: Int) -> XCUIElement { app.staticTexts["Reading marker \(number)."] }

    func testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream"], allowance: 360)
        openRiver(app)
        let latest = app.buttons["Latest"]
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5), "Opening at the latest hides the indicator")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).tap()
        let earlier = app.buttons["companion-show-earlier"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
        XCTAssertTrue(bringTranscriptRowIntoView(earlier, in: app))
        let visibleMarkers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading marker '")).allElementsBoundByIndex
        guard let anchor = visibleMarkers.first(where: { $0.frame.minY > 150 && $0.frame.maxY < 500 }) else {
            XCTFail("A reading entry must intersect the viewport"); return
        }
        let before = anchor.frame.minY
        earlier.tap()
        XCTAssertTrue(waitFor(anchor, NSPredicate(format: "exists == true"), timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 4, "Prepending history preserves the visible entry's pixel offset")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 4, "Streaming later content must not pull the reader down")

        let composer = element(app, "companion-composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 6, "Opening the keyboard keeps the reading anchor")
        app.swipeDown(velocity: .slow)
        let returned = anchor.frame.minY
        app.tabBars.buttons["Agents"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        XCTAssertEqual(anchor.frame.minY, returned, accuracy: 6, "Tab return preserves the reader's place")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        openRiver(app)
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        XCTAssertEqual(anchor.frame.minY, returned, accuracy: 6, "Leaving and reopening restores the entry bookmark")
        waitAndTap(latest, untilGone: latest, timeout: 10)
        XCTAssertFalse(latest.exists, "Returning to the true bottom resumes following")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(latest.exists, "Keyboard and safe area changes at the bottom cannot leave a stale indicator")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reading controls above the composer"; shot.lifetime = .keepAlways; add(shot)
    }

    func testFailedOutputFoldsButErrorStatusStaysVisible() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading"])
        openRiver(app)
        let status = element(app, "companion-tool-status-reading-failure")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Failed (exit 2)")
        XCTAssertTrue(element(app, "companion-subagent-reading-helper").label.contains("Helper activity"), "Streamed helper text has its own identity")
        let output = element(app, "companion-tool-output-reading-failure")
        XCTAssertFalse(output.exists, "A huge failed output starts folded")
        XCTAssertTrue(element(app, "companion-tool-preview-reading-failure").label.contains("Preview error: build failed"))
        let toggle = app.buttons["companion-tool-toggle-reading-failure"]
        XCTAssertTrue(bringTranscriptRowIntoView(toggle, in: app))
        toggle.tap()
        XCTAssertTrue(output.exists)
        toggle.tap()
        XCTAssertFalse(output.exists)
        XCTAssertTrue(status.exists && status.label.contains("Failed"), "The failure remains outside the output fold")
    }

    func testCompactActivityBuildsNoHiddenDetailAndNavigationSkipsIt() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        openRiver(app)
        let group = app.buttons["companion-activity-routed:relay-1:0"]
        XCTAssertTrue(bringTranscriptRowIntoView(group, in: app))
        XCTAssertEqual(group.value as? String, "Collapsed")
        let part = element(app, "companion-routed-relay-1-0")
        XCTAssertFalse(part.exists, "Closed activity constructs no routed content")
        XCTAssertTrue(group.label.contains("2 messages") && group.label.contains("Dispatcher"))
        tapToExpand(group)
        XCTAssertEqual(part.label, "Dispatcher: Finish the reconnect fix and open a PR. Report back when it's in review.")
        group.tap()
        XCTAssertFalse(part.exists)
        let previous = app.buttons["companion-previous-message"]
        let next = app.buttons["companion-next-message"]
        XCTAssertTrue(previous.exists && next.exists, "VoiceOver has named previous/next assistant controls")
        previous.tap()
        XCTAssertFalse(part.exists, "Jumping never opens helper traffic")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Compact activity and message navigation"; shot.lifetime = .keepAlways; add(shot)
    }
}
