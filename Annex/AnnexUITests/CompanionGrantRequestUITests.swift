import XCTest

/// Clubhouse grant requests in Needs you and chat (Go #337, #357): the desktop's lines, full call arguments, the agent's
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

    private func revealChatAnswer(_ answer: XCUIElement, in app: XCUIApplication) {
        let viewport = app.scrollViews["companion-chat-grant-requests-scroll"]
        for _ in 0..<6 {
            if answer.exists && answer.isHittable && (!viewport.exists || pixelContains(viewport.frame, answer.frame)) { return }
            XCTAssertTrue(viewport.exists, "Long requests have their own scroll viewport")
            viewport.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(answer.isHittable && pixelContains(viewport.frame, answer.frame), "The complete answer button is reachable")
    }

    func testAnswerInChatRemovesNeedsYouCardAndKeepsCLIApprovalSeparate() {
        let app = openNeedsYou()
        let call = app.staticTexts[callSummary]
        XCTAssertTrue(scrollUntilExists(call, in: app))
        let openChat = app.cells.containing(.staticText, identifier: callSummary).buttons["grant-request-open-chat"]
        XCTAssertTrue(scrollTo(openChat, in: app))
        let card = app.descendants(matching: .any).matching(identifier: "companion-chat-grant-requests").firstMatch
        waitAndTap(openChat, until: card)

        XCTAssertTrue(app.navigationBars["River"].exists, "The request opens its own agent's chat")
        XCTAssertTrue(app.staticTexts["Clubhouse permission request"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "grant-request-detail").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "grant-request-arguments").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "grant-request-reason").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "grant-request-effect").firstMatch.exists)
        XCTAssertFalse(app.buttons["grant-request-open-chat"].exists, "Chat does not link to itself")
        XCTAssertTrue(app.buttons["Deny"].exists, "The CLI approval remains its own pinned request")
        let allow = button("grant-request-allow", "Allow once", in: app)
        revealChatAnswer(allow, in: app)
        attach(app, "Grant request: answer in chat")
        waitAndTap(allow, untilGone: card)
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Answering the grant does not answer the CLI approval")

        let back = app.navigationBars.buttons.firstMatch
        waitAndTap(back, until: app.navigationBars["Needs you"])
        XCTAssertFalse(call.exists, "The answered chat request is gone from Needs you")
        XCTAssertTrue(scrollUntilExists(app.staticTexts[askSummary], in: app), "The other agent's request still waits")
    }

    func testNeedsYouAnswerRemovesRequestFromPreviouslyOpenedChat() {
        let app = openNeedsYou()
        let ask = app.staticTexts[askSummary]
        XCTAssertTrue(scrollUntilExists(ask, in: app))
        let openChat = app.cells.containing(.staticText, identifier: askSummary).buttons["grant-request-open-chat"]
        XCTAssertTrue(scrollTo(openChat, in: app))
        let card = app.descendants(matching: .any).matching(identifier: "companion-chat-grant-requests").firstMatch
        waitAndTap(openChat, until: card)
        XCTAssertTrue(app.navigationBars["Cedar"].exists)
        let allow = button("grant-request-allow", "Allow", in: app)
        revealChatAnswer(allow, in: app)
        XCTAssertFalse(button("grant-request-allow", "Allow once", in: app).exists)
        XCTAssertTrue(app.staticTexts["Allow adds this to its Clubhouse permissions, where you can remove it later."].exists)
        waitAndTap(app.navigationBars.buttons.firstMatch, until: app.navigationBars["Needs you"])
        XCTAssertTrue(scrollTo(allow, in: app))
        waitAndTap(allow, untilGone: ask)

        waitAndTap(app.tabBars.buttons["Agents"], until: app.navigationBars["Agents"])
        let cedar = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-cedar").firstMatch
        XCTAssertTrue(scrollUntilExists(cedar, in: app) && scrollTo(cedar, in: app))
        waitAndTap(cedar, until: app.navigationBars["Cedar"])
        XCTAssertFalse(card.exists, "The Needs you answer is reflected when chat reopens")
        XCTAssertFalse(app.buttons["grant-request-allow"].exists)
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
