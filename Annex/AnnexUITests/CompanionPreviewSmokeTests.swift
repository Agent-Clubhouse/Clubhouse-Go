import XCTest

/// Exercises the new SwiftUI navigation on a real simulator without enrolling
/// any desktop, storing credentials, or pretending preview commands succeeded.
@MainActor
final class CompanionPreviewSmokeTests: XCTestCase {
    func testPreviewOpensScopedConversationAndKeepsCommandsNonLive() {
        continueAfterFailure = false
        // The launch-configuration matrix can leave the shared device in landscape.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Selecting an agent must open its conversation")
        XCTAssertTrue(app.navigationBars["River"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native companion conversation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        composer.tap()
        composer.typeText("Preview smoke message")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 5), "Preview must never claim a command reached a desktop")
    }

    /// A one-line composer shorter than its text view's content scrolls to the caret as you type,
    /// which reads as the text jittering until it wraps. One line must be exactly half of two lines.
    func testComposerSingleLineHeightMatchesWrappedLineHeight() {
        continueAfterFailure = false
        // Each keystroke and frame read is a slow round trip on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Hey")
        let oneLine = composer.frame.height
        // Two words at a time: fewer round trips, and still far short of a whole line, so it stops at two lines.
        for _ in 0..<10 where composer.frame.height <= oneLine + 1 {
            composer.typeText(" steady steady")
        }
        let twoLines = composer.frame.height
        XCTAssertGreaterThan(twoLines, oneLine + 1, "Composer must grow when the draft wraps")
        XCTAssertEqual(oneLine, twoLines / 2, accuracy: 0.5, "A single line must use the same line height as wrapped lines")
    }

    /// A preview opened from a tool card must close while the agent keeps streaming, even after its
    /// card is re-projected or folded into "Ran N tools" (#134).
    func testContentPreviewDismissesWhileToolUpdatesStream() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview", "--companion-preview-stream"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "build/test-log.txt")).firstMatch
        let done = app.buttons["companion-preview-done"]
        let title = app.navigationBars["test-log.txt"]

        // Done: wait through several updates, including a fold, before closing.
        XCTAssertTrue(link.waitForExistence(timeout: 15), "The streaming tool card must offer its log")
        link.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done must show while the preview loads")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The sample file must load")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(done.isHittable, "Done must stay reachable while updates stream")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done must close the preview while updates stream")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "After closing preview with Done"
        add(screenshot)

        // Swipe down.
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Swiping down must close the preview while updates stream")
    }

    /// Agent replies render block Markdown natively: the sample reply's heading, table and list
    /// appear as elements, and none of the raw syntax (`## `, `|---|`) reaches the screen.
    func testAgentReplyRendersBlockMarkdown() {
        continueAfterFailure = false
        // Element queries over a long conversation are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10))

        // The conversation opens at the latest item; the reply sits just above the approval.
        let heading = app.staticTexts["Reconnect status"]
        if !heading.waitForExistence(timeout: 10) {
            for _ in 0..<3 where !heading.exists { app.swipeDown() }
        }
        XCTAssertTrue(heading.exists, "The heading must render without its hashes")
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Row 1.' AND label CONTAINS 'Check: Resume after sleep'")).firstMatch
        XCTAssertTrue(row.exists, "The table must render as rows VoiceOver reads cell by cell")
        XCTAssertTrue(app.staticTexts["Keep drafts per agent"].exists, "The task list item must render")
        XCTAssertTrue(app.images["Done"].exists, "A checked task shows its checkbox")

        let raw = NSPredicate(format: "label CONTAINS '|---' OR label CONTAINS '|:--' OR label CONTAINS '| Check' OR label BEGINSWITH '## ' OR label BEGINSWITH '- ['")
        XCTAssertEqual(app.staticTexts.matching(raw).count, 0, "No raw Markdown syntax may reach the screen")
        XCTAssertFalse(app.staticTexts["Agent"].exists, "Agent replies carry no author label, like the desktop")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Block Markdown reply"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
