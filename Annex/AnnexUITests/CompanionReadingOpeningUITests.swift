import XCTest
import UIKit

/// The external ticket records video BEFORE launch. The first rendered frame comes from that recording,
/// not from AX readiness below. These attachments label the first public UI observation and final controls.
@MainActor final class CompanionReadingOpeningUITests: ReliableUITestCase {
    private func state(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["reading-opening-state"] }
    private func control(_ id: String, in app: XCUIApplication) {
        let oldTarget = state(app).label.split(separator: " ").first { $0.hasPrefix("target=") }.map(String.init)
        func tap(_ button: XCUIElement) {
            button.tap()
            if id == "other", let oldTarget {
                XCTAssertTrue(waitFor(state(app), NSPredicate { _, _ in
                    !self.state(app).label.split(separator: " ").map(String.init).contains(oldTarget)
                }, timeout: 8), "The other chat must actually be selected before its controls are assessed")
            }
        }
        let button = app.buttons["reading-opening-" + id]
        let strip = app.scrollViews["reading-opening-actions"]
        func canTap() -> Bool {
            guard button.exists else { return false }
            let frame = button.frame
            guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.maxX.isFinite, frame.maxY.isFinite,
                  strip.frame.intersects(frame) else { return false }
            return button.isHittable
        }
        for _ in 0..<8 {
            checkTimeLeft("revealing recording-fixture control")
            if canTap() { tap(button); return }
            strip.swipeLeft()
        }
        for _ in 0..<8 {
            if canTap() { tap(button); return }
            strip.swipeRight()
        }
        XCTFail("The recording-fixture control must be reachable: \(id)")
    }
    private func waitState(_ fragment: String, in app: XCUIApplication) {
        XCTAssertTrue(waitFor(state(app), NSPredicate(format: "label CONTAINS %@", fragment), timeout: 8), state(app).label)
    }
    private func viewport(_ app: XCUIApplication) -> CGRect {
        let top = app.navigationBars.firstMatch.frame.maxY
        let footer = app.descendants(matching: .any).matching(identifier: "companion-composer-region").firstMatch.frame.minY
        return CGRect(x: 0, y: top, width: app.frame.width, height: max(0, footer - top))
    }
    private func observation(_ name: String, in app: XCUIApplication, anchor: XCUIElement? = nil) {
        let frame = anchor?.exists == true ? anchor!.frame : .zero
        let region = viewport(app)
        let data = "time=\(Date().timeIntervalSince1970) \(state(app).label) anchor=\(frame) viewport=\(region) distanceFromTop=\(frame.minY - region.minY) Latest=\(app.pausedChatNavigation.exists) keyboard=\(app.keyboards.firstMatch.exists)"
        let trace = XCTAttachment(string: data); trace.name = name + " first public UI observation (not first paint)"; trace.lifetime = .keepAlways; add(trace)
        let pixels = XCTAttachment(screenshot: app.screenshot()); pixels.name = name; pixels.lifetime = .keepAlways; add(pixels)
    }
    private func settledY(_ anchor: XCUIElement, in app: XCUIApplication) -> CGFloat {
        let deadline = Date().addingTimeInterval(6)
        var previous: CGRect?, since: Date?
        while Date() < deadline {
            let frame = anchor.exists ? anchor.frame : .zero
            if frame.isEmpty || frame != previous { since = frame.isEmpty ? nil : Date() }
            previous = frame
            if let since, Date().timeIntervalSince(since) >= 0.5 { return frame.minY }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("The bookmark's public frame must settle independently of its expected position")
        return anchor.frame.minY
    }
    private func launchFixture() -> XCUIApplication {
        let app = launchApp(["--reading-opening-ui-testing", "--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"])
        XCTAssertTrue(state(app).waitForExistence(timeout: 10))
        waitState("case=ready", in: app)
        return app
    }

    func testRecordedFirstFramesKeepPausedAndLatestChoicesAcrossMountsAndChats() {
        let app = launchFixture()
        control("latest", in: app)
        waitState("case=latest", in: app)
        XCTAssertTrue(app.scrollViews["companion-transcript"].waitForExistence(timeout: 5))
        waitState("follow=1", in: app)
        XCTAssertFalse(app.pausedChatNavigation.exists)
        observation("Fresh latest", in: app)

        control("paused", in: app)
        waitState("case=paused-expanded", in: app)
        let anchor = app.staticTexts["Reading marker 90."]
        observation("Paused expanded-window opening", in: app, anchor: anchor)
        waitState("outcome=arrived", in: app)
        let savedY = settledY(anchor, in: app)
        XCTAssertTrue(anchor.isHittable && viewport(app).intersects(anchor.frame))
        XCTAssertTrue(app.pausedChatNavigation.exists)

        control("hide", in: app)
        waitState("visible=0", in: app)
        control("show", in: app)
        waitState("case=tab-return", in: app)
        observation("Retained tab return", in: app, anchor: anchor)
        waitState("outcome=arrived", in: app)
        XCTAssertEqual(settledY(anchor, in: app), savedY, accuracy: 6)
        control("close", in: app)
        waitState("case=closed", in: app)
        control("reopen", in: app)
        waitState("case=reopen", in: app)
        observation("Native destination reopen", in: app, anchor: anchor)
        waitState("outcome=arrived", in: app)
        XCTAssertEqual(settledY(anchor, in: app), savedY, accuracy: 6)

        control("other", in: app)
        waitState("follow=1", in: app)
        observation("Other chat starts latest", in: app)
        XCTAssertFalse(app.pausedChatNavigation.exists)
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        XCTAssertTrue(app.pausedChatNavigation.exists)
        control("other", in: app)
        waitState("outcome=arrived", in: app)
        observation("Original chat keeps its pause", in: app, anchor: anchor)
        XCTAssertEqual(settledY(anchor, in: app), savedY, accuracy: 6)
        app.pausedChatNavigation.tap()
        waitState("follow=1", in: app)
        XCTAssertFalse(app.pausedChatNavigation.exists)
        control("other", in: app)
        waitState("follow=0", in: app)
        observation("Latest on one chat leaves the other paused", in: app, anchor: anchor)
        XCTAssertTrue(app.pausedChatNavigation.exists)

        // A real finger drag complements the hosted injected-phase/ownership branch tests.
        // This probe reports SwiftUI's actual flag, never the DEBUG ownership override.
        let handoffs = state(app).label.split(separator: " ").first { $0.hasPrefix("handoffs=") }.map(String.init)
        XCTAssertNotNil(handoffs)
        app.scrollViews["companion-transcript"].swipeDown()
        waitState("user=1", in: app)
        observation("Real drag reports native user ownership", in: app)
        control("stream", in: app)
        waitState("case=streamed", in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(state(app).label.split(separator: " ").map(String.init).contains(handoffs ?? "missing"),
                      "No identity handoff may be written after the real drag owns scrolling")
    }

    func testRecordedReloadsKeepTheOpenMountAndPreserveKeyboardDraftAndReadingControls() {
        let app = launchFixture()
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        let anchor = app.staticTexts["Reading marker 90."]
        let composer = app.textViews["companion-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("First paint draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let savedY = settledY(anchor, in: app)
        control("reload", in: app)
        waitState("case=open-reload", in: app)
        observation("Reload while open", in: app, anchor: anchor)
        waitState("outcome=arrived", in: app)
        XCTAssertEqual(settledY(anchor, in: app), savedY, accuracy: 6)
        XCTAssertEqual(composer.value as? String, "First paint draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.pausedChatNavigation.exists)

        control("hide", in: app)
        waitState("visible=0", in: app)
        control("reload", in: app)
        waitState("case=hidden-reload", in: app)
        control("show", in: app)
        waitState("case=tab-return", in: app)
        observation("Reload while hidden then re-show", in: app, anchor: anchor)
        waitState("outcome=arrived", in: app)
        XCTAssertEqual(composer.value as? String, "First paint draft")
        XCTAssertTrue(app.pausedChatNavigation.exists)
        observation("Returned draft and keyboard state", in: app, anchor: anchor)
        control("session", in: app)
        waitState("case=session-replacement", in: app)
        let newSession = app.staticTexts["New session marker 90."]
        observation("Session replacement uses existing generation handling", in: app, anchor: newSession)
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "First paint draft")
    }
}
