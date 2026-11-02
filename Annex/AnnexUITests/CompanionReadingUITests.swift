import XCTest

@MainActor final class CompanionReadingUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openRiver(_ app: XCUIApplication) {
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch
        if home.exists && !home.isSelected { home.tap() }
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-composer"))
    }
    private func marker(_ app: XCUIApplication, _ number: Int) -> XCUIElement { app.staticTexts["Reading marker \(number)."] }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func openSoftwareKeyboard(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        // An iPad can focus the field with only the compact input palette.
        // This geometry test needs the software keyboard's actual height.
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    }


    func testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream"], allowance: 360)
        openRiver(app)
        let latest = app.buttons["Latest"]
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5), "Opening at the latest hides the indicator")
        XCTAssertLessThan(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading marker '")).count, 40, "The reading fixture uses a small window")
        let earlier = app.buttons["companion-show-earlier"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
        let composer = element(app, "companion-composer")
        let header = element(app, "companion-chat-header")
        // This test prepares a reading position by dragging. Native status-bar
        // scrolling under a stream is covered separately by #252.
        for _ in 0..<8 {
            checkTimeLeft("moving to the earlier-history control")
            if earlier.isHittable && earlier.frame.minY >= header.frame.maxY && earlier.frame.maxY <= composer.frame.minY { break }
            let top = header.frame.maxY + 20
            let bottom = composer.frame.minY - 40
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: top + 20))
            let distance = min(420, bottom - top - 40)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(earlier.isHittable)
        XCTAssertGreaterThanOrEqual(earlier.frame.minY, header.frame.maxY)
        XCTAssertLessThanOrEqual(earlier.frame.maxY, composer.frame.minY)
        let visibleMarkers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading marker '")).allElementsBoundByIndex
        guard let candidate = visibleMarkers.first(where: { $0.frame.minY > 150 && $0.frame.maxY < 500 }) else {
            XCTFail("A reading entry must intersect the viewport"); return
        }
        // A bound-by-index query changes identity when history is prepended. Re-query the same marker by label.
        let anchor = app.staticTexts[candidate.label]
        let before = anchor.frame.minY
        earlier.tap()
        XCTAssertTrue(waitFor(anchor, NSPredicate(format: "exists == true"), timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 4, "Prepending history preserves the visible entry's pixel offset")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 4, "Streaming later content must not pull the reader down")

        openSoftwareKeyboard(composer, in: app)
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 6, "Opening the keyboard keeps the reading anchor")
        let returned = anchor.frame.minY
        // This base hides the tab bar inside a chat; #211 supplies direct tab switching separately.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // iPad exposes these as top buttons outside a UITabBar.
        app.buttons.matching(NSPredicate(format: "label == %@", "Agents")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch.tap()
        openRiver(app)
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        XCTAssertEqual(anchor.frame.minY, returned, accuracy: 6, "Tab return preserves the reader's place")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        openRiver(app)
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        XCTAssertEqual(anchor.frame.minY, returned, accuracy: 6, "Leaving and reopening restores the entry bookmark")
        waitAndTap(latest, untilGone: latest, timeout: 10)
        XCTAssertFalse(latest.exists, "Returning to the true bottom resumes following")
        openSoftwareKeyboard(composer, in: app)
        XCTAssertFalse(latest.exists, "Keyboard and safe area changes at the bottom cannot leave a stale indicator")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reading controls above the composer"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLatestClearsAfterTinyUpScrollBounceAndKeyboardLayout() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading"])
        openRiver(app)
        let latest = app.buttons["Latest"]
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5))
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: 24)), withVelocity: XCUIGestureVelocity(rawValue: 40), thenHoldForDuration: 0.1)
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "A real tiny upscroll pauses following, even near the bottom")
        screenshot(app, "Latest offered after a slow tiny upscroll")
        // A paused reader may remain inside the 16pt near-bottom band. A downward return/bounce must clear it.
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -40)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5), "Returning to bottom clears Latest")
        openSoftwareKeyboard(element(app, "companion-composer"), in: app)
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5), "Keyboard resizing at bottom cannot latch Latest")
        screenshot(app, "Latest hidden at the actual bottom with keyboard open")
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
        screenshot(app, "Failed tool status remains visible with folded output")
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
        screenshot(app, "Routine helper traffic collapsed")
        tapToExpand(group)
        XCTAssertEqual(part.label, "Dispatcher: Finish the reconnect fix and open a PR. Report back when it's in review.")
        XCTAssertTrue(bringTranscriptRowIntoView(part, in: app))
        screenshot(app, "Routine helper traffic expanded with sender boundaries")
        XCTAssertTrue(bringTranscriptRowIntoView(group, in: app))
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
