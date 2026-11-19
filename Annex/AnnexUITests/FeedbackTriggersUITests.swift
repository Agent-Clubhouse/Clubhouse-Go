import XCTest

/// Feedback entry points that don't depend on a shake (#181): the offer after an iOS screenshot and the
/// Send feedback menu items. The fixture posts `userDidTakeScreenshotNotification` as iOS does.
final class FeedbackTriggersUITests: ReliableUITestCase {
    @MainActor private func confirmation(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        // An enrollment sheet can contain the popover and its same-named underlying button.
        let popover = app.popovers.containing(.staticText, identifier: title).firstMatch
        return popover.exists ? popover : app.sheets.containing(.staticText, identifier: title).firstMatch
    }

    @MainActor private func revealFeedbackRow(_ row: XCUIElement, in app: XCUIApplication, title: String) throws {
        let form = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.last)
        let navigation = app.navigationBars[title]
        for _ in 0..<12 {
            checkTimeLeft("revealing the feedback row")
            let bounds = form.frame
            let visible = CGRect(x: bounds.minX, y: navigation.frame.maxY + 8,
                                 width: bounds.width, height: bounds.maxY - navigation.frame.maxY - 24)
            if row.exists && row.isHittable && visible.contains(row.frame) { return }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dy = row.exists && row.frame.minY < visible.minY ? visible.height * 0.2 : -visible.height * 0.2
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
        }
        XCTFail("The feedback row must be fully visible below its sheet's navigation bar")
    }

    @MainActor func testExpiredInvitationStaysInSettingsWhileChatUsesKeyboard() throws {
        try checkRenewalInSettings(expected: "Expired")
    }

    @MainActor func testExpiredInvitationRenewalRemainsReachableAtAccessibilitySize() throws {
        try checkRenewalInSettings(expected: "Expired", largeText: true)
    }

    @MainActor func testOfflineFeedbackKeepsEnrollmentWhenSettingsReopens() throws {
        try checkRenewalInSettings(expected: "Offline, will retry", flags: ["--feedback-renewal-offline"])
    }

    @MainActor func testAccessRequiredFeedbackKeepsRenewalInSettings() throws {
        try checkRenewalInSettings(expected: "Needs a new invitation", flags: ["--feedback-renewal-access-required"])
    }

    @MainActor func testRegisteredFeedbackKeepsSettingsAndChatUnobstructed() throws {
        try checkRenewalInSettings(expected: "Connected", flags: ["--feedback-renewal-registered"])
    }

    @MainActor private func checkRenewalInSettings(expected: String, flags: [String] = [], largeText: Bool = false) throws {
        let app = launchApp(["--feedback-renewal-ui-testing", "--companion-root-ui-testing"] + flags
            + (largeText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []),
            attempts: 1)
        defer { app.terminate() }
        let evidence = app.descendants(matching: .any).matching(identifier: "feedback-renewal-evidence").firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(evidence, NSPredicate { _, _ in
            (evidence.value as? String)?.contains("queued=2;enrolled=true;diagnostics=off") == true
        }, timeout: 5))
        let original = try XCTUnwrap(evidence.value as? String)
        XCTAssertTrue(original.contains("preferences=[false, false, false]"))
        let refresh = flags.contains("--feedback-renewal-offline") || flags.contains("--feedback-renewal-registered")
        XCTAssertTrue(original.hasPrefix(refresh ? "requests=1;" : "requests=0;"),
                      "Only the offline/registered fixture's preparatory refresh may reach the non-socket transport")
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollTo(agent, in: app, maxSwipes: 6)); agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let send = app.buttons["companion-send"]
        let banner = app.buttons["Feedback needs a new invitation. Reports stay on this device. Open Settings."]
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Renewal \(expected) AX=\(largeText) keyboard"; capture.lifetime = .keepAlways; add(capture)
        print("RENEWAL_LAYOUT status=\(expected) AX=\(largeText) composer=\(composer.frame) send=\(send.frame) keyboard=\(app.keyboards.firstMatch.frame) banner=\(banner.exists ? banner.frame.description : "absent")")
        XCTAssertFalse(banner.exists, "Feedback renewal must not add a global inset above navigation or the keyboard")
        XCTAssertTrue(composer.isHittable && send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, app.keyboards.firstMatch.frame.minY)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)

        for _ in 0..<2 {
            waitAndTap(app.buttons["Settings"], until: app.navigationBars["Settings"], attempts: 1)
            let options = app.buttons["settings-feedback-options"]
            try revealFeedbackRow(options, in: app, title: "Settings")
            XCTAssertTrue(options.label.contains(expected), "The Settings entry speaks its current status")
            options.tap()
            let status = app.staticTexts["feedback-access-status"]
            try revealFeedbackRow(status, in: app, title: "Feedback options")
            XCTAssertEqual(status.label, "Feedback access: \(expected)")
            let renewal = app.buttons["feedback-enrollment"]
            try revealFeedbackRow(renewal, in: app, title: "Feedback options")
            XCTAssertTrue(renewal.isHittable)
            XCTAssertGreaterThanOrEqual(renewal.frame.height, 44)
            renewal.tap()
            XCTAssertTrue(app.navigationBars["Feedback enrollment"].waitForExistence(timeout: 5))
            let invitation = app.secureTextFields["Invitation"]
            try revealFeedbackRow(invitation, in: app, title: "Feedback enrollment")
            invitation.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Redeem invitation"].isEnabled, "Opening renewal cannot redeem an invitation")
            app.navigationBars["Feedback enrollment"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Feedback options"].waitForExistence(timeout: 5))
            app.navigationBars["Feedback options"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons["settings-close"].tap()
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(evidence.value as? String, original,
                       "Navigation/dismiss/reopen must preserve enrollment, queued bytes, preferences, diagnostics choice and request count")
    }

    @MainActor func testSettingsFromHomeToolbarAttachesCaptureOrOffersPhotos() throws {
        for failed in [false, true] {
            let app = launchApp(["--companion-preview", "--companion-preview-feedback", "--companion-preview-start-home",
                                 "--framebriar-wire-ui-testing"] + (failed ? ["--feedback-capture-failure"] : []))
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
            waitAndTap(app.buttons["Settings"], until: app.navigationBars["Settings"], timeout: 5)
            let send = app.buttons["Send feedback"]
            XCTAssertTrue(scrollTo(send, in: app, maxSwipes: 6)); send.tap()
            XCTAssertTrue(app.textViews["framebriar-notes"].waitForExistence(timeout: 5))
            if failed {
                XCTAssertFalse(app.images["framebriar-attachment"].exists)
                let add = app.buttons["Add screenshot"]
                XCTAssertTrue(scrollTo(add, in: app, maxSwipes: 4)); add.tap()
                let photos = app.navigationBars["Photos"]
                XCTAssertTrue(photos.waitForExistence(timeout: 20)); photos.buttons["Cancel"].tap()
                XCTAssertTrue(app.staticTexts["framebriar-screenshot-unavailable"].exists)
            } else {
                XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Replace screenshot"].exists)
            }
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons["settings-close"].tap()
            app.terminate()
        }
    }

    /// Both Go's modal enrollment route and Settings expose clearing without enrollment or a send.
    @MainActor func testClearQueuedFeedbackIsReachableFromEnrollmentSheetAndSettings() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-shake-unenrolled"])
        let shake = app.buttons["fixture-shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10))
        shake.tap()
        let explainer = app.alerts["Feedback enrollment required"]
        XCTAssertTrue(explainer.waitForExistence(timeout: 5))
        explainer.buttons["Set up feedback"].tap()
        XCTAssertTrue(app.navigationBars["Feedback enrollment"].waitForExistence(timeout: 5))
        let clear = app.buttons["Clear queued feedback"]
        try revealFeedbackRow(clear, in: app, title: "Feedback enrollment")
        clear.tap()
        var confirmation = confirmation(app, titled: "Clear queued feedback from this device?")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear queued feedback"].tap()
        try revealFeedbackRow(app.staticTexts["framebriar-status"], in: app, title: "Feedback enrollment")
        XCTAssertTrue(app.staticTexts["framebriar-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["framebriar-status"].label, "Queued reports cleared from this device.")
        app.buttons["Done"].tap()

        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 5)
        try revealFeedbackRow(clear, in: app, title: "Fixture settings")
        clear.tap()
        confirmation = self.confirmation(app, titled: "Clear queued feedback from this device?")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear queued feedback"].tap()
        try revealFeedbackRow(app.staticTexts["feedback-queue-status"], in: app, title: "Fixture settings")
        XCTAssertTrue(app.staticTexts["feedback-queue-status"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    @MainActor func testHeldReportsRequireConfirmationAndCanBeClearedWhileUnenrolled() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-held-ui-testing"])
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        let summary = app.staticTexts["feedback-held-summary"]
        try revealFeedbackRow(summary, in: app, title: "Fixture settings")
        XCTAssertTrue(summary.label.hasPrefix("2 reports were saved under a previous enrollment"))
        let release = app.buttons["feedback-release-held"]
        try revealFeedbackRow(release, in: app, title: "Fixture settings")
        release.tap()
        let confirmation = confirmation(app, titled: "Send 2 reports saved under a previous enrollment with this one?")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts["Send 2 reports saved under a previous enrollment with this one?"].exists)
        // Compact iOS 26 confirmation popovers omit an automatic Cancel row. An outside
        // tap is their native cancel action; keep the same retained-report assertions.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Fixture settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertFalse(confirmation.waitForExistence(timeout: 1))
        XCTAssertTrue(summary.exists, "Cancel retains the held reports")
        release.tap()
        confirmation.buttons["Send"].tap()
        let result = app.staticTexts["feedback-queue-status"]
        try revealFeedbackRow(result, in: app, title: "Fixture settings")
        XCTAssertEqual(result.label, "2 will send with this enrollment. They aren't confirmed sent yet.")
        XCTAssertFalse(summary.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.hasPrefix("Queued: 2"), "Offline release queues; it isn't delivery")

        app.terminate()
        app.launchArguments = ["--framebriar-shake-ui-testing", "--framebriar-held-ui-testing", "--framebriar-shake-unenrolled"]
        app.launch()
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        let clear = app.buttons["feedback-clear-held"]
        try revealFeedbackRow(clear, in: app, title: "Fixture settings")
        XCTAssertFalse(app.buttons["feedback-release-held"].exists, "No release token while unenrolled")
        clear.tap()
        let clearConfirmation = self.confirmation(app, titled: "Clear 2 reports saved under a previous enrollment? They won't be sent.")
        XCTAssertTrue(clearConfirmation.waitForExistence(timeout: 5))
        clearConfirmation.buttons["Clear held reports"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "2 cleared from this device. They weren't sent.")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    @MainActor func testShakeOpensOverSettingsAndClosesBackToSettings() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        app.buttons["Simulate shake in Settings"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Fixture settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))
    }

    @MainActor func testScreenshotPromptOpensComposerWithTheScreenAttached() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        let screenshot = app.buttons["fixture-screenshot"]
        let prompt = app.buttons["screenshot-feedback-prompt"]
        let composer = app.navigationBars["Send feedback"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "An enrolled screenshot offers feedback")
        XCTAssertEqual(prompt.label, "Send feedback with this screenshot?")
        prompt.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5), "The screen is pre-attached for review")
        XCTAssertFalse(app.buttons["Submit reviewed feedback"].exists, "Opening never submits")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-counters"].label.contains("Queued: 0 · Network: 0"))

        // The prompt can be dismissed, and goes away by itself.
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        app.buttons["screenshot-feedback-dismiss"].tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 1))
        screenshot.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: prompt)
        waitForExpectations(timeout: 12)
        XCTAssertFalse(composer.exists)

        // No prompt while a password field is in use.
        let password = app.secureTextFields["Fixture password"]
        scrollTo(password, in: app, maxSwipes: 3)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2), "A focused password field suppresses the prompt and capture")
    }

    @MainActor func testScreenshotPromptSettingTurnsItOff() throws {
        let app = launchApp(["--framebriar-shake-ui-testing"])
        let toggle = app.switches["Offer feedback when you take a screenshot"]
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        scrollTo(toggle, in: app, maxSwipes: 3)
        // isHittable can be true for the visible top of a clipped row while its switch is
        // below the window. Reveal the entire row before choosing a control coordinate.
        for _ in 0..<3 {
            if app.windows.firstMatch.frame.contains(toggle.frame) { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(toggle.frame))
        XCTAssertEqual(toggle.value as? String, "1", "On by default")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].tap()
        let screenshot = app.buttons["fixture-screenshot"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].waitForExistence(timeout: 2))
    }

    /// Unenrolled: the enrollment explainer, once per session, so ordinary screenshots aren't nagged.
    @MainActor func testUnenrolledScreenshotExplainsEnrollmentOnce() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-shake-unenrolled"])
        let screenshot = app.buttons["fixture-screenshot"]
        let explainer = app.alerts["Feedback enrollment required"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
        scrollTo(screenshot, in: app, maxSwipes: 3)
        screenshot.tap()
        XCTAssertTrue(explainer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].exists)
        explainer.buttons["Not now"].tap()
        XCTAssertFalse(explainer.waitForExistence(timeout: 1))
        screenshot.tap()
        XCTAssertFalse(explainer.waitForExistence(timeout: 2), "Explained once per session")
        XCTAssertFalse(app.buttons["screenshot-feedback-prompt"].exists)
    }

    @MainActor func testSendFeedbackInSettingsAndChatMenu() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-feedback"])
        let composer = app.navigationBars["Send feedback"]
        XCTAssertFalse(app.buttons["home-more-menu"].exists, "Home has no one-item overflow menu")
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        waitAndTap(settings, until: app.navigationBars["Settings"], timeout: 5)
        let send = app.buttons["Send feedback"]
        XCTAssertTrue(scrollTo(send, in: app, maxSwipes: 6))
        send.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Settings opens the feedback form")
        XCTAssertTrue(app.images["framebriar-attachment"].exists, "The underlying screen starts attached for review")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings-close"].tap()

        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app, maxSwipes: 4)
        XCTAssertTrue(scrollTo(agent, in: app, maxSwipes: 4))
        let actions = app.buttons["Conversation actions"]
        waitAndTap(agent, until: actions, timeout: 15)
        waitAndTap(actions, until: app.buttons["Send feedback"], timeout: 5)
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "The chat ⋯ menu opens the feedback form")
        XCTAssertTrue(app.images["framebriar-attachment"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
    }
}
