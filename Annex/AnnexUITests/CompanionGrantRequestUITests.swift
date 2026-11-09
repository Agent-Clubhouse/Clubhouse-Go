import XCTest

/// Clubhouse grant requests in Needs you (Go #337): the desktop's lines, the call's arguments in full, the agent's
/// reason, and only the answers each request takes. The preview accepts these answers so the rows can go.
@MainActor final class CompanionGrantRequestUITests: ReliableUITestCase {
    private let callSummary = "Wants to run remove_device, which needs: Manage devices on the app."
    private let askSummary = "Asks for Change app settings on the app."

    private func openNeedsYou() -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-grant-requests"])
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        waitAndTap(tab, until: app.navigationBars["Needs you"], timeout: 10)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func button(_ identifier: String, _ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: identifier).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testAllowOnceAndDeclineAnswerGrantRequests() {
        let app = openNeedsYou()
        // A held call: the host's line, its arguments whole, the agent's reason, and Allow once or Decline.
        let call = app.staticTexts[callSummary]
        XCTAssertTrue(scrollUntilExists(call, in: app), "The held call is in Needs you")
        let detail = app.descendants(matching: .any).matching(identifier: "grant-request-detail").firstMatch
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(detail.label.hasPrefix("Remove Travel iPad (tablet, in this network)."), "The host's plain-words line for the call")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "grant-request-arguments").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Reason: You said the iPad was lost.")).firstMatch.exists)
        let allowOnce = button("grant-request-allow", "Allow once", in: app)
        XCTAssertTrue(scrollTo(allowOnce, in: app), "A call takes Allow once")
        XCTAssertTrue(app.staticTexts["Allow runs this one call when it tries again. Its permissions stay as they are."].exists)
        attach(app, "Grant request: held call")
        waitAndTap(allowOnce, untilGone: call, "Allow once answers the call and its row goes")

        // The agent asking for itself: a lasting Allow or Decline, never Allow once.
        let ask = app.staticTexts[askSummary]
        XCTAssertTrue(scrollUntilExists(ask, in: app) || scrollUntilExists(ask, in: app, up: false), "The request_grant ask is in Needs you")
        XCTAssertTrue(button("grant-request-allow", "Allow", in: app).exists, "A grant takes a lasting Allow")
        XCTAssertFalse(button("grant-request-allow", "Allow once", in: app).exists)
        XCTAssertTrue(app.staticTexts["Allow adds this to its Clubhouse permissions, where you can remove it later."].exists)
        attach(app, "Grant request: lasting ask")
        let decline = app.buttons.matching(identifier: "grant-request-decline").firstMatch
        XCTAssertTrue(scrollTo(decline, in: app))
        waitAndTap(decline, untilGone: ask, "Decline answers the ask and its row goes")
        XCTAssertFalse(app.buttons.matching(identifier: "grant-request-allow").firstMatch.exists, "No grant requests are left")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "grant-request-error").firstMatch.exists)
    }
}
