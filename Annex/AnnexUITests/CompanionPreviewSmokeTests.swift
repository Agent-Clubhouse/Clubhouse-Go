import XCTest

/// Exercises the new SwiftUI navigation on a real simulator without enrolling
/// any desktop or storing credentials. Provider Apply cases opt into a DEBUG-only
/// in-memory transaction fixture; its receipts never claim an actual session.
@MainActor
final class CompanionPreviewSmokeTests: ReliableUITestCase {
    /// Opens River from Home; callers can bound tap attempts without changing the existing scroll limits.
    private func openRiver(_ app: XCUIApplication, maxSwipes: Int = 4, attempts: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch
        if home.exists && !home.isSelected { home.tap() }
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app, maxSwipes: maxSwipes, file: file, line: line)
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear", file: file, line: line)
        // At large text sizes River's row exists below the fold before it can be tapped.
        XCTAssertTrue(scrollTo(agent, in: app, maxSwipes: maxSwipes, file: file, line: line), "River's row must be on screen", file: file, line: line)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(agent, until: composer, timeout: 15, attempts: attempts, "Selecting an agent must open its conversation", file: file, line: line)
    }

    private func openAgentSettings(_ app: XCUIApplication, sleeping: Bool = false) {
        let home = app.tabBars.buttons["Home"]
        if home.waitForExistence(timeout: 5), !home.isSelected { home.tap() }
        let any = app.descendants(matching: .any)
        let row = any.matching(identifier: sleeping ? "agent-preview-studio-juniper" : "agent-preview-studio-river").firstMatch
        if sleeping { expandFold(any.matching(identifier: "fold-quiet-preview-studio-clubhouse").firstMatch, revealing: row, in: app) }
        scrollTo(row, in: app)
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settings)
        waitAndTap(settings, until: any.matching(identifier: "agent-settings-summary").firstMatch)
    }

    func testSleepIsSeparateFromInterruptAndSettingsKeepProviderLockedOnRefusal() {
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard"])
        openRiver(app)
        let transcriptBeforeDialog = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let navigationBeforeDialog = app.navigationBars["River"].frame
        waitAndTap(app.buttons["Conversation actions"], until: app.buttons["agent-sleep"])
        XCTAssertTrue(app.buttons["Interrupt turn"].exists)
        let confirmation = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Sleep agent", "agent-sleep")).firstMatch
        waitAndTap(app.buttons["agent-sleep"], until: confirmation)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).count > 0)
        let dialog = XCTAttachment(screenshot: app.screenshot())
        dialog.name = "Sleep confirmation names agent and machine"; dialog.lifetime = .keepAlways; add(dialog)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else {
            // iOS can dismiss this popover and deliver the outside tap to the underlying control.
            // Use the blank transcript gutter, not the navigation bar's Back button.
            let transcript = transcriptBeforeDialog
            let point = CGPoint(x: transcript.minX + 4, y: transcript.midY)
            XCTAssertTrue(transcript.contains(point))
            XCTAssertFalse(navigationBeforeDialog.contains(point))
            XCTAssertFalse(confirmation.frame.contains(point))
            XCTContext.runActivity(named: "Dismiss Sleep outside the popup at transcript gutter \(point)") { _ in
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            }
        }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["River"].exists, "Cancelling Sleep must leave the conversation open")
        waitAndTap(app.buttons["Conversation actions"], until: app.buttons["Agent settings"])
        waitAndTap(app.buttons["Agent settings"], until: app.descendants(matching: .any).matching(identifier: "agent-settings-summary").firstMatch)
        let provider = app.descendants(matching: .any).matching(identifier: "agent-settings-orchestrator").firstMatch
        XCTAssertTrue(scrollUntilExists(provider, in: app))
        XCTAssertFalse(app.buttons["agent-settings-orchestrator"].exists)
        // #452 moved Sleep to the last Form section. Swipe toward later rows;
        // the old downward swipe at the top dismissed the entire settings sheet.
        let sleep = app.buttons["agent-sleep"]
        XCTAssertTrue(scrollTo(sleep, in: app, up: true))
        let form = app.collectionViews.containing(.button, identifier: "agent-sleep").firstMatch
        XCTAssertTrue(form.exists, "Sleep must belong to the presented settings Form")
        // Hittable can include a partly clipped last row. Finish native Form travel
        // before the unchanged full-viewport assertion; never tap that partial row.
        for _ in 0..<4 {
            checkTimeLeft("fully revealing Sleep inside the settings Form")
            if pixelContains(form.frame.intersection(app.frame), sleep.frame) { break }
            form.swipeUp()
        }
        let settingsDone = app.buttons["agent-settings-done"]
        XCTAssertTrue(settingsDone.exists && settingsDone.isHittable, "Agent settings must remain presented after scrolling")
        XCTAssertTrue(sleep.isHittable, "Sleep must be reachable by a normal settings scroll")
        XCTAssertTrue(pixelContains(form.frame.intersection(app.frame), sleep.frame), "Sleep must be entirely inside the settings viewport")
        captureProvider(app, "Sleep fully contained after native settings Form scroll")
        waitAndTap(sleep, until: confirmation)
        confirmation.tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["agent-sleep-pending"].exists)
        let refusal = XCTAttachment(screenshot: app.screenshot())
        refusal.name = "Sleep refused, provider remains locked"; refusal.lifetime = .keepAlways; add(refusal)
        // Return from the last Sleep section to the earlier Runtime provider row.
        XCTAssertTrue(scrollUntilExists(provider, in: app, up: false))
        XCTAssertFalse(app.buttons["agent-settings-orchestrator"].exists, "A refused stop cannot create an unsafe provider menu")
    }

    func testGuidedProviderSelectionRequiresSaveAndDoesNotOfferResume() {
        checkGuidedProviderFlow(largeText: false)
    }

    func testGuidedProviderFlowAtLargeText() {
        checkGuidedProviderFlow(largeText: true)
    }

    func testProviderApplyKeepsSavedProposalAndStartSeparate() {
        checkProviderApply(largeText: false, lostReply: false)
    }

    func testProviderApplyAtAccessibilitySizeKeepsSavedProposalAndStartSeparate() {
        checkProviderApply(largeText: true, lostReply: false)
    }

    func testProviderApplyLostReceiptStaysLockedUntilItsResultIsChecked() {
        checkProviderApply(largeText: false, lostReply: true)
    }

    func testProviderApplyCannotSilentlyReplaceAnExplicitRuntime() {
        let app = launchApp(["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-control",
                             "--companion-preview-provider-apply-fixture", "--companion-preview-provider-apply-runtime-mismatch"], attempts: 1)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        tapVisibleProviderControl(app.buttons["provider-choice-codex-cli"], in: app)
        let reason = app.staticTexts["provider-apply-reason"]
        XCTAssertTrue(scrollTo(reason, in: app, up: false, maxSwipes: 8))
        XCTAssertTrue(reason.label.contains("does not preserve the requested runtime") && reason.label.contains("unsupported"))
        XCTAssertFalse(app.buttons["provider-save"].isEnabled)
        XCTAssertFalse(app.buttons["provider-start-new"].exists)
    }

    /// Synthetic only: main's fail-before uses the same launch and first assertion.
    /// No real host/configuration/provider or session is started by these receipts.
    private func checkProviderApply(largeText: Bool, lostReply: Bool) {
        var arguments = ["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-control",
                         "--companion-preview-provider-apply-fixture"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        if lostReply { arguments += ["--companion-preview-provider-apply-lost"] }
        let app = launchApp(arguments, attempts: 1)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        let choice = app.buttons["provider-choice-codex-cli"]
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        captureProvider(app, "Provider top and last-reported state before selection")
        let apply = app.buttons["provider-save"]
        XCTAssertTrue(scrollTo(apply, in: app), "Apply must be reachable before selecting, including at AX size")
        XCTAssertEqual(apply.label, "Apply provider")
        XCTAssertFalse(apply.isEnabled)
        let session = app.descendants(matching: .any).matching(identifier: "provider-session-unverified").firstMatch
        XCTAssertTrue(scrollTo(session, in: app))
        XCTAssertTrue(session.label.contains("Not verified here"))
        captureProvider(app, "Provider session evidence remains unverified before selection")
        tapVisibleProviderControl(choice, in: app)
        XCTAssertTrue(apply.isHittable && pixelContains(app.frame, apply.frame), "Apply must remain visible immediately after selection; no search scroll")
        let visibleReason = app.staticTexts["provider-apply-reason"]
        XCTAssertTrue(visibleReason.exists && pixelContains(app.frame, visibleReason.frame), "The action's reason must remain fully visible at this text size")
        app.buttons["provider-review-change"].tap()
        let saved = app.descendants(matching: .any).matching(identifier: "provider-saved-value").firstMatch
        let proposed = app.descendants(matching: .any).matching(identifier: "provider-proposed-value").firstMatch
        XCTAssertTrue(waitFor(saved, NSPredicate(format: "hittable == true"), timeout: 5), "The explicit Review change action must reveal saved/proposed values")
        XCTAssertTrue(saved.label.contains("Claude"))
        XCTAssertTrue(proposed.exists && proposed.label.contains("Codex"))
        XCTAssertTrue(pixelContains(app.frame, proposed.frame))
        captureProvider(app, "Review shows saved Claude, proposed Codex, and persistent Apply reason")
        XCTAssertFalse(app.buttons["provider-start-new"].exists, "A proposal cannot enable wake")
        let resets = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Applying resets:")).firstMatch
        XCTAssertTrue(scrollTo(resets, in: app, maxSwipes: 12))
        for consequence in ["model", "effort", "context window", "provider routing", "resume selection"] {
            XCTAssertTrue(resets.label.contains(consequence))
        }
        let scope = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "does not prepare or load skills or MCP")).firstMatch
        XCTAssertTrue(scrollUntilExists(scope, in: app, up: false, maxSwipes: 8))
        let proposalShot = XCTAttachment(screenshot: app.screenshot())
        proposalShot.name = "Synthetic preview native-primary scope and reset consequences"; proposalShot.lifetime = .keepAlways; add(proposalShot)
        XCTAssertTrue(apply.isHittable && pixelContains(app.frame, apply.frame))
        apply.tap()
        if lostReply {
            let check = app.buttons["provider-check-result"]
            XCTAssertTrue(scrollTo(check, in: app, maxSwipes: 12))
            XCTAssertFalse(app.buttons["provider-start-new"].exists)
            XCTAssertFalse(choice.isEnabled, "An uncertain write cannot be replaced by another selection")
            app.navigationBars["Provider"].buttons.firstMatch.tap()
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
            XCTAssertTrue(scrollTo(choice, in: app, maxSwipes: 12), "Reveal the same provider row after the native Form remount")
            XCTAssertFalse(choice.isEnabled, "Reopening the screen cannot forget the unresolved action")
            captureProvider(app, "Reopened unresolved Apply keeps the same provider choice disabled")
            tapVisibleProviderControl(check, in: app)
        }
        let receipt = app.staticTexts["provider-saved"]
        app.buttons["provider-review-change"].tap()
        XCTAssertTrue(scrollUntilExists(receipt, in: app, up: false, maxSwipes: 12))
        XCTAssertTrue(receipt.label.contains("Codex") && receipt.label.contains("No session was started by Apply"))
        captureProvider(app, "Matching Apply receipt before any Start confirmation")
        let start = app.buttons["provider-start-new"]
        XCTAssertTrue(scrollTo(start, in: app, maxSwipes: 8))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.staticTexts["provider-start-requested"].exists)
        tapVisibleProviderControl(start, in: app)
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Start new session", "provider-start-new")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        captureProvider(app, "Start confirmation before native AX dismissal")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else {
            // iOS 26 presents this as a popover without a Cancel button. Its
            // named AX dismissal element avoids a guessed point. XCTest activation
            // here does not establish spoken VoiceOver behavior.
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertEqual(dismiss.label, "dismiss popup")
            XCTAssertTrue(dismiss.isHittable, "The native accessible dismissal must be reachable")
            dismiss.tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Provider"].exists)
        XCTAssertEqual(app.navigationBars["Provider"].buttons.firstMatch.label, "Juniper", "Cancellation returns to the same agent's Provider screen")
        XCTAssertFalse(app.staticTexts["provider-start-requested"].exists)
        captureProvider(app, "Cancelled Start returns to Juniper without a requested Start")
        tapVisibleProviderControl(start, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let requested = app.staticTexts["provider-start-requested"]
        XCTAssertTrue(scrollTo(requested, in: app, maxSwipes: 12))
        XCTAssertTrue(requested.label.contains("not verified here"), "A synthetic Start receipt must not claim a running provider")
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = "Synthetic Apply receipt and separately requested Start"; result.lifetime = .keepAlways; add(result)
    }

    private func captureProvider(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func checkGuidedProviderFlow(largeText: Bool) {
        var arguments = ["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-control"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        let app = launchApp(arguments, attempts: 1)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        let current = app.buttons["provider-choice-claude-code"]
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        let apply = app.buttons["provider-save"]
        XCTAssertTrue(scrollUntilExists(apply, in: app), "Apply is discoverable before choosing, rather than hidden below Preview")
        XCTAssertEqual(apply.label, "Apply provider")
        XCTAssertFalse(apply.isEnabled, "Opening the flow must not preview or save a provider")
        let reason = app.staticTexts["provider-apply-reason"]
        XCTAssertTrue(scrollUntilExists(reason, in: app))
        XCTAssertTrue(reason.label.contains("Nothing is saved or started by choosing"))
        let unavailable = app.buttons["provider-choice-codex"]
        XCTAssertTrue(scrollUntilExists(unavailable, in: app))
        XCTAssertFalse(unavailable.isEnabled)
        tapVisibleProviderControl(current, in: app, up: false)
        XCTAssertTrue(app.navigationBars["Provider"].exists)
        XCTAssertTrue(waitFor(current, NSPredicate(format: "selected == true"), timeout: 5))
        let save = app.buttons["provider-save"]
        XCTAssertTrue(scrollUntilExists(save, in: app, up: false, maxSwipes: 8))
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.buttons["Resume"].exists, "Same-provider resume hint must not offer Resume")
        XCTAssertFalse(app.buttons["provider-start-new"].exists)
        let alternative = app.buttons["provider-choice-codex-cli"]
        tapVisibleProviderControl(alternative, in: app)
        XCTAssertTrue(app.navigationBars["Provider"].exists, "Choosing a provider must stay on the Provider page")
        XCTAssertTrue(waitFor(alternative, NSPredicate(format: "selected == true"), timeout: 5), "Codex CLI must be selected before looking for Save")
        XCTAssertTrue(save.isHittable && pixelContains(app.frame, save.frame), "Apply stays visible after choosing without a search scroll")
        XCTAssertTrue(save.isEnabled)
        app.buttons["provider-review-change"].tap()
        let savedValue = app.descendants(matching: .any).matching(identifier: "provider-saved-value").firstMatch
        let proposal = app.descendants(matching: .any).matching(identifier: "provider-proposed-value").firstMatch
        XCTAssertTrue(scrollUntilExists(savedValue, in: app, up: false, maxSwipes: 8))
        XCTAssertTrue(savedValue.label.contains("Claude"), "A Codex proposal must not replace the last reported saved Claude")
        XCTAssertTrue(scrollUntilExists(proposal, in: app, maxSwipes: 8))
        XCTAssertTrue(proposal.label.contains("Codex"))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = largeText ? "Guided provider preview at large text" : "Guided provider preview"; preview.lifetime = .keepAlways; add(preview)
        tapVisibleProviderControl(save, in: app)
        let refusal = app.staticTexts["provider-flow-error"]
        XCTAssertTrue(scrollUntilExists(refusal, in: app, maxSwipes: 8))
        XCTAssertTrue(refusal.label.contains("Preview only"))
        XCTAssertFalse(app.buttons["provider-start-new"].exists, "Refused Save never enables Start")
        XCTAssertFalse(app.buttons["Resume"].exists)
    }

    /// A partially obscured Form row can be reported hittable and tap Back instead.
    /// Reveal the entire control below this sheet's navigation bar, then tap once at its checked center.
    private func tapVisibleProviderControl(_ control: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        let navigation = app.navigationBars["Provider"]
        XCTAssertTrue(navigation.exists)
        XCTAssertTrue(scrollTo(control, in: app, up: up, maxSwipes: 8))
        func clearBottom() -> CGFloat {
            let bottom = app.frame.maxY - 34
            guard !["provider-save", "provider-review-change"].contains(control.identifier) else { return bottom }
            // Form rows must clear the persistent action inset, even when a
            // partially covered row reports hittable. Keep the full-frame check.
            let apply = app.buttons["provider-save"], review = app.buttons["provider-review-change"]
            guard apply.exists && review.exists else { return bottom }
            return min(bottom, min(apply.frame.minY, review.frame.minY) - 12)
        }
        var precedingFrame: CGRect?
        var precedingDrag: CGFloat?
        var observedResponse: CGFloat = 1
        for attempt in 0..<4 {
            let top = navigation.frame.maxY + 12
            let bottom = clearBottom()
            let frame = control.frame
            let settled = precedingFrame.map { frame.midY - $0.midY }
            if let settled, let precedingDrag, abs(settled) > 0.5,
               settled * precedingDrag > 0 {
                observedResponse = min(4, max(0.25, settled / precedingDrag))
            }
            print("PROVIDER_CONTROL_GEOMETRY id=\(control.identifier) attempt=\(attempt) row=\(frame) band=\(top)...\(bottom) settled=\(String(describing: settled)) response=\(observedResponse)")
            guard frame.height <= bottom - top else {
                XCTFail("The full provider control must fit between navigation and sticky actions: row \(frame), band \(top)...\(bottom)")
                return
            }
            if frame.minY >= top && frame.maxY <= bottom { break }
            // Fixed 120pt drags can fling an SE row across both clearances.
            // Center using the last measured native response, within the same
            // four gestures and the original protected viewport. No timing wait.
            let travel = min(120, (bottom - top) / 2 - 8)
            guard travel > 0 else { XCTFail("The protected viewport must permit a native scroll"); return }
            let dy = min(travel, max(-travel, ((top + bottom) / 2 - frame.midY) / observedResponse))
            // A sub-pan correction could activate a row before the checked tap.
            // Refuse it rather than trade the original clearances for a tap.
            guard abs(dy) >= 24 else {
                XCTFail("The measured correction must establish a native scroll, not an unchecked tap: drag \(dy), row \(frame), band \(top)...\(bottom)")
                return
            }
            let origin = CGPoint(x: app.frame.midX, y: (top + bottom) / 2)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: origin.x - app.frame.minX, dy: origin.y - app.frame.minY))
            precedingFrame = frame; precedingDrag = dy
            XCTContext.runActivity(named: "Measured provider scroll \(control.identifier): row \(frame), band \(top)...\(bottom), drag \(dy), response \(observedResponse)") { _ in
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
            }
        }
        let frame = control.frame
        let finalShift = precedingFrame.map { frame.midY - $0.midY }
        print("PROVIDER_CONTROL_GEOMETRY id=\(control.identifier) finalRow=\(frame) band=\(navigation.frame.maxY + 12)...\(clearBottom()) settled=\(String(describing: finalShift))")
        let point = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(control.exists && control.isHittable)
        XCTAssertGreaterThanOrEqual(frame.minY, navigation.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, clearBottom())
        XCTAssertFalse(navigation.frame.contains(point))
        XCTContext.runActivity(named: "Tap visible provider control at \(point), frame \(frame), navigation \(navigation.frame)") { _ in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Visible \(control.identifier) before one checked tap"; shot.lifetime = .keepAlways; add(shot)
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func testAgentSettingsShowsDispatcherWithOrchestrationOff() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        openAgentSettings(app)
        let toggle = app.switches["agent-settings-orchestrate-dispatcher"]
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.exists && toggle.isEnabled)
    }

    func testHelperSettingsHidesOnlyTheDispatcherConnection() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-helper-identity"])
        openAgentSettings(app, sleeping: true)
        for id in ["agent-settings-orchestrate", "agent-settings-orchestrate-access", "agent-settings-orchestrate-control",
                   "agent-settings-orchestrate-max-helpers", "agent-settings-orchestrate-cross-project"] {
            let control = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(scrollUntilExists(control, in: app), id)
        }
        XCTAssertFalse(app.switches["agent-settings-orchestrate-dispatcher"].exists, "A known helper talks only to its parent")
    }

    func testUnsupportedProviderChangesDoNotOfferAnUnsafeGenericMenu() {
        let app = launchApp(["--companion-preview", "--companion-preview-provider-options"], attempts: 1)
        openAgentSettings(app, sleeping: true)
        let saved = app.descendants(matching: .any).matching(identifier: "agent-settings-orchestrator").firstMatch
        XCTAssertTrue(scrollTo(saved, in: app))
        XCTAssertTrue(saved.label.contains("Claude Code"))
        XCTAssertFalse(app.buttons["agent-settings-orchestrator"].exists, "Old hosts must not offer generic cross-provider writes")
        let unsupported = app.staticTexts["agent-settings-provider-unsupported"]
        XCTAssertTrue(scrollTo(unsupported, in: app))
        XCTAssertTrue(unsupported.label.contains("unavailable") && unsupported.label.contains("Provider Apply"))
        let model = app.buttons["agent-settings-model"]
        XCTAssertTrue(scrollTo(model, in: app))
        XCTAssertTrue(model.isEnabled, "Unrelated supported settings remain editable for this sleeping agent")
        XCTAssertFalse(app.staticTexts["agent-settings-error"].exists)
        let orchestrate = app.switches["agent-settings-orchestrate"]
        XCTAssertTrue(scrollTo(orchestrate, in: app))
        XCTAssertFalse(app.switches["agent-settings-orchestrate-dispatcher"].exists, "Dispatcher off still hides its connection switch")
    }

    /// Home's New agent button, which shows only on Home.
    private func homeNewAgent(_ app: XCUIApplication) -> XCUIElement { app.navigationBars.buttons["New agent"] }

    func testKnownGoneAndQuickSendersHaveAccessibleAvatars() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        openRiver(app)
        let any = app.descendants(matching: .any)
        for (id, label) in [
            ("companion-sender-avatar-sender-preview-3", "willow avatar"),
            ("companion-sender-avatar-sender-preview-0", "Cedar avatar"),
            ("companion-sender-avatar-sender-preview-1", "Maple avatar"),
            ("companion-sender-avatar-relay-1-0", "Dispatcher controller avatar"),
            ("companion-sender-avatar-relay-1-1", "Reviewer avatar")
        ] {
            let avatar = any.matching(identifier: id).firstMatch
            XCTAssertTrue(scrollUntilExists(avatar, in: app, up: false, maxSwipes: 8), id)
            XCTAssertTrue(bringTranscriptRowIntoView(avatar, in: app), "The compact sender face must be visible")
            XCTAssertEqual(avatar.label, label)
            if id == "companion-sender-avatar-sender-preview-3" {
                let quickFaces = XCTAttachment(screenshot: app.screenshot())
                quickFaces.name = "Inline known and quick sender faces"
                quickFaces.lifetime = .keepAlways
                add(quickFaces)
            }
        }
        XCTAssertFalse(app.buttons["companion-activity-routed:relay-1:0"].exists, "Relayed messages never become activity cards")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Known and gone sender faces"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreviewOpensScopedConversationAndKeepsCommandsNonLive() {
        let app = launchApp(["--companion-preview"])
        openRiver(app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Selecting an agent must open its conversation")
        XCTAssertTrue(app.navigationBars["River"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native companion conversation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        composer.tap()
        composer.typeText("Preview smoke message")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 5), "Preview must never claim a command reached a desktop")
    }

    /// A one-line composer shorter than its text view's content scrolls to the caret as you type,
    /// which reads as the text jittering until it wraps. One line must be exactly half of two lines.
    func testComposerSingleLineHeightMatchesWrappedLineHeight() {
        let app = launchApp(["--companion-preview"])
        openRiver(app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let send = app.buttons["companion-send"]
        XCTAssertLessThanOrEqual(composer.frame.maxY, send.frame.minY, "The placeholder stays above the action row")
        XCTAssertGreaterThanOrEqual(composer.frame.width, app.frame.width * 0.7, "The ordinary editor keeps the full text row")
        composer.tap()
        composer.typeText("Hey")
        let oneLine = composer.frame.height
        XCTAssertLessThanOrEqual(composer.frame.maxY, send.frame.minY, "One line stays above the action row")
        XCTAssertEqual(composer.value as? String, "Hey")
        // Two words at a time: fewer round trips, and still far short of a whole line, so it stops at two lines.
        for _ in 0..<10 where composer.frame.height <= oneLine + 1 {
            composer.typeText(" steady steady")
        }
        let twoLines = composer.frame.height
        XCTAssertGreaterThan(twoLines, oneLine + 1, "Composer must grow when the draft wraps")
        XCTAssertEqual(oneLine, twoLines / 2, accuracy: 0.5, "A single line must use the same line height as wrapped lines")
        XCTAssertLessThanOrEqual(composer.frame.maxY, send.frame.minY, "Wrapped text stays above the action row")
        XCTAssertGreaterThanOrEqual(composer.frame.width, app.frame.width * 0.7, "Wrapping does not reserve a control column")
    }

    /// Accessibility text gives the draft its own full-width row above the actions.
    func testComposerCentresOneLineAtLargeText() {
        let app = launchApp(["--companion-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openRiver(app, maxSwipes: 6)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let send = app.buttons["companion-send"]
        /// The full-width draft sits above its action row, both clear of the navigation bar and keyboard.
        func assertStacked(_ state: String, editing: Bool) {
            let keyboard = app.keyboards.firstMatch
            XCTAssertEqual(keyboard.exists, editing, state)
            let navigation = app.navigationBars.firstMatch.frame
            let bottom = editing ? keyboard.frame.minY : app.frame.maxY
            let viewport = CGRect(x: app.frame.minX, y: navigation.maxY, width: app.frame.width, height: max(0, bottom - navigation.maxY))
            XCTAssertTrue(pixelContains(viewport, composer.frame), "\(state): the readable editor stays above the keyboard")
            XCTAssertTrue(pixelContains(viewport, send.frame), "\(state): Send stays above the keyboard")
            XCTAssertGreaterThanOrEqual(composer.frame.width, app.frame.width * 0.7, state)
            XCTAssertLessThanOrEqual(pixelAligned(composer.frame.maxY), pixelAligned(send.frame.minY), "\(state): the editor is above its action row")
            assertMinimumTarget(send, "Send")
            XCTAssertTrue(composer.isHittable, state)
            if editing { XCTAssertTrue(send.isEnabled && send.isHittable, state) }
        }
        assertStacked("placeholder", editing: false)
        composer.tap()
        composer.typeText("Hey")
        XCTAssertEqual(composer.value as? String, "Hey")
        assertStacked("one line", editing: true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer at accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// A preview opened from a tool card must close while the agent keeps streaming, even as the card is
    /// re-projected and lookups around it fold into "Explored…" (#134).
    func testContentPreviewDismissesWhileToolUpdatesStream() {
        let app = launchApp(["--companion-preview", "--companion-preview-stream"])
        openRiver(app)
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "build/test-log.txt")).firstMatch
        let done = app.buttons["companion-preview-done"]
        let title = app.navigationBars["test-log.txt"]

        let links = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "build/test-log.txt"))
        func openVisibleLog(until expected: XCUIElement) {
            let transcript = app.scrollViews.containing(.button, identifier: "companion-content-link").firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: 5))
            let approval = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Approval needed: ")).firstMatch
            let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
            func usableViewport() -> CGRect {
                let bounds = transcript.frame.intersection(app.frame)
                let top = bounds.minY + 12
                var bottom = min(bounds.maxY, composer.frame.minY, approval.exists ? approval.frame.minY : composer.frame.minY) - 12
                let latest = app.pausedChatNavigation
                if latest.exists { bottom = min(bottom, latest.frame.minY - 12) }
                return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            }
            var viewport = usableViewport()
            XCTAssertGreaterThan(viewport.height, 100)
            // Stop following the live bottom with a real reading gesture; updates keep streaming.
            // Waiting for the total link count to settle can prevent every tap as new runs arrive.
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.3))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: viewport.height * 0.4)))
            XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5), "Read above the live bottom before resolving the log")
            // Existing links precede appended runs. Reveal one instead of chasing the newest index.
            let candidate = links.firstMatch
            // The generic helper's fixed screen band can accept a link above this viewport.
            // Use the same current unobscured region for revealing and checking the whole link.
            for _ in 0..<40 {
                checkTimeLeft("bringing the streaming log inside its usable viewport")
                viewport = usableViewport()
                XCTAssertGreaterThan(viewport.height, 100)
                if candidate.exists && viewport.contains(candidate.frame) && candidate.isHittable { break }
                let above = candidate.exists && candidate.frame.minY < viewport.minY
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
                let distance = viewport.height * 0.3 * (above ? 1 : -1)
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
            }
            viewport = usableViewport()
            XCTAssertTrue(candidate.exists, "A real log link must be visible in the transcript")
            XCTAssertTrue(candidate.isHittable)
            let frame = candidate.frame
            XCTAssertTrue(viewport.contains(frame), "Log \(frame) must fit within the current unobscured transcript \(viewport)")
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Visible log before one checked tap"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTContext.runActivity(named: "Tap visible log once at \(point), link \(frame), transcript \(viewport)") { _ in
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            }
            XCTAssertTrue(expected.waitForExistence(timeout: 5), "The streaming card's log must open after one real tap")
        }

        // Done: wait through several updates, including a fold, before closing.
        revealActivityContent(link, in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15), "The streaming tool card must offer its log")
        openVisibleLog(until: done)
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The sample file must load")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(done.isHittable, "Done must stay reachable while updates stream")
        waitAndTap(done, untilGone: done, "Done must close the preview while updates stream")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "After closing preview with Done"
        add(screenshot)

        // Open another visible log while updates continue, then swipe down to dismiss.
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        openVisibleLog(until: title)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Swiping down must close the preview while updates stream")
    }

    /// Agent replies render block Markdown natively: the sample reply's heading, table and list
    /// appear as elements, and none of the raw syntax (`## `, `|---|`) reaches the screen.
    func testAgentReplyRendersBlockMarkdown() {
        let app = launchApp(["--companion-preview"])
        openRiver(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10))

        // The conversation opens at the latest item; the reply sits just above the approval.
        let heading = app.staticTexts["Reconnect status"]
        if !heading.waitForExistence(timeout: 10) {
            scrollUntilExists(heading, in: app, up: false, maxSwipes: 3, wait: 0.5)
        }
        XCTAssertTrue(heading.exists, "The heading must render without its hashes")
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Row 1.' AND label CONTAINS 'Check: Resume after sleep'")).firstMatch
        XCTAssertTrue(row.exists, "The table must render as rows VoiceOver reads cell by cell")
        XCTAssertTrue(app.staticTexts["Keep drafts per agent"].exists, "The task list item must render")
        XCTAssertTrue(app.images["Done"].exists, "A checked task shows its checkbox")

        let raw = NSPredicate(format: "label CONTAINS '|---' OR label CONTAINS '|:--' OR label CONTAINS '| Check' OR label BEGINSWITH '## ' OR label BEGINSWITH '- ['")
        XCTAssertEqual(app.staticTexts.matching(raw).count, 0, "No raw Markdown syntax may reach the screen")
        XCTAssertFalse(app.staticTexts["Agent"].exists, "Agent replies carry no author label, like the desktop")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Block Markdown reply"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Mobile activity groups all four routine calls and keeps their links available on expansion;
    /// the approval card shows its own title, "1 of 2", and the persistent option the desktop answers;
    /// the pinned summary names the oldest request and the header shows context fill.
    func testExploredFoldAndApprovalCardMatchDesktop() {
        let app = launchApp(["--companion-preview"])
        openRiver(app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.placeholderValue, "Message River… / for commands", "The placeholder names the agent and offers / commands, like the desktop")

        let summary = app.buttons["companion-decision-show-in-chat"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "Run xcodebuild", "The pinned summary names the oldest waiting request")
        XCTAssertEqual(summary.value as? String, "1 of 2 waiting · Bash")
        XCTAssertFalse(app.staticTexts["companion-chat-activity"].exists, "The pinned request replaces the redundant activity line")
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(context.exists)
        XCTAssertEqual(context.label, "Context and plan limits")
        XCTAssertEqual(context.value as? String, "Latest reported context: 42% full")

        // Review retains the full card and scoped persistent action without duplicating transcript decisions.
        let close = app.buttons["companion-approval-review-close"]
        openPinnedDecisionReview(in: app, until: close)
        let review = app.scrollViews["companion-approval-review-scroll"]
        let position = review.staticTexts.matching(identifier: "companion-approval-position").firstMatch
        XCTAssertTrue(position.exists, "Two waiting approvals must show their count")
        XCTAssertTrue(review.staticTexts["Run xcodebuild"].exists, "The card uses the request's title")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'Always allow' AND label CONTAINS 'xcodebuild:*'")).firstMatch.exists,
                      "Persistent options stay listed, with their scope")
        XCTAssertTrue(app.buttons["companion-approval-option-allow-always"].exists, "A desktop that takes lasting options gets a button")
        XCTAssertFalse(app.staticTexts["Choose this on your desktop"].exists)
        XCTAssertFalse(app.staticTexts["Your approval is needed"].exists)
        let approvalShot = XCTAttachment(screenshot: app.screenshot())
        approvalShot.name = "Approval card with title, count and persistent option"
        approvalShot.lifetime = .keepAlways
        add(approvalShot)
        waitAndTap(close, untilGone: close, attempts: 1)

        // The explored fold sits above the replies: scroll up to it.
        let fold = app.buttons.matching(identifier: "companion-activity-tool:tool-1").firstMatch
        scrollTo(fold, in: app, up: false, maxSwipes: 8)
        // Hittable can still mean under floating chrome; keep the fold clear of the header, Latest and decision tray.
        XCTAssertTrue(scrollIntoClearArea(fold, in: app), "The fold is clear of the chrome: \(fold.frame), clear \(clearTranscriptArea(in: app))")
        XCTAssertTrue(fold.isHittable, "Read-only lookups must fold into one row")
        XCTAssertTrue(fold.label.contains("4 tool calls"), "The fold counts like the desktop: \(fold.label)")
        XCTAssertFalse(any.matching(NSPredicate(format: "label BEGINSWITH 'Ran '")).firstMatch.exists, "The old \"Ran N tools\" fold is gone")
        XCTAssertFalse(app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "/Users/river/clubhouse/.build/test.log")).firstMatch.exists,
                       "Collapsed tool content and links are not built")

        // Each lookup's link opens from inside the fold, and its preview closes.
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "Sources/Companion/Conversation.swift")).firstMatch
        fold.tap()
        XCTAssertTrue(waitFor(fold, NSPredicate(format: "value == %@", "Expanded"), timeout: 5), "The fold must expand after its tap")
        XCTAssertTrue(link.waitForExistence(timeout: 5), "An expanded fold offers each lookup's links")
        let foldShot = XCTAttachment(screenshot: app.screenshot())
        foldShot.name = "Explored fold expanded"
        foldShot.lifetime = .keepAlways
        add(foldShot)
        // The bookmark keeps the header in place as it expands. Scroll from a safe transcript coordinate;
        // a short drag on the header itself can become a second tap and close the group.
        XCTAssertTrue(scrollIntoClearArea(link, in: app), "The lookup link is clear of the chrome: \(link.frame), clear \(clearTranscriptArea(in: app))")
        let done = app.buttons["companion-preview-done"]
        waitAndTap(link, until: done, timeout: 5, "A link inside the fold opens its preview")
        waitAndTap(done, untilGone: done, "The preview closes")
    }

    /// Home matches the desktop sidebar: idle projects fold into one section, sleeping and finished
    /// quick agents fold inside a project, and a pinned project moves to the top.
    func testHomeFoldsIdleProjectsAndPinsToTop() {
        let app = launchApp(["--companion-preview"])
        func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
        func reveal(_ target: XCUIElement) { scrollTo(target, in: app, maxSwipes: 5, velocity: .slow) }
        func scrollToTop() { for _ in 0..<3 { app.swipeDown(velocity: .fast) } }

        XCTAssertTrue(element("agent-preview-studio-river").waitForExistence(timeout: 15), "Preview desktop must load")
        let cedar = element("agent-preview-studio-cedar")
        reveal(cedar)
        XCTAssertTrue(cedar.label.contains("Auto") && !cedar.label.contains("Auto or Full access"), "The row names the exact saved Access")
        let river = element("agent-preview-studio-river")
        scrollTo(river, in: app, up: false, maxSwipes: 5, velocity: .slow)
        XCTAssertTrue(river.label.contains("Ask first"), "Rows show saved Access, not the live Auto-accept edits level")

        let sleeping = element("fold-quiet-preview-studio-clubhouse")
        reveal(sleeping)
        XCTAssertTrue(sleeping.label.contains("1 sleeping"))
        XCTAssertFalse(element("agent-preview-studio-juniper").exists, "Sleeping agents start folded")
        XCTAssertTrue(element("fold-quiet-preview-studio-clubhouse").label.contains("3 finished quick agents"))
        tapToExpand(sleeping)
        XCTAssertTrue(element("agent-preview-studio-juniper").waitForExistence(timeout: 5), "Opening the fold shows the sleeping agent")

        let idle = element("idle-projects-fold")
        reveal(idle)
        XCTAssertTrue(idle.label.contains("1 idle project"))
        XCTAssertFalse(element("project-preview-studio-prototype").exists, "Idle projects start folded")
        tapToExpand(idle)
        XCTAssertTrue(element("project-preview-studio-prototype").waitForExistence(timeout: 5), "Opening the idle section shows the project")

        scrollToTop()
        let header = element("open-project-preview-studio-website")
        reveal(header)
        let pin = app.buttons["Pin to top of Home"]
        longPressUntilMenu(header, shows: pin, attempts: 1)
        pin.tap()
        scrollToTop()
        let website = element("project-preview-studio-website"), clubhouse = element("project-preview-studio-clubhouse")
        reveal(website)
        XCTAssertTrue(clubhouse.waitForExistence(timeout: 5))
        XCTAssertLessThan(website.frame.minY, clubhouse.frame.minY, "A pinned project goes first")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home with a pinned project and the idle section"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// A sleeping agent with a session offers both of the desktop's wake choices, in its chat and on its row.
    func testSleepingAgentOffersWakeAndResumeAndStartNewSession() {
        let app = launchApp(["--companion-preview"])
        let juniper = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-juniper").firstMatch
        // Home folds sleeping agents; open the fold to reach Juniper.
        func unfoldJuniper() {
            let fold = app.descendants(matching: .any).matching(identifier: "fold-quiet-preview-studio-clubhouse").firstMatch
            scrollUntilExists(fold, in: app)
            expandFold(fold, revealing: juniper, in: app)
        }
        unfoldJuniper()
        XCTAssertTrue(juniper.waitForExistence(timeout: 15), "The sleeping preview agent must appear")

        let resume = app.buttons["companion-wake"]
        waitAndTap(juniper, until: resume, timeout: 10, "The asleep bar must appear")
        XCTAssertEqual(resume.label, "Wake & Resume")
        let fresh = app.buttons["companion-wake-newSession"]
        XCTAssertTrue(fresh.exists)
        XCTAssertEqual(fresh.label, "Start New Session")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Wake choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        waitAndTap(app.navigationBars.buttons.element(boundBy: 0), until: homeNewAgent(app))
        if !juniper.waitForExistence(timeout: 5) { unfoldJuniper() }
        XCTAssertTrue(juniper.waitForExistence(timeout: 10))
        longPressUntilMenu(juniper, shows: app.buttons["Wake & Resume"], "The long-press menu offers Wake & Resume")
        XCTAssertTrue(app.buttons["Start New Session"].exists, "The long-press menu offers Start New Session")
        XCTAssertTrue(app.buttons["Agent settings"].exists)
    }

    /// Needs you leads with the desktop's requested action, with tool and timeout metadata beneath it.
    func testNeedsYouUsesTheDesktopWords() {
        let app = launchApp(["--companion-preview"])
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        waitAndTap(tab, until: app.staticTexts["Run xcodebuild"], timeout: 10)
        XCTAssertTrue(app.staticTexts["Bash"].exists, "The tool is metadata beneath the requested action")
        XCTAssertFalse(app.staticTexts["Needs permission to use Bash"].exists)
        let countdown = app.descendants(matching: .any).matching(identifier: "companion-approval-countdown").firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertTrue(countdown.label.contains("Times out in"), countdown.label)
    }

    /// The sheet is already open. Keep every visibility/hit assertion while resolving each row frame once.
    private func scrollDetailsRow(_ target: XCUIElement, in sheet: XCUIElement, app: XCUIApplication, up: Bool = true) {
        let list = sheet.collectionViews.firstMatch
        var reached = false
        for _ in 0..<12 {
            checkTimeLeft("scrolling the details list")
            let frame = list.frame
            let top = max(frame.minY, sheet.navigationBars.firstMatch.frame.maxY) + 12
            let visible = CGRect(x: frame.minX + 8, y: top, width: frame.width - 16, height: frame.maxY - top - 12)
            let targetFrame = target.exists ? target.frame : nil
            if let targetFrame, visible.contains(targetFrame), target.isHittable { reached = true; break }
            let down = targetFrame.map { $0.minY < visible.minY } ?? !up
            let distance = min(180, visible.height * 0.35) * (down ? 1 : -1)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(reached, "Details row must scroll into view")
    }

    private func openRiverDetails(_ app: XCUIApplication) -> XCUIElement {
        let any = app.descendants(matching: .any)
        let river = any.matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(river, in: app)
        XCTAssertTrue(river.waitForExistence(timeout: 15), "Preview agent must appear")
        let actions = app.buttons["Conversation actions"]
        waitAndTap(river, until: actions, timeout: 10)
        let details = app.buttons["Agent details"]
        waitAndTap(actions, until: details, timeout: 5, "The chat header offers the agent's details")
        let sheet = any.matching(identifier: "agent-details-sheet").firstMatch
        waitAndTap(details, until: sheet, timeout: 10)
        XCTAssertTrue(sheet.collectionViews.firstMatch.waitForExistence(timeout: 5))
        return sheet
    }

    func testAgentDetailsSheetMatchesTheDesktopHoverCard() {
        let app = launchApp(["--companion-preview"])
        let any = app.descendants(matching: .any)
        func element(_ id: String) -> XCUIElement { any.matching(identifier: id).firstMatch }
        let sheet = openRiverDetails(app)
        // The iPad form sheet is shorter than the phone sheet. Visit the lazy
        // list in display order rather than reading rows below its viewport.
        let branch = element("agent-details-branch")
        let cli = element("agent-details-cli")
        scrollDetailsRow(cli, in: sheet, app: app, up: false)
        XCTAssertTrue(cli.label.contains("Claude Code 2.1.4"), "Runs on with the session's CLI version")
        let effort = element("agent-details-effort")
        scrollDetailsRow(effort, in: sheet, app: app)
        XCTAssertTrue(effort.label.contains("High"))
        scrollDetailsRow(branch, in: sheet, app: app)
        XCTAssertTrue(branch.label.contains("river/companion"), branch.label)
        let workspace = element("agent-details-worktree")
        scrollDetailsRow(workspace, in: sheet, app: app)
        XCTAssertTrue(workspace.label.contains(".clubhouse/agents/river"))
        let access = element("agent-details-access")
        scrollDetailsRow(access, in: sheet, app: app)
        XCTAssertTrue(access.label.contains("Auto-accept edits now, starts at Ask first"), "Details distinguish live and next-start Access")
        XCTAssertFalse(element("agent-details-free-agent-mode").exists, "The exact Access row replaces the coarse boolean row")
        let autoSleep = element("agent-details-auto-sleep")
        scrollDetailsRow(autoSleep, in: sheet, app: app)
        XCTAssertTrue(autoSleep.label.contains("Sleeps after 30 min"))
        let failedServer = element("agent-details-mcp-offline")
        scrollDetailsRow(failedServer, in: sheet, app: app)
        XCTAssertTrue(failedServer.label.contains("Failed"))
        XCTAssertTrue(failedServer.label.contains("Connection refused (sanitized by desktop)"), failedServer.label)
        let mcp = element("agent-details-mcp-summary")
        scrollDetailsRow(mcp, in: sheet, app: app)
        XCTAssertEqual(mcp.label, "2 connected · 1 needs sign-in · 1 not connected · 1 configured", "The MCP card's summary")
        let changes = element("agent-details-changes")
        scrollDetailsRow(changes, in: sheet, app: app)
        XCTAssertTrue(changes.label.contains("6 files +94 −51"), changes.label)
        XCTAssertTrue(app.staticTexts["2 commits ahead of main · 1 uncommitted"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Agent details"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAgentDetailsSheetLinksToAgentSettings() {
        let app = launchApp(["--companion-preview"])
        let any = app.descendants(matching: .any)
        func element(_ id: String) -> XCUIElement { any.matching(identifier: id).firstMatch }
        let sheet = openRiverDetails(app)
        // Agent settings opens from the sheet, for editing.
        let openSettings = element("agent-details-open-settings")
        scrollDetailsRow(openSettings, in: sheet, app: app)
        waitAndTap(openSettings, until: element("agent-settings-summary"), timeout: 10, "Details links to the agent's settings")
        waitAndTap(sheet.navigationBars.buttons.element(boundBy: 0), until: openSettings, timeout: 5)
        waitAndTap(sheet.buttons["Done"], untilGone: openSettings)
    }

    func testAgentDetailsSheetForAnAgentWithoutSession() {
        let app = launchApp(["--companion-preview"])
        let any = app.descendants(matching: .any)
        func element(_ id: String) -> XCUIElement { any.matching(identifier: id).firstMatch }
        // Sleeping agents start folded on Home.
        let sleeping = element("fold-quiet-preview-studio-clubhouse")
        let juniper = element("agent-preview-studio-juniper")
        expandFold(sleeping, revealing: juniper, in: app)
        XCTAssertTrue(juniper.waitForExistence(timeout: 10))
        let rowDetails = app.buttons["Agent details"]
        // A recorded center press opened the chat instead (#247). Exercise the
        // visible name explicitly; center-press behavior remains an open product investigation.
        let name = juniper.staticTexts["Juniper"].firstMatch
        XCTAssertTrue(name.exists && name.isHittable)
        let frame = juniper.frame
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, rowContentBottom(in: app))
        let point = CGPoint(x: name.frame.midX, y: name.frame.midY)
        XCTAssertTrue(frame.contains(point))
        XCTContext.runActivity(named: "Long-press visible Juniper name at \(point), row \(frame)") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).press(forDuration: 1.2)
        }
        XCTAssertTrue(rowDetails.waitForExistence(timeout: 5), "The long-press menu offers the agent's details")
        let sheet = element("agent-details-sheet")
        let worktree = element("agent-details-worktree")
        waitAndTap(rowDetails, until: sheet, timeout: 10)
        XCTAssertTrue(sheet.collectionViews.firstMatch.waitForExistence(timeout: 5))
        scrollDetailsRow(worktree, in: sheet, app: app)
        XCTAssertTrue(worktree.label.contains("Works in the project folder"), worktree.label)
        XCTAssertFalse(element("agent-details-effort").exists, "No session, so no effort is guessed")
        let juniperChanges = element("agent-details-changes")
        scrollDetailsRow(juniperChanges, in: sheet, app: app)
        XCTAssertTrue(juniperChanges.label.contains("No changes"), juniperChanges.label)
    }

    /// The desktop composer's pills (#155): level, model and effort menus with the desktop's labels, a confirmation
    /// before raising to Full access, and "Always allow" as a confirmed secondary action. Controls refuse changes;
    /// the existing pinned-decision fixture acknowledges only the exact synthetic approval option.
    func testChatControlsMenusAndPersistentApproval() {
        let app = launchApp(["--companion-preview", "--companion-preview-pinned-decisions"], attempts: 1)
        openRiver(app, attempts: 1)
        let any = app.descendants(matching: .any)
        func item(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch }
        let previewError = app.staticTexts["Preview only. This action does not contact a desktop."]
        let dismissError = app.buttons["Dismiss"]

        // The header shows the current level.
        let header = any.matching(identifier: "companion-chat-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("Auto-accept edits"), "The header shows the level: \(header.label)")

        // Level: the ladder, with the driver's names, and a confirmation before Full access.
        let level = any.matching(identifier: "companion-level-menu").firstMatch
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        let permissions = any.matching(identifier: "companion-permissions-menu").firstMatch
        waitAndTap(level, until: permissions, timeout: 5, attempts: 1)
        let fullAccess = item("Full access")
        waitAndTap(permissions, until: fullAccess, timeout: 5, attempts: 1, "Every live level is offered")
        for label in ["Plan", "Ask first", "Auto-accept edits", "Auto"] { XCTAssertTrue(item(label).exists, label) }
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'bypassPermissions'")).firstMatch.exists, "The driver's own name is the subtitle")
        let levelShot = XCTAttachment(screenshot: app.screenshot())
        levelShot.name = "Permission level menu"
        levelShot.lifetime = .keepAlways
        add(levelShot)
        let confirmLevel = app.buttons["Switch to Full access"]
        waitAndTap(fullAccess, until: confirmLevel, timeout: 5, attempts: 1, "Raising to Full access asks first")
        confirmLevel.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5), "Preview must never claim the level changed")
        dismissError.tap()

        // Model: the session's models, and when a change applies.
        let model = any.matching(identifier: "companion-model-menu").firstMatch
        waitAndTap(level, until: model, timeout: 5, attempts: 1)
        XCTAssertTrue(model.exists)
        XCTAssertTrue(model.label.contains("Opus"), "The chip names the model: \(model.label)")
        let mini = item("Haiku")
        waitAndTap(model, until: mini, timeout: 5, attempts: 1)
        XCTAssertTrue(any.matching(NSPredicate(format: "label == 'Applies from the next message.'")).firstMatch.exists, "The switch note shows under the menu")
        let modelShot = XCTAttachment(screenshot: app.screenshot())
        modelShot.name = "Model menu"
        modelShot.lifetime = .keepAlways
        add(modelShot)
        mini.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5))
        dismissError.tap()

        // Effort: sentence case, with Default when the provider has one.
        let effort = any.matching(identifier: "companion-effort-menu").firstMatch
        waitAndTap(level, until: effort, timeout: 5, attempts: 1)
        XCTAssertTrue(effort.exists)
        XCTAssertTrue(effort.label.contains("High effort"), "The chip names the effort: \(effort.label)")
        let extraHigh = item("Extra high")
        waitAndTap(effort, until: extraHigh, timeout: 5, attempts: 1, "xhigh reads as Extra high")
        XCTAssertTrue(item("Default").exists, "Default is offered when the provider has one")
        extraHigh.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5))
        dismissError.tap()

        // Always allow lives in the pinned request's full Review card and still requires confirmation.
        let close = app.buttons["companion-approval-review-close"]
        openPinnedDecisionReview(in: app, until: close)
        let review = app.scrollViews["companion-approval-review-scroll"]
        let always = review.buttons["companion-approval-option-allow-always"]
        XCTAssertTrue(always.waitForExistence(timeout: 5))
        XCTAssertTrue(always.label.contains("xcodebuild:*"), "The offered lasting option preserves its scope")
        scrollTo(always, in: app, maxSwipes: 4)
        XCTAssertTrue(always.isHittable, "Always allow is tappable on a desktop that takes it")
        always.tap()
        let confirmAlways = app.buttons.matching(NSPredicate(format: "label == 'Always allow'")).firstMatch
        XCTAssertTrue(confirmAlways.waitForExistence(timeout: 5), "Always allow asks first")
        let approvalShot = XCTAttachment(screenshot: app.screenshot())
        approvalShot.name = "Always allow confirmation"
        approvalShot.lifetime = .keepAlways
        add(approvalShot)
        confirmAlways.tap()
        XCTAssertTrue(review.staticTexts["Allowed"].waitForExistence(timeout: 5))
        waitAndTap(close, untilGone: close, attempts: 1)
        let receipt = app.staticTexts["Synthetic decision: approval-1 / allow-always"]
        XCTAssertTrue(scrollUntilExists(receipt, in: app), "The synthetic service receives the original approval and persistent option IDs")
        XCTAssertFalse(previewError.exists, "The fixture acknowledges only a synthetic decision, without contacting a desktop")
    }

    /// Helper requests show in Needs you with the desktop's line. A dispose with work at risk is "Dispose anyway",
    /// asks first as the desktop's dispose dialog does, and the preview never claims it reached a desktop.
    func testNeedsYouAnswersHelperRequestsWithTheDesktopRules() {
        let app = launchApp(["--companion-preview", "--companion-preview-helper-requests"])
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        waitAndTap(tab, until: app.staticTexts["Wants to start the helper docs-pass"], timeout: 10)
        XCTAssertTrue(app.staticTexts["Update the reconnect section of the README"].exists, "A start shows the helper's task")
        let summary = app.staticTexts["River asked to dispose this helper. 2 uncommitted files, 1 unpushed commit."]
        let disposeAnyway = app.buttons.matching(identifier: "helper-request-approve").matching(NSPredicate(format: "label == 'Dispose anyway'")).firstMatch
        scrollTo(disposeAnyway, in: app, maxSwipes: 4)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dispose anyway deletes this work. To keep it, commit and push from Cedar first."].exists)
        XCTAssertTrue(disposeAnyway.waitForExistence(timeout: 5), "Work at risk makes the dispose \"Dispose anyway\"")
        waitAndTap(disposeAnyway, until: app.staticTexts["Dispose of Cedar?"], timeout: 5, "Disposing asks first")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Helper dispose confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Dispose anyway' AND identifier != 'helper-request-approve'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let error = app.descendants(matching: .any).matching(identifier: "helper-request-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Preview must never claim a command reached a desktop")
        XCTAssertEqual(error.label, "Preview only. This action does not contact a desktop.")
    }

    /// Retained runs share the quiet fold; the overflow menu wakes a sleeping agent with a message.
    func testProjectPageFinishedFoldAndWake() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        XCUIDevice.shared.orientation = .portrait
        let app = launchApp(["--companion-preview", "--companion-preview-start-home"], attempts: 1)
        let any = app.descendants(matching: .any)
        let header = any.matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(header, in: app) && scrollTo(header, in: app))
        waitAndTap(header, until: app.buttons["project-page-options"])
        XCTAssertFalse(app.buttons["project-changes"].exists, "The project page no longer offers Changes")
        let fold = app.buttons["fold-quiet-preview-studio-clubhouse"]
        XCTAssertTrue(scrollTo(fold, in: app))
        XCTAssertTrue(fold.label.contains("sleeping") && fold.label.contains("finished"), fold.label)
        fold.tap()
        let willow = any.matching(identifier: "finished-preview-studio-clubhouse-quick-willow").firstMatch
        let aspen = any.matching(identifier: "finished-preview-studio-clubhouse-quick-aspen").firstMatch
        XCTAssertTrue(willow.waitForExistence(timeout: 5) && aspen.exists)
        XCTAssertLessThan(willow.frame.minY, aspen.frame.minY, "The newest run comes first")
        XCTAssertTrue(willow.label.contains("Tidy the onboarding copy") && willow.label.contains("m ago"), willow.label)
        XCTAssertTrue(aspen.label.contains("Exited with code 1"), aspen.label)
        XCTAssertTrue(app.buttons["project-new-agent"].isEnabled)
        let pageShot = XCTAttachment(screenshot: app.screenshot())
        pageShot.name = "Project page"
        pageShot.lifetime = .keepAlways
        add(pageShot)

        willow.swipeLeft()
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "A finished run swipes to Dismiss")
        dismiss.tap()
        XCTAssertTrue(willow.waitForNonExistence(timeout: 5), "A dismissed run leaves the list")
        XCTAssertTrue(aspen.exists)

        // An agent opens from the page and Back returns to it.
        let river = any.matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<3 where !(river.exists && river.isHittable) { app.swipeUp() }
        river.tap()
        XCTAssertTrue(any.matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5), "Back returns to the project page")
        XCTAssertFalse(app.buttons["project-changes"].exists)

        // Wake still sends one exact message; only its entry point moved into the toolbar menu.
        let wake = app.buttons["project-wake"]
        waitAndTap(app.buttons["project-page-options"], until: wake)
        XCTAssertTrue(wake.isEnabled, "Juniper is asleep, so Wake with a message is offered")
        wake.tap()
        let message = any.matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wake-agent-picker"].label.contains("Juniper") || any.matching(NSPredicate(format: "label CONTAINS 'Juniper'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["wake-send"].isEnabled, "Wake needs a message")
        // The sheet's intermittent missing autofocus is tracked in #246. Exercise
        // a real field tap here, then require every character before sending once.
        XCTAssertTrue(message.isHittable)
        message.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the wake message must open the keyboard")
        message.typeText("Draft the release notes")
        let entered = NSPredicate(format: "value == %@", "Draft the release notes")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: message)], timeout: 5), .completed,
                       "The wake message retains the exact typed text")
        XCTAssertEqual(message.value as? String, "Draft the release notes")
        let send = app.buttons["wake-send"]
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5), "A message enables Wake")
        send.tap()
        XCTAssertTrue(app.navigationBars["Juniper"].waitForExistence(timeout: 10), "Waking opens the agent's chat")
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 10),
                      "The message is sent, and a preview says it never reached a desktop")
    }

    func testOriginalArtifactsOfferFilesAndShareAndCancelWithoutReloading() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance", "--companion-preview-artifact-export"], attempts: 1)
        openRiver(app)
        let paths = ["~/.clubhouse/scratch/acceptance.pdf", "~/.clubhouse/scratch/original.png"]
        let picker = app.otherElements["Browse View (Picker)"]
        let localRoot = picker.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: On My iPhone"]
        func openLocalDestination() {
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            if !localRoot.exists {
                let browse = picker.navigationBars.buttons["Browse"]
                if browse.exists {
                    XCTAssertTrue(browse.isHittable)
                    browse.tap()
                }
                let local = picker.staticTexts["On My iPhone"]
                XCTAssertTrue(local.waitForExistence(timeout: 10), "Device-local Files must be offered; do not silently substitute cloud-only export")
                XCTAssertTrue(local.isHittable)
                local.tap()
            }
            XCTAssertTrue(localRoot.waitForExistence(timeout: 10))
        }
        for (index, path) in paths.enumerated() {
            let reference = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", path))
            XCTAssertTrue(reference.element.waitForExistence(timeout: 10))
            XCTAssertEqual(reference.count, 1)
            reference.element.tap()
            let name = (path as NSString).lastPathComponent
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
            let save = app.buttons["Save to Files"]
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            contentAcceptanceCapture(app, name: "Original artifact before explicit export \(name)")
            save.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            contentAcceptanceCapture(app, name: "Native Files export name and destination \(name)")
            openLocalDestination()
            contentAcceptanceCapture(app, name: "Native device-local Files destination \(name)")
            let browse = picker.navigationBars.buttons["Browse"]
            if browse.exists {
                XCTAssertTrue(browse.isHittable)
                browse.tap()
            }
            contentAcceptanceCapture(app, name: "Native Files navigation before cancellation \(name)")
            let cancel = app.buttons["Cancel"]
            if cancel.exists {
                XCTAssertTrue(cancel.isHittable)
                cancel.tap()
            } else {
                // The Cancel Other overlaps visible More; use the sheet gesture, not its coordinates.
                let navigationBar = picker.navigationBars
                XCTAssertEqual(navigationBar.count, 1)
                XCTAssertTrue(navigationBar.element.isHittable)
                navigationBar.element.swipeDown(velocity: .fast)
            }
            XCTAssertTrue(picker.waitForNonExistence(timeout: 10), "Cancellation must actually dismiss the native picker")
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            XCTAssertTrue(save.isHittable)
            XCTAssertFalse(app.alerts["Couldn't export this file"].exists)
            contentAcceptanceCapture(app, name: "Cancelled Files export returned to original preview \(name)")
            save.tap()
            openLocalDestination()
            let files = localRoot.collectionViews["File View"]
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            if index == 0 {
                XCTAssertTrue(localRoot.staticTexts["On My iPhone is Empty"].waitForExistence(timeout: 10))
            }
            let expectedFiles = NSPredicate { _, _ in files.cells.count == index }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expectedFiles, object: nil)], timeout: 10), .completed,
                           "Cancellation must leave no saved sample; only the earlier explicit PDF save may exist")
            let stem = (name as NSString).deletingPathExtension
            let filename = picker.textFields.element
            XCTAssertTrue(filename.exists)
            XCTAssertTrue([name, stem].contains(filename.value as? String ?? ""), "Files must retain the original suggested filename")
            let cancelledName = NSPredicate(format: "label == %@ OR label == %@", name, stem)
            XCTAssertFalse(files.descendants(matching: .any).matching(cancelledName).firstMatch.exists)
            if index > 0 {
                let priorName = NSPredicate(format: "label == %@ OR label == %@", "acceptance.pdf", "acceptance")
                XCTAssertTrue(files.descendants(matching: .any).matching(priorName).firstMatch.exists,
                              "The earlier explicitly saved PDF remains, without a cancelled PNG save")
            }
            contentAcceptanceCapture(app, name: "Explicit device-local original-file save \(name)")
            let confirm = picker.buttons["Save"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10) && confirm.isHittable)
            confirm.tap()
            XCTAssertTrue(picker.waitForNonExistence(timeout: 10))
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            XCTAssertTrue(save.isHittable)
            XCTAssertFalse(app.alerts["Couldn't export this file"].exists)
            app.buttons["Share"].tap()
            let shareClose = app.buttons["Close"]
            XCTAssertTrue(shareClose.waitForExistence(timeout: 10))
            contentAcceptanceCapture(app, name: "Native original-file Share presentation \(name)")
            shareClose.tap()
            XCTAssertTrue(shareClose.waitForNonExistence(timeout: 10))
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            XCTAssertTrue(save.isHittable)
            XCTAssertTrue(app.navigationBars[name].exists)
            if name.hasSuffix(".png") { XCTAssertTrue(app.buttons["Copy image"].exists) }
            contentAcceptanceCapture(app, name: "Cancelled native Share returned to original preview \(name)")
            let done = app.buttons["companion-preview-done"]
            XCTAssertEqual(done.label, "Done")
            XCTAssertTrue(done.isHittable && app.frame.contains(done.frame))
            done.tap()
            XCTAssertTrue(app.buttons["companion-preview-done"].waitForNonExistence(timeout: 5))
        }
        app.terminate()
    }

    /// This fixture crosses actual link discovery, Store policy and the sheet; it does not contact a desktop.
    func testScratchAndHomeTextOpenInApp() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance"], attempts: 1)
        openRiver(app)
        for path in ["~/.clubhouse/scratch/home.txt", "/tmp/clubhouse-preview/scratch.txt"] {
            let links = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", path))
            XCTAssertTrue(links.element.waitForExistence(timeout: 10), "The negotiated scratch reference must load")
            XCTAssertEqual(links.count, 1, "The negotiated scratch reference must be offered once")
            guard links.count == 1 else { return }
            let link = links.element(boundBy: 0)
            XCTAssertTrue(link.isHittable)
            contentAcceptanceCapture(app, name: "Scratch link before opening \(path)")
            link.tap()
            let text = app.staticTexts["Synthetic scratch preview\nRaw path: \(path)"]
            XCTAssertTrue(text.waitForExistence(timeout: 10), "The raw reference must reach the synthetic service unchanged")
            contentAcceptanceCapture(app, name: "Scratch text inside sheet \(path)")
            XCTAssertEqual(app.state, .runningForeground)
            let done = app.buttons.matching(identifier: "companion-preview-done")
            XCTAssertEqual(done.count, 1)
            guard done.count == 1 else { return }
            XCTAssertTrue(done.element(boundBy: 0).isHittable)
            done.element(boundBy: 0).tap()
            XCTAssertTrue(text.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["River"].exists)
        }
    }

    func testLocalLinksAndPathsResolveToFileFolderTruncatedMissingAndNotShared() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance", "--companion-preview-local-links"], attempts: 1)
        openRiver(app)
        func open(_ href: String) {
            let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", href)).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10), href)
            XCTAssertTrue(scrollTo(link, in: app, maxSwipes: 3), href)
            link.tap()
        }
        func close(_ gone: XCUIElement) {
            let done = app.buttons["companion-preview-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(gone.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["River"].exists)
        }
        func entry(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "companion-folder-entry")
                .matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }
        let preview = app.staticTexts["Synthetic local link preview"]

        open("Some%20Folder/notes.md#intro")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        contentAcceptanceCapture(app, name: "Local link file")
        close(preview)

        open("Some%20Folder/")
        let list = app.descendants(matching: .any).matching(identifier: "companion-folder-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Some Folder"].exists)
        for name in ["images", "latest.md", "notes.md", "socket"] { XCTAssertTrue(entry(name).exists, name) }
        XCTAssertTrue(entry("notes.md").label.contains("File"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "companion-folder-more").firstMatch.exists)
        contentAcceptanceCapture(app, name: "Local link folder list")
        entry("notes.md").tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "A file entry previews")
        back()
        XCTAssertTrue(entry("images").waitForExistence(timeout: 5))
        entry("images").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-folder-empty").firstMatch.waitForExistence(timeout: 10), "A folder entry drills in")
        XCTAssertTrue(app.navigationBars["images"].exists)
        back()
        XCTAssertTrue(entry("latest.md").waitForExistence(timeout: 5))
        entry("latest.md").tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "A symlink resolves on the desktop")
        back()
        close(list)

        open("Big%20Folder/")
        let more = app.descendants(matching: .any).matching(identifier: "companion-folder-more").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(entry("file-001.txt").waitForExistence(timeout: 10))
        XCTAssertTrue(scrollUntilExists(more, in: app, maxSwipes: 4))
        XCTAssertTrue(more.label.contains("More items on the desktop"))
        contentAcceptanceCapture(app, name: "Local link truncated folder")
        close(list)

        open("missing.md")
        let missing = app.descendants(matching: .any).matching(identifier: "companion-link-missing").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Not found on Studio Mac"].exists)
        XCTAssertFalse(app.buttons["Try again"].exists)
        contentAcceptanceCapture(app, name: "Local link missing")
        close(missing)

        open("/Users/river/private/keys.md")
        let notShared = app.descendants(matching: .any).matching(identifier: "companion-link-not-allowed").firstMatch
        XCTAssertTrue(notShared.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This target can't be previewed"].exists)
        XCTAssertTrue(app.staticTexts["The target may be unreadable, unsupported, or outside shared locations. Open it on your desktop to check."].exists)
        contentAcceptanceCapture(app, name: "Local link not shared")
        close(notShared)

        // Code-span paths resolve the same way as links.
        open("Some Folder/notes.md")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        contentAcceptanceCapture(app, name: "Code span file")
        close(preview)
        open("Some Folder/")
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(entry("notes.md").exists)
        contentAcceptanceCapture(app, name: "Code span folder")
        close(list)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testHomePDFSheetDismissesReopensAndStaysForegroundAfterExportedURLTap() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance"], attempts: 1)
        openRiver(app)
        let references = app.buttons.matching(identifier: "companion-content-link")
            .matching(NSPredicate(format: "label == %@", "~/.clubhouse/scratch/acceptance.pdf"))
        XCTAssertTrue(references.element.waitForExistence(timeout: 10), "The negotiated PDF reference must load")
        XCTAssertEqual(references.count, 1)
        guard references.count == 1 else { return }
        for opening in 1...2 {
            let reference = references.element(boundBy: 0)
            XCTAssertTrue(reference.isHittable)
            reference.tap()
            let title = app.navigationBars["acceptance.pdf"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            contentAcceptanceCapture(app, name: "PDF sheet opening \(opening)")
            let previews = app.descendants(matching: .any).matching(identifier: "companion-pdf-preview")
            XCTAssertEqual(previews.count, 1, "Unsupported or ambiguous native PDF export")
            guard previews.count == 1 else { return }
            let preview = previews.element(boundBy: 0)
            let frame = preview.frame
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite })
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(app.frame.contains(frame), "The native PDF view must fit the actual app viewport")
            XCTAssertGreaterThanOrEqual(frame.minY, title.frame.maxY)
            XCTAssertTrue(preview.isHittable)
            if opening == 2 {
                let links = app.links.matching(NSPredicate(format: "label CONTAINS %@", "example.invalid"))
                contentAcceptanceCapture(app, name: "Native PDF URL export before tap")
                XCTAssertEqual(links.count, 1, "Unsupported native link export; no coordinate fallback")
                guard links.count == 1 else { return }
                let link = links.element(boundBy: 0)
                let linkFrame = link.frame
                XCTAssertTrue([linkFrame.minX, linkFrame.minY, linkFrame.width, linkFrame.height].allSatisfy { $0.isFinite })
                XCTAssertGreaterThan(linkFrame.width, 0); XCTAssertGreaterThan(linkFrame.height, 0)
                XCTAssertTrue(frame.contains(linkFrame) && app.frame.contains(linkFrame))
                XCTAssertTrue(link.isHittable)
                link.tap()
                XCTAssertEqual(app.state, .runningForeground)
                XCTAssertFalse(app.wait(for: .runningBackground, timeout: 2), "No runningBackground state observed in this bounded interval")
                XCTAssertEqual(app.state, .runningForeground)
                XCTAssertTrue(preview.exists && title.exists)
                contentAcceptanceCapture(app, name: "PDF after native URL tap")
            }
            let done = app.buttons.matching(identifier: "companion-preview-done")
            XCTAssertEqual(done.count, 1)
            guard done.count == 1 else { return }
            XCTAssertTrue(done.element(boundBy: 0).isHittable)
            done.element(boundBy: 0).tap()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["River"].exists)
            contentAcceptanceCapture(app, name: "PDF sheet dismissed \(opening)")
        }
    }

    private func contentAcceptanceCapture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let raw = Array(app.debugDescription.utf8)
        let tree = XCTAttachment(string: String(decoding: raw.prefix(65_536), as: UTF8.self))
        tree.name = "\(name) public hierarchy (\(min(raw.count, 65_536))/\(raw.count) UTF8 bytes)"
        tree.lifetime = .keepAlways; add(tree)
        print("content-acceptance appFrame=\(app.frame) rawHierarchyBytes=\(raw.count) truncated=\(raw.count > 65_536)")
    }
}
