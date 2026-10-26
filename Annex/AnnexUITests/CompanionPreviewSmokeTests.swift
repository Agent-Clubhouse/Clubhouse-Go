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
}
