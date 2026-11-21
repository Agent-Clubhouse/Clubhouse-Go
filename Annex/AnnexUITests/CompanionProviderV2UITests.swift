import XCTest

/// Existing V2 cases isolated for bounded whole-class hosted routing.
@MainActor
final class CompanionProviderV2UITests: ReliableUITestCase {
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

    /// Capture-only supplement: one preview, no Apply or Start.
    func testProviderV2CaptureAccessibilityLargeReviewRows() {
        let app = openProviderV2Capture(largeText: true, unsupportedStart: false)
        XCTAssertTrue(captureReadableProviderRow("provider-session-unverified", in: app, containing: ["Not verified"], name: "V2 Large initial runtime uncertainty readable"))
        selectProviderV2ForCapture(app, slowNativePan: true)
        app.buttons["provider-review-change"].tap()
        // Saved then proposed: at most 16 pans across both reveals (eight each).
        // Five readable targets allow 40 pans, plus the unchanged four-pan selection cap.
        XCTAssertTrue(captureReadableProviderRow("provider-v2-saved-model", in: app, containing: ["fixture-current-model", "saved agent override"], name: "V2 Large saved override readable before proposed defaults"))
        XCTAssertTrue(captureReadableProviderRow("provider-v2-proposed-model", in: app, containing: ["Provider default", "host reported"], name: "V2 Large proposed model and source readable BEFORE Apply"))
        XCTAssertTrue(captureReadableProviderRow("provider-v2-proposed-effort", in: app, containing: ["Provider default", "host reported"], name: "V2 Large proposed effort and source readable BEFORE Apply"))
        XCTAssertTrue(captureReadableProviderRow("provider-reset-impacts", in: app, containing: ["Applying resets:", "model", "effort"], name: "V2 Large explicit reset list readable BEFORE Apply"))
        XCTAssertFalse(app.staticTexts["provider-saved"].exists)
        XCTAssertFalse(app.buttons["provider-start-new"].exists)
    }

    /// Capture-only supplement: one Apply, with Start independently unsupported.
    func testProviderV2CaptureUnsupportedStartReason() {
        let app = openProviderV2Capture(largeText: false, unsupportedStart: true)
        selectProviderV2ForCapture(app)
        tapVisibleProviderControl(app.buttons["provider-save"], in: app)
        app.buttons["provider-review-change"].tap()
        XCTAssertTrue(captureReadableProviderRow("provider-saved", in: app,
            containing: ["historical", "started no session", "Current runtime unverified"], name: "V2 revised historical Apply receipt readable with Start unsupported"))
        XCTAssertTrue(captureReadableProviderRow("provider-start-reason", in: app, containing: ["does not separately support"], name: "V2 independently unsupported Start reason readable"))
        XCTAssertTrue(app.buttons["provider-start-new"].exists)
        XCTAssertFalse(app.buttons["provider-start-new"].isEnabled)
        XCTAssertFalse(app.staticTexts["provider-v2-start-evidence"].exists)
    }

