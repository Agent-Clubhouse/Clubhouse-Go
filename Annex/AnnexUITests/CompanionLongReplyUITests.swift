import XCTest

/// A reply of about 10,000 words with large blocks in it (#188). One row that tall kept the conversation's lazy stack
/// re-estimating its layout as you scrolled past it, and the main thread stalled. Scrolling to the top and back must
/// stay quick, round after round, and the conversation must still respond afterwards.
@MainActor
final class CompanionLongReplyUITests: ReliableUITestCase {
    /// Each round trip, top and back, on a loaded CI runner. A stalled main thread blows through it.
    private static let roundTripLimit: TimeInterval = 75

    private func openRiver(_ app: XCUIApplication) {
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app)
        XCTAssertTrue(scrollTo(agent, in: app), "River's row must be on screen")
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(agent, until: composer, timeout: 15, "Selecting an agent must open its conversation")
    }

    /// Scrolls the conversation until `target` is on screen, between the navigation bar and the composer. Up, it flings
    /// with momentum, through the whole reply; down, it drags without momentum, so it stops at `target`.
    private func fling(to target: XCUIElement, up: Bool, in app: XCUIApplication, maxFlings: Int = 40, _ message: String) {
        let window = app.windows.firstMatch.frame
        func visible() -> Bool { target.exists && target.frame.minY > window.height * 0.1 && target.frame.maxY < window.height * 0.85 }
        for attempt in 0..<maxFlings {
            if visible() {
                XCTContext.runActivity(named: "Reached after \(attempt) gestures") { _ in }
                break
            }
            checkTimeLeft(message)
            if up && attempt % 4 == 0 {
                // A tap on the status bar scrolls to the top without dragging, which must still stop following.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            } else if up {
                app.swipeDown(velocity: .fast)
            } else {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -window.height * 0.4)), withVelocity: .fast,
                           thenHoldForDuration: 0.1)
            }
        }
        if !visible() {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Not reached: \(message)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(visible(), target.exists ? "\(message) (at \(target.frame))" : message)
    }

    func testLongReplyScrollsToTheTopAndBackWithoutStalling() {
        let app = launchApp(["--companion-preview", "--companion-preview-long-reply"], allowance: 600)
        openRiver(app)
        let top = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Preview conversation'")).firstMatch
        let end = app.staticTexts["End of the long reply."]
        let start = app.staticTexts["Start of the long reply."]
        let latest = app.buttons["Latest"]
        XCTAssertTrue(end.waitForExistence(timeout: 15), "The conversation opens at its newest items, just after the long reply")

        // Tapping the status bar scrolls to the top with no dragging and no scroll phase, and must still stop following:
        // otherwise Latest isn't offered and the next update pulls the conversation back down.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 10), "After the status bar's scroll to the top, Latest is offered")
        waitAndTap(latest, untilGone: latest, timeout: 10, "Latest must return from the top to the newest items")
        XCTAssertTrue(end.waitForExistence(timeout: 10), "Latest must show the end of the reply")

        for round in 1...3 {
            let began = Date()
            // To the top, through the whole reply: every slice is laid out on the way.
            fling(to: top, up: true, in: app, "Round \(round): the top of the conversation must be reachable")
            XCTAssertTrue(latest.waitForExistence(timeout: 5), "Away from the latest, Latest is offered")
            // Back down: drag partway, then jump the rest with Latest, which crosses unrealised rows in one go.
            fling(to: start, up: false, in: app, "Round \(round): the start of the long reply must be reachable")
            waitAndTap(latest, untilGone: latest, timeout: 10, "Round \(round): Latest must return to the newest items")
            XCTAssertTrue(end.waitForExistence(timeout: 10), "Round \(round): Latest must show the end of the reply")
            let elapsed = Date().timeIntervalSince(began)
            XCTContext.runActivity(named: "Round \(round) took \(String(format: "%.1f", elapsed)) s") { _ in }
            XCTAssertLessThan(elapsed, Self.roundTripLimit, "Round \(round): scrolling a long reply must not stall")
        }

        // Still responding: the composer takes typing straight away.
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        composer.tap()
        composer.typeText("Still here")
        XCTAssertEqual(composer.value as? String, "Still here", "The conversation must respond after scrolling")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Long reply, back at the latest"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
