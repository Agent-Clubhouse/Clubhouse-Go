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
        openPinnedDecisionReview(in: app, until: close)
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
    private func assertPinned(_ app: XCUIApplication, keyboard: Bool = false, compact: Bool = false) {
        let tray = element(app, "companion-pinned-decision")
        let composer = element(app, "companion-composer-region")
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = keyboard ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
        let visible = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
        XCTAssertTrue(pixelContains(visible, tray.frame), "The pending card stays above the composer: \(tray.frame), \(visible)")
        XCTAssertLessThanOrEqual(tray.frame.maxY, composer.frame.minY)
        XCTAssertTrue(pixelContains(visible, composer.frame), "The composer stays usable: \(composer.frame), \(visible)")
        let title = summary(app).label
        let position = summary(app).value as? String ?? ""
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", title, "\(title), \(position)")).count, 1,
                       "VoiceOver exposes one title button, with no second popup child")
        let compactActions = keyboard || compact
        if compactActions {
            XCTAssertFalse(app.buttons["Deny"].exists, "Option A keeps compact decisions inside Review")
            XCTAssertFalse(app.buttons["Allow once"].exists, "Option A keeps compact decisions inside Review")
        }
        let actionIDs = compactActions
            ? ["companion-decision-show-in-chat", "companion-review-approval"]
            : ["companion-decision-show-in-chat", "Deny", "Allow once"]
        for id in actionIDs {
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
        XCTAssertEqual(summary(app).value as? String, "2 of 3 waiting · Bash", "One swipe advances exactly one request")
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

    /// #543: typing first, then a request arrives. Every composer action stays above the keyboard. The tray shows one
    /// Review control only when the full rows do not fit, and the ticking activity line never flips it back and forth.
    func testRequestArrivingWhileTypingAtLargestTextKeepsEveryComposerActionAboveTheKeyboard() throws {
        try requestArrivingWhileTypingAtLargestText(appearance: [])
    }

    /// The same contract in dark appearance; also captures the Review-only look for review.
    func testRequestArrivingWhileTypingAtLargestTextInDarkKeepsEveryComposerActionAboveTheKeyboard() throws {
        try requireFullAppearanceMatrix("dark largest text")
        try requestArrivingWhileTypingAtLargestText(appearance: ["--companion-preview-dark"])
    }

    private func requestArrivingWhileTypingAtLargestText(appearance: [String]) throws {
        let app = openRiver(extra: ["--companion-preview-pinned-late", "--companion-preview-assistive-keyboard", "--companion-ui-test-fit-metrics",
                                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] + appearance)
        let states = try typeThenAwaitRequest(app)
        let reviewOnly = states[0] == "Review-only request controls"
        let review = app.buttons["companion-review-approval"]
        XCTAssertEqual(review.label, "Review approval: Run preview build, 1 of 3")
        if reviewOnly {
            XCTAssertEqual(review.value as? String, "1 of 3 waiting · Bash", "Position and tool stay complete for VoiceOver")
            XCTAssertFalse(summary(app).exists, "One Review control replaces the rows")
            // One snapshot for both frames: the working agent's activity line comes and goes between preview ticks and
            // reflows the footer by its height, so two separate queries could pair frames from different layouts (#545).
            let (tray, footer) = try frames(app, "companion-pinned-decision", "companion-grant-footer-scroll")
            XCTAssertGreaterThanOrEqual(pixelAligned(tray.minY), pixelAligned(footer.minY), "The waiting dot stays inside the card: \(tray), \(footer)")
        } else {
            // The full rows are shown only when they fit: the whole title stays above the composer and the keyboard.
            let title = summary(app).frame
            XCTAssertTrue(summary(app).exists)
            XCTAssertLessThanOrEqual(title.maxY, element(app, "companion-composer-region").frame.minY, "The full title fits above the composer")
            XCTAssertGreaterThanOrEqual(title.minY, app.navigationBars.firstMatch.frame.maxY, "The full title is not under the navigation bar")
        }
    }

    /// #543: standard text sizes never use the Review-only fallback, on any device.
    func testRequestArrivingWhileTypingAtStandardTextNeverCollapsesTheTray() throws {
        let app = openRiver(extra: ["--companion-preview-pinned-late", "--companion-preview-assistive-keyboard", "--companion-ui-test-fit-metrics"])
        let states = try typeThenAwaitRequest(app)
        XCTAssertFalse(states.contains("Review-only request controls"), "Standard sizes keep the title row: \(states)")
        XCTAssertTrue(summary(app).exists)
    }

    /// Two frames from ONE accessibility snapshot, so they always describe the same layout.
    private func frames(_ app: XCUIApplication, _ first: String, _ second: String) throws -> (CGRect, CGRect) {
        let root = try app.snapshot()
        var found: [String: CGRect] = [:]
        func visit(_ node: XCUIElementSnapshot) {
            if node.identifier == first || node.identifier == second, found[node.identifier] == nil { found[node.identifier] = node.frame }
            node.children.forEach(visit)
        }
        visit(root)
        return (try XCTUnwrap(found[first], first), try XCTUnwrap(found[second], second))
    }

    /// Diagnostic only (#545): one console line with every frame that shares the room above the keyboard, so a
    /// cancelled CI lane (no uploaded bundle) still shows what takes the footer's room. No assertions.
    private func printFooterRoom(_ app: XCUIApplication, sample: String = "arrival") {
        guard let root = try? app.snapshot() else { print("FOOTER_ROOM sample=\(sample) snapshot unavailable"); return }
        var frames: [String: CGRect] = [:], values: [String: String] = [:]
        var navigation: CGRect?, keyboardTop: CGFloat?, paused: CGRect?
        func visit(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if node.elementType == .navigationBar, navigation == nil { navigation = node.frame }
            if node.elementType == .keyboard || id == "SystemInputAssistantView", node.frame.intersects(root.frame) {
                keyboardTop = min(keyboardTop ?? .infinity, node.frame.minY)
            }
            if id == "companion-latest", (node.value as? String) == "Reading earlier messages" { paused = node.frame }
            if !id.isEmpty, frames[id] == nil { frames[id] = node.frame; values[id] = node.value as? String }
            node.children.forEach(visit)
        }
        visit(root)
        func f(_ rect: CGRect?) -> String { rect.map { "(\($0.minX),\($0.minY),\($0.width),\($0.height))" } ?? "nil" }
        let ids = ["companion-chat-header", "companion-chat-header-actions", "companion-transcript", "companion-latest",
                   "companion-grant-footer-scroll", "companion-pinned-decision", "companion-chat-activity", "companion-composer-region"]
        let parts = ["sample=\(sample)", "window=\(f(root.frame))", "nav=\(f(navigation))", "pausedChat=\(f(paused))"]
            + ids.map { "\($0)=\(f(frames[$0]))" }
            + ["keyboardTop=\(keyboardTop.map { "\($0)" } ?? "nil")", "fit=\(values["companion-pinned-decision-fit"] ?? "nil")",
               "tray=\(values["companion-pinned-decision"] ?? "nil")"]
        print("FOOTER_ROOM " + parts.joined(separator: " "))
    }

    /// Types first, waits for the late request, then samples the tray across at least eight activity ticks (1s each).
    /// Returns the sampled tray states after asserting they are stable and that the composer stays above the keyboard.
    private func typeThenAwaitRequest(_ app: XCUIApplication) throws -> [String] {
        let composer = element(app, "companion-composer")
        let tray = element(app, "companion-pinned-decision")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        composer.typeText("Keep this draft")
        XCTAssertFalse(tray.exists, "The request must arrive after the keyboard is already up")
        // The late request arrives on preview tick 75 (`pinnedArrivalStep`). Hosted runners stretch the 400ms tick
        // (CI: fewer than 30 ticks in 25s), so wait on that tick's own notice, not on wall-clock time.
        XCTAssertTrue(app.staticTexts["companion-notice-notice:pinned-progress-75"].waitForExistence(timeout: 180),
                      "Preview tick 75, which carries the late request, must arrive")
        XCTAssertTrue(tray.waitForExistence(timeout: 20), "The late request's tray appears with its tick")
        let reviewButton = app.buttons["companion-review-approval"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10) || summary(app).exists, "The request is reachable")
        printFooterRoom(app)
        var states: [String] = []
        var activity: [String] = []
        let started = Date()
        while states.count < 8 || Date().timeIntervalSince(started) < 8 {
            states.append(tray.value as? String ?? "")
            let line = element(app, "companion-chat-activity")
            activity.append(line.exists ? line.label : "")
            // Diagnostic only (#545): the footer's room per tick, to catch a time-dependent shrink after arrival.
            printFooterRoom(app, sample: "\(states.count)")
            Thread.sleep(forTimeInterval: 1)
        }
        let samples = XCTAttachment(string: zip(states, activity).map { "\($0) | \($1)" }.joined(separator: "\n"))
        samples.name = "Tray state per activity tick"; samples.lifetime = .keepAlways; add(samples)
        capture(app, "Request arrived while typing")
        XCTAssertEqual(Set(states).count, 1, "The tray must not flip while the activity line ticks: \(states)")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Arrival keeps editing")
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        let region = element(app, "companion-composer-region").frame
        XCTAssertGreaterThan(pixelAligned(keyboardTop - region.maxY), 0, "Composer keeps a measured margin above the keyboard: \(region), \(keyboardTop)")
        var actions = ["companion-level-menu", "companion-send", "companion-dismiss-keyboard"]
        if app.buttons["companion-attach"].exists { actions.append("companion-attach") }
        if app.buttons["companion-interrupt"].exists { actions.append("companion-interrupt") }
        for id in actions {
            let frame = app.buttons[id].frame
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) stays reachable")
            XCTAssertLessThanOrEqual(frame.maxY, keyboardTop, "\(id) stays above the keyboard: \(frame)")
        }
        if reviewButton.exists {
            let review = reviewButton.frame
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).width, 44)
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).height, 44)
            XCTAssertLessThanOrEqual(review.maxY, region.minY, "Review stays above the composer")
        }
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        return states
    }

    func testKeyboardKeepsPendingTrayAndDraftUsableOnSmallPhones() throws {
        let app = openRiver()
        awaitApproval(app)
        assertPinned(app)
        let tray = element(app, "companion-pinned-decision")
        let expandedHeight = tray.frame.height
        XCTAssertEqual(tray.value as? String, "Expanded request controls")
        let roomyTitle = summary(app).frame
        let roomyDeny = app.buttons["Deny"].frame
        let roomyAllow = app.buttons["Allow once"].frame
        let roomyIsSingleRow = pixelAligned(roomyTitle.midY) == pixelAligned(roomyDeny.midY)
            && pixelAligned(roomyDeny.midY) == pixelAligned(roomyAllow.midY)
        XCTAssertTrue(app.buttons["Allow once"].exists && app.buttons["Deny"].exists, "Roomy reading retains expanded decisions")
        // #448 makes the request title itself the Chat action; Review also remains in its native menu.
        try assertVisibleLabel(summary(app), text: "Run preview build")
        try assertVisibleLabel(app.buttons["Deny"], text: "Deny")
        try assertVisibleLabel(app.buttons["Allow once"], text: "Allow once")
        capture(app, "Roomy expanded tray before keyboard")
        let composer = element(app, "companion-composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Keep this draft")
        awaitApproval(app)
        assertPinned(app, keyboard: true)
        // Equal height is legitimate only when the new roomy layout already fits one minimum-height row.
        // Keep strict shrinkage everywhere else: an arbitrary equal-height/taller compact tray still fails.
        if pixelAligned(tray.frame.height) == pixelAligned(expandedHeight) {
            let singleRowFloor: CGFloat = 44 + 2 * 4 // minimum target plus the card's vertical insets
            XCTAssertEqual(pixelAligned(expandedHeight), singleRowFloor)
            XCTAssertEqual(pixelAligned(tray.frame.height), singleRowFloor)
            XCTAssertTrue(roomyIsSingleRow, "Equality requires a genuinely single-row roomy layout")
        } else {
            XCTAssertLessThan(tray.frame.height, expandedHeight, "The keyboard uses the compact tray rather than compressing the draft")
        }
        XCTAssertEqual(tray.value as? String, "Compact request controls", "The actual compact policy must activate")
        XCTAssertLessThanOrEqual(tray.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(element(app, "companion-composer-region").frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertFalse(app.buttons["Allow once"].exists, "Keyboard-up decisions remain available through compact Review")
        XCTAssertFalse(app.buttons["Deny"].exists)
        let show = app.buttons["companion-decision-show-in-chat"]
        let review = app.buttons["companion-review-approval"]
        XCTAssertEqual(show.label, "Run preview build", "The compact title keeps the full request identity")
        XCTAssertEqual(show.value as? String, "1 of 3 waiting · Bash")
        XCTAssertEqual(review.label, "Review approval: Run preview build, 1 of 3")
        try assertVisibleLabel(show, text: "Run preview build")
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

    func testLandscapeAndAX5KeepReviewContextAndDecisionsReachable() throws {
        let app = openRiver(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        awaitApproval(app)
        assertPinned(app, compact: true)
        capture(app, "AX5: bounded pending request and composer")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in app.frame.width > app.frame.height }, timeout: 5))
        capture(app, "AX5 landscape: pending bar and composer containment")
        assertPinned(app, compact: true)
        // Option A preserves Review at AX sizes; full-card decisions are checked below.
        for label in ["Review"] {
            let button = app.buttons["companion-review-approval"]
            XCTAssertEqual(button.label, "Review approval: Run preview build, 1 of 3")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(button.screenshot().image.cgImage)).perform([request])
            let text = try XCTUnwrap(request.results).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertTrue(text.contains(label), "The landscape action is visibly whole, without ellipsis: \(text)")
        }
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
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists,
                       "Opening the native menu and Review sends nothing")
    }
    func testSwipesAndTitleTapsNeverSendADecision() {
        let app = openRiver()
        awaitApproval(app)
        swipe(app, next: false)
        XCTAssertEqual(summary(app).label, "Run preview build", "The first boundary does not wrap")
        let titleFrame = summary(app).frame
        let verticalStart = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: titleFrame.midX, dy: titleFrame.midY))
        verticalStart.press(forDuration: 0.05, thenDragTo: verticalStart.withOffset(CGVector(dx: 0, dy: -60)),
                            withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(summary(app).label, "Run preview build", "A mostly vertical drag never changes selection")
        swipe(app, next: true)
        XCTAssertEqual(summary(app).label, "Edit preview notes")
        XCTAssertEqual(summary(app).value as? String, "2 of 3 waiting · Bash", "One swipe advances exactly one request")
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

    func testNativeReviewMenuStaysStableAcrossTwoFormerTicksBeforeOneTouch() {
        let app = openRiver()
        awaitApproval(app)
        awaitManyUpdates(app)
        summary(app).press(forDuration: 0.8)
        let item = app.buttons["companion-decision-review-menu"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "companion-decision-review-menu").count, 1)
        var readyFrame: CGRect?
        var unchangedSince = ContinuousClock.now
        let ready = waitFor(item, NSPredicate { _, _ in
            let frame = item.frame
            guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
                  frame.maxX.isFinite, frame.maxY.isFinite, self.pixelContains(app.frame, frame), item.isHittable else {
                readyFrame = nil
                return false
            }
            if readyFrame != frame {
                readyFrame = frame
                unchangedSince = .now
                return false
            }
            return unchangedSince.duration(to: .now) >= .milliseconds(500)
        }, timeout: 5)
        guard ready else { XCTFail("The native menu must finish opening before the stability observation"); return }
        let initialFrame = item.frame
        let started = ContinuousClock.now
        var samples: [String] = []
        // Regression observation, not a settling sleep: every sample across >2 former 1s ticks must be valid.
        repeat {
            let frame = item.frame
            let sample = "elapsed=\(started.duration(to: .now)) frame=\(frame)"
            print("PINNED_MENU_STABILITY \(sample)"); samples.append(sample)
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite)
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(pixelContains(app.frame, frame))
            XCTAssertEqual(frame, initialFrame, "The open native item cannot be replaced by a countdown tick")
            XCTAssertTrue(item.isHittable)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while started.duration(to: .now) < .milliseconds(2200)
        XCTAssertGreaterThanOrEqual(samples.count, 3)
        let frames = XCTAttachment(string: samples.joined(separator: "\n"))
        frames.name = "Native Review finite unchanged frames across two former ticks"; frames.lifetime = .keepAlways; add(frames)
        capture(app, "Stable native Review menu before ONE touch")
        XCTAssertEqual(item.frame, initialFrame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: initialFrame.midX, dy: initialFrame.midY)).tap()
        let close = app.buttons["companion-approval-review-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "One touch opens full Review")
        XCTAssertTrue(app.scrollViews["companion-approval-review-scroll"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(summary(app).value as? String, "1 of 3 waiting · Bash")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
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
        let always = review.buttons["companion-approval-option-always"]
        XCTAssertTrue(scrollTo(always, in: app) && always.isHittable)
        XCTAssertEqual(always.label, "Always allow, preview:*", "Full review retains the permission label and scope")
        always.tap()
        XCTAssertTrue(app.staticTexts["Always allow?"].waitForExistence(timeout: 5), "A broader permission keeps its existing confirmation")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
        // iOS 26 presents this shared confirmation as a popover without a Cancel button.
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.exists)
        let popoverFrame = popover.frame
        let outside = CGPoint(x: (popoverFrame.maxX + app.frame.maxX) / 2,
                              y: popoverFrame.midY)
        XCTAssertFalse(popoverFrame.contains(outside), "Dismissal must land outside the measured confirmation popover")
        XCTAssertTrue(app.frame.contains(outside))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: outside.x, dy: outside.y)).tap()
        XCTAssertTrue(app.staticTexts["Always allow?"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic decision:")).firstMatch.exists)
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
    func testDarkDecisionBar() throws {
        try requireFullAppearanceMatrix("dark")
        appearance("dark", flags: ["--companion-preview-dark"])
    }
    func testLatteDecisionBar() throws {
        try requireFullAppearanceMatrix("Catppuccin Latte")
        appearance("Catppuccin Latte", flags: ["--companion-preview-light", "--companion-preview-theme-latte"])
    }
    func testMochaDecisionBar() throws {
        try requireFullAppearanceMatrix("Catppuccin Mocha")
        appearance("Catppuccin Mocha", flags: ["--companion-preview-dark", "--companion-preview-theme-mocha"])
    }
    func testAccessibilityDecisionBar() {
        appearance("accessibility XXXL", flags: ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
    private func appearance(_ name: String, flags: [String]) {
        let app = openRiver(extra: flags)
        awaitApproval(app)
        let compact = flags.contains("UICTContentSizeCategoryAccessibilityXXXL")
        assertPinned(app, compact: compact)
        if compact {
            XCTAssertEqual(app.buttons["companion-review-approval"].label, "Review approval: Run preview build, 1 of 3")
        } else {
            let deny = app.buttons["Deny"].frame
            let allow = app.buttons["Allow once"].frame
            if deny.maxY <= allow.minY {
                XCTAssertLessThan(deny.midY, allow.midY, "The vertical fallback keeps Deny above Allow once")
            } else {
                XCTAssertLessThan(deny.midX, allow.midX, "The horizontal layout keeps Deny before Allow once")
            }
        }
        XCTAssertFalse(app.buttons["companion-pinned-decision-previous"].exists)
        XCTAssertFalse(app.buttons["companion-pinned-decision-next"].exists)
        capture(app, "Decision bar — \(name)")
    }

}
