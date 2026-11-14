import XCTest

@MainActor final class CompanionQuestionUITests: ReliableUITestCase {
    func testIncompleteQuestionsRequireDesktopAndCompleteQuestionCanBeAnswered() { checkQuestion(keyboardUp: false) }

    func testLastQuestionCanScrollClearOfComposerAndNavigationWhileEditing() { checkQuestion(keyboardUp: true) }

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
            waitAndTap(app.buttons["companion-review-approval"], until: close)
            let notice = app.scrollViews["companion-approval-review-scroll"].staticTexts["desktop-answer-\(id)"]
            XCTAssertTrue(notice.exists)
            XCTAssertEqual(notice.label, "Answer this question on the desktop. This phone can't show all of its prompts.")
            XCTAssertFalse(app.buttons["send-answers-\(id)"].isEnabled)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            app.buttons["companion-pinned-decision-next"].tap()
        }
        waitAndTap(app.buttons["companion-review-approval"], until: close)
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
