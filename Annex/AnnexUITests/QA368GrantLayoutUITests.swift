import XCTest

@MainActor final class QA368GrantLayoutUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func openRiver(accessibility: Bool = false, extra: [String] = [], fromNeedsYou: Bool = false) -> XCUIApplication {
        let app = launchApp(
            ["--companion-preview", "--companion-preview-grant-requests", "--companion-preview-hide-banner"] + extra
            + (accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []),
            attempts: 1
        )
        if fromNeedsYou {
            let tab = app.tabBars.buttons["Needs you"]
            XCTAssertTrue(tab.waitForExistence(timeout: 15))
            waitAndTap(tab, until: app.navigationBars["Needs you"])
            let summary = "Wants to run remove_device, which needs: Manage devices on the app."
            let open = app.cells.containing(.staticText, identifier: summary).buttons["grant-request-open-chat"]
            XCTAssertTrue(scrollTo(open, in: app) && scrollIntoClearArea(open, in: app))
            tapVisibleRow(open, in: app, until: element(app, "companion-chat-grant-requests"))
        } else {
            let agents = app.tabBars.buttons["Agents"]
            XCTAssertTrue(agents.waitForExistence(timeout: 15))
            waitAndTap(agents, until: app.navigationBars["Agents"])
            let river = element(app, "agent-preview-studio-river")
            XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
            waitAndTap(river, until: element(app, "companion-chat-grant-requests"))
        }
        return app
    }

    private func focus(_ app: XCUIApplication) {
        element(app, "companion-composer").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    private func answerBounds(_ app: XCUIApplication, viewport: XCUIElement) -> CGRect {
        let bounds = viewport.frame.intersection(app.frame)
        let inReview = app.buttons["companion-grant-review-close"].exists
        let navigation = inReview ? app.navigationBars["Review permission"] : app.navigationBars.firstMatch
        let top = max(bounds.minY, navigation.frame.maxY)
        var bottom = bounds.maxY
        if inReview {
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
            return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
        }
        let composer = element(app, "companion-composer-region")
        if composer.exists { bottom = min(bottom, composer.frame.minY) }
        let activity = app.staticTexts["companion-chat-activity"]
        if activity.exists { bottom = min(bottom, activity.frame.minY) }
        if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
        if app.tabBars.firstMatch.exists { bottom = min(bottom, app.tabBars.firstMatch.frame.minY) }
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
    }

    private func openReview(_ app: XCUIApplication, name: String, requiresFallback: Bool) {
        let review = app.buttons["companion-grant-review"]
        if requiresFallback { XCTAssertTrue(review.waitForExistence(timeout: 5), "Insufficient space offers Review") }
        capture(app, name + " compact row")
        if review.exists {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let visible = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(0, bottom - top))
            XCTAssertTrue(review.isHittable && pixelContains(visible, review.frame), "Review is entirely above the keyboard and below navigation")
            assertMinimumTarget(review, "Review")
            waitAndTap(review, until: app.buttons["companion-grant-review-close"], attempts: 1)
        }
    }

    private func verifyAnswer(_ app: XCUIApplication, name: String, requiresFallback: Bool = false) {
        openReview(app, name: name, requiresFallback: requiresFallback)
        let viewport = app.scrollViews.containing(.button, identifier: "grant-request-allow").firstMatch
        for id in ["grant-request-allow", "grant-request-decline"] {
            let answer = app.buttons[id]
            for _ in 0..<12 {
                let bounds = answerBounds(app, viewport: viewport)
                if answer.exists && answer.isHittable && pixelContains(bounds, answer.frame) { break }
                XCTAssertGreaterThan(bounds.height, 44)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * 0.8))
                let end = origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * 0.2))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            capture(app, name + " review sheet " + id)
            let bounds = answerBounds(app, viewport: viewport)
            XCTAssertTrue(answer.isEnabled && answer.isHittable && pixelContains(bounds, answer.frame),
                          "\(name): complete \(id) must be reachable: \(answer.frame) in \(bounds)")
            assertMinimumTarget(answer, id)
        }
        let close = app.buttons["companion-grant-review-close"]
        if close.exists { waitAndTap(close, untilGone: close, attempts: 1) }
        XCTAssertTrue(element(app, "companion-chat-grant-requests").exists, "Reviewing sends no decision")
    }

    func testPortraitDefault() {
        let app = openRiver()
        verifyAnswer(app, name: "QA368 portrait default")
        focus(app)
        verifyAnswer(app, name: "QA368 portrait default keyboard")
    }

    func testPortraitAX5() {
        let app = openRiver(accessibility: true)
        verifyAnswer(app, name: "QA368 portrait AX5", requiresFallback: true)
        focus(app)
        verifyAnswer(app, name: "QA368 portrait AX5 keyboard", requiresFallback: true)
    }

    func testLandscapeDefaultKeyboard() {
        let app = openRiver()
        focus(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Rotation keeps the draft's keyboard")
        verifyAnswer(app, name: "QA368 landscape default keyboard", requiresFallback: true)
    }

    func testLandscapeAX5Keyboard() {
        let app = openRiver(accessibility: true)
        focus(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Rotation keeps the draft's keyboard")
        verifyAnswer(app, name: "QA368 landscape AX5 keyboard", requiresFallback: true)
    }

    func testGoneNoticeFromNeedsYouChat() {
        let app = openRiver(extra: ["--qa368-grant-gone"], fromNeedsYou: true)
        verifyAnswer(app, name: "QA368 gone request before answer")
        openReview(app, name: "QA368 gone request", requiresFallback: false)
        XCTAssertTrue(scrollIntoClearArea(app.buttons["grant-request-allow"], in: app))
        app.buttons.matching(identifier: "grant-request-allow").firstMatch.tap()
        let alert = app.alerts["Request no longer waiting"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture(app, "QA368 gone request notice")
        XCTAssertTrue(alert.staticTexts["QA grant is no longer waiting."].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element(app, "companion-chat-grant-requests").exists)
        waitAndTap(app.navigationBars.buttons.firstMatch, until: app.navigationBars["Needs you"])
        XCTAssertFalse(app.alerts.firstMatch.exists, "The parent must not present the notice again")
    }

    func testRefusalInChatKeepsRequestAndError() {
        let app = openRiver(extra: ["--qa368-grant-refused"], fromNeedsYou: true)
        verifyAnswer(app, name: "QA368 refused request before answer")
        openReview(app, name: "QA368 refused request", requiresFallback: false)
        XCTAssertTrue(scrollIntoClearArea(app.buttons["grant-request-allow"], in: app))
        app.buttons.matching(identifier: "grant-request-allow").firstMatch.tap()
        XCTAssertTrue(element(app, "grant-request-error").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["grant-request-allow"].exists)
        XCTAssertEqual(element(app, "grant-request-error").label, "QA permission could not be saved.")
        capture(app, "QA368 refused request error")
    }
}
