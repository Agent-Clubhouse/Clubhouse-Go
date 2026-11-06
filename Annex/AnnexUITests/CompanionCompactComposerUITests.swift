import XCTest

@MainActor final class CompanionCompactComposerUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testIdleControlsStayCollapsedBeforeAndAfterTyping() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        assertRow(app, working: false, state: "idle empty unfocused")
        let controls = app.buttons["companion-level-menu"]
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"])
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        XCTAssertTrue(app.buttons["companion-effort-menu"].exists)
        // Dismiss the menu through the field; then type through the actual editor.
        composer.tap()
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        assertRow(app, working: false, state: "idle typed focused")
        assertEnabledEditingRow(app, working: false)
    }

    func testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation() {
        workingRow(largestText: false)
    }

    func testLargestTextWorkingAttachmentRowFits() {
        workingRow(largestText: true)
    }

    private func workingRow(largestText: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard", "--companion-sample-images"]
                            + (largestText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []))
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        XCTAssertFalse(app.buttons["companion-send"].isEnabled, "An empty draft cannot steer")
        assertRow(app, working: true, state: "working empty unfocused", stacked: largestText)
        if largestText {
            reviewApprovalWithoutAnswering(app, editing: false)
        } else {
            XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Approval stays pinned")
        }
        waitAndTap(app.buttons["companion-attach"], until: element(app, "companion-attachment-thumbnail"))
        XCTAssertTrue(app.buttons["companion-send"].isEnabled, "An image-only draft can steer")
        assertRow(app, working: true, state: "working image-only unfocused", stacked: largestText)
        composer.tap()
        let direction = largestText ? "Keep this direction\nAnd this detail" : "Keep this direction"
        composer.typeText(direction)
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertTrue(app.buttons["companion-send"].isEnabled)
        XCTAssertTrue(app.buttons["companion-dismiss-keyboard"].exists)
        assertRow(app, working: true, state: "working typed focused", stacked: largestText)
        assertEnabledEditingRow(app, working: true)
        if largestText {
            reviewApprovalWithoutAnswering(app, editing: true)
            assertEnabledEditingRow(app, working: true)
        }
        XCTAssertFalse(app.staticTexts["Your direction will be sent to the running agent."].exists)
        let interrupt = app.buttons["companion-interrupt"]
        waitAndTap(interrupt, until: app.buttons["Interrupt turn"])
        XCTAssertTrue(app.staticTexts["Interrupt this turn?"].exists)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists,
                       "Preview errors should not appear while confirmation is open")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, direction)
        // The dialog can end editing. Refocus so this always exercises the real dismiss action.
        composer.tap()
        assertEnabledEditingRow(app, working: true)
        let dismiss = app.buttons["companion-dismiss-keyboard"]
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), "The assistive action leaves editing")
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", direction), timeout: 5))
        XCTAssertFalse(composer.debugDescription.contains("Keyboard Focused"))
        XCTAssertTrue(element(app, "companion-attachment-thumbnail").exists, "Dismissal keeps the image draft")
        assertRow(app, working: true, state: "working typed unfocused", stacked: largestText)
    }

    private func reviewApprovalWithoutAnswering(_ app: XCUIApplication, editing: Bool) {
        let composer = element(app, "companion-composer")
        let originalDraft = composer.value as? String
        let imageCount = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count
        let trigger = app.buttons["companion-review-approval"]
        XCTAssertEqual(trigger.label, "Review approval: Run xcodebuild, 1 of 2")
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(trigger, until: close)
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", "Run xcodebuild")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Run xcodebuild"))
        let position = app.staticTexts.matching(NSPredicate(format: "label == %@", "Request 1 of 2")).firstMatch
        XCTAssertEqual(position.label, "Request 1 of 2")
        XCTAssertTrue(app.staticTexts["Build the iOS application to verify the updated conversation layout."].exists)
        for label in ["Allow once", "Deny"] {
            let decision = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(scrollTo(decision, in: app, maxSwipes: 8))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Approval review \(label), editing=\(editing)"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(decision.isEnabled && decision.isHittable, label)
            XCTAssertGreaterThanOrEqual(decision.frame.width, 44)
            XCTAssertGreaterThanOrEqual(decision.frame.height, 44)
            XCTAssertGreaterThanOrEqual(decision.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(decision.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(decision.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            XCTAssertLessThanOrEqual(decision.frame.maxY, bottom)
        }
        // Close is presentation-only; source review separately verifies that only explicit decisions dispatch.
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, originalDraft)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count, imageCount)
        XCTAssertEqual(trigger.label, "Review approval: Run xcodebuild, 1 of 2", "The approval remains pending after closing review")
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        if editing {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Closing review retains the keyboard editing context")
        }
    }

    private func assertRow(_ app: XCUIApplication, working: Bool, state: String, stacked: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) {
        // Capture the unmodified screen before geometry checks so a failure retains its actual row.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact composer \(state)"; shot.lifetime = .keepAlways; add(shot)
        let controls = app.buttons["companion-level-menu"]
        let send = app.buttons["companion-send"]
        XCTAssertTrue(controls.label.contains("Chat controls"), state, file: file, line: line)
        let buttons = [controls, send] + (working ? [app.buttons["companion-interrupt"]] : [])
        for button in buttons {
            XCTAssertTrue(button.exists, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX, state, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX, state, file: file, line: line)
            XCTAssertEqual(button.frame.midY, send.frame.midY, accuracy: 3, state, file: file, line: line)
        }
        XCTAssertLessThan(controls.frame.maxX, send.frame.minX, state, file: file, line: line)
        if working {
            let interrupt = app.buttons["companion-interrupt"]
            let attach = app.buttons["companion-attach"]
            let composer = element(app, "companion-composer")
            XCTAssertTrue(attach.isHittable, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(attach.frame.width, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(attach.frame.height, 44, state, file: file, line: line)
            XCTAssertGreaterThanOrEqual(composer.frame.width, 44, "The editor retains usable width: \(state)", file: file, line: line)
            if stacked {
                XCTAssertGreaterThanOrEqual(composer.frame.width, app.frame.width * 0.7, "Large-text draft keeps readable width", file: file, line: line)
                XCTAssertLessThanOrEqual(composer.frame.maxY, send.frame.minY, state, file: file, line: line)
                let review = app.buttons["companion-review-approval"]
                XCTAssertTrue(review.isHittable, state, file: file, line: line)
                XCTAssertGreaterThanOrEqual(review.frame.width, 44, state, file: file, line: line)
                XCTAssertGreaterThanOrEqual(review.frame.height, 44, state, file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(interrupt.frame.minX, composer.frame.maxX - 2, state, file: file, line: line)
            }
            XCTAssertLessThanOrEqual(interrupt.frame.maxX, send.frame.minX, state, file: file, line: line)
            XCTAssertLessThanOrEqual(send.frame.minX - interrupt.frame.maxX, 16, state, file: file, line: line)
            XCTAssertTrue(interrupt.isHittable, state, file: file, line: line)
        } else {
            XCTAssertFalse(app.buttons["companion-interrupt"].exists, state, file: file, line: line)
        }
    }

    /// Only typed, enabled states require actionable Send; empty drafts intentionally keep it disabled.
    private func assertEnabledEditingRow(_ app: XCUIApplication, working: Bool,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), file: file, line: line)
        let header = element(app, "companion-chat-header")
        let top = max(app.frame.minY, app.navigationBars.firstMatch.frame.maxY, header.exists ? header.frame.maxY : app.frame.minY)
        let bottom = min(app.frame.maxY, keyboard.frame.minY)
        let unobscured = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(0, bottom - top))
        XCTAssertGreaterThan(unobscured.height, 0, file: file, line: line)
        var targets = [app.buttons["companion-level-menu"], app.buttons["companion-send"], element(app, "companion-composer")]
        if working {
            let dismiss = app.buttons["companion-dismiss-keyboard"]
            XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44, file: file, line: line)
            targets += [app.buttons["companion-interrupt"], app.buttons["companion-attach"], dismiss]
            let review = app.buttons["companion-review-approval"]
            if review.exists { targets.append(review) }
        }
        for target in targets {
            XCTAssertTrue(target.isEnabled && target.isHittable, target.identifier, file: file, line: line)
            let frame = target.frame
            let details = "\(target.identifier): \(frame), unobscured: \(unobscured)"
            XCTAssertGreaterThanOrEqual(frame.minX, unobscured.minX, details, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, unobscured.maxX, details, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, unobscured.minY, details, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, unobscured.maxY, details, file: file, line: line)
        }
    }
}
