import XCTest
import UIKit

/// Existing archive-header control, with its unchanged reading fixture helpers.
@MainActor
final class CompanionReadingArchiveHeaderUITests: ReliableUITestCase {
    private func state(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["reading-opening-state"] }

    private func control(_ id: String, in app: XCUIApplication) {
        let oldTarget = state(app).label.split(separator: " ").first { $0.hasPrefix("target=") }.map(String.init)
        let button = app.buttons["reading-opening-" + id]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let frame = button.frame
        XCTAssertTrue(!frame.isEmpty && !frame.isNull && !frame.isInfinite && app.frame.contains(frame),
                      "Every DEBUG grid action must be physically on screen: \(id), \(frame)")
        XCTAssertTrue(button.isHittable, "Every DEBUG grid action must be natively hittable: \(id)")
        button.tap() // One real tap, no scrolling/retry can rescue an unreachable fixture action.
        if id == "other", let oldTarget {
            XCTAssertTrue(waitFor(state(app), NSPredicate { _, _ in
                !self.state(app).label.split(separator: " ").map(String.init).contains(oldTarget)
            }, timeout: 8), "The other chat must actually be selected before its controls are assessed")
        }
    }

    private func waitState(_ fragment: String, in app: XCUIApplication) {
        XCTAssertTrue(waitFor(state(app), NSPredicate(format: "label CONTAINS %@", fragment), timeout: 8), state(app).label)
    }

    private func launchFixture(extra: [String] = []) -> XCUIApplication {
        let app = launchApp(["--reading-opening-ui-testing", "--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"] + extra, attempts: 1)
        XCTAssertTrue(state(app).waitForExistence(timeout: 10))
        waitState("case=ready", in: app)
        return app
    }

    /// A real header action retained across equivalent parent values must still write the parent's live State storage.
    func testPausedTranscriptArchiveHeaderStillOpensAndClosesAfterStreaming() {
        let app = launchFixture(extra: ["--companion-reading-equality-archive"])
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        control("stream", in: app)
        waitState("case=streamed", in: app)
        let transcript = app.scrollViews["companion-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        // Native movement reaches the inline header after the accepted numeric restore, without an action seam.
        transcript.swipeDown()
        let archive = app.buttons["Read earlier messages in archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5) && archive.isHittable)
        archive.tap()
        let navigation = app.navigationBars["Conversation archive"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        let pixels = XCTAttachment(screenshot: app.screenshot())
        pixels.name = "Actual paused transcript header opened parent archive sheet"; pixels.lifetime = .keepAlways; add(pixels)
        navigation.buttons["Done"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertFalse(navigation.exists)
        XCTAssertTrue(state(app).label.contains("follow=0"), "Opening the archive must not make the chat follow latest")
    }
}
