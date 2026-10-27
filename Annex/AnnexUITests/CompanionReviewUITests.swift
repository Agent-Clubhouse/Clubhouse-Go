import XCTest

/// Review on the preview desktop: each page is an agent's full chat, a horizontal swipe moves between agents
/// and never answers anything, and approvals use the chat's own controls.
@MainActor
final class CompanionReviewUITests: XCTestCase {
    /// From Home: every awake agent on connected desktops, in desktop order, each page a full chat.
    func testHomeOpensReviewOnEveryAwakeAgent() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()

        let open = app.buttons.matching(identifier: "companion-open-review").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15), "Home must offer Review")
        open.tap()

        // Needs you only and Sleeping are off. The sleeping agents and the offline laptop's agent are left out, and so are
        // the finished quick runs (Fix lint warnings, willow, aspen), which the desktop's Review never shows.
        let title = app.descendants(matching: .any).matching(identifier: "review-title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Review must open on an agent")
        XCTAssertTrue(waitFor(title, label: "Maple, 1 of 3"), "Review must start at the first agent in desktop order")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10),
                      "Each page must be the agent's full chat")
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "Cedar, 2 of 3"), "Swiping left must show the next agent's chat")
        swipe(app, left: false)
        XCTAssertTrue(waitFor(title, label: "Maple, 1 of 3"), "Swiping right must go back")

        app.buttons["review-done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Done must close Review")
    }

    /// From Needs you: Needs you only is on. Swipes navigate and never answer; approvals use the chat's own controls.
    func testReviewSwipesBetweenChatsAndApprovesInPlace() {
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
        // The preview gives every agent the same sample chat, and neighbouring pages stay loaded, so take River's own
        // button: the one on screen. Tapping a neighbour's would scroll the pager to it.
        let allows = app.buttons.matching(NSPredicate(format: "label == %@", "Allow once"))
        XCTAssertTrue(allows.firstMatch.waitForExistence(timeout: 10), "River's chat must carry its approval")
        attach(app, "Review page: River's chat")
        // With nobody else waiting, a swipe has nowhere to go.
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "River, 1 of 1"))

        // Everyone awake: River stays on screen, now last in desktop order.
        app.descendants(matching: .any).matching(identifier: "review-filter-needs-you").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 3 of 3"), "Turning off Needs you only must add the other awake agents")
        swipe(app, left: false)
        XCTAssertTrue(waitFor(title, label: "Cedar, 2 of 3"), "Swiping right must show the previous agent's chat")
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "River, 3 of 3"), "Swiping left must go forward again")

        // A swipe never answers: River's approval is still waiting. Approve it with the chat's own button.
        guard let allow = onScreen(allows) else { return XCTFail("Swiping must not answer the approval") }
        allow.tap()
        // The preview desktop takes no commands, so the chat says so and River stays on screen.
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(title, label: "River, 3 of 3"), "Answering in the chat must not change the page")

        // Sleeping adds Juniper before River and Birch after.
        app.descendants(matching: .any).matching(identifier: "review-filter-sleeping").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 4 of 5"), "Sleeping must add the sleeping agents")
        swipe(app, left: true)
        XCTAssertTrue(waitFor(title, label: "Birch, 5 of 5"))

        // Needs you only drops Birch, who is on screen, and lands on River, the only one waiting.
        app.descendants(matching: .any).matching(identifier: "review-filter-needs-you").firstMatch.tap()
        XCTAssertTrue(waitFor(title, label: "River, 1 of 1"), "Needs you only must keep only agents that need you")
        attach(app, "Review with Needs you only")
    }

    /// A deliberate horizontal swipe across the chat's top, clear of the composer and the transcript's wide tables.
    private func swipe(_ app: XCUIApplication, left: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.9 : 0.1, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.9, dy: 0.24))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// The first match that's visible and can be tapped, waiting briefly for a page turn to settle.
    private func onScreen(_ query: XCUIElementQuery, timeout: TimeInterval = 5) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return nil
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
