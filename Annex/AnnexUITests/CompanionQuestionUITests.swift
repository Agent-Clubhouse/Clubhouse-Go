import XCTest

@MainActor final class CompanionQuestionUITests: ReliableUITestCase {
    func testIncompleteQuestionsRequireDesktopAndCompleteQuestionCanBeAnswered() {
        let app = launchApp(["--companion-preview", "--companion-preview-questions"])
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(river, until: composer)
        for id in ["empty", "partial"] {
            let notice = app.staticTexts["desktop-answer-\(id)"]
            XCTAssertTrue(scrollTo(notice, in: app, up: false))
            XCTAssertEqual(notice.label, "Answer this question on the desktop. This phone can't show all of its prompts.")
            let submit = app.buttons["send-answers-\(id)"]
            XCTAssertTrue(submit.exists)
            XCTAssertFalse(submit.isEnabled)
        }
        let red = app.buttons["Red"]
        XCTAssertTrue(scrollTo(red, in: app))
        red.tap()
        let submit = app.buttons["send-answers-complete"]
        XCTAssertTrue(scrollTo(submit, in: app))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 10), "The complete question attempts the preview command")
    }
}
