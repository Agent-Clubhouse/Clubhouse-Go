import XCTest

@MainActor final class CompanionDesktopQuestionsUITests: ReliableUITestCase {
    /// Uses the production grouping, jump resolver and question review sheet with unchanged preview questions.
    func testGroupedQuestionJumpsAnswerableReviewAndDetentsInLightXXXLAndDark() {
        let appearances: [(String, [String])] = [
            ("light XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
            ("dark", ["--companion-preview-dark"])
        ]
        for (name, flags) in appearances {
            let app = launchApp(["--companion-preview", "--companion-preview-questions"] + flags, attempts: 1)
            let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
            XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
            let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
            waitAndTap(river, until: composer, attempts: 1)
            let summary = app.descendants(matching: .any).matching(identifier: "companion-desktop-questions").firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 10))
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "companion-desktop-questions").count, 1)
            XCTAssertTrue(summary.label.contains("2 questions this phone can't answer"), summary.label)
            XCTAssertTrue(summary.label.contains("Answer them in Clubhouse on Studio Mac."), summary.label)
            let transcript = app.scrollViews["companion-transcript"]
            let show = app.buttons["companion-decision-show-in-chat"]
            // Both original request identities must resolve to the one visible timeline row.
            for index in 1...2 {
                XCTAssertEqual(show.value as? String, "\(index) of 3 waiting · Question")
                XCTAssertTrue(show.isHittable)
                show.tap()
                XCTAssertTrue(waitFor(summary, NSPredicate { _, _ in
                    let tray = app.descendants(matching: .any).matching(identifier: "companion-pinned-decision").firstMatch.frame
                    let top = max(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY)
                    let visible = CGRect(x: transcript.frame.minX, y: top, width: transcript.frame.width, height: max(0, tray.minY - top))
                    // Short transcripts clamp at their scroll extent; fitting rows must be
                    // fully visible. Oversized AX rows instead expose their jump anchor.
                    if summary.frame.height <= visible.height { return self.pixelContains(visible, summary.frame) }
                    return abs(summary.frame.minY - top) <= 24
                        && summary.frame.minY < visible.maxY && summary.frame.maxY > top
                }, timeout: 5), "Original request \(index) jumps to the grouped summary: \(summary.frame), \(transcript.frame)")
                if index == 2 { capture(app, "\(name) later-member jump and grouped summary") }
                swipeToNextQuestion(in: app)
            }
            XCTAssertEqual(show.value as? String, "3 of 3 waiting · Question")
            XCTAssertEqual(show.label, "Which color?")
            let close = app.buttons["companion-approval-review-close"]
            waitAndTap(app.buttons["companion-decision-answer"], until: close, attempts: 1)
            XCTAssertTrue(close.isHittable)
            let review = app.scrollViews["companion-approval-review-scroll"]
            let nav = app.navigationBars["Review question"]
            XCTAssertTrue(waitFor(nav, NSPredicate { _, _ in nav.frame.minY > app.frame.height * 0.30 }, timeout: 5),
                          "Question review initially uses its medium detent")
            let mediumTop = nav.frame.minY
            capture(app, "\(name) medium question sheet")
            // Drag the actual sheet's upper edge, rather than scrolling its answer content.
            let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: mediumTop - 12))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: -app.frame.height * 0.40)), withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(waitFor(nav, NSPredicate { _, _ in nav.frame.minY < mediumTop - app.frame.height * 0.15 }, timeout: 5),
                          "The question sheet expands to its large detent")
            let red = review.buttons["Red"]
            XCTAssertTrue(scrollTo(red, in: app) && red.isEnabled && red.isHittable)
            red.tap()
            let submit = review.buttons["send-answers-complete"]
            XCTAssertTrue(scrollTo(submit, in: app))
            XCTAssertTrue(submit.isEnabled && submit.isHittable, "The answerable request keeps its real answer controls")
            XCTAssertFalse(review.staticTexts["desktop-answer-complete"].exists)
            capture(app, "\(name) large question sheet with answer enabled")
            // Opening, jumping, selecting and dismissing do not submit an answer.
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertEqual(show.value as? String, "3 of 3 waiting · Question")
            XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
            app.terminate()
        }
    }

    /// #448 replaces pager controls with a real horizontal, selection-only swipe.
    private func swipeToNextQuestion(in app: XCUIApplication) {
        let frame = app.buttons["companion-decision-show-in-chat"].frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.85, dy: frame.midY))
        let distance = frame.width * 0.7
        XCTAssertGreaterThan(distance, 44)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -distance, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Desktop questions — \(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