    private func openProviderV2Capture(largeText: Bool, unsupportedStart: Bool) -> XCUIApplication {
        var arguments = ["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-v2"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        if unsupportedStart { arguments += ["--companion-preview-provider-v2-no-start"] }
        let app = launchApp(arguments, attempts: 1)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        XCTAssertEqual(app.navigationBars["Provider"].buttons.firstMatch.label, "Juniper")
        XCTAssertTrue(app.buttons["provider-save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["provider-save"].isEnabled)
        return app
    }

    private func selectProviderV2ForCapture(_ app: XCUIApplication, slowNativePan: Bool = false) {
        tapVisibleProviderControl(app.buttons["provider-choice-codex-cli"], in: app, slowNativePan: slowNativePan)
        let apply = app.buttons["provider-save"], reason = app.staticTexts["provider-apply-reason"]
        XCTAssertTrue(waitFor(apply, NSPredicate(format: "enabled == true"), timeout: 5))
        // Check the actual selection path before any search/review navigation.
        XCTAssertTrue(apply.isHittable && pixelContains(app.frame, apply.frame))
        XCTAssertTrue(reason.exists && pixelContains(app.frame, reason.frame))
        XCTAssertEqual(app.navigationBars["Provider"].buttons.firstMatch.label, "Juniper")
    }

    /// One native snapshot per observation keeps all bounds from the same hierarchy revision.
    /// Reading each element attribute separately re-queried the whole AX tree on hosted iOS 26.5.
    private struct ProviderRowObservation {
        let window: CGRect
        let navigation: CGRect
        let backLabel: String?
        let form: CGRect
        let apply: CGRect
        let review: CGRect
        let row: XCUIElementSnapshot?

        var top: CGFloat { max(navigation.maxY + 12, form.minY) }
        var bottom: CGFloat { min(min(window.maxY - 34, form.maxY), min(apply.minY, review.minY) - 12) }
        func contains(_ frame: CGRect) -> Bool {
            frame.width > 0 && frame.height > 0 && frame.minY >= top && frame.maxY <= bottom
                && frame.minX >= max(window.minX, form.minX) && frame.maxX <= min(window.maxX, form.maxX)
        }
    }

    private func providerRowObservation(_ identifier: String, in app: XCUIApplication) -> ProviderRowObservation? {
        do {
            let snapshot = try app.snapshot()
            var elements: [XCUIElementSnapshot] = []
            func visit(_ node: XCUIElementSnapshot) {
                elements.append(node)
                node.children.forEach(visit)
            }
            visit(snapshot)
            func unique(_ predicate: (XCUIElementSnapshot) -> Bool, _ name: String) throws -> XCUIElementSnapshot {
                let matches = elements.filter(predicate)
                return try XCTUnwrap(matches.count == 1 ? matches.first : nil, "Exactly one native \(name) is required")
            }
            let navigation = try unique({ $0.elementType == .navigationBar && ($0.identifier == "Provider" || $0.label == "Provider") }, "Provider navigation bar")
            let form = try unique({ $0.elementType == .collectionView && $0.identifier == "provider-flow" }, "Provider Form")
            let apply = try unique({ $0.elementType == .button && $0.identifier == "provider-save" }, "Apply action")
            let review = try unique({ $0.elementType == .button && $0.identifier == "provider-review-change" }, "Review action")
            let rows = elements.filter { $0.identifier == identifier }
            guard rows.count <= 1 else { XCTFail("The native row identifier must be unique: \(identifier)"); return nil }
            func buttons(in node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
                (node.elementType == .button ? [node] : []) + node.children.flatMap { buttons(in: $0) }
            }
            return .init(window: snapshot.frame, navigation: navigation.frame,
                         backLabel: buttons(in: navigation).first?.label, form: form.frame,
                         apply: apply.frame, review: review.frame, row: rows.first)
        } catch {
            XCTFail("Cannot observe the native Provider hierarchy: \(error)")
            return nil
        }
    }

    /// Full-row visual proof and Large-only navigation inside the protected native Form.
    private func captureReadableProviderRow(_ identifier: String, in app: XCUIApplication,
                                            containing expected: [String], name: String) -> Bool {
        var previousFrame: CGRect?
        var previousDrag: CGFloat?
        var response: CGFloat = 1
        // Initial observation plus at most eight native pans, not nine gestures.
        for attempt in 0...8 {
            guard let observation = providerRowObservation(identifier, in: app) else { return false }
            let top = observation.top, bottom = observation.bottom
            let frame = observation.row?.frame
            print("PROVIDER_CAPTURE_GEOMETRY id=\(identifier) attempt=\(attempt) row=\(String(describing: frame)) band=\(top)...\(bottom)")
            if let frame {
                guard frame.width > 0 && frame.height > 0 && frame.height <= bottom - top,
                      frame.minX >= max(observation.window.minX, observation.form.minX),
                      frame.maxX <= min(observation.window.maxX, observation.form.maxX) else {
                    XCTFail("The complete text row must fit in the native readable band: \(frame), \(top)...\(bottom)"); return false
                }
                if frame.minY >= top && frame.maxY <= bottom {
                    // The fresh complete hierarchy below proves current existence as well as fit.
                    // A separate Any query can stall despite the exact row already being realized.
                    guard let current = providerRowObservation(identifier, in: app), let realized = current.row,
                          realized.identifier == identifier, expected.allSatisfy({ realized.label.contains($0) }),
                          current.contains(realized.frame), current.backLabel == "Juniper" else {
                        XCTFail("The realized row must retain its full fit, expected identity, text and Juniper context in the current hierarchy"); return false
                    }
                    captureProvider(app, name)
                    return true
                }
                if let previousFrame, let previousDrag {
                    let movement = frame.midY - previousFrame.midY
                    print("PROVIDER_CAPTURE_MOVEMENT id=\(identifier) settled=\(movement) drag=\(previousDrag)")
                    guard abs(movement) > 0.5 else { XCTFail("Native scrolling made no progress toward the readable row"); return false }
                    if movement * previousDrag > 0 { response = min(4, max(0.25, movement / previousDrag)) }
                }
            }
            guard attempt < 8 else { XCTFail("Readable row not reached within eight native pans"); return false }
            let travel = min(120, (bottom - top) / 2 - 8)
            guard travel >= 24 else { XCTFail("Protected content band cannot support a native pan"); return false }
            let dy = frame.map { min(travel, max(-travel, ((top + bottom) / 2 - $0.midY) / response)) } ?? -travel
            guard abs(dy) >= 24 else { XCTFail("Refusing a sub-pan correction before capture: \(dy)"); return false }
            let origin = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: observation.form.midX - observation.window.minX,
                                     dy: (top + bottom) / 2 - observation.window.minY))
            previousFrame = frame; previousDrag = dy
            XCTContext.runActivity(named: "Reveal readable provider row \(identifier), band \(top)...\(bottom), drag \(dy)") { _ in
                origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: dy)),
                             withVelocity: .slow, thenHoldForDuration: 0)
            }
        }
        return false
    }

    func testProviderV2ApplyAndStartStaySeparate() { checkProviderV2(largeText: false, mode: "success") }

    func testProviderV2ApplyAtAccessibilityLargeKeepsReviewReachable() { checkProviderV2(largeText: true, mode: "success") }

    func testProviderV2LostApplyStaysUnknownAfterReopeningAndEqualRead() { checkProviderV2(largeText: false, mode: "lost-apply") }

    func testProviderV2LostStartNeverRequestsAnotherStart() { checkProviderV2(largeText: false, mode: "lost-start") }

    func testProviderV2ApplyDoesNotImplyStartCapability() { checkProviderV2(largeText: false, mode: "no-start") }

    private func checkProviderV2(largeText: Bool, mode: String) {
        var arguments = ["--companion-preview", "--companion-preview-provider-options", "--companion-preview-provider-v2"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        if mode != "success" { arguments += ["--companion-preview-provider-v2-" + mode] }
        let app = launchApp(arguments, attempts: 1)
        openAgentSettings(app, sleeping: true)
        let link = app.buttons["agent-settings-provider-flow"]
        XCTAssertTrue(scrollTo(link, in: app))
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        let apply = app.buttons["provider-save"], reason = app.staticTexts["provider-apply-reason"]
        let session = app.descendants(matching: .any).matching(identifier: "provider-session-unverified").firstMatch
        if largeText { XCTAssertTrue(scrollTo(session, in: app, maxSwipes: 12)) }
        XCTAssertTrue(session.waitForExistence(timeout: 5) && session.label.contains("Not verified"))
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        captureProvider(app, largeText ? "V2 Accessibility Large first session report" : "V2 standard first session report")
        XCTAssertTrue(apply.exists && apply.isHittable && pixelContains(app.frame, apply.frame))
        XCTAssertFalse(apply.isEnabled)
        let choice = app.buttons["provider-choice-codex-cli"]
        tapVisibleProviderControl(choice, in: app, slowNativePan: largeText)
        XCTAssertTrue(waitFor(apply, NSPredicate(format: "enabled == true"), timeout: 5))
        // Actual selection path: no identifier-search scrolling to make Apply visible.
        XCTAssertTrue(apply.isHittable && pixelContains(app.frame, apply.frame))
        XCTAssertTrue(reason.exists && pixelContains(app.frame, reason.frame))
        captureProvider(app, "V2 actual selection leaves Apply and reason visible")
        app.buttons["provider-review-change"].tap()
        let saved = app.descendants(matching: .any).matching(identifier: "provider-v2-saved-model").firstMatch
        let proposed = app.descendants(matching: .any).matching(identifier: "provider-v2-proposed-model").firstMatch
        if largeText {
            XCTAssertTrue(captureReadableProviderRow("provider-v2-saved-model", in: app,
                containing: ["fixture-current-model", "saved agent override"], name: "V2 Large saved model fully readable before Apply"))
        } else { XCTAssertTrue(scrollTo(saved, in: app, up: false, maxSwipes: 12)) }
        XCTAssertTrue(saved.label.contains("fixture-current-model") && saved.label.contains("saved agent override"))
        captureProvider(app, "V2 host-reported saved model before Apply")
        if largeText {
            XCTAssertTrue(captureReadableProviderRow("provider-v2-proposed-model", in: app,
                containing: ["Provider default", "host reported"], name: "V2 Large proposed model fully readable before Apply"))
        } else { XCTAssertTrue(scrollTo(proposed, in: app, maxSwipes: 12)) }
        XCTAssertTrue(proposed.label.contains("Provider default"))
        let resets = app.staticTexts["provider-reset-impacts"]
        if largeText {
            XCTAssertTrue(captureReadableProviderRow("provider-reset-impacts", in: app,
                containing: ["Applying resets:", "model", "effort"], name: "V2 Large reset list fully readable before Apply"))
        } else { XCTAssertTrue(scrollTo(resets, in: app, maxSwipes: 12)) }
        XCTAssertTrue(resets.label.contains("model") && resets.label.contains("effort"))
        captureProvider(app, "V2 proposed provider defaults and reset impacts before Apply")
        XCTAssertFalse(app.buttons["provider-start-new"].exists)
        tapVisibleProviderControl(apply, in: app, slowNativePan: largeText)
        if mode == "lost-apply" {
            checkV2Unknown(app, link: link, choice: choice)
            XCTAssertFalse(app.buttons["provider-start-new"].exists)
            return
        }
        app.buttons["provider-review-change"].tap()
        let receipt = app.staticTexts["provider-saved"]
        if largeText {
            XCTAssertTrue(captureReadableProviderRow("provider-saved", in: app,
                containing: ["historical", "started no session"], name: "V2 Large historical Apply receipt fully readable before Start"))
        } else { XCTAssertTrue(scrollTo(receipt, in: app, maxSwipes: 12)) }
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(receipt.label.contains("historical") && receipt.label.contains("started no session"))
        captureProvider(app, "V2 historical Apply receipt before Start")
        let start = app.buttons["provider-start-new"]
        if largeText {
            XCTAssertTrue(captureReadableProviderRow("provider-start-new", in: app,
                containing: ["Start new session"], name: "V2 Large Start control fully readable before separate confirmation"))
        } else { XCTAssertTrue(scrollTo(start, in: app, maxSwipes: 12)) }
        if mode == "no-start" {
            XCTAssertFalse(start.isEnabled)
            let explanation = app.staticTexts["provider-start-reason"]
            XCTAssertTrue(scrollTo(explanation, in: app, maxSwipes: 8))
            XCTAssertTrue(explanation.label.contains("does not separately support"))
            captureProvider(app, "V2 Apply receipt with Start explicitly unsupported")
            return
        }
        XCTAssertTrue(start.isEnabled)
        tapVisibleProviderControl(start, in: app, slowNativePan: largeText)
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Start new session", "provider-start-new")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        captureProvider(app, "V2 explicit Start confirmation before cancellation")
        if app.buttons["Cancel"].exists {
            XCTAssertTrue(app.buttons["Cancel"].isHittable); app.buttons["Cancel"].tap()
        } else {
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertEqual(dismiss.label, "dismiss popup"); XCTAssertTrue(dismiss.isHittable); dismiss.tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Provider"].exists)
        XCTAssertEqual(app.navigationBars["Provider"].buttons.firstMatch.label, "Juniper")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "provider-v2-start-evidence").firstMatch.exists)
        captureProvider(app, "V2 Cancel returns to same Juniper without a Start receipt")
        tapVisibleProviderControl(start, in: app, slowNativePan: largeText)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        if mode == "lost-start" {
            checkV2Unknown(app, link: link, choice: choice)
            XCTAssertTrue(scrollTo(start, in: app, maxSwipes: 12)); XCTAssertFalse(start.isEnabled)
        } else {
            let creation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This is not a provider handshake")).firstMatch
            if largeText {
                XCTAssertTrue(captureReadableProviderRow("provider-v2-start-creation", in: app,
                    containing: ["host observed PTY creation", "This is not a provider handshake"], name: "V2 Large historical creation fully readable after confirmed Start"))
            } else { XCTAssertTrue(scrollTo(creation, in: app, maxSwipes: 12)) }
            XCTAssertTrue(creation.label.contains("host observed PTY creation"))
            captureProvider(app, "V2 held historical creation is not a current runtime claim")
        }
    }

    private func checkV2Unknown(_ app: XCUIApplication, link: XCUIElement, choice: XCUIElement) {
        let review = app.buttons["provider-review-held-result"]
        XCTAssertTrue(scrollTo(review, in: app, maxSwipes: 12))
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["provider-save"].isEnabled)
        captureProvider(app, "V2 unresolved state and held review reached by native scrolling")
        app.navigationBars["Provider"].buttons.firstMatch.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        waitAndTap(link, until: app.navigationBars["Provider"], attempts: 1)
        XCTAssertTrue(scrollTo(choice, in: app, maxSwipes: 12)); XCTAssertFalse(choice.isEnabled)
        tapVisibleProviderControl(review, in: app)
        let error = app.staticTexts["provider-flow-error"]
        XCTAssertTrue(scrollTo(error, in: app, up: false, maxSwipes: 12))
        XCTAssertTrue(error.label.contains("will not send it again"))
        let refresh = app.buttons["provider-refresh"]
        tapVisibleProviderControl(refresh, in: app)
        let saved = app.descendants(matching: .any).matching(identifier: "provider-v2-saved-provider").firstMatch
        app.buttons["provider-review-change"].tap()
        XCTAssertTrue(scrollTo(saved, in: app, up: false, maxSwipes: 12)); XCTAssertTrue(saved.label.contains("Codex"))
        XCTAssertFalse(app.buttons["provider-save"].isEnabled)
        XCTAssertTrue(scrollTo(choice, in: app, maxSwipes: 12)); XCTAssertFalse(choice.isEnabled)
        captureProvider(app, "V2 reopened unknown action stays locked after equal fresh state")
    }

    private func captureProvider(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// A partially obscured Form row can be reported hittable and tap Back instead.
    /// Reveal the entire control below this sheet's navigation bar, then tap once at its checked center.
    private func tapVisibleProviderControl(_ control: XCUIElement, in app: XCUIApplication, up: Bool = true,
                                           slowNativePan: Bool = false) {
        let navigation = app.navigationBars["Provider"]
        XCTAssertTrue(navigation.exists)
        if slowNativePan && control.exists {
            guard let observation = providerRowObservation(control.identifier, in: app) else { return }
            // A full-fit row already observed by the Large reading path needs no second search.
            // The unchanged checked-tap guards below still remeasure its actual control frame.
            if observation.row.map({ observation.contains($0.frame) }) != true {
                XCTAssertTrue(scrollTo(control, in: app, up: up, maxSwipes: 8))
            }
        } else {
            XCTAssertTrue(scrollTo(control, in: app, up: up, maxSwipes: 8))
        }
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
                if slowNativePan {
                    print("PROVIDER_CONTROL_VELOCITY id=\(control.identifier) velocity=slow initialPress=0.05 endHold=0")
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                                withVelocity: .slow, thenHoldForDuration: 0)
                } else {
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
                }
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
        if slowNativePan {
            guard control.exists else { XCTFail("The exact Large control must still exist before its checked tap"); return }
            guard let observation = providerRowObservation(control.identifier, in: app),
                  let current = observation.row else {
                XCTFail("The exact Large control must still resolve in the current hierarchy"); return
            }
            let stickyAction = ["provider-save", "provider-review-change"].contains(control.identifier)
            let top = stickyAction ? observation.navigation.maxY + 12 : observation.top
            let bottom = stickyAction ? observation.window.maxY - 34 : observation.bottom
            guard current.frame == frame, current.identifier == control.identifier, current.isEnabled,
                  observation.backLabel == "Juniper",
                  frame.minX >= max(observation.window.minX, observation.form.minX),
                  frame.maxX <= min(observation.window.maxX, observation.form.maxX),
                  frame.minY >= top, frame.maxY <= bottom,
                  control.exists && control.isHittable else {
                XCTFail("The exact Large control must remain actionable and fully contained before its checked tap"); return
            }
        }
        XCTContext.runActivity(named: "Tap visible provider control at \(point), frame \(frame), navigation \(navigation.frame)") { _ in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Visible \(control.identifier) before one checked tap"; shot.lifetime = .keepAlways; add(shot)
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
