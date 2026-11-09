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
        XCTAssertTrue(scrollIntoClearArea(red, in: app), "Red is clear of the floating chrome: \(red.frame)")
        red.tap()
        let submit = app.buttons["send-answers-complete"]
        XCTAssertTrue(scrollTo(submit, in: app))
        // safeAreaBar keeps transcript elements in the accessibility tree underneath the glass composer.
        // Hittable alone can select a point covered by that bar; expose the actual answer before tapping.
        let region = app.descendants(matching: .any).matching(identifier: "companion-composer-region").firstMatch
        if keyboardUp {
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            composer.typeText("Keep this draft")
        }
        let header = app.descendants(matching: .any).matching(identifier: "companion-chat-header").firstMatch
        let navigation = app.buttons["companion-previous-message"]
        for _ in 0..<6 {
            let bottom = min(region.frame.minY, navigation.exists ? navigation.frame.minY : region.frame.minY)
            if submit.frame.maxY < bottom { break }
            let top = header.frame.maxY + 12
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: top + (bottom - top) * 0.8))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: top + (bottom - top) * 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertLessThan(submit.frame.maxY, region.frame.minY)
        if navigation.exists { XCTAssertLessThan(submit.frame.maxY, navigation.frame.minY) }
        print("QUESTION_VIEWPORT keyboardUp=\(keyboardUp) submit=\(submit.frame) composer=\(region.frame) navigation=\(navigation.frame)")
        XCTAssertTrue(submit.isEnabled)
        if keyboardUp { XCTAssertTrue(app.keyboards.firstMatch.exists, "The last question stays reachable with the keyboard up") }
        submit.tap()
        let error = app.staticTexts["Preview only. This action does not contact a desktop."]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "The complete question attempts the preview command")
        XCTAssertTrue(error.isHittable, "Command failures remain visible above the transcript")
        XCTAssertLessThan(error.frame.maxY, region.frame.minY)
        if keyboardUp { XCTAssertEqual(composer.value as? String, "Keep this draft") }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Question failure visible, keyboard up \(keyboardUp)"; shot.lifetime = .keepAlways; add(shot)
    }
}
