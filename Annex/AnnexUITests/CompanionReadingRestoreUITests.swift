import XCTest

@MainActor final class CompanionReadingRestoreUITests: ReliableUITestCase {
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
