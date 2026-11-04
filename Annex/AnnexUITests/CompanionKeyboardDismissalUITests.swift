import XCTest

@MainActor final class CompanionKeyboardDismissalUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func focus(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        // iPad can focus the field with only its compact input palette.
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3)); show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["companion-dismiss-keyboard"].exists,
                       "Keyboard dismissal does not add a navigation-bar control")
    }
    private func transcriptPoint(_ app: XCUIApplication) -> XCUICoordinate {
        let frame = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let top = max(frame.minY, element(app, "companion-chat-header").frame.maxY) + 20
        let bottom = min(frame.maxY, element(app, "companion-composer").frame.minY) - 20
        XCTAssertGreaterThan(bottom - top, 30)
        let point = CGPoint(x: frame.minX + 8, y: top + min(35, (bottom - top) / 2))
        XCTAssertTrue(frame.contains(point))
        XCTAssertFalse(app.keyboards.firstMatch.frame.contains(point))
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }
    private func assertDismissed(_ app: XCUIApplication, draft: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitFor(element(app, "companion-composer"), NSPredicate(format: "value == %@", draft), timeout: 5))
        XCTAssertFalse(element(app, "companion-composer").debugDescription.contains("Keyboard Focused"),
                       "Focus, not just the software keyboard, ends")
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists,
                       "The assistive control is scoped to editing")
    }
    private func dispatcher(_ flags: [String]) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"] + flags, allowance: 360)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        focus(composer, in: app)
        composer.typeText("Keep my Dispatcher draft")
        if app.tabBars.firstMatch.exists {
            XCTAssertFalse(tab(app, "Home").isHittable, "The software keyboard covers iPhone's bottom tabs")
        }
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists, "Sighted editing has no extra control")
        screenshot(app, "Dispatcher keyboard with transcript exit")
        // A single real tap in blank transcript space, with no rescue tap.
        transcriptPoint(app).tap()
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        XCTAssertTrue(tab(app, "Home").isHittable)
        tab(app, "Home").tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        tab(app, "Dispatcher").tap()
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 5))
        assertDismissed(app, draft: "Keep my Dispatcher draft")

        focus(composer, in: app)
        // Also cover the other end of the full-height blank hit area, just above the composer.
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let composerRegion = element(app, "companion-composer-region")
        XCTAssertTrue(composerRegion.exists)
        // The text field's AX frame excludes its outer padding; use the entire bottom bar's bounds.
        let bottom = min(transcript.maxY, composerRegion.frame.minY) - 12
        let point = CGPoint(x: transcript.minX + 8, y: bottom)
        XCTAssertGreaterThan(bottom, element(app, "companion-chat-header").frame.maxY)
        XCTAssertFalse(app.keyboards.firstMatch.frame.contains(point))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        // Native interactive dismissal is a user drag, never a streamed scrollTo.
        focus(composer, in: app)
        let start = transcriptPoint(app)
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        XCTAssertTrue(tab(app, "Home").isHittable)
        screenshot(app, "Dispatcher draft kept and tabs reachable")
    }
    func testEmptyDispatcherCanDismissAndReturnHome() { dispatcher(["--companion-preview-empty-chat"]) }
    func testShortDispatcherCanDismissAndReturnHome() { dispatcher([]) }
    func testLongDispatcherCanDismissAndReturnHome() { dispatcher(["--companion-preview-long-reply"]) }

    func testStreamingInAnOrdinaryChatKeepsEditingUntilTheUserDismisses() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream", "--companion-preview-long-reply", "--companion-preview-follow-trace"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-composer"))
        let replies = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Streaming preview reply."))
        XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(replies.count, 1, "The live fixture must exercise more than one text slice")
        let composer = element(app, "companion-composer")
        focus(composer, in: app); composer.typeText("Keep editing while streaming")
        let before = replies.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitFor(replies.firstMatch, NSPredicate { _, _ in
            replies.allElementsBoundByIndex.map(\.label) != before
        }, timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Programmatic following must never dismiss the keyboard")
        XCTAssertEqual(composer.value as? String, "Keep editing while streaming")
        // Tap real selectable text, rather than the blank gutter used above.
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let viewportTop = max(transcript.minY, element(app, "companion-chat-header").frame.maxY)
        let viewportBottom = min(transcript.maxY, app.buttons["companion-level-menu"].frame.minY)
        let viewport = CGRect(x: transcript.minX, y: viewportTop, width: transcript.width, height: max(0, viewportBottom - viewportTop))
        // The first slice can be offscreen once the reply grows. Choose the
        // largest actually visible text fragment, retaining the real-text tap.
        let live = replies.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.intersects(viewport) }
            .max { $0.frame.intersection(viewport).height < $1.frame.intersection(viewport).height }
        XCTContext.runActivity(named: "Streaming viewport \(viewport), keyboard \(app.keyboards.firstMatch.frame), transcript \(transcript)") { _ in }
        if live == nil { screenshot(app, "Stream viewport missing live text") }
        XCTAssertNotNil(live, "A streamed text fragment must be visible while typing")
        guard let live else { return }
        let band = viewport.intersection(live.frame)
        let top = band.minY + 12
        let bottom = band.maxY - 12
        XCTAssertGreaterThan(bottom, top)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: band.midX, dy: (top + bottom) / 2)).tap()
        assertDismissed(app, draft: "Keep editing while streaming")
        focus(composer, in: app); transcriptPoint(app).tap()
        assertDismissed(app, draft: "Keep editing while streaming")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(river.waitForExistence(timeout: 5))
        waitAndTap(river, until: composer)
        assertDismissed(app, draft: "Keep editing while streaming")
    }
    func testAssistiveDismissControlFitsTheComposerAndKeepsTheSlashWordClosed() {
        // This flag exercises the same button as VoiceOver/Switch Control without changing simulator settings.
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists)
        focus(composer, in: app)
        composer.typeText("/r")
        let menu = element(app, "companion-slash-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let dismiss = app.buttons["companion-dismiss-keyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertEqual(dismiss.label, "Dismiss Keyboard")
        let interrupt = app.buttons["Interrupt"]
        let attach = app.buttons["companion-attach"]
        let send = app.buttons["companion-send"]
        for control in [interrupt, attach, send, dismiss] {
            XCTAssertTrue(control.isHittable, "Every composer control remains reachable: \(control.label)")
            XCTAssertTrue(app.frame.contains(control.frame))
        }
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertGreaterThanOrEqual(composer.frame.width, 100, "Retain a useful text-entry width with every control visible")
        XCTAssertLessThanOrEqual(interrupt.frame.maxX, composer.frame.minX)
        XCTAssertLessThanOrEqual(composer.frame.maxX, send.frame.minX)
        XCTAssertLessThanOrEqual(send.frame.maxX, dismiss.frame.minX)
        XCTContext.runActivity(named: "Assistive row: window \(app.frame), input \(composer.frame), interrupt \(interrupt.frame), attach \(attach.frame), send \(send.frame), dismiss \(dismiss.frame)") { _ in }
        screenshot(app, "Assistive composer row with slash menu")
        dismiss.tap()
        assertDismissed(app, draft: "/r")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        focus(composer, in: app)
        composer.typeText("e")
        XCTAssertFalse(menu.waitForExistence(timeout: 1), "Refocusing keeps the dismissed slash word closed")
        composer.typeText(" /")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "A new slash word opens the menu")
    }

    func testTranscriptCardContentLinkAndCopyStillWorkWhileEditing() {
        let app = launchApp(["--companion-preview", "--companion-preview-keyboard-interactions"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        let group = app.buttons["companion-activity-tool:keyboard-tool"]
        focus(composer, in: app); composer.typeText("Draft beside a file link")
        XCTAssertTrue(group.isHittable)
        group.tap()
        XCTAssertTrue(waitFor(group, NSPredicate(format: "value == %@", "Expanded"), timeout: 5), "Ending editing must not swallow a card's toggle")
        group.tap()
        XCTAssertTrue(waitFor(group, NSPredicate(format: "value == %@", "Collapsed"), timeout: 5))
        focus(composer, in: app)
        let link = app.buttons.matching(identifier: "companion-content-link")
            .matching(NSPredicate(format: "label == %@", "Sources/Companion/Conversation.swift")).firstMatch
        XCTAssertTrue(link.isHittable)
        XCTAssertGreaterThan(link.frame.minY, element(app, "companion-chat-header").frame.maxY)
        XCTAssertLessThan(link.frame.maxY, composer.frame.minY)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["companion-preview-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Ending editing must not swallow the content link")
        done.tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "Draft beside a file link"), timeout: 5))
        // A long press still belongs to the message's selection/context menu.
        focus(composer, in: app)
        // Copy the final message, which remains above the composer on a phone
        // after the keyboard reduces the viewport.
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Open ")).firstMatch
        XCTAssertTrue(message.isHittable)
        message.press(forDuration: 1.2)
        let copy = app.buttons["Copy message"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "Draft beside a file link"), timeout: 5))
    }
}
