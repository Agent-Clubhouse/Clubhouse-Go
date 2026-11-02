import XCTest

@MainActor final class CompanionQueuedBurstUITests: ReliableUITestCase {
    func testQueuedJoinsKeepOneDeliveredRowAndStablePartIdentifiers() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        let river = element("agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element("companion-chat-header"), timeout: 10)
        for index in 0..<4 {
            let part = element("companion-routed-relay-1-\(index)")
            XCTAssertTrue(scrollUntilExists(part, in: app, up: false, maxSwipes: 8))
            XCTAssertTrue(part.label.contains(["Dispatcher:", "Reviewer:", "Clubhouse:", "Another agent:"][index]))
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-routed-relay-1-")).count, 4)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-routed-relay-join-")).count, 0)
        let delivered = app.staticTexts["Delivered to the agent"]
        XCTAssertTrue(scrollUntilExists(delivered, in: app, up: false, maxSwipes: 4))
        XCTAssertFalse(app.staticTexts["Follow-up submitted"].exists)
    }
}
