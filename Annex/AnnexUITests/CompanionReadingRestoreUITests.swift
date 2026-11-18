import XCTest

@MainActor final class CompanionReadingRestoreUITests: ReliableUITestCase {
    /// Diagnostic fail-before only: the -shift signature describes unchanged main, not a passing fixed contract.
    func testPrefixTrimDuringPinnedRestoreCharacterizesTheOneBlockMiss() {
        let app = launchApp(["--reading-prefix-trim-ui-testing", "--companion-preview-reading"])
        let state = app.staticTexts["reading-prefix-trim-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let transcript = app.scrollViews["companion-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if state.label.contains("follow=0") { break }
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(waitFor(state, NSPredicate(format: "label CONTAINS %@", "follow=0"), timeout: 5))
        XCTAssertTrue(app.pausedChatNavigation.exists)
        let top = app.navigationBars.firstMatch.frame.maxY + 30
        let bottom = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.frame.minY - 30
        let markers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker ")).allElementsBoundByIndex
        guard let marker = markers.first(where: { $0.isHittable && $0.frame.minY > top && $0.frame.maxY < bottom }) else {
            XCTFail("A real reading marker must be visible before the fixture is armed"); return
        }
        let anchor = app.staticTexts[marker.label]
        func stableFrame() -> Bool {
            let deadline = Date().addingTimeInterval(4)
            var previous: CGRect?, stable = 0
            while Date() < deadline {
                let current = anchor.frame
                stable = current == previous && !current.isEmpty ? stable + 1 : 0
                previous = current
                if stable >= 2 { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            return false
        }
        guard stableFrame() else { XCTFail("The prepared marker did not settle"); return }
        let beforeY = anchor.frame.minY
        app.buttons["reading-prefix-trim-begin"].tap()
        XCTAssertTrue(waitFor(state, NSPredicate { _, _ in
            state.label.contains("phase=H1-not-exercised") || state.label.contains("outcome=arrived")
        }, timeout: 5), state.label)
        guard !state.label.contains("phase=H1-not-exercised") else {
            XCTFail("H1 not exercised: the real geometry gate missed its bound. \(state.label)"); return
        }
        guard state.label.contains("outcome=arrived") else { XCTFail("Only final arrived can classify H1"); return }
        guard stableFrame() else { XCTFail("The completed restore did not settle"); return }
        func number(_ key: String) -> Double? {
            state.label.split(separator: " ").first { $0.hasPrefix(key + "=") }
                .flatMap { Double($0.dropFirst(key.count + 1)) }
        }
        guard let shift = number("shift"), let miss = number("miss"),
              let attempts = number("attempts"), let elapsed = number("elapsed") else {
            XCTFail("The diagnostic state must contain its measured gate and displacement"); return
        }
        XCTAssertLessThanOrEqual(attempts, 10)
        XCTAssertLessThan(elapsed, 1)
        XCTAssertGreaterThan(abs(shift), 8)
        XCTAssertEqual(miss, -shift, accuracy: 2, "Main's numeric miss must match the prefix displacement")
        XCTAssertEqual(beforeY - anchor.frame.minY, -shift, accuracy: 2, "The real pixels must show the same one-block miss")
        XCTAssertTrue(app.pausedChatNavigation.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Deterministic prefix trim after the restore pin"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(anchor.frame.minY, beforeY, accuracy: 6, "Restoration must preserve the reader's entry")
    }

    func testRealDragAfterTimeoutSavesAndRemountsTheNewReadingPosition() {
        let app = launchApp(["--reading-restore-ui-testing"])
        let state = app.staticTexts["reading-restore-fixture"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(state, NSPredicate(format: "label CONTAINS %@", "outcome=exhausted"), timeout: 10))
        func number(_ key: String) -> Double {
            let field = state.label.split(separator: " ").first { $0.hasPrefix(key + "=") }
            return field.flatMap { Double($0.dropFirst(key.count + 1)) } ?? -.infinity
        }
        XCTAssertEqual(number("saved"), 1_200, accuracy: 2)
        XCTAssertEqual(number("held"), 1)
        XCTAssertEqual(number("restoring"), 0)
        let before = number("offset")
        let transcript = app.scrollViews["companion-transcript"]
        XCTAssertTrue(transcript.exists)
        // A real downward finger drag moves away from the bottom into older content.
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        let saved = NSPredicate { _, _ in
            number("held") == 0 && number("restoring") == 0 && number("offset") < before - 100
                && abs(number("saved") - number("offset")) <= 2
        }
        XCTAssertTrue(waitFor(state, saved, timeout: 5), state.label)
        // Let deceleration finish before choosing the final bookmark to compare on return.
        var previous = number("offset"), stable = 0
        for _ in 0..<30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let current = number("offset")
            stable = abs(current - previous) <= 1 ? stable + 1 : 0
            previous = current
            if stable >= 3 { break }
        }
        XCTAssertGreaterThanOrEqual(stable, 3, state.label)
        let chosen = number("saved")
        XCTAssertEqual(chosen, number("offset"), accuracy: 2)
        XCTAssertGreaterThan(chosen, 1_300, "This must be the drag's position, not the original bookmark")
        app.buttons["reading-restore-remount"].tap()
        XCTAssertTrue(waitFor(state, NSPredicate(format: "label CONTAINS %@", "outcome=arrived"), timeout: 5), state.label)
        XCTAssertEqual(number("offset"), chosen, accuracy: 2)
        XCTAssertEqual(number("saved"), chosen, accuracy: 2)
        XCTAssertEqual(number("held"), 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real drag after timeout restores its new bookmark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
