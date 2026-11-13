import XCTest
import UIKit

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

    private func transcriptViewport(_ app: XCUIApplication) -> CGRect {
        // The scroll view's AX bounds can stay unchanged as the landscape keyboard
        // moves its content. Measure the unobscured window between the real bars.
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = element(app, "companion-composer-region").frame.minY
        return CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(0, bottom - top))
    }

    private func assertNewestLineVisible(_ app: XCUIApplication, state: String) {
        let end = app.staticTexts["End of the long reply."]
        let viewport = transcriptViewport(app)
        screenshot(app, state)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(state) hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(end.exists)
        XCTAssertTrue(pixelContains(viewport, end.frame), "\(state): newest line \(end.frame) must fit in viewport \(viewport)")
        XCTAssertFalse(app.pausedChatNavigation.exists, "A viewport resize must not pause following")
    }

    func testRotationKeepsNewestLineInsideViewportWhileFollowing() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls",
                             "--companion-preview-context-window", "--companion-preview-long-reply", "--companion-preview-follow-trace"], attempts: 1)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        assertNewestLineVisible(app, state: "Portrait tail")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        assertNewestLineVisible(app, state: "Rotated landscape tail")
        openSoftwareKeyboard(composer, in: app)
        composer.typeText("Rotation draft")
        assertNewestLineVisible(app, state: "Rotated landscape editing tail")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.height > app.frame.width }, timeout: 5))
        assertNewestLineVisible(app, state: "Rotated portrait editing tail")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        assertNewestLineVisible(app, state: "Rotated landscape with keyboard already open")
        XCTAssertEqual(composer.value as? String, "Rotation draft")
    }

    func testRotationPreservesAScrolledUpReader() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"], attempts: 1)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        openRiver(app)
        let viewport = transcriptViewport(app)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + 8, dy: viewport.minY + 40))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: viewport.height / 2)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5))
        // An explicit message jump aligns the entry selected by that reader, avoiding an
        // assertion about text reflow inside the preceding paragraph.
        app.buttons["companion-previous-message"].tap()
        let markers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading marker '")).allElementsBoundByIndex
        guard let candidate = markers.first(where: { pixelContains(transcriptViewport(app), $0.frame) }) else {
            XCTFail("The scrolled-up reader needs a visible marker"); return
        }
        let anchor = app.staticTexts[candidate.label]
        let distance = anchor.frame.minY - transcriptViewport(app).minY
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        screenshot(app, "Scrolled-up reader after landscape rotation")
        XCTAssertTrue(anchor.exists && pixelContains(transcriptViewport(app), anchor.frame))
        XCTAssertEqual(anchor.frame.minY - transcriptViewport(app).minY, distance, accuracy: 4)
        XCTAssertTrue(app.pausedChatNavigation.exists, "Rotation cannot reclaim a reader's viewport")
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


    func testPointerWheelScrollPausesFollowingWhileStreaming() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Pointer events require iPadOS")
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream",
                             "--companion-preview-follow-trace"], attempts: 1)
        openRiver(app)
        let audit = app.scrollViews["companion-transcript"]
        XCTAssertTrue((audit.value as? String)?.hasPrefix("Following: 1; pauses: ") == true)
        audit.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertTrue(waitFor(audit, NSPredicate { _, _ in
            (audit.value as? String)?.hasPrefix("Following: 0; pauses: ") == true
        }, timeout: 5), "An indirect pointer scroll must pause following without a touch pan")
        let replies = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Streaming preview reply."))
        let before = replies.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitFor(audit, NSPredicate { _, _ in
            replies.allElementsBoundByIndex.map(\.label) != before
        }, timeout: 5))
        XCTAssertTrue((audit.value as? String)?.hasPrefix("Following: 0; pauses: ") == true,
                      "Later chunks cannot reclaim a pointer reader's position")
    }

    func testMomentumAfterAShortUpwardPanKeepsFollowingPaused() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream",
                             "--companion-preview-follow-trace"], attempts: 1)
        openRiver(app)
        let audit = app.scrollViews["companion-transcript"]
        XCTAssertTrue((audit.value as? String)?.hasPrefix("Following: 1; pauses: ") == true)
        let viewport = transcriptViewport(app)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.minX + 8, dy: viewport.midY))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 40)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitFor(audit, NSPredicate { _, _ in
            (audit.value as? String)?.contains("decelerated: 1") == true
        }, timeout: 5), "The gesture must actually enter deceleration, not merely perform a held drag")
        XCTAssertTrue((audit.value as? String)?.hasPrefix("Following: 0; pauses: ") == true)
        let replies = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Streaming preview reply."))
        let before = replies.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitFor(audit, NSPredicate { _, _ in
            replies.allElementsBoundByIndex.map(\.label) != before
        }, timeout: 5))
        XCTAssertTrue((audit.value as? String)?.hasPrefix("Following: 0; pauses: ") == true,
                      "Streaming after momentum cannot resume following")
    }

    func testNativeScrollToTopSticksWithAndWithoutStreaming() {
        for streaming in [false, true] {
            let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"] + (streaming ? ["--companion-preview-stream"] : []))
            openRiver(app)
            let earlier = app.buttons["companion-show-earlier"], latest = app.pausedChatNavigation
            XCTAssertTrue(earlier.waitForExistence(timeout: 5))
            XCTAssertFalse(latest.exists)
            let live = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming preview reply.")).firstMatch
            if streaming { XCTAssertTrue(live.waitForExistence(timeout: 5)) }
            let before = streaming ? live.label : ""
            // Exactly one native tap: no drag or second tap can rescue a failed jump.
            tapChatStatusBar(in: app)
            XCTAssertTrue(earlier.wait(for: \.isHittable, toEqual: true, timeout: 5), "Native top must finish (streaming: \(streaming))")
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            let y = earlier.frame.minY
            if streaming {
                XCTAssertTrue(waitFor(live, NSPredicate(format: "label != %@", before), timeout: 5), "The stream must continue while reading")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertTrue(earlier.isHittable, "Later chunks must not pull the reader back down")
            XCTAssertEqual(earlier.frame.minY, y, accuracy: 1)
            XCTAssertTrue(latest.exists)
            screenshot(app, "Native top remains with streaming \(streaming)")
        }
    }

    func testStreamingKeepsFollowingWhenNobodyScrolls() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace", "--companion-preview-stream"])
        // Streaming begins before navigation. Cross the first four-second tool
        // run deliberately: history replacement can discard live-0 on a slow launch.
        RunLoop.current.run(until: Date().addingTimeInterval(4.2))
        openRiver(app)
        let live = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming preview reply.")).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        let activities = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-activity-tool:live-"))
        XCTAssertTrue(activities.firstMatch.waitForExistence(timeout: 5))
        guard let lastActivity = activities.allElementsBoundByIndex.last else {
            XCTFail("The stream must supply a final activity row"); return
        }
        // Keep this identity while its count changes; a bound-by-index query
        // could switch rows when another tool run is appended.
        let activity = app.buttons[lastActivity.identifier]
        let initialHeight = live.frame.height, initialActivity = activity.label
        // The reply must gain height while routine tools update their collapsed
        // summary. No gesture or Latest tap may keep the final row in view.
        XCTAssertTrue(waitFor(live, NSPredicate { _, _ in live.frame.height > initialHeight }, timeout: 15))
        XCTAssertTrue(waitFor(activity, NSPredicate(format: "label != %@", initialActivity), timeout: 5))
        XCTAssertTrue(activity.isHittable)
        XCTAssertGreaterThanOrEqual(activity.frame.minY, element(app, "companion-chat-header").frame.maxY)
        XCTAssertLessThanOrEqual(activity.frame.maxY, element(app, "companion-composer").frame.minY)
        XCTAssertFalse(app.pausedChatNavigation.exists, "Growth without scrolling must keep following")
        screenshot(app, "Streaming continues following with no scroll")
    }

    func testProgrammaticPreviousMessageJumpStaysWhileStreaming() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream", "--companion-preview-long-reply", "--companion-preview-follow-trace"])
        openRiver(app)
        let replies = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming preview reply."))
        XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.pausedChatNavigation.exists)
        let before = replies.allElementsBoundByIndex.map(\.label)
        app.buttons["companion-previous-message"].tap()
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5))
        let first = replies.firstMatch
        XCTAssertTrue(first.isHittable, "The explicit message jump puts its first text slice on screen")
        let y = first.frame.minY
        XCTAssertTrue(waitFor(first, NSPredicate { _, _ in replies.allElementsBoundByIndex.map(\.label) != before }, timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(first.isHittable)
        XCTAssertEqual(first.frame.minY, y, accuracy: 1, "Later chunks cannot undo a programmatic message jump")
        XCTAssertTrue(app.pausedChatNavigation.exists)
        screenshot(app, "Programmatic message jump stays under streaming")
    }

    func testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace", "--companion-preview-stream"], allowance: 360)
        openRiver(app)
        let latest = app.pausedChatNavigation
        XCTAssertTrue(waitFor(latest, NSPredicate(format: "exists == false"), timeout: 5), "Opening at the latest hides the indicator")
        XCTAssertLessThan(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading marker '")).count, 40, "The reading fixture uses a small window")
        let earlier = app.buttons["companion-show-earlier"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
        let composer = element(app, "companion-composer")
        let header = element(app, "companion-chat-header")
        // This test prepares a reading position by dragging. Native status-bar
        // scrolling has its own on/off regression above.
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
        navigateToChatEnd(app)
        XCTAssertFalse(latest.exists, "Returning to the true bottom resumes following")
        openSoftwareKeyboard(composer, in: app)
        XCTAssertFalse(latest.exists, "Keyboard and safe area changes at the bottom cannot leave a stale indicator")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reading controls above the composer"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLatestClearsAfterTinyUpScrollBounceAndKeyboardLayout() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"])
        openRiver(app)
        let latest = app.pausedChatNavigation
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
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"])
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

    func testHelperRepliesAreInlineWhileToolsStayFoldedAndStatusesStayCompact() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-messages"])
        openRiver(app)
        let part = element(app, "companion-routed-helper-report-0")
        XCTAssertTrue(part.waitForExistence(timeout: 10))
        XCTAssertEqual(part.label, "Cedar: The transcript fix is ready for review.")
        XCTAssertFalse(app.buttons["companion-activity-routed:helper-report:0"].exists)
        XCTAssertFalse(app.buttons["companion-routed-helper-report-0"].exists, "A short reply needs no expansion control")
        for id in ["helper-read", "helper-check"] {
            let tools = app.buttons["companion-activity-tool:\(id)"]
            XCTAssertTrue(tools.exists)
            XCTAssertEqual(tools.value as? String, "Collapsed")
            XCTAssertTrue(tools.label.contains("1 tool call"))
            XCTAssertFalse(tools.label.contains("message"))
        }
        let status = element(app, "companion-routed-helper-status-0")
        XCTAssertEqual(status.label, "Clubhouse: A helper has started its task.")
        XCTAssertTrue((status.value as? String ?? "").contains("Steered into the running turn"), "Delivery metadata remains accessible")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Steered into the running turn")).firstMatch.exists, "Clubhouse status has no delivery caption clutter")
        let lifecycle = element(app, "companion-notice-notice:subagent-preview")
        XCTAssertTrue(lifecycle.exists)
        XCTAssertLessThan(status.frame.height, 80, "Status text uses a compact caption, without a message bubble")
        XCTAssertLessThan(lifecycle.frame.height, 30)
        XCTAssertTrue(app.buttons["companion-previous-message"].exists)
        screenshot(app, "Inline helper reply with compact Clubhouse statuses")
    }

    func testDownAtActualBottomDoesNotPauseFollowing() {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"], attempts: 1)
        let down = app.buttons["companion-next-message"]
        let final = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker 18.")).firstMatch
        XCTAssertTrue(waitFor(final, NSPredicate { _, _ in
            final.exists && self.pixelContains(self.transcriptViewport(app), final.frame)
        }, timeout: 10))
        XCTAssertEqual(down.value as? String, "Following latest")
        XCTAssertEqual(down.label, "Latest")
        let y = final.frame.minY
        screenshot(app, "At actual bottom before down")
        down.tap()
        XCTAssertTrue(waitFor(down, NSPredicate(format: "value == %@", "Following latest"), timeout: 5))
        XCTAssertEqual(final.frame.minY, y, accuracy: 1)
        screenshot(app, "At actual bottom after down")
    }

    func testLatestArrivesGeometricallyWithoutAnIncomingUpdate() {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture",
                             "--companion-header-held-tail"], attempts: 1)
        let down = app.buttons["companion-next-message"]
        let final = app.staticTexts["Held final row."]
        XCTAssertTrue(final.waitForExistence(timeout: 10))
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: transcriptViewport(app).midY))
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: 250)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(down, NSPredicate(format: "label == %@", "Latest"), timeout: 5))
        XCTAssertFalse(pixelContains(transcriptViewport(app), final.frame))
        screenshot(app, "Latest before stationary tap")
        down.tap()
        XCTAssertTrue(waitFor(final, NSPredicate { _, _ in
            final.exists && self.pixelContains(self.transcriptViewport(app), final.frame)
        }, timeout: 5), "The tap must bring the entire final row into view before any incoming update")
        XCTAssertEqual(down.value as? String, "Following latest")
        screenshot(app, "Latest immediate stationary arrival")
        waitAndTap(app.buttons["header-fixture-menu"], until: app.buttons["header-fixture-append"], attempts: 1)
        app.buttons["header-fixture-append"].tap()
        let incoming = app.staticTexts["Held incoming tail."]
        XCTAssertTrue(waitFor(incoming, NSPredicate { _, _ in
            incoming.exists && self.pixelContains(self.transcriptViewport(app), incoming.frame)
        }, timeout: 5))
        XCTAssertEqual(down.value as? String, "Following latest")
        screenshot(app, "Latest follows explicitly released update")
    }

    func testLastReplyLabelMatchesTheActualStationaryAction() {
        let app = launchApp(["--companion-preview", "--companion-preview-long-reply",
                             "--companion-preview-follow-trace"], attempts: 1)
        openRiver(app)
        let down = app.buttons["companion-next-message"]
        app.buttons["companion-previous-message"].tap()
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5))
        let start = app.staticTexts["Start of the long reply."]
        XCTAssertTrue(start.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let final = app.staticTexts["Edit Docs/Companion.md"]
        XCTAssertFalse(pixelContains(transcriptViewport(app), final.frame))
        XCTAssertTrue(waitFor(down, NSPredicate(format: "label == %@", "Latest"), timeout: 5),
                      "VoiceOver must announce the same end destination that the tap activates")
        screenshot(app, "Last reply announces Latest before tap")
        down.tap()
        XCTAssertTrue(waitFor(final, NSPredicate { _, _ in
            final.exists && self.pixelContains(self.transcriptViewport(app), final.frame)
        }, timeout: 5))
        screenshot(app, "Last reply Latest action arrives")
    }

    func testLatestIsOneNonoverlappingDownActionAndReachesStreamingTail() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream", "--companion-preview-long-reply",
                             "--companion-preview-follow-trace"], attempts: 1)
        openRiver(app)
        let replies = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming preview reply."))
        let live = replies.firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        let latest = app.pausedChatNavigation
        let down = app.buttons["companion-next-message"]
        let previous = app.buttons["companion-previous-message"]
        app.buttons["companion-previous-message"].tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        previous.tap()
        XCTAssertEqual(down.label, "Next message")
        screenshot(app, "Streaming reader latest controls")
        XCTAssertEqual(app.buttons.matching(identifier: "companion-next-message").count, 1)
        XCTAssertFalse(app.buttons["Latest"].exists, "There is no separate Latest pill beside Next message")
        XCTAssertFalse(previous.frame.intersects(latest.frame), "Latest and previous message have separate hit targets")
        let viewport = CGRect(x: app.frame.minX, y: app.navigationBars.firstMatch.frame.maxY, width: app.frame.width,
                              height: element(app, "companion-composer-region").frame.minY - app.navigationBars.firstMatch.frame.maxY)
        XCTAssertTrue(pixelContains(viewport, latest.frame))
        down.tap()
        XCTAssertTrue(latest.exists, "Next message navigates without reclaiming the reader's viewport")
        for _ in 0..<4 {
            if down.label == "Latest" { break }
            down.tap()
        }
        XCTAssertTrue(waitFor(down, NSPredicate(format: "label == %@", "Latest"), timeout: 5), "In the last reply, down becomes jump-to-end")
        screenshot(app, "Last reply offers one Latest down control")
        down.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5), "Latest reaches the true bottom and resumes following")
        let before = replies.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitFor(live, NSPredicate { _, _ in replies.allElementsBoundByIndex.map(\.label) != before }, timeout: 5))
        let activities = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-activity-tool:live-"))
        guard let last = activities.allElementsBoundByIndex.last else { return XCTFail("Streaming needs a final activity row") }
        XCTAssertTrue(pixelContains(viewport, last.frame), "The complete last row stays above the composer while streaming")
        XCTAssertFalse(latest.exists)
        screenshot(app, "Latest follows the streaming tail")
    }
}
