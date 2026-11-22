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

    @MainActor private func uniqueHeldConfirmation(_ app: XCUIApplication, titled title: String) throws -> XCUIElement {
        let popovers = app.popovers.containing(.staticText, identifier: title).allElementsBoundByIndex
        if !popovers.isEmpty {
            return try XCTUnwrap(popovers.count == 1 ? popovers.first : nil,
                                 "The titled held-report confirmation must be unique")
        }
        let sheets = app.sheets.containing(.staticText, identifier: title).allElementsBoundByIndex
        return try XCTUnwrap(sheets.count == 1 ? sheets.first : nil,
                             "The titled held-report confirmation must be unique")
    }

    @MainActor private func heldPopoverDismissal(_ app: XCUIApplication, titled title: String) throws -> XCUIElement {
        _ = try XCTUnwrap(app.popovers.containing(.staticText, identifier: title).count == 1 ? true : nil,
                          "Outside cancellation requires the unique current titled popover")
        // Presented Settings can leave its own inactive dismissal regions in AX.
        let hosts = app.otherElements.containing(.popover, identifier: nil).allElementsBoundByIndex.filter {
            $0.children(matching: .popover).containing(.staticText, identifier: title).count == 1
        }
        let host = try XCTUnwrap(hosts.count == 1 ? hosts.first : nil,
                                "The current held-report popover must have one immediate native host")
        let dismissals = host.children(matching: .other).matching(NSPredicate(
            format: "identifier == %@ OR label ==[c] %@", "PopoverDismissRegion", "dismiss popup"))
        return try XCTUnwrap(dismissals.count == 1 ? dismissals.allElementsBoundByIndex.first : nil,
                             "Only the current confirmation's unique native dismissal region may cancel it")
    }

    private struct RevealState: Equatable {
        var container: CGRect
        var navigation: CGRect
        var keyboard: CGRect?
        var tabBar: CGRect?
        var viewport: CGRect
        var target: CGRect?
        var hittable: Bool
        var anchor: CGRect?
        var anchorLabel: String?
    }

    @MainActor private func revealFeedbackRow(_ row: XCUIElement, in app: XCUIApplication, title: String) throws {
        let navigations = app.navigationBars.matching(identifier: title)
        XCTAssertTrue(navigations.firstMatch.waitForExistence(timeout: 5))
        func fail(_ reason: String) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Feedback reveal failure: \(title)"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Feedback reveal failure: \(title)"; image.lifetime = .keepAlways; add(image)
            XCTFail("\(reason): \(row)")
        }
        guard navigations.count == 1 else {
            fail("Expected one named native navigation bar for \(title), found \(navigations.count)")
            return
        }
        let navigation = try XCTUnwrap(navigations.allElementsBoundByIndex.first)
        guard navigation.buttons.allElementsBoundByIndex.contains(where: \.isHittable) else {
            fail("The named navigation context for \(title) has no hittable native navigation control")
            return
        }
        guard app.alerts.count == 0 && app.popovers.count == 0 && app.sheets.count == 0 else {
            fail("A native alert, popover or confirmation sheet blocks the \(title) list")
            return
        }
        let contexts = app.otherElements.containing(.navigationBar, identifier: title).allElementsBoundByIndex.filter {
            $0.children(matching: .navigationBar).matching(identifier: title).count == 1
        }
        guard contexts.count == 1 else {
            fail("Expected one immediate native navigation context for \(title), found \(contexts.count)")
            return
        }
        let context = try XCTUnwrap(contexts.first)
        let lists = context.descendants(matching: .collectionView).allElementsBoundByIndex
        guard lists.count == 1 else {
            print("FEEDBACK_REVEAL containers=\(lists.map { "id=\($0.identifier) frame=\($0.frame) hittable=\($0.isHittable)" })")
            fail("Expected one native list owned by \(title), found \(lists.count)")
            return
        }
        let form = try XCTUnwrap(lists.first)
        print("FEEDBACK_REVEAL ownership title=\(title) context=\(context.frame) navigation=\(navigation.frame) list=\(form.frame) containerHittable=\(form.isHittable)")
        let anchor = form.cells.firstMatch
        func state() -> RevealState {
            let bounds = form.frame.intersection(app.frame)
            let nav = navigation.frame
            let keyboard = app.keyboards.firstMatch
            let keyboardFrame = keyboard.exists ? keyboard.frame : nil
            let tabs = app.tabBars.firstMatch
            let tabFrame = tabs.exists && tabs.isHittable ? tabs.frame : nil
            let bottom = min(bounds.maxY, keyboardFrame?.minY ?? bounds.maxY, tabFrame?.minY ?? bounds.maxY) - 16
            let top = max(bounds.minY, nav.maxY) + 8
            let viewport = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            let exists = row.exists
            let hasAnchor = anchor.exists
            return RevealState(container: bounds, navigation: nav, keyboard: keyboardFrame, tabBar: tabFrame,
                viewport: viewport, target: exists ? row.frame : nil,
                hittable: exists && row.isHittable,
                anchor: hasAnchor ? anchor.frame : nil, anchorLabel: hasAnchor ? anchor.label : nil)
        }
        func revealed(_ sample: RevealState) -> Bool {
            guard let frame = sample.target, !frame.isEmpty else { return false }
            return sample.hittable && sample.viewport.contains(frame)
        }
        func targetState(_ sample: RevealState) -> String {
            guard let frame = sample.target else { return "absent target" }
            return frame.isEmpty ? "unrealized target" : "realized target"
        }
        var before = state()
        print("FEEDBACK_REVEAL title=\(title) before=\(before)")
        for step in 0..<12 {
            checkTimeLeft("revealing the feedback row")
            if revealed(before) { return }
            guard !before.viewport.isEmpty else {
                fail("Navigation, keyboard or tab bar leaves no native list viewport")
                return
            }
            if let frame = before.target, !frame.isEmpty {
                guard frame.height <= before.viewport.height && frame.width <= before.viewport.width else {
                    fail("The realized row is physically larger than its unobstructed viewport")
                    return
                }
                guard !before.viewport.contains(frame) else {
                    fail("The fully contained row is blocked from native hit testing")
                    return
                }
            }
            let down = before.target.map { !$0.isEmpty && $0.minY < before.viewport.minY } ?? false
            let startPoint = CGPoint(x: before.viewport.minX + before.viewport.width * 0.15,
                                     y: before.viewport.minY + before.viewport.height * (down ? 0.2 : 0.8))
            var distance = min(200, before.viewport.height * 0.35)
            if let frame = before.target, !frame.isEmpty {
                // Aim toward the viewport centre. A full drag for a barely clipped
                // row can carry it past the opposite edge on the next sample.
                distance = min(distance, abs(frame.midY - before.viewport.midY))
            }
            let delta = distance * (down ? 1 : -1)
            let endPoint = CGPoint(x: startPoint.x, y: startPoint.y + delta)
            XCTAssertTrue(before.viewport.contains(startPoint) && before.viewport.contains(endPoint))
            // Screen coordinates avoid resolving a background List as the gesture's coordinate space.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            XCTContext.runActivity(named: "Reveal \(title) row: native list \(before.container), viewport \(before.viewport), drag \(startPoint) to \(endPoint)") { _ in
                origin.withOffset(CGVector(dx: startPoint.x, dy: startPoint.y)).press(forDuration: 0.05,
                    thenDragTo: origin.withOffset(CGVector(dx: endPoint.x, dy: endPoint.y)))
            }
            let after = state()
            print("FEEDBACK_REVEAL title=\(title) step=\(step) after=\(after)")
            if revealed(after) { return }
            guard before.target != after.target || before.anchor != after.anchor
                    || before.anchorLabel != after.anchorLabel || before.viewport != after.viewport else {
                fail("The native list made no observed scroll progress toward the \(targetState(after))")
                return
            }
            before = after
        }
        fail("The \(targetState(before)) is not fully visible and hittable after bounded native list scrolling")
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
        print("RENEWAL_STATE phase=before status=\(expected) AX=\(largeText) \(original)")
        XCTAssertTrue(original.contains("preferences=[false, false, false]"))
        XCTAssertTrue(original.hasSuffix("accessibilityXXXL=\(largeText)"), "The requested AX category must actually reach the fixture")
        let refresh = flags.contains("--feedback-renewal-offline") || flags.contains("--feedback-renewal-registered")
        XCTAssertTrue(original.hasPrefix(refresh ? "requests=1;" : "requests=0;"),
                      "Only the offline/registered fixture's preparatory refresh may reach the non-socket transport")
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        try revealFeedbackRow(agent, in: app, title: "Clubhouse")
        XCTAssertEqual(agent.identifier, "agent-preview-studio-river")
        XCTAssertTrue(agent.label.contains("River"))
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let send = app.buttons["companion-send"]
        let banner = app.buttons["Feedback needs a new invitation. Reports stay on this device. Open Settings."]
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Renewal \(expected) AX=\(largeText) keyboard"; capture.lifetime = .keepAlways; add(capture)
        print("RENEWAL_LAYOUT status=\(expected) AX=\(largeText) composer=\(composer.frame) send=\(send.frame) keyboard=\(app.keyboards.firstMatch.frame) banner=\(banner.exists ? String(describing: banner.frame) : "absent")")
        XCTAssertFalse(banner.exists, "Feedback renewal must not add a global inset above navigation or the keyboard")
        XCTAssertTrue(composer.isHittable && send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, app.keyboards.firstMatch.frame.minY)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)

        for cycle in 1...2 {
            waitAndTap(app.buttons["Settings"], until: app.navigationBars["Settings"], attempts: 1)
            let options = app.buttons["settings-feedback-options"]
            try revealFeedbackRow(options, in: app, title: "Settings")
            XCTAssertTrue(options.label.contains(expected), "The Settings entry speaks its current status")
            options.tap()
            let status = app.staticTexts["feedback-access-status"]
            try revealFeedbackRow(status, in: app, title: "Feedback options")
            print("RENEWAL_SETTINGS cycle=\(cycle) AX=\(largeText) status=\(status.label) frame=\(status.frame)")
            XCTAssertEqual(status.label, "Feedback access: \(expected)")
            let renewal = app.buttons["feedback-enrollment"]
            try revealFeedbackRow(renewal, in: app, title: "Feedback options")
            print("RENEWAL_TARGET cycle=\(cycle) AX=\(largeText) label=\(renewal.label) frame=\(renewal.frame) hittable=\(renewal.isHittable)")
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
        let final = try XCTUnwrap(evidence.value as? String)
        print("RENEWAL_STATE phase=after status=\(expected) AX=\(largeText) \(final)")
        let states = XCTAttachment(string: "before=\(original)\nafter=\(final)")
        states.name = "Renewal state \(expected) AX=\(largeText)"; states.lifetime = .keepAlways; add(states)
        XCTAssertEqual(final, original,
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
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-shake-unenrolled"], attempts: 1)
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
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-held-ui-testing"], attempts: 1)
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 10)
        let summary = app.staticTexts["feedback-held-summary"]
        try revealFeedbackRow(summary, in: app, title: "Fixture settings")
        XCTAssertTrue(summary.label.hasPrefix("2 reports were saved under a previous enrollment"))
        let release = app.buttons["feedback-release-held"]
        try revealFeedbackRow(release, in: app, title: "Fixture settings")
        let heldBeforeCancel = summary.label
        let result = app.staticTexts["feedback-queue-status"]
        let resultBeforeCancel = result.exists ? result.label : nil
        release.tap()
        let confirmationTitle = "Send 2 reports saved under a previous enrollment with this one?"
        let presentationClock = ContinuousClock()
        let presentationDeadline = presentationClock.now.advanced(by: .seconds(5))
        let titlePresented = app.staticTexts[confirmationTitle].waitForExistence(timeout: 5)
        guard titlePresented, presentationClock.now < presentationDeadline else {
            XCTFail("The held-report confirmation must present within five seconds"); return
        }
        let confirmation = try uniqueHeldConfirmation(app, titled: confirmationTitle)
        guard confirmation.exists, presentationClock.now < presentationDeadline else {
            XCTFail("The unique held-report confirmation must resolve within the same five seconds"); return
        }
        XCTAssertTrue(confirmation.staticTexts["Send 2 reports saved under a previous enrollment with this one?"].exists)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Held release confirmation native hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let cancel = confirmation.buttons["Cancel"]
        print("FEEDBACK_CANCEL cancel=\(cancel.exists)")
        if cancel.exists {
            print("FEEDBACK_CANCEL route=nativeCancel frame=\(cancel.frame) hittable=\(cancel.isHittable)")
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
        } else {
            let dismiss = try heldPopoverDismissal(app, titled: confirmationTitle)
            XCTAssertTrue(dismiss.exists, "The native popover must expose its named dismissal region")
            print("FEEDBACK_CANCEL namedDismissal id=\(dismiss.identifier) label=\(dismiss.label) frame=\(dismiss.frame) hittable=\(dismiss.isHittable); accessibilityActivation=unproven")
            XCTAssertTrue(dismiss.isHittable)
            let region = dismiss.frame
            let forms = app.collectionViews.containing(.staticText, identifier: "feedback-held-summary")
            let form = try XCTUnwrap(forms.count == 1 ? forms.allElementsBoundByIndex.first : nil,
                                    "The held-report form must be unique")
            XCTAssertTrue(form.exists)
            XCTAssertTrue(form.buttons["feedback-release-held"].exists && form.buttons["feedback-clear-held"].exists)
            XCTAssertTrue(confirmation.buttons["Send"].exists)
            let navigation = app.navigationBars["Fixture settings"].frame
            let popover = confirmation.frame
            let actions = (form.buttons.allElementsBoundByIndex + confirmation.buttons.allElementsBoundByIndex).map(\.frame)
            // The section heading may be virtualized after revealing the held rows on
            // iPad. Both candidates are actual, non-action text in the same form.
            var anchor: (label: String, frame: CGRect)?
            for label in ["Developer feedback", "Send queues these reports for the current enrollment. Delivery needs a service receipt."] {
                let matches = form.staticTexts.matching(NSPredicate(format: "label == %@", label))
                let count = matches.count
                guard count <= 1 else { XCTFail("The cancellation anchor must be unambiguous"); return }
                guard count == 1 else { continue }
                let frame = matches.element(boundBy: 0).frame
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                if !frame.isEmpty && !frame.isNull && !frame.isInfinite,
                   [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                   app.frame.contains(frame) && form.frame.contains(frame),
                   frame.minY > navigation.maxY, !popover.intersects(frame), region.contains(centre),
                   !actions.contains(where: { $0.contains(centre) }) {
                    anchor = (label, frame)
                    break
                }
            }
            let selected = try XCTUnwrap(anchor, "Cancellation needs visible non-action text outside the current popover")
            let headingFrame = selected.frame
            let point = CGPoint(x: headingFrame.midX, y: headingFrame.midY)
            print("FEEDBACK_CANCEL route=namedRegionCheckedTouch region=\(region) anchor=\(selected.label) frame=\(headingFrame) navigation=\(navigation) popover=\(popover) actions=\(actions) point=\(point)")
            XCTAssertFalse(headingFrame.isEmpty)
            XCTAssertTrue(app.frame.contains(headingFrame) && form.frame.contains(headingFrame))
            XCTAssertTrue(region.contains(point), "Cancel inside the actual native dismissal region")
            XCTAssertGreaterThan(headingFrame.minY, navigation.maxY)
            XCTAssertFalse(popover.intersects(headingFrame))
            XCTAssertFalse(actions.contains { $0.contains(point) }, "Cancellation must not activate any form or confirmation action")
            dismiss.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - region.minX, dy: point.y - region.minY)).tap()
        }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(summary.exists, "Cancel retains the held reports")
        XCTAssertEqual(summary.label, heldBeforeCancel)
        XCTAssertEqual(result.exists ? result.label : nil, resultBeforeCancel, "Cancel cannot release, send or clear reports")
        release.tap()
        confirmation.buttons["Send"].tap()
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
