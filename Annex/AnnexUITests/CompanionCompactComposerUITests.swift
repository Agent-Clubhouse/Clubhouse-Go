import XCTest

@MainActor final class CompanionCompactComposerUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testIdleControlsStayCollapsedBeforeAndAfterTyping() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window"], attempts: 1)
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        assertRow(app, working: false, state: "idle empty unfocused")
        let controls = app.buttons["companion-level-menu"]
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"], attempts: 1)
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        XCTAssertTrue(app.buttons["companion-effort-menu"].exists)
        // A menu can cover the editor: dismiss outside the whole native menu before one focus action.
        guard dismissChatControls(app) else { return }
        composer.tap()
        guard composer.debugDescription.contains("Keyboard Focused"), app.keyboards.count == 1 else {
            XCTFail("The single editor tap must establish actual keyboard focus before typing")
            return
        }
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
                            + (largestText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []), attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer, attempts: 1)
        XCTAssertFalse(app.buttons["companion-send"].isEnabled, "An empty draft cannot steer")
        assertRow(app, working: true, state: "working empty unfocused", stacked: largestText)
        if largestText {
            reviewApprovalWithoutAnswering(app, editing: false)
        } else {
            XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Approval stays pinned")
        }
        waitAndTap(app.buttons["companion-attach"], until: element(app, "companion-attachment-thumbnail"), attempts: 1)
        XCTAssertTrue(app.buttons["companion-send"].isEnabled, "An image-only draft can steer")
        assertRow(app, working: true, state: "working image-only unfocused", stacked: largestText)
        composer.tap()
        let direction = largestText ? "Keep this direction\nAnd this detail" : "Keep this direction"
        composer.typeText(direction)
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertTrue(app.buttons["companion-send"].isEnabled)
        XCTAssertTrue(app.buttons["companion-dismiss-keyboard"].exists)
        assertRow(app, working: true, state: "working typed focused", stacked: largestText, ordinaryAssistiveEditing: !largestText)
        assertEnabledEditingRow(app, working: true)
        if largestText {
            reviewApprovalWithoutAnswering(app, editing: true)
            assertEnabledEditingRow(app, working: true)
        }
        XCTAssertFalse(app.staticTexts["Your direction will be sent to the running agent."].exists)
        let interrupt = app.buttons["companion-interrupt"]
        waitAndTap(interrupt, until: app.buttons["Interrupt turn"], attempts: 1)
        XCTAssertTrue(app.staticTexts["Interrupt this turn?"].exists)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists,
                       "Preview errors should not appear while confirmation is open")
        let imageCount = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count
        capture(app, "Interrupt confirmation before native cancellation")
        guard cancelInterruptConfirmation(app) else { return }
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count, imageCount)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
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

    private func capture(_ app: XCUIApplication, _ state: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact composer \(state)"; shot.lifetime = .keepAlways; add(shot)
    }

    private func finiteRect(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite && frame.width > 0 && frame.height > 0
    }

    /// Keys alone omit the predictive/accessory row. All exported visible input surfaces constrain the bottom.
    private func unobscuredViewport(_ app: XCUIApplication, requiresKeyboard: Bool = false,
                                    approvalReview: Bool = false) -> CGRect? {
        let mainWindow = app.windows.firstMatch.frame
        let appFrame = app.frame
        let window = mainWindow.intersection(appFrame)
        // Only approval review selects its own presentation bar. Conversation callers stay globally unique.
        let bars = approvalReview
            ? app.navigationBars.matching(identifier: "Review approval")
                .containing(.button, identifier: "companion-approval-review-close")
            : app.navigationBars
        let navigationCount = bars.count, globalNavigationCount = app.navigationBars.count
        let tabCount = app.tabBars.count, keyboardCount = app.keyboards.count
        let context = "approvalReview=\(approvalReview), main=\(mainWindow), app=\(appFrame), window=\(window), navigation=\(navigationCount)/global\(globalNavigationCount), tabs=\(tabCount), keyboards=\(keyboardCount), requiresKeyboard=\(requiresKeyboard)"
        XCTContext.runActivity(named: "Compact viewport inputs — \(context)") { _ in }
        guard finiteRect(mainWindow) else { XCTFail("Main window must be finite: \(context)"); return nil }
        guard finiteRect(appFrame) else { XCTFail("Application frame must be finite: \(context)"); return nil }
        guard finiteRect(window) else { XCTFail("Main window intersection must be finite: \(context)"); return nil }
        guard navigationCount == 1 else { XCTFail("Exactly one applicable navigation bar is required: \(context)"); return nil }
        let navigation = bars.element(boundBy: 0)
        let navigationExists = navigation.exists
        guard navigationExists else { XCTFail("Selected navigation bar must exist: \(context)"); return nil }
        let navigationFrame = navigation.frame
        XCTContext.runActivity(named: "Compact viewport navigation — exists=\(navigationExists), frame=\(navigationFrame), \(context)") { _ in }
        guard finiteRect(navigationFrame) else { XCTFail("Navigation frame must be finite: \(navigationFrame), \(context)"); return nil }
        guard window.intersects(navigationFrame) else { XCTFail("Navigation must intersect the window: \(navigationFrame), \(context)"); return nil }
        guard tabCount <= 1 else { XCTFail("Tab bar must be unambiguous: \(context)"); return nil }
        guard keyboardCount <= 1 else { XCTFail("Keyboard must be unambiguous: \(context)"); return nil }
        guard !requiresKeyboard || keyboardCount == 1 else { XCTFail("Editing requires one keyboard: \(context)"); return nil }
        var bottom = window.maxY
        if app.tabBars.firstMatch.exists {
            let tabFrame = app.tabBars.firstMatch.frame
            let tab = tabFrame.intersection(window)
            XCTContext.runActivity(named: "Compact viewport tab — frame=\(tabFrame), visible=\(tab)") { _ in }
            guard finiteRect(tab) else { XCTFail("The visible tab bar must have a finite frame"); return nil }
            bottom = min(bottom, tab.minY)
        }
        let inputSurfaces = app.keyboards.allElementsBoundByIndex
            + app.otherElements.matching(NSPredicate(format: "identifier IN %@", ["inputView", "SystemInputAssistantView"])).allElementsBoundByIndex
        for surface in inputSurfaces {
            let frame = surface.frame
            XCTContext.runActivity(named: "Compact viewport input surface — \(frame)") { _ in }
            guard finiteRect(frame) else { XCTFail("An exported input surface has invalid geometry"); return nil }
            let visible = frame.intersection(window)
            if finiteRect(visible) { bottom = min(bottom, visible.minY) }
        }
        let top = max(window.minY, navigationFrame.maxY)
        let viewport = CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
        XCTContext.runActivity(named: "Compact viewport result — \(viewport), navigation=\(navigationFrame), bottom=\(bottom)") { _ in }
        guard finiteRect(viewport) else { XCTFail("The navigation-to-input viewport must be nonempty: \(viewport), \(context)"); return nil }
        return viewport
    }

    /// One point on a proved side of an exclusion, never a guessed editor/menu coordinate.
    private func outsidePoint(in bounds: CGRect, excluding exclusion: CGRect) -> CGPoint? {
        guard finiteRect(bounds), finiteRect(exclusion) else { return nil }
        let overlap = bounds.intersection(exclusion)
        guard finiteRect(overlap) else { return nil }
        let sides = [
            CGRect(x: bounds.minX, y: bounds.minY, width: overlap.minX - bounds.minX, height: bounds.height),
            CGRect(x: overlap.maxX, y: bounds.minY, width: bounds.maxX - overlap.maxX, height: bounds.height),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: overlap.minY - bounds.minY),
            CGRect(x: bounds.minX, y: overlap.maxY, width: bounds.width, height: bounds.maxY - overlap.maxY)
        ].filter { finiteRect($0) && $0.width > 24 && $0.height > 24 }
        guard let side = sides.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let interior = side.insetBy(dx: 12, dy: 12)
        let point = CGPoint(x: interior.midX, y: interior.midY)
        guard finiteRect(interior), bounds.contains(point), !exclusion.contains(point) else { return nil }
        return point
    }

    private func tap(_ point: CGPoint, in app: XCUIApplication, named name: String) {
        XCTContext.runActivity(named: "\(name): \(point)") { _ in
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }
    }

    private func dismissChatControls(_ app: XCUIApplication) -> Bool {
        let menus = app.collectionViews.containing(.button, identifier: "companion-permissions-menu")
        guard menus.count == 1, app.collectionViews.count == 1,
              let viewport = unobscuredViewport(app) else {
            XCTFail("Chat controls must expose exactly one native menu before dismissal")
            return false
        }
        let menuFrame = menus.firstMatch.frame
        guard finiteRect(menuFrame) else { XCTFail("The native menu must have a finite frame"); return false }
        let menu = menuFrame.intersection(app.windows.firstMatch.frame)
        guard let point = outsidePoint(in: viewport, excluding: menu) else {
            XCTFail("No finite outside-menu side is available for a single dismissal tap")
            return false
        }
        tap(point, in: app, named: "Dismiss chat controls outside native menu \(menu)")
        let ids = ["companion-permissions-menu", "companion-model-menu", "companion-effort-menu"]
            + ["full_access", "auto", "auto_edit", "ask", "plan"].map { "companion-level-\($0)" }
        let closed = waitFor(app, NSPredicate { _, _ in
            app.collectionViews.count == 0 && app.buttons.matching(NSPredicate(format: "identifier IN %@", ids)).count == 0
        }, timeout: 5)
        XCTAssertTrue(closed, "The native collection, parent triggers and every permission choice must disappear before focus")
        guard closed else { return false }
        capture(app, "idle menu dismissed before single focus tap")
        return true
    }

    /// One native content drag only when actual alert geometry proves Cancel overflows below its action clip.
    private func revealCancelIfNeeded(_ app: XCUIApplication) -> Bool {
        func geometry(_ phase: String, requiresScroll: Bool) -> (cancel: XCUIElement, target: CGRect, alert: CGRect, app: CGRect, window: CGRect, clip: CGRect?)? {
            let expected = app.alerts.containing(.staticText, identifier: "Interrupt this turn?")
            let total = app.alerts.count, matching = expected.count
            XCTContext.runActivity(named: "Cancel reveal \(phase) alert counts — global=\(total), expected=\(matching)") { _ in }
            guard total == 1, matching == 1 else {
                XCTFail("Cancel reveal requires one actual expected alert: global=\(total), expected=\(matching)"); return nil
            }
            let alert = expected.element(boundBy: 0)
            let cancels = alert.buttons.matching(identifier: "Cancel")
            let count = cancels.count
            XCTContext.runActivity(named: "Cancel reveal \(phase) scoped Cancel count=\(count)") { _ in }
            guard count == 1 else { XCTFail("Cancel reveal requires one scoped Cancel: \(count)"); return nil }
            let cancel = cancels.element(boundBy: 0)
            let label = cancel.label, target = cancel.frame, alertFrame = alert.frame
            let mainWindow = app.windows.firstMatch.frame, appFrame = app.frame
            let window = mainWindow.intersection(appFrame)
            let frames = "Cancel=\(target), alert=\(alertFrame), main=\(mainWindow), app=\(appFrame), window=\(window)"
            let finiteTarget = finiteRect(target), finiteAlert = finiteRect(alertFrame), finiteMain = finiteRect(mainWindow)
            let finiteApp = finiteRect(appFrame), finiteWindow = finiteRect(window)
            XCTContext.runActivity(named: "Cancel reveal \(phase) geometry — label=\(label), finiteTarget=\(finiteTarget), finiteAlert=\(finiteAlert), finiteMain=\(finiteMain), finiteApp=\(finiteApp), finiteWindow=\(finiteWindow), \(frames)") { _ in }
            guard label == "Cancel", finiteTarget, finiteAlert, finiteMain, finiteApp, finiteWindow else {
                XCTFail("Cancel reveal needs exact label and finite actual frames: \(label), \(frames)"); return nil
            }
            var clip: CGRect?
            if requiresScroll {
                // Title and actions can have different native ScrollViews. Never choose a global first scroll.
                let scrolls = alert.scrollViews.containing(.button, identifier: "Cancel")
                let scrollCount = scrolls.count
                XCTContext.runActivity(named: "Cancel reveal \(phase) containing action ScrollView count=\(scrollCount)") { _ in }
                guard scrollCount == 1 else { XCTFail("Cancel reveal requires one actual Cancel-containing action scroll: \(scrollCount)"); return nil }
                let scrollFrame = scrolls.element(boundBy: 0).frame
                let visible = scrollFrame.intersection(alertFrame).intersection(window)
                let finiteScroll = finiteRect(scrollFrame), finiteClip = finiteRect(visible)
                XCTContext.runActivity(named: "Cancel reveal \(phase) actual clip — scroll=\(scrollFrame), finiteScroll=\(finiteScroll), clip=\(visible), finiteClip=\(finiteClip), \(frames)") { _ in }
                guard finiteScroll, finiteClip else { XCTFail("Cancel reveal has no proven finite action clip: scroll=\(scrollFrame), clip=\(visible), \(frames)"); return nil }
                clip = visible
            }
            return (cancel, target, alertFrame, appFrame, window, clip)
        }

        guard let initial = geometry("initial", requiresScroll: false) else { return false }
        let insideAlert = initial.alert.contains(initial.target), insideWindow = initial.window.contains(initial.target)
        XCTContext.runActivity(named: "Cancel reveal zero-gesture predicates — insideAlert=\(insideAlert), insideWindow=\(insideWindow)") { _ in }
        if insideAlert && insideWindow { return true } // No action-scroll prerequisite on the original contained route.

        guard let before = geometry("before navigation", requiresScroll: true), let clip = before.clip else { return false }
        let target = before.target
        let horizontal = target.minX >= clip.minX && target.maxX <= clip.maxX
        let fitsHeight = target.height <= clip.height
        let below = target.minY >= clip.minY && target.maxY > clip.maxY
        let displacement = target.midY - clip.midY
        XCTContext.runActivity(named: "Cancel reveal navigation predicates — target=\(target), clip=\(clip), horizontal=\(horizontal), fitsHeight=\(fitsHeight), below=\(below), displacement=\(displacement)") { _ in }
        guard horizontal, fitsHeight, below, displacement.isFinite, displacement > 0 else {
            XCTFail("Only a real below-clip Cancel fitting the whole actual clip may receive one upward content drag: target=\(target), clip=\(clip), displacement=\(displacement)")
            return false
        }
        let interior = clip.insetBy(dx: 12, dy: 12)
        let start = CGPoint(x: interior.midX, y: interior.maxY - 1)
        let end = CGPoint(x: start.x, y: start.y - displacement)
        let budgetFits = finiteRect(interior) && displacement <= interior.height - 2
        let endpointsInside = interior.contains(start) && interior.contains(end) && clip.contains(start) && clip.contains(end)
            && before.alert.contains(start) && before.alert.contains(end) && before.window.contains(start) && before.window.contains(end)
        let distance = hypot(start.x - end.x, start.y - end.y)
        let velocity = distance / 1.0 // Nominal one-second traversal, not a delivered-timing guarantee.
        XCTContext.runActivity(named: "Cancel reveal one-drag budget — interior=\(interior), fits=\(budgetFits), endpointsInside=\(endpointsInside), \(start) → \(end), distance=\(distance), velocity=\(velocity)") { _ in }
        guard budgetFits, endpointsInside, velocity.isFinite, velocity > 0 else {
            XCTFail("Cancel reveal displacement must fit one actual inset12 content gesture: clip=\(clip), interior=\(interior), \(start) → \(end)")
            return false
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: start.x - before.app.minX, dy: start.y - before.app.minY))
        let to = origin.withOffset(CGVector(dx: end.x - before.app.minX, dy: end.y - before.app.minY))
        XCTContext.runActivity(named: "Interrupt Cancel one upward content drag — clip=\(clip), target=\(target), \(start) → \(end), velocity=\(velocity), terminal contact hold=0.2") { _ in
            from.press(forDuration: 0.05, thenDragTo: to,
                       withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0.2)
        }
        capture(app, "Interrupt Cancel after one bounded content navigation")
        // Capture before any later query/assertion can fail; then read the current native tree afresh.
        guard let after = geometry("after navigation", requiresScroll: true), let afterClip = after.clip else { return false }
        let inClip = afterClip.contains(after.target), inAlert = after.alert.contains(after.target), inWindow = after.window.contains(after.target)
        let widthOK = after.target.width >= 44, heightOK = after.target.height >= 44
        let enabled = after.cancel.isEnabled, hittable = after.cancel.isHittable
        XCTContext.runActivity(named: "Cancel reveal final predicates — target=\(after.target), clip=\(afterClip), inClip=\(inClip), inAlert=\(inAlert), inWindow=\(inWindow), width44=\(widthOK), height44=\(heightOK), enabled=\(enabled), hittable=\(hittable)") { _ in }
        guard inClip, inAlert, inWindow, widthOK, heightOK, enabled, hittable else {
            XCTFail("One content drag must reveal the whole actionable Cancel inside its actual clip/alert/window; no second gesture or tap rescue")
            return false
        }
        return true
    }

    private func cancelInterruptConfirmation(_ app: XCUIApplication) -> Bool {
        guard revealCancelIfNeeded(app) else { return false }
        let expected = app.alerts.containing(.staticText, identifier: "Interrupt this turn?")
        let totalAlerts = app.alerts.count, expectedCount = expected.count
        XCTContext.runActivity(named: "Interrupt alert cardinality — global=\(totalAlerts), expected=\(expectedCount)") { _ in }
        XCTAssertEqual(totalAlerts, 1, "Interrupt must have exactly one actual alert")
        XCTAssertEqual(expectedCount, 1, "Interrupt must have exactly one title-containing alert")
        guard totalAlerts == 1, expectedCount == 1 else { return false }
        let alert = expected.element(boundBy: 0)
        let titles = alert.staticTexts.matching(NSPredicate(format: "label == %@", "Interrupt this turn?"))
        let cancels = alert.buttons.matching(identifier: "Cancel")
        let interrupts = alert.buttons.matching(identifier: "Interrupt turn")
        let titleCount = titles.count, cancelCount = cancels.count, interruptCount = interrupts.count
        XCTContext.runActivity(named: "Interrupt alert children — title=\(titleCount), Cancel=\(cancelCount), destructive=\(interruptCount)") { _ in }
        XCTAssertEqual(titleCount, 1)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(interruptCount, 1)
        guard titleCount == 1, cancelCount == 1, interruptCount == 1 else { return false }
        let title = titles.element(boundBy: 0), cancel = cancels.element(boundBy: 0)
        let interrupt = interrupts.element(boundBy: 0)
        let titleLabel = title.label, cancelLabel = cancel.label, interruptLabel = interrupt.label
        let alertFrame = alert.frame, titleFrame = title.frame, cancelFrame = cancel.frame
        let mainWindow = app.windows.firstMatch.frame, appFrame = app.frame
        let window = mainWindow.intersection(appFrame)
        let labels = "title=\(titleLabel), Cancel=\(cancelLabel), destructive=\(interruptLabel)"
        let frames = "alert=\(alertFrame), title=\(titleFrame), Cancel=\(cancelFrame), main=\(mainWindow), app=\(appFrame), window=\(window)"
        XCTContext.runActivity(named: "Interrupt alert labels/frames — \(labels); \(frames)") { _ in }
        XCTAssertEqual(titleLabel, "Interrupt this turn?")
        XCTAssertEqual(cancelLabel, "Cancel")
        XCTAssertEqual(interruptLabel, "Interrupt turn")
        guard titleLabel == "Interrupt this turn?", cancelLabel == "Cancel", interruptLabel == "Interrupt turn" else { return false }
        let finiteAlert = finiteRect(alertFrame), finiteTitle = finiteRect(titleFrame), finiteCancel = finiteRect(cancelFrame)
        let finiteMain = finiteRect(mainWindow), finiteApp = finiteRect(appFrame), finiteWindow = finiteRect(window)
        XCTContext.runActivity(named: "Interrupt alert finite geometry — alert=\(finiteAlert), title=\(finiteTitle), Cancel=\(finiteCancel), main=\(finiteMain), app=\(finiteApp), window=\(finiteWindow)") { _ in }
        XCTAssertTrue(finiteAlert && finiteTitle && finiteCancel && finiteMain && finiteApp && finiteWindow, frames)
        guard finiteAlert, finiteTitle, finiteCancel, finiteMain, finiteApp, finiteWindow else { return false }
        let enabled = cancel.isEnabled, hittable = cancel.isHittable
        let withinAlert = alertFrame.contains(cancelFrame), withinWindow = window.contains(cancelFrame)
        let widthOK = cancelFrame.width >= 44, heightOK = cancelFrame.height >= 44
        XCTContext.runActivity(named: "Interrupt semantic Cancel predicates — enabled=\(enabled), hittable=\(hittable), width44=\(widthOK), height44=\(heightOK), withinAlert=\(withinAlert), withinWindow=\(withinWindow); \(frames)") { _ in }
        XCTAssertTrue(enabled && hittable, "The actual alert's Cancel must be enabled and hittable")
        XCTAssertGreaterThanOrEqual(cancelFrame.width, 44)
        XCTAssertGreaterThanOrEqual(cancelFrame.height, 44)
        XCTAssertTrue(withinAlert && withinWindow, "The whole Cancel must be inside its actual alert and window: \(frames)")
        guard enabled, hittable, widthOK, heightOK, withinAlert, withinWindow else { return false }
        cancel.tap()
        let closed = waitFor(app, NSPredicate { _, _ in
            !app.staticTexts["Interrupt this turn?"].exists && !app.buttons["Interrupt turn"].exists
        }, timeout: 5)
        XCTAssertTrue(closed, "Native cancellation must remove confirmation title and destructive action before draft checks")
        return closed
    }

    private func reviewApprovalWithoutAnswering(_ app: XCUIApplication, editing: Bool) {
        let composer = element(app, "companion-composer")
        let originalDraft = composer.value as? String
        let imageCount = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count
        let trigger = app.buttons["companion-review-approval"]
        XCTAssertEqual(trigger.label, "Review approval: Run xcodebuild, 1 of 2")
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(trigger, until: close, attempts: 1)
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
            guard let viewport = unobscuredViewport(app, approvalReview: true) else { return }
            XCTAssertGreaterThanOrEqual(decision.frame.minY, viewport.minY)
            XCTAssertLessThanOrEqual(decision.frame.maxY, viewport.maxY)
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
                           ordinaryAssistiveEditing: Bool = false,
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
            let frame = button.frame
            let measured = "\(state), id=\(button.identifier), \(NativeGeometryEvidence.describe(frame))"
            XCTContext.runActivity(named: "Compact strict target operands — \(measured)") { _ in }
            XCTAssertGreaterThanOrEqual(frame.width, 44, measured, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 44, measured, file: file, line: line)
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
            } else if ordinaryAssistiveEditing {
                XCTAssertGreaterThanOrEqual(composer.frame.width, 100, "Focused assistive draft retains useful width: \(state)", file: file, line: line)
                XCTAssertLessThanOrEqual(composer.frame.maxY, send.frame.minY, state, file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(interrupt.frame.minX, composer.frame.maxX - 2, state, file: file, line: line)
            }
            let interruptFrame = interrupt.frame, sendFrame = send.frame
            let gap = sendFrame.minX - interruptFrame.maxX
            let adjacent = "\(state): Interrupt \(interruptFrame), Send \(sendFrame), gap \(gap)"
            XCTContext.runActivity(named: "Compact composer adjacent action frames — \(adjacent)") { _ in }
            XCTAssertLessThanOrEqual(interruptFrame.maxX, sendFrame.minX, adjacent, file: file, line: line)
            XCTAssertLessThanOrEqual(gap, 16, adjacent, file: file, line: line)
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
        guard let viewport = unobscuredViewport(app, requiresKeyboard: true) else { return }
        let top = max(viewport.minY, header.exists ? header.frame.maxY : viewport.minY)
        let unobscured = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
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
