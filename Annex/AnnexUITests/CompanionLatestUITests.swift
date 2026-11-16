import XCTest

/// Socket-free visual inputs, with the same transcript and Latest action as a real conversation.
@MainActor final class CompanionLatestUITests: ReliableUITestCase {
    func testDarkLatest() { checkLatest("dark") }
    func testLightLatest() { checkLatest("light", flags: ["--companion-header-light"]) }
    func testLatteLatest() { checkLatest("Catppuccin Latte", flags: ["--companion-header-light", "--companion-header-latte"]) }
    func testMochaLatest() { checkLatest("Catppuccin Mocha", flags: ["--companion-header-mocha"]) }
    func testAccessibilityLatest() {
        checkLatest("accessibility XXXL", flags: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    private func checkLatest(_ state: String, flags: [String] = []) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-header-held-tail",
                             "--companion-preview-follow-trace"] + flags, attempts: 1)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer-region").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let transcript = app.scrollViews["companion-transcript"]
        let final = app.staticTexts["Held final row."]
        let latest = app.pausedChatNavigation
        func viewport() -> CGRect {
            let top = app.navigationBars.firstMatch.frame.maxY
            return CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: composer.frame.minY - top)
        }
        XCTAssertTrue(waitFor(final, NSPredicate { _, _ in final.exists && self.pixelContains(viewport(), final.frame) }, timeout: 10))
        XCTAssertFalse(latest.exists, "Latest starts hidden at the true bottom")
        XCTAssertTrue((transcript.value as? String)?.hasPrefix("Following: 1; pauses: ") == true)
        let bounds = viewport()
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.minX + 8, dy: bounds.minY + bounds.height * 0.2))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: bounds.height * 0.6)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertEqual(latest.label, "Latest")
        XCTAssertEqual(latest.value as? String, "Reading earlier messages")
        XCTAssertEqual(app.buttons.matching(identifier: "companion-latest").count, 1)
        XCTAssertFalse(app.buttons["companion-previous-message"].exists)
        XCTAssertFalse(app.buttons["companion-next-message"].exists)
        XCTAssertTrue((transcript.value as? String)?.hasPrefix("Following: 0; pauses: ") == true)
        assertMinimumTarget(latest, "Latest at \(state)")
        XCTAssertTrue(latest.isHittable)
        XCTAssertTrue(pixelContains(viewport(), latest.frame))
        XCTAssertEqual(latest.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(latest.frame.maxY, composer.frame.minY - 4)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Latest pill — \(state)"; screenshot.lifetime = .keepAlways; add(screenshot)
        let geometry = XCTAttachment(string: "Latest=\(latest.frame), viewport=\(viewport()), composer=\(composer.frame)\n\(app.debugDescription)")
        geometry.name = "Latest geometry — \(state)"; geometry.lifetime = .keepAlways; add(geometry)
        // One activation, without incoming content, must reach the complete final row.
        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        XCTAssertTrue(final.exists && pixelContains(viewport(), final.frame))
        XCTAssertTrue((transcript.value as? String)?.hasPrefix("Following: 1; pauses: ") == true)
    }
}
