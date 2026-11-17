import XCTest

@MainActor final class CompanionHomeVisibilityUITests: ReliableUITestCase {
    /// Recording is the mid-gesture proof; XCTest's public drag API returns only after release.
    func testAgentSwipeBackPreservesHomeTitleBackLabelAndNonblankContent() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects"], attempts: 1)
        let home = app.navigationBars["Clubhouse"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        let cedarQuery = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-cedar")
        let cedar = cedarQuery.firstMatch
        XCTAssertTrue(scrollUntilExists(cedar, in: app) && scrollTo(cedar, in: app))
        XCTAssertEqual(cedarQuery.count, 1, "The real agent link is unique")
        XCTAssertTrue(cedar.isHittable, "Home renders a real agent before the push")
        capture(app, "Nonblank Home before agent push")
        cedar.tap()
        let agent = app.navigationBars["Cedar"]
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        let back = agent.buttons["Clubhouse"]
        XCTAssertTrue(back.exists && back.isHittable, "The mounted Home owner supplies the native back title")
        XCTAssertTrue(app.descendants(matching: .any)["companion-chat-header"].exists)
        capture(app, "Pushed agent retains Clubhouse back label")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertFalse(agent.exists)
        XCTAssertTrue(cedar.waitForExistence(timeout: 5) && cedar.isHittable, "Swipe-back reveals the retained list, not a blank root")
        XCTAssertGreaterThan(cedar.frame.height, 0)
        XCTAssertGreaterThan(cedar.frame.width, 0)
        capture(app, "Nonblank Home after real swipe-back")
        // A second push verifies the title/back relationship survives the pop too.
        cedar.tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertTrue(back.exists && back.isHittable)
        back.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(cedar.waitForExistence(timeout: 5) && cedar.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
