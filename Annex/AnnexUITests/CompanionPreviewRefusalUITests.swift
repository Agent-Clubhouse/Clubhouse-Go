import XCTest

@MainActor final class CompanionPreviewRefusalUITests: ReliableUITestCase {
    func testDeniedLocalLinkTapsExplainSharingAndRootsWithoutExternalHandoff() {
        for (scenario, reason) in [
            ("local-sharing-off", "Rich chat content is off on Studio Mac"),
            ("local-roots-denied", "This conversation can't preview that file")
        ] {
            let app = launchApp(["--companion-preview", "--mobile-links-ui-testing"],
                                environment: ["MOBILE_LINK_SCENARIO": scenario], attempts: 1)
            let link = app.links["Local file"]
            XCTAssertTrue(link.waitForExistence(timeout: 10))
            XCTAssertTrue(link.isHittable && app.frame.contains(link.frame))
            link.tap()
            XCTAssertTrue(app.staticTexts["Preview unavailable"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", reason)).firstMatch.exists)
            let done = app.buttons["companion-preview-done"]
            XCTAssertEqual(done.label, "Done")
            XCTAssertTrue(done.isHittable && app.frame.contains(done.frame))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Explicit local preview refusal - \(scenario)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            done.tap()
            XCTAssertTrue(app.buttons["companion-preview-done"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["mobile-link-open-receipt"].label, "opens=0;url=")
            app.terminate()
        }
    }
}
