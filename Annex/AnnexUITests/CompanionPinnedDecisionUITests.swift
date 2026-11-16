import XCTest
import Vision

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
    private func summary(_ app: XCUIApplication) -> XCUIElement { app.buttons["companion-decision-show-in-chat"] }
    private func swipe(_ app: XCUIApplication, next: Bool) {
        let frame = summary(app).frame
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * (next ? 0.85 : 0.15), dy: frame.midY))
        let distance = frame.width * 0.7 * (next ? -1.0 : 1.0)
        XCTAssertGreaterThan(abs(distance), 44, "A real horizontal swipe must cross the selection threshold")
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: distance, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    private func openReview(_ app: XCUIApplication, until close: XCUIElement) {
        summary(app).press(forDuration: 0.8)
        waitAndTap(app.buttons["companion-review-approval"], until: close, attempts: 1)
    }
    private func awaitApproval(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "companion-pinned-decision").waitForExistence(timeout: 20))
        XCTAssertEqual(summary(app).label, "Run preview build")
        XCTAssertEqual(summary(app).value as? String, "1 of 3 waiting · Bash")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func assertVisibleLabel(_ button: XCUIElement, text: String) throws {
        let image = try XCTUnwrap(button.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(lines.contains(text), "The visible action label is whole: \(text), OCR \(lines)")
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
        for id in ["companion-decision-show-in-chat", "Deny", "Allow once"] {
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id)).count, 1,
                           "Only the fitting action layout is exposed")
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, id)
            // This tray's controls retain >=44pt targets in both expanded and compact layouts.
            assertMinimumTarget(button, id)
        }
    }
    private func awaitManyUpdates(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["companion-notice-notice:pinned-progress-50"].waitForExistence(timeout: 25),
                      "At least 30 tool updates must arrive after the approval")
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

    func testPinnedAnswersSwipesQuestionsAndCloseShareOneDecisionState() {
        let app = openRiver()
        awaitApproval(app)
        swipe(app, next: true)
        XCTAssertEqual(summary(app).label, "Edit preview notes")
        XCTAssertEqual(summary(app).value as? String, "2 of 3 waiting · Bash")
        swipe(app, next: false)
        app.buttons["Allow once"].tap()
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in self.summary(app).label == "Edit preview notes" }, timeout: 5))
        XCTAssertEqual(summary(app).value as? String, "1 of 2 waiting · Bash")
        swipe(app, next: true)
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(app.buttons["companion-decision-answer"], until: close, attempts: 1)
        XCTAssertTrue(app.buttons["Red"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(summary(app).label, "Which color?", "Dismissal sends nothing")
        waitAndTap(app.buttons["companion-decision-answer"], until: close, attempts: 1)
        app.buttons["Red"].tap()
        app.buttons["send-answers-pinned-question"].tap()
        XCTAssertTrue(app.staticTexts["Answered"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(summary(app).label, "Edit preview notes")
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

    func testKeyboardKeepsPendingTrayAndDraftUsableOnSmallPhones() throws {
        let app = openRiver()
        awaitApproval(app)
        assertPinned(app)
        let tray = element(app, "companion-pinned-decision")
        let expandedHeight = tray.frame.height
        XCTAssertTrue(app.buttons["Allow once"].exists && app.buttons["Deny"].exists, "Roomy reading retains expanded decisions")
        try assertVisibleLabel(app.buttons["companion-decision-show-in-chat"], text: "Show in chat")
        try assertVisibleLabel(app.buttons["companion-review-approval"], text: "Review request")
        capture(app, "Roomy expanded tray before keyboard")
        let composer = element(app, "companion-composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Keep this draft")
        awaitApproval(app)
        assertPinned(app, keyboard: true)
        XCTAssertLessThan(tray.frame.height, expandedHeight, "The keyboard uses the compact tray rather than compressing the draft")
        XCTAssertFalse(app.buttons["Allow once"].exists, "Keyboard-up decisions remain available through compact Review")
        XCTAssertFalse(app.buttons["Deny"].exists)
        let show = app.buttons["companion-decision-show-in-chat"]
        let review = app.buttons["companion-review-approval"]
        XCTAssertEqual(show.label, "Show in chat", "Compact visible text keeps the full AX meaning")
        XCTAssertEqual(review.label, "Review approval: Run preview build, 1 of 3")
        try assertVisibleLabel(show, text: "Chat")
        try assertVisibleLabel(review, text: "Review")
        if app.frame.width < 390 {
            XCTAssertFalse(app.buttons["Allow once"].exists, "Small phones use compact Review while the keyboard is up")
            XCTAssertFalse(app.buttons["Deny"].exists)
        }
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue((app.scrollViews["companion-transcript"].value as? String)?.hasPrefix("Following: 1; pauses: 0") == true)
        capture(app, "Small phone: pending approval above composer and keyboard")
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(review, until: close, attempts: 1)
        XCTAssertTrue(app.staticTexts["Synthetic request for Run preview build. Full context stays in chat."].exists)
        let viewport = app.scrollViews["companion-approval-review-scroll"]
        for label in ["Allow once", "Deny"] {
            let decision = viewport.buttons[label]
            XCTAssertTrue(scrollTo(decision, in: app, maxSwipes: 8))
            XCTAssertTrue(decision.isEnabled && decision.isHittable)
            // Full-card Review buttons have a pre-existing smaller standard-size target.
            // This regression checks reachability here; >=44pt is asserted on the compact tray above.
        }
        waitAndTap(close, untilGone: close, attempts: 1)
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        awaitApproval(app)
    }

    func testLandscapeAndAX5KeepReviewContextAndDecisionsReachable() {
        let app = openRiver(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        awaitApproval(app)
        assertPinned(app)
        capture(app, "AX5: bounded pending request and composer")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        assertPinned(app)
        let close = app.buttons["companion-approval-review-close"]
        openReview(app, until: close)
        let review = app.scrollViews["companion-approval-review-scroll"]
        XCTAssertTrue(review.exists)
        let allow = review.buttons["Allow once"]
        for _ in 0..<8 {
            if allow.exists && allow.isHittable && pixelContains(review.frame, allow.frame) { break }
            review.swipeUp(velocity: .slow)
        }
        capture(app, "AX5 landscape: scrollable approval decisions")
        XCTAssertTrue(allow.isEnabled && allow.isHittable, "The review's decision stays reachable: \(allow.frame), \(review.frame)")
    }
    func testSwipesAndTitleTapsNeverSendADecision() {
        let app = openRiver()
        awaitApproval(app)
        swipe(app, next: false)
        XCTAssertEqual(summary(app).label, "Run preview build", "The first boundary does not wrap")
        swipe(app, next: true)
        XCTAssertEqual(summary(app).label, "Edit preview notes")
        XCTAssertEqual(summary(app).value as? String, "2 of 3 waiting · Bash")
        swipe(app, next: true)
        XCTAssertEqual(summary(app).label, "Which color?")
        XCTAssertEqual(summary(app).value as? String, "3 of 3 waiting · Question")
        XCTAssertTrue(app.buttons["companion-decision-answer"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists || app.buttons["Allow once"].exists)
        swipe(app, next: true)
        XCTAssertEqual(summary(app).label, "Which color?", "The last boundary does not wrap")
        swipe(app, next: false); swipe(app, next: false)
        awaitManyUpdates(app)
        summary(app).tap()
        XCTAssertTrue(app.staticTexts["Synthetic request for Run preview build. Full context stays in chat."].waitForExistence(timeout: 5))
        XCTAssertEqual(summary(app).label, "Run preview build")
        XCTAssertEqual(summary(app).value as? String, "1 of 3 waiting · Bash", "Every original request is still pending")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Synthetic request for Run preview build. Full context stays in chat."].exists)
        let close = app.buttons["companion-approval-review-close"]
        openReview(app, until: close)
        XCTAssertTrue(app.scrollViews["companion-approval-review-scroll"].exists, "The final title node retains its long-press Review menu")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(summary(app).label, "Run preview build")
        XCTAssertEqual(summary(app).value as? String, "1 of 3 waiting · Bash", "Review dismissal also sends nothing")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
        capture(app, "Swipe selection and title jump send no decision")
    }

    func testBroaderAndCustomOptionsStayInReviewAndKeepConfirmation() {
        let app = openRiver(extra: ["--companion-preview-pinned-broader-only"])
        awaitApproval(app)
        XCTAssertFalse(app.buttons["Allow once"].exists, "Neither Always nor a custom kind with this label may become inline Allow once")
        XCTAssertFalse(app.buttons["Always allow"].exists)
        XCTAssertTrue(app.buttons["Deny"].isEnabled)
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(app.buttons["companion-review-approval"], until: close, attempts: 1)
        let review = app.scrollViews["companion-approval-review-scroll"]
        let always = review.buttons["Always allow"]
        XCTAssertTrue(scrollTo(always, in: app) && always.isHittable)
        always.tap()
        XCTAssertTrue(app.staticTexts["Always allow?"].waitForExistence(timeout: 5), "A broader permission keeps its existing confirmation")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
        app.buttons["Cancel"].tap()
        close.tap()
        XCTAssertEqual(summary(app).value as? String, "1 of 3 waiting · Bash")
    }

    func testIncompleteRequestDisablesAllowButKeepsDenyAvailable() {
        let app = openRiver(extra: ["--companion-preview-pinned-incomplete"])
        awaitApproval(app)
        XCTAssertFalse(app.buttons["Allow once"].isEnabled)
        XCTAssertTrue(app.buttons["Deny"].isEnabled)
        app.buttons["Deny"].tap()
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in self.summary(app).label == "Edit preview notes" }, timeout: 5))
        XCTAssertEqual(summary(app).value as? String, "1 of 2 waiting · Bash")
    }

    func testLightDecisionBar() { appearance("light", flags: ["--companion-preview-light"]) }
    func testDarkDecisionBar() { appearance("dark", flags: ["--companion-preview-dark"]) }
    func testLatteDecisionBar() { appearance("Catppuccin Latte", flags: ["--companion-preview-light", "--companion-preview-theme-latte"]) }
    func testMochaDecisionBar() { appearance("Catppuccin Mocha", flags: ["--companion-preview-dark", "--companion-preview-theme-mocha"]) }
    func testAccessibilityDecisionBar() {
        appearance("accessibility XXXL", flags: ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
    private func appearance(_ name: String, flags: [String]) {
        let app = openRiver(extra: flags)
        awaitApproval(app)
        assertPinned(app)
        XCTAssertLessThan(app.buttons["Deny"].frame.midX, app.buttons["Allow once"].frame.midX)
        XCTAssertFalse(app.buttons["companion-pinned-decision-previous"].exists)
        XCTAssertFalse(app.buttons["companion-pinned-decision-next"].exists)
        capture(app, "Decision bar — \(name)")
    }

}
