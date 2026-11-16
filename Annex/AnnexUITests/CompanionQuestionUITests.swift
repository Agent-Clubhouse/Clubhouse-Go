import XCTest

@MainActor final class CompanionQuestionUITests: ReliableUITestCase {
    func testIncompleteQuestionsRequireDesktopAndCompleteQuestionCanBeAnswered() { checkQuestion(keyboardUp: false) }

    func testLastQuestionCanScrollClearOfComposerAndNavigationWhileEditing() { checkQuestion(keyboardUp: true) }

    /// #448 replaces the request pager with selection-only horizontal swipes.
    private func swipeToNextQuestion(in app: XCUIApplication) {
        let frame = app.buttons["companion-decision-show-in-chat"].frame
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.85, dy: frame.midY))
        let distance = frame.width * 0.7
        XCTAssertGreaterThan(distance, 44, "A real swipe crosses the selection threshold")
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -distance, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func checkQuestion(keyboardUp: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-questions"])
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(river, until: composer)
        if keyboardUp {
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            composer.typeText("Keep this draft")
        }
        let close = app.buttons["companion-approval-review-close"]
        for id in ["empty", "partial"] {
            XCTAssertFalse(app.buttons["send-answers-\(id)"].exists, "Inline history has no second answer surface")
            waitAndTap(app.buttons["companion-decision-answer"], until: close)
            let notice = app.scrollViews["companion-approval-review-scroll"].staticTexts["desktop-answer-\(id)"]
            XCTAssertTrue(notice.exists)
            XCTAssertEqual(notice.label, "Answer this question on the desktop. This phone can't show all of its prompts.")
            XCTAssertFalse(app.buttons["send-answers-\(id)"].isEnabled)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            swipeToNextQuestion(in: app)
        }
        waitAndTap(app.buttons["companion-decision-answer"], until: close)
        let red = app.buttons["Red"]
        XCTAssertTrue(scrollTo(red, in: app))
        red.tap()
        let submit = app.buttons["send-answers-complete"]
        XCTAssertTrue(scrollTo(submit, in: app))
        XCTAssertTrue(submit.isEnabled && submit.isHittable)
        submit.tap()
        let error = app.staticTexts.matching(identifier: "Preview only. This action does not contact a desktop.").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "The complete question attempts the preview command")
        XCTAssertTrue(scrollTo(error, in: app) && error.isHittable, "Failures remain reachable in the pinned review")
        if keyboardUp {
            let sheet = app.scrollViews["companion-approval-review-scroll"]
            let card = app.descendants(matching: .any).matching(identifier: "companion-approval-review-question-card").firstMatch
            XCTAssertTrue(card.exists)
            XCTAssertLessThanOrEqual(card.frame.maxX, sheet.frame.maxX + 1, "The card stays within the medium sheet after draft keyboard use")
            XCTAssertGreaterThanOrEqual(card.frame.minX, sheet.frame.minX - 1)
            XCTAssertLessThanOrEqual(error.frame.maxX, sheet.frame.maxX + 1, "The error wraps within the sheet")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pinned question failure, draft keyboard previously up \(keyboardUp)"; shot.lifetime = .keepAlways; add(shot)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        if keyboardUp {
            XCTAssertEqual(composer.value as? String, "Keep this draft")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Closing review restores the draft keyboard")
        }
    }
}
