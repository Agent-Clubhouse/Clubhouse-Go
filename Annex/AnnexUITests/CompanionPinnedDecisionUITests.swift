import XCTest

@MainActor final class CompanionPinnedDecisionUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openRiver(extra: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream",
                             "--companion-preview-pinned-decisions", "--companion-preview-follow-trace"] + extra, attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-composer"), attempts: 1)
        return app
    }
    private func awaitApproval(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "companion-pinned-decision").waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-summary"].label, "Run preview build")
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-position"].label, "Request 1 of 3")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func assertPinned(_ app: XCUIApplication, keyboard: Bool = false) {
        let tray = element(app, "companion-pinned-decision")
        let composer = element(app, "companion-composer-region")
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = keyboard ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
        let visible = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
        XCTAssertTrue(pixelContains(visible, tray.frame), "The pending card stays above the composer: \(tray.frame), \(visible)")
        XCTAssertLessThanOrEqual(tray.frame.maxY, composer.frame.minY)
        XCTAssertTrue(pixelContains(visible, composer.frame), "The composer stays usable")
        for id in ["companion-review-approval", "companion-decision-show-in-chat", "companion-pinned-decision-next"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, id)
            assertMinimumTarget(button, id)
        }
    }
    private func awaitManyUpdates(_ app: XCUIApplication) {
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic tool updates: "))
                .allElementsBoundByIndex.contains { (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) >= 50 }
        }, timeout: 25), "At least 30 tool updates must arrive after the approval")
    }

    func testApprovalArrivesWhileStreamingAndStaysPinnedWithoutPausingFollow() {
        let app = openRiver()
        awaitApproval(app)
        assertPinned(app)
        awaitManyUpdates(app)
        assertPinned(app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Allow once")).count, 1,
                       "Only the selected pinned request has actionable decisions")
        XCTAssertTrue((app.scrollViews["companion-transcript"].value as? String)?.hasPrefix("Following: 1; pauses: 0") == true)
        capture(app, "After: approval stays pinned after 30 streaming tool updates")
    }

    func testPinnedAnswersPagerQuestionsAndCloseShareOneDecisionState() {
        let app = openRiver()
        awaitApproval(app)
        app.buttons["companion-pinned-decision-next"].tap()
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-summary"].label, "Edit preview notes")
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-position"].label, "Request 2 of 3")
        app.buttons["companion-pinned-decision-previous"].tap()
        app.buttons["Allow once"].tap()
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.staticTexts["companion-pinned-decision-summary"].label == "Edit preview notes" }, timeout: 5))
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-position"].label, "Request 1 of 2")
        app.buttons["companion-pinned-decision-next"].tap()
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(app.buttons["companion-review-approval"], until: close, attempts: 1)
        XCTAssertTrue(app.buttons["Red"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-summary"].label, "Which color?", "Dismissal sends nothing")
        waitAndTap(app.buttons["companion-review-approval"], until: close, attempts: 1)
        app.buttons["Red"].tap()
        app.buttons["send-answers-pinned-question"].tap()
        XCTAssertTrue(app.staticTexts["Answered"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["companion-pinned-decision-summary"].label, "Edit preview notes")
        app.buttons["Deny"].tap()
        XCTAssertTrue(element(app, "companion-pinned-decision").waitForNonExistence(timeout: 5))
    }

    func testShowInChatRevealsOriginalRequestOutsideTheTimelineWindow() {
        let app = openRiver()
        awaitApproval(app)
        awaitManyUpdates(app)
        app.buttons["companion-decision-show-in-chat"].tap()
        let context = app.staticTexts["Synthetic request for Run preview build. Full context stays in chat."]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = element(app, "companion-pinned-decision").frame.minY
        XCTAssertTrue(pixelContains(CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top), context.frame))
        XCTAssertTrue((app.scrollViews["companion-transcript"].value as? String)?.hasPrefix("Following: 0;") == true)
        assertPinned(app)
        capture(app, "Show in chat: original request and pinned decisions")
    }

    func testKeyboardKeepsPendingTrayAndDraftUsableOnSmallPhones() {
        let app = openRiver()
        let composer = element(app, "companion-composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Keep this draft")
        awaitApproval(app)
        assertPinned(app, keyboard: true)
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue((app.scrollViews["companion-transcript"].value as? String)?.hasPrefix("Following: 1; pauses: 0") == true)
        capture(app, "Small phone: pending approval above composer and keyboard")
    }

    func testLandscapeAndAX5KeepCompactReviewContextAndPagerReachable() {
        let app = openRiver(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        awaitApproval(app)
        assertPinned(app)
        capture(app, "AX5: bounded pending request and composer")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        assertPinned(app)
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(app.buttons["companion-review-approval"], until: close, attempts: 1)
        XCTAssertTrue(app.staticTexts["Synthetic request for Run preview build. Full context stays in chat."].exists)
        let allow = app.buttons["Allow once"]
        XCTAssertTrue(scrollTo(allow, in: app) && allow.isEnabled && allow.isHittable)
        capture(app, "AX5 landscape: scrollable approval decisions")
    }
}
