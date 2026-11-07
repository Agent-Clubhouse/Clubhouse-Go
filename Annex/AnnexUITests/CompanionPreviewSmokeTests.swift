import XCTest

/// Exercises the new SwiftUI navigation on a real simulator without enrolling
/// any desktop, storing credentials, or pretending preview commands succeeded.
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
        if sleeping { expandFold(any.matching(identifier: "fold-sleeping-preview-studio-clubhouse").firstMatch, revealing: row, in: app) }
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
        let provider = app.buttons["agent-settings-orchestrator"]
        XCTAssertTrue(scrollUntilExists(provider, in: app))
        XCTAssertFalse(provider.isEnabled)
        XCTAssertTrue(scrollTo(app.buttons["agent-sleep"], in: app, up: false))
        waitAndTap(app.buttons["agent-sleep"], until: confirmation)
        confirmation.tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["agent-sleep-pending"].exists)
        let refusal = XCTAttachment(screenshot: app.screenshot())
        refusal.name = "Sleep refused, provider remains locked"; refusal.lifetime = .keepAlways; add(refusal)
        XCTAssertTrue(scrollUntilExists(provider, in: app))
        XCTAssertFalse(provider.isEnabled, "A refused stop cannot unlock the provider")
    }

    func testAgentSettingsKeepsMcpOffSwitchesVisibleAndDisabled() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-mcp-off"])
        openAgentSettings(app)
        for id in ["agent-settings-orchestrate", "agent-settings-orchestrate-cross-project", "agent-settings-orchestrate-dispatcher"] {
            let toggle = app.switches[id]
            scrollTo(toggle, in: app)
            XCTAssertTrue(toggle.exists, id)
            XCTAssertFalse(toggle.isEnabled, id)
        }
        // The last switch can be visible while the lazy Form footer is still below the viewport.
        let footer = app.staticTexts["These settings need Clubhouse MCP. Turn on Clubhouse MCP on the desktop."]
        XCTAssertTrue(scrollTo(footer, in: app), "The MCP-off explanation must be reachable and readable")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "MCP off switches and explanation"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(footer.exists)
    }

    func testGuidedProviderSelectionRequiresSaveAndDoesNotOfferResume() {
        checkGuidedProviderFlow(largeText: false)
    }

    func testGuidedProviderFlowAtLargeText() {
        checkGuidedProviderFlow(largeText: true)
    }

    private func checkGuidedProviderFlow(largeText: Bool) {
        var arguments = ["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-control"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        let app = launchApp(arguments)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        let current = app.buttons["provider-choice-claude-code"]
        waitAndTap(link, until: current)
        XCTAssertFalse(app.buttons["provider-save"].exists, "Opening the flow must not preview or save a provider")
        let unavailable = app.buttons["provider-choice-codex"]
        XCTAssertTrue(scrollUntilExists(unavailable, in: app))
        XCTAssertFalse(unavailable.isEnabled)
        tapVisibleProviderControl(current, in: app, up: false)
        XCTAssertTrue(app.navigationBars["Provider"].exists)
        XCTAssertTrue(waitFor(current, NSPredicate(format: "selected == true"), timeout: 5))
        let save = app.buttons["provider-save"]
        XCTAssertTrue(scrollUntilExists(save, in: app, maxSwipes: 8))
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.buttons["Resume"].exists, "Same-provider resume hint must not offer Resume")
        XCTAssertFalse(app.buttons["provider-start-new"].exists)
        let alternative = app.buttons["provider-choice-codex-cli"]
        tapVisibleProviderControl(alternative, in: app, up: false)
        XCTAssertTrue(app.navigationBars["Provider"].exists, "Choosing a provider must stay on the Provider page")
        XCTAssertTrue(waitFor(alternative, NSPredicate(format: "selected == true"), timeout: 5), "Codex CLI must be selected before looking for Save")
        XCTAssertTrue(scrollTo(save, in: app, maxSwipes: 8))
        XCTAssertTrue(save.isEnabled)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = largeText ? "Guided provider preview at large text" : "Guided provider preview"; preview.lifetime = .keepAlways; add(preview)
        tapVisibleProviderControl(save, in: app)
        let refusal = app.staticTexts["provider-flow-error"]
        XCTAssertTrue(scrollUntilExists(refusal, in: app, up: false, maxSwipes: 8))
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
        for _ in 0..<4 {
            let top = navigation.frame.maxY + 12
            let bottom = app.frame.maxY - 34
            let frame = control.frame
            if frame.minY >= top && frame.maxY <= bottom { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dy: CGFloat = frame.minY < top ? 120 : -120
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
        }
        let frame = control.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(control.exists && control.isHittable)
        XCTAssertGreaterThanOrEqual(frame.minY, navigation.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, app.frame.maxY - 34)
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

    func testAgentSettingsConfirmsCliChangeAndCancelKeepsTheOldSelection() {
        let app = launchApp(["--companion-preview", "--companion-preview-provider-options"])
        openAgentSettings(app, sleeping: true)
        let picker = app.buttons["agent-settings-orchestrator"]
        let codex = app.buttons["Codex CLI"]
        waitAndTap(picker, until: codex)
        let unavailable = app.buttons["Codex (Not installed on this desktop)"]
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(unavailable.isEnabled, "An unavailable provider cannot be selected")
        let confirm = app.buttons["Change CLI"]
        waitAndTap(codex, until: confirm)
        XCTAssertTrue(app.staticTexts["Juniper starts a new session on Codex CLI the next time it wakes. Its current conversation can't move to another CLI."].exists)
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            waitAndTap(cancel, untilGone: confirm)
        } else {
            // iOS 26 can present this as a popover, with cancellation by tapping outside it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(picker.label.contains("Claude Code"), picker.label)
        XCTAssertFalse(app.staticTexts["agent-settings-error"].exists, "Cancel sends nothing")
        waitAndTap(picker, until: codex)
        waitAndTap(codex, until: confirm)
        let error = app.staticTexts["agent-settings-error"]
        waitAndTap(confirm, until: error)
        XCTAssertTrue(error.label.contains("Preview only"), "Confirm attempts the update, which preview refuses")
        XCTAssertTrue(picker.label.contains("Claude Code"), "A refused update keeps the desktop's value")
        let orchestrate = app.switches["agent-settings-orchestrate"]
        scrollTo(orchestrate, in: app)
        XCTAssertFalse(app.switches["agent-settings-orchestrate-dispatcher"].exists, "Dispatcher off hides its connection switch")
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
            ("companion-sender-avatar-relay-1-0", "Dispatcher avatar"),
            ("companion-sender-avatar-relay-1-1", "Reviewer avatar")
        ] {
            let avatar = any.matching(identifier: id).firstMatch
            XCTAssertTrue(scrollUntilExists(avatar, in: app, up: false, maxSwipes: 8), id)
            XCTAssertTrue(bringTranscriptRowIntoView(avatar, in: app), "The compact sender face must be visible")
            XCTAssertEqual(avatar.label, label)
            if id == "companion-sender-avatar-sender-preview-3" {
                let quickFaces = XCTAttachment(screenshot: app.screenshot())
                quickFaces.name = "Collapsed known and quick sender faces"
                quickFaces.lifetime = .keepAlways
                add(quickFaces)
            }
        }
        XCTAssertFalse(any.matching(identifier: "companion-routed-sender-preview-0").firstMatch.exists, "Avatars remain accessible while routed detail stays collapsed")
        XCTAssertEqual(app.buttons["companion-activity-routed:relay-1:0"].value as? String, "Collapsed")
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
        func assertStacked(_ state: String, editing: Bool) -> Bool {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Accessibility stacked composer before geometry: \(state)"
            shot.lifetime = .keepAlways; add(shot)
            let navigations = app.navigationBars
            let keyboards = app.keyboards
            let inputs = app.otherElements.matching(identifier: "inputView")
            let assistants = app.otherElements.matching(identifier: "SystemInputAssistantView")
            let navCount = navigations.count, keyboardCount = keyboards.count
            let inputCount = inputs.count, assistantCount = assistants.count
            XCTContext.runActivity(named: "Stacked composer \(state) counts nav=\(navCount) keyboard=\(keyboardCount) input=\(inputCount) assistant=\(assistantCount)") { _ in }
            XCTAssertEqual(navCount, 1)
            guard navCount == 1 else { return false }
            if editing {
                XCTAssertEqual(keyboardCount, 1); XCTAssertEqual(inputCount, 1)
                XCTAssertLessThanOrEqual(assistantCount, 1)
                guard keyboardCount == 1, inputCount == 1, assistantCount <= 1 else { return false }
            } else {
                XCTAssertEqual(keyboardCount, 0, "The initial placeholder is inspected before focus")
                guard keyboardCount == 0 else { return false }
            }
            let appFrame = app.frame, navFrame = navigations.element(boundBy: 0).frame
            let editorFrame = composer.frame, sendFrame = send.frame
            var inputFrames: [CGRect] = []
            if editing {
                inputFrames = [keyboards.element(boundBy: 0).frame, inputs.element(boundBy: 0).frame]
                if assistantCount == 1 { inputFrames.append(assistants.element(boundBy: 0).frame) }
            }
            let frames = [appFrame, navFrame, editorFrame, sendFrame] + inputFrames
            let finite = frames.allSatisfy { frame in
                !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                    && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
            }
            XCTContext.runActivity(named: "Stacked composer \(state) app=\(appFrame) nav=\(navFrame) editor=\(editorFrame) Send=\(sendFrame) fullInput=\(inputFrames) finite=\(finite)") { _ in }
            XCTAssertTrue(finite)
            guard finite else { return false }
            let visibleInputs = inputFrames.map { $0.intersection(appFrame) }
            XCTAssertTrue(visibleInputs.allSatisfy { !$0.isNull && !$0.isEmpty })
            guard visibleInputs.allSatisfy({ !$0.isNull && !$0.isEmpty }) else { return false }
            let bottom = visibleInputs.map(\.minY).min() ?? appFrame.maxY
            let viewport = CGRect(x: appFrame.minX, y: navFrame.maxY, width: appFrame.width,
                                  height: max(0, bottom - navFrame.maxY))
            XCTAssertTrue(appFrame.contains(navFrame))
            XCTAssertTrue(viewport.contains(editorFrame), "The full readable editor stays above input surfaces")
            XCTAssertTrue(viewport.contains(sendFrame), "The full action stays above input surfaces")
            XCTAssertGreaterThanOrEqual(editorFrame.width, appFrame.width * 0.7)
            XCTAssertLessThanOrEqual(editorFrame.maxY, sendFrame.minY, "Accessibility editor is above its action row")
            XCTAssertGreaterThanOrEqual(sendFrame.width, 44)
            XCTAssertGreaterThanOrEqual(sendFrame.height, 44)
            XCTAssertTrue(composer.isHittable)
            if editing { XCTAssertTrue(send.isEnabled && send.isHittable) }
            return true
        }
        guard assertStacked("placeholder", editing: false) else { return }
        composer.tap()
        composer.typeText("Hey")
        XCTAssertEqual(composer.value as? String, "Hey")
        guard assertStacked("one line", editing: true) else { return }
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
                let latest = app.buttons["Latest"]
                if latest.exists { bottom = min(bottom, latest.frame.minY - 12) }
                return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            }
            var viewport = usableViewport()
            XCTAssertGreaterThan(viewport.height, 100)
            // Stop following the live bottom with a real reading gesture; updates keep streaming.
            // Waiting for the total link count to settle can prevent every tap as new runs arrive.
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.3))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: viewport.height * 0.4)))
            XCTAssertTrue(app.buttons["Latest"].waitForExistence(timeout: 5), "Read above the live bottom before resolving the log")
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
    /// the header shows what the agent waits on and its context fill.
    func testExploredFoldAndApprovalCardMatchDesktop() {
        let app = launchApp(["--companion-preview"])
        openRiver(app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.placeholderValue, "Message River… / for commands", "The placeholder names the agent and offers / commands, like the desktop")

        // Header: what River waits on, and how full its context is.
        let activity = app.staticTexts.matching(identifier: "companion-chat-activity").firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertEqual(activity.label, "Run xcodebuild", "The activity line names the oldest waiting request")
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(context.exists)
        XCTAssertEqual(context.label, "Context and plan limits")
        XCTAssertEqual(context.value as? String, "Latest reported context: 42% full")

        // The approval card: the request's title, its place in the queue, and the desktop-only option.
        let position = app.staticTexts.matching(identifier: "companion-approval-position").firstMatch
        if !position.waitForExistence(timeout: 5) {
            scrollUntilExists(position, in: app, maxSwipes: 3, wait: 0.5)
        }
        XCTAssertTrue(position.exists, "Two waiting approvals must show their count")
        XCTAssertTrue(app.staticTexts["Run xcodebuild"].exists, "The card uses the request's title")
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

        // The explored fold sits above the replies: scroll up to it.
        let fold = app.buttons.matching(identifier: "companion-activity-tool:tool-1").firstMatch
        scrollTo(fold, in: app, up: false, maxSwipes: 8)
        XCTAssertTrue(fold.isHittable, "Read-only lookups must fold into one row")
        XCTAssertTrue(fold.label.contains("4 tool calls"), "The fold counts like the desktop: \(fold.label)")
        XCTAssertFalse(any.matching(NSPredicate(format: "label BEGINSWITH 'Ran '")).firstMatch.exists, "The old \"Ran N tools\" fold is gone")
        XCTAssertFalse(app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "/Users/river/clubhouse/.build/test.log")).firstMatch.exists,
                       "Collapsed tool content and links are not built")

        // Each lookup's link opens from inside the fold, and its preview closes.
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "Sources/Companion/Conversation.swift")).firstMatch
        waitAndTap(fold, until: link, timeout: 5, "An expanded fold offers each lookup's links")
        let foldShot = XCTAttachment(screenshot: app.screenshot())
        foldShot.name = "Explored fold expanded"
        foldShot.lifetime = .keepAlways
        add(foldShot)
        // The bookmark keeps the header in place as it expands. Scroll from a safe transcript coordinate;
        // a short drag on the header itself can become a second tap and close the group.
        XCTAssertTrue(bringTranscriptRowIntoView(link, in: app))
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
        XCTAssertTrue(cedar.label.contains("Free Agent Mode"), "A Free Agent Mode agent must say so on its row")

        let sleeping = element("fold-sleeping-preview-studio-clubhouse")
        reveal(sleeping)
        XCTAssertTrue(sleeping.label.contains("1 sleeping"))
        XCTAssertFalse(element("agent-preview-studio-juniper").exists, "Sleeping agents start folded")
        XCTAssertTrue(element("fold-finished-preview-studio-clubhouse").label.contains("3 finished quick agents"))
        tapToExpand(sleeping)
        XCTAssertTrue(element("agent-preview-studio-juniper").waitForExistence(timeout: 5), "Opening the fold shows the sleeping agent")

        let idle = element("idle-projects-fold")
        reveal(idle)
        XCTAssertTrue(idle.label.contains("1 idle project"))
        XCTAssertFalse(element("project-preview-studio-prototype").exists, "Idle projects start folded")
        tapToExpand(idle)
        XCTAssertTrue(element("project-preview-studio-prototype").waitForExistence(timeout: 5), "Opening the idle section shows the project")

        scrollToTop()
        let menu = element("project-menu-preview-studio-website")
        reveal(menu)
        let pin = app.buttons["Pin project"]
        waitAndTap(menu, until: pin, timeout: 5)
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
            let fold = app.descendants(matching: .any).matching(identifier: "fold-sleeping-preview-studio-clubhouse").firstMatch
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

    /// Needs you says why in the desktop's words, and shows how long an approval has.
    func testNeedsYouUsesTheDesktopWords() {
        let app = launchApp(["--companion-preview"])
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        waitAndTap(tab, until: app.staticTexts["Needs permission to use Bash"], timeout: 10)
        XCTAssertTrue(app.staticTexts["Run xcodebuild"].exists, "The request's title goes under the reason")
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
        XCTAssertTrue(access.label.contains("Auto-accept edits"), "The live permission level")
        let freeAgent = element("agent-details-free-agent-mode")
        scrollDetailsRow(freeAgent, in: sheet, app: app)
        XCTAssertTrue(freeAgent.label.contains("Off"))
        let autoSleep = element("agent-details-auto-sleep")
        scrollDetailsRow(autoSleep, in: sheet, app: app)
        XCTAssertTrue(autoSleep.label.contains("Sleeps after 30 min"))
        let mcp = element("agent-details-mcp-summary")
        scrollDetailsRow(mcp, in: sheet, app: app)
        XCTAssertEqual(mcp.label, "2 connected · 1 needs sign-in · 1 configured", "The MCP card's summary")
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
        let sleeping = element("fold-sleeping-preview-studio-clubhouse")
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
    /// before raising to Full access, and "Always allow" as a confirmed secondary action. Preview refuses every change.
    func testChatControlsMenusAndPersistentApproval() {
        let app = launchApp(["--companion-preview"], attempts: 1)
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

        // Always allow: a secondary action, confirmed first.
        let always = app.buttons["companion-approval-option-allow-always"]
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
        XCTAssertTrue(previewError.waitForExistence(timeout: 5), "Preview must never claim the approval was sent")
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

    /// The project page (#158): a project header on Home opens it. Finished quick agents can be dismissed, the
    /// Changes list opens a native diff that scrolls sideways, agents open and come back, and a sleeping agent wakes
    /// with a message.
    func testProjectPageFinishedChangesAndWake() {
        continueAfterFailure = false
        // Swipes, sheets and element queries are slow round trips on CI runners.
        executionTimeAllowance = 300
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let any = app.descendants(matching: .any)
        let header = any.matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        for _ in 0..<4 where !(header.waitForExistence(timeout: 2) && header.isHittable) { app.swipeUp() }
        XCTAssertTrue(header.isHittable, "A project header must open its page")
        // A tap while the list is still settling from the swipes only stops it, so tap again if nothing opened.
        let finishedHeader = app.staticTexts["Finished, waiting on you"]
        for _ in 0..<3 where !finishedHeader.exists {
            header.tap()
            _ = finishedHeader.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(finishedHeader.waitForExistence(timeout: 10))
        let willow = any.matching(identifier: "finished-quick-willow").firstMatch
        let aspen = any.matching(identifier: "finished-quick-aspen").firstMatch
        XCTAssertTrue(willow.waitForExistence(timeout: 5) && aspen.exists)
        XCTAssertLessThan(willow.frame.minY, aspen.frame.minY, "The newest run comes first")
        XCTAssertTrue(willow.label.contains("Tidy the onboarding copy") && willow.label.contains("m ago"), willow.label)
        XCTAssertTrue(aspen.label.contains("Exited with code 1"), aspen.label)
        XCTAssertTrue(app.buttons["project-new-agent"].isEnabled)
        XCTAssertTrue(app.buttons["project-wake"].isEnabled, "Juniper is asleep, so Wake with a message is offered")
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
        XCTAssertTrue(app.buttons["project-changes"].waitForExistence(timeout: 5), "Back returns to the project page")

        // Changes: each file with its status, and a tap opens its diff.
        let changes = app.buttons["project-changes"]
        for _ in 0..<3 where !changes.isHittable { app.swipeUp() }
        changes.tap()
        let modified = any.matching(identifier: "changed-file-Sources/Companion/Conversation.swift").firstMatch
        XCTAssertTrue(modified.waitForExistence(timeout: 10))
        XCTAssertTrue(modified.label.hasPrefix("Modified, Conversation.swift"), modified.label)
        XCTAssertTrue(any.matching(identifier: "changed-file-Sources/Companion/ProjectPage.swift").firstMatch.label.hasPrefix("Added"))
        XCTAssertTrue(any.matching(identifier: "changed-file-Docs/Old notes.md").firstMatch.label.hasPrefix("Deleted"))
        XCTAssertTrue(any.matching(identifier: "changed-file-Sources/Companion/Reconnect.swift").firstMatch.label.contains("Renamed, Reconnect.swift, from Sources/Companion/Retry.swift"))
        let changesShot = XCTAttachment(screenshot: app.screenshot())
        changesShot.name = "Project changes"
        changesShot.lifetime = .keepAlways
        add(changesShot)
        modified.tap()

        let summary = any.matching(identifier: "diff-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("+2") && summary.label.contains("−1"), summary.label)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Added, line 3: ' AND label CONTAINS 'let target: ConversationTarget'")).firstMatch.exists)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Removed, line 7: '")).firstMatch.exists)
        let long = any.matching(NSPredicate(format: "label CONTAINS 'edited to explain why'")).firstMatch
        XCTAssertTrue(long.exists)
        let before = long.frame.minX
        let diffShot = XCTAttachment(screenshot: app.screenshot())
        diffShot.name = "File diff"
        diffShot.lifetime = .keepAlways
        add(diffShot)
        any.matching(identifier: "diff-lines").firstMatch.swipeLeft()
        XCTAssertLessThan(long.frame.minX, before - 20, "Long lines scroll sideways rather than wrapping")

        // Wake with a message: Juniper's chat opens with the message, which a preview never delivers.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(modified.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        // The page scrolled to reach Changes, which can leave Wake under the navigation bar: there it still reports
        // hittable, but a tap lands on the bar. Scroll until it is clear of the bar.
        let wake = app.buttons["project-wake"]
        let navigationBar = app.navigationBars.firstMatch
        for _ in 0..<4 where !(wake.exists && wake.isHittable && wake.frame.minY >= navigationBar.frame.maxY) { app.swipeDown() }
        XCTAssertGreaterThanOrEqual(wake.frame.minY, navigationBar.frame.maxY, "Wake with a message is below the navigation bar")
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
}
