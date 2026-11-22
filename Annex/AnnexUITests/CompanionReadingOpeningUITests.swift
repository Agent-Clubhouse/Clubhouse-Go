import XCTest
import UIKit

/// The external ticket records video BEFORE launch. The first rendered frame comes from that recording,
/// not from AX readiness below. These attachments label the first public UI observation and final controls.
@MainActor final class CompanionReadingOpeningUITests: ReliableUITestCase {
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
    private func assertEarlierIsClearOfThePinnedBanner(in app: XCUIApplication) {
        let earlier = app.buttons["companion-show-earlier"]
        let banner = app.buttons["View River"]
        let track = app.scrollViews["companion-transcript"].otherElements
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "This proof requires the real pinned other-agent banner")
        XCTAssertTrue(track.waitForExistence(timeout: 5), "The public native track measures the unobscured scroll region")
        XCTAssertTrue(waitFor(earlier, NSPredicate { _, _ in
            let frame = earlier.frame, native = track.frame
            return earlier.exists && earlier.isHittable && !frame.isEmpty && !native.isEmpty
                && frame.minY >= native.minY && frame.maxY <= native.maxY
                && native.minY >= banner.frame.maxY
        }, timeout: 5), "Show earlier must be completely below the pinned banner, not merely AX-hittable")
        XCTAssertEqual(earlier.label, "Show earlier messages", "The spoken action label is unchanged")
        XCTAssertEqual(earlier.identifier, "companion-show-earlier", "The existing public identifier is unchanged")
        let note = XCTAttachment(string: "earlier=\(earlier.frame) nativeTrack=\(track.frame) bannerAction=\(banner.frame) label=\(earlier.label) identifier=\(earlier.identifier)")
        note.name = "Native content-top clearance and unchanged action semantics"; note.lifetime = .keepAlways; add(note)
    }

    private func openSoftwareKeyboard(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    }

    private func launchFixture(extra: [String] = []) -> XCUIApplication {
        let app = launchApp(["--reading-opening-ui-testing", "--companion-preview", "--companion-preview-reading", "--companion-preview-follow-trace"] + extra, attempts: 1)
        XCTAssertTrue(state(app).waitForExistence(timeout: 10))
        waitState("case=ready", in: app)
        return app
    }



    func testRecordedBookmarkFirstFramesKeepPausedAndLatestChoicesAcrossMountsAndChats() {
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
        observation("Paused bookmark-first opening", in: app, anchor: anchor)
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

        control("short", in: app)
        waitState("case=short-paused", in: app)
        let short = app.staticTexts["Short bookmark."]
        XCTAssertTrue(short.waitForExistence(timeout: 5))
        observation("Short-tail paused opening", in: app, anchor: short)
        XCTAssertTrue(short.isHittable && viewport(app).intersects(short.frame))
    }

    /// External video audits every frame across each prepend; these are public-AX samples, not first-paint claims.
    func testRecordedEarlierExpansionPreservesTheBookmarkDuringTailArrival() {
        let app = launchFixture()
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        let anchor = app.staticTexts["Reading marker 90."]
        let earlier = app.buttons["companion-show-earlier"]
        let transcript = app.scrollViews["companion-transcript"]
        // A intentionally aligns the saved entry after first paint. Reach the inline control like a reader:
        // one native status-bar scroll to content top, not a tap through the pinned banner's hit region.
        tapChatStatusBar(in: app)
        assertEarlierIsClearOfThePinnedBanner(in: app)
        let before = settledY(anchor, in: app)
        var expansions = 0
        while earlier.exists, expansions < 8 {
            let previousStart = state(app).label.split(separator: " ").first { $0.hasPrefix("start=") }.map(String.init)
            XCTAssertNotNil(previousStart)
            observation("Before earlier expansion \(expansions)", in: app, anchor: anchor)
            assertEarlierIsClearOfThePinnedBanner(in: app)
            earlier.tap()
            XCTAssertTrue(waitFor(state(app), NSPredicate { _, _ in
                !self.state(app).label.split(separator: " ").map(String.init).contains(previousStart ?? "missing")
            }, timeout: 8), "The real loaded prefix must widen before this can pass")
            XCTAssertEqual(settledY(anchor, in: app), before, accuracy: 4,
                "Show earlier preserves the same entry's screen position")
            observation("After earlier expansion \(expansions)", in: app, anchor: anchor)
            expansions += 1
        }
        XCTAssertGreaterThan(expansions, 0)
        XCTAssertFalse(earlier.exists, "The bounded expansion must recover the entire prior prefix")
        XCTAssertTrue(app.staticTexts["Reading marker 1."].exists)
        control("append", in: app)
        waitState("case=tail-arrived", in: app)
        XCTAssertEqual(settledY(anchor, in: app), before, accuracy: 4,
            "A normal new tail reply cannot move the entry after prefix expansion")
        observation("Tail arrives after earlier expansion", in: app, anchor: anchor)
        let oldest = app.staticTexts["Reading marker 1."]
        for _ in 0..<25 {
            checkTimeLeft("reaching the restored older history")
            if oldest.frame.intersects(viewport(app)), oldest.isHittable { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(oldest.isHittable && viewport(app).intersects(oldest.frame),
            "Restored earlier history must be user-reachable, not just retained in the model")
        observation("Recovered beginning of history", in: app, anchor: oldest)
    }

    func testRecordedReloadsKeepTheOpenMountAndPreserveKeyboardDraftAndReadingControls() {
        let app = launchFixture()
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        let anchor = app.staticTexts["Reading marker 90."]
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        openSoftwareKeyboard(composer, in: app)
        composer.typeText("First paint draft")
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
    /// Run on SE portrait. Encoded first paused frame must show this unchanged label fully below the banner.
    /// Eventual AX checks establish semantics/real access only; they cannot rescue a bad first encoded frame.
    func testRecordedSEPortraitFirstPausedFrameKeepsEarlierBelowThePinnedBanner() {
        let app = launchFixture()
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        observation("SE portrait paused first-frame recording; later AX sample", in: app,
                    anchor: app.staticTexts["Reading marker 90."])
        tapChatStatusBar(in: app)
        assertEarlierIsClearOfThePinnedBanner(in: app)
    }

    /// Run on Pro Max at XXXL portrait; first-frame visibility and canonical-first content are video gates.
    func testRecordedXXXLPortraitFirstPausedFrameKeepsEarlierBelowThePinnedBanner() {
        let app = launchFixture(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        control("paused", in: app)
        waitState("outcome=arrived", in: app)
        observation("XXXL portrait paused first-frame recording; later AX sample", in: app,
                    anchor: app.staticTexts["Reading marker 90."])
        tapChatStatusBar(in: app)
        assertEarlierIsClearOfThePinnedBanner(in: app)
    }

    /// Diagnostic recording ONLY: #483 excludes landscape tight-room visibility from this acceptance contract.
    /// No passing portrait/landscape containment claim may be inferred from this method's eventual completion.
    func testRecordedLandscapePausedOpeningIsUncreditedForTheKnown483Limit() {
        let app = launchFixture()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        control("paused", in: app)
        waitState("case=paused-expanded", in: app)
        observation("Landscape diagnostic only; #483 visibility exclusion", in: app,
                    anchor: app.staticTexts["Reading marker 90."])
    }

}
