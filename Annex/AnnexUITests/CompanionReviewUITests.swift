import XCTest

/// Review on the preview desktop: each page is an agent's full chat, a horizontal swipe moves between agents
/// and never answers anything, and approvals use the chat's own controls.
@MainActor
final class CompanionReviewUITests: XCTestCase {
    func testReviewSwipesBetweenChatsAndApprovesInPlace() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()

        let open = app.buttons.matching(identifier: "companion-open-review").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15), "Home must offer Review")
        open.tap()

        // From Home, Needs you only is off and Sleeping is off: River and Cedar, in desktop order.
        // Juniper is asleep and the offline laptop's agent is left out.
        let title = app.descendants(matching: .any).matching(identifier: "review-title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Review must open on an agent")
        XCTAssertTrue(waitFor(title, label: "River, 1 of 2"))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Each page must be the agent's full chat")
        let allow = app.buttons.matching(NSPredicate(format: "label == %@", "Allow once")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "River's chat must carry its approval")
        attach(app, "Review page: River's chat")

        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "Cedar, 2 of 2"), "Swiping left must show the next agent's chat")
        swipe(app, left: false)
        XCTAssertTrue(waitFor(title, label: "River, 1 of 2"), "Swiping right must go back")

        // A swipe never answers: River's approval is still waiting. Approve it with the chat's own button.
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Swiping must not answer the approval")
        allow.tap()
        // The preview desktop takes no commands, so the chat says so and River stays on screen.
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(title, label: "River, 1 of 2"), "Answering in the chat must not change the page")

        // Sleeping adds Juniper at the end.
        app.descendants(matching: .any).matching(identifier: "review-filter-sleeping").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 1 of 3"), "Sleeping must add the sleeping agent")
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "Cedar, 2 of 3"))
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "Juniper, 3 of 3"))

        // Needs you only drops Juniper, who is on screen, and lands on River, the only one waiting.
        app.descendants(matching: .any).matching(identifier: "review-filter-needs-you").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 1 of 1"), "Needs you only must keep only agents that need you")
        attach(app, "Review with Needs you only")

        app.buttons["review-done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Done must close Review")
    }

    func testNeedsYouOpensReviewWithNeedsYouOnly() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let tab = app.tabBars.buttons["Needs you"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let open = app.navigationBars["Needs you"].buttons["companion-open-review"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Needs you must offer Review")
        open.tap()
        let title = app.descendants(matching: .any).matching(identifier: "review-title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(title, label: "River, 1 of 1"), "From Needs you, Review starts with Needs you only on")
        // With nobody else waiting, a swipe has nowhere to go.
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "River, 1 of 1"))
        app.descendants(matching: .any).matching(identifier: "review-filter-needs-you").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 1 of 2"), "Turning off Needs you only must add the other awake agents")
    }

    /// A deliberate horizontal swipe across the chat's top, clear of the composer and the transcript's wide tables.
    private func swipe(_ app: XCUIApplication, left: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.9 : 0.1, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.9, dy: 0.24))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
