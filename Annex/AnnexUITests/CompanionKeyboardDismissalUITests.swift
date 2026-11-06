import XCTest

@MainActor final class CompanionKeyboardDismissalUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func focus(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        // iPad can focus the field with only its compact input palette.
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3)); show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["companion-dismiss-keyboard"].exists,
                       "Keyboard dismissal does not add a navigation-bar control")
    }
    private func transcriptPoint(_ app: XCUIApplication) -> XCUICoordinate {
        let frame = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let top = max(frame.minY, element(app, "companion-chat-header").frame.maxY) + 20
        let bottom = min(frame.maxY, element(app, "companion-composer").frame.minY) - 20
        XCTAssertGreaterThan(bottom - top, 30)
        let point = CGPoint(x: frame.minX + 8, y: top + min(35, (bottom - top) / 2))
        XCTAssertTrue(frame.contains(point))
        XCTAssertFalse(app.keyboards.firstMatch.frame.contains(point))
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }
    private func dispatcherTranscriptPoint(_ app: XCUIApplication, stage: String) -> XCUICoordinate? {
        func note(_ text: String) {
            XCTContext.runActivity(named: "Dispatcher transcript gutter \(stage) — \(text)") { _ in }
        }
        func finite(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite
                && [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height].allSatisfy { $0.isFinite }
                && frame.width > 0 && frame.height > 0
        }
        func reject(_ reason: String) {
            note("FAIL: \(reason)")
            screenshot(app, "Dispatcher transcript gutter \(stage) unsupported geometry")
            let attachment = XCTAttachment(data: Data(app.debugDescription.utf8.prefix(65_536)),
                                           uniformTypeIdentifier: "public.plain-text")
            attachment.name = "Dispatcher transcript gutter \(stage) public hierarchy (capped; later retrieval)"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTFail(reason)
        }
        screenshot(app, "Dispatcher gutter original before geometry: \(stage)")
        let keyboards = app.keyboards
        let keyboardCount = keyboards.count
        note("keyboard count=\(keyboardCount)")

        let allWindows = app.windows
        let windows = allWindows
            .containing(.navigationBar, identifier: "Dispatcher")
            .containing(.other, identifier: "companion-transcript")
            .containing(.scrollView, identifier: "companion-transcript")
            .containing(.other, identifier: "companion-composer-region")
        let navigationBars = app.navigationBars
        let dispatcherBars = navigationBars.matching(identifier: "Dispatcher")
        let transcriptID = "companion-transcript"
        let allTranscripts = app.descendants(matching: .any).matching(identifier: transcriptID)
        let reducedTranscripts = app.otherElements.matching(identifier: transcriptID)
        let nativeTranscripts = app.scrollViews.matching(identifier: transcriptID)
        let composerID = "companion-composer-region"
        let composers = app.descendants(matching: .any).matching(identifier: composerID)
        let composerOthers = app.otherElements.matching(identifier: composerID)
        let inputViews = app.otherElements.matching(identifier: "inputView")
        let assistants = app.otherElements.matching(identifier: "SystemInputAssistantView")
        let tabs = app.tabBars
        let previous = app.buttons.matching(identifier: "companion-previous-message")
        let next = app.buttons.matching(identifier: "companion-next-message")
        let latest = app.buttons.matching(NSPredicate(format: "label == %@", "Latest"))
        let previousCount = previous.count, nextCount = next.count, latestCount = latest.count
        note("overlay Button counts Previous/Next/Latest=\(previousCount)/\(nextCount)/\(latestCount)")
        let windowCount = allWindows.count, contentWindowCount = windows.count
        let navigationCount = navigationBars.count, dispatcherCount = dispatcherBars.count
        let transcriptCount = allTranscripts.count, reducedCount = reducedTranscripts.count, nativeCount = nativeTranscripts.count
        let composerCount = composers.count, composerOtherCount = composerOthers.count
        let inputCount = inputViews.count, assistantCount = assistants.count, tabCount = tabs.count
        note("counts window(diagnostic)=\(windowCount) contentWindow=\(contentWindowCount) nav=\(navigationCount) Dispatcher=\(dispatcherCount) transcriptAny/Other/ScrollView=\(transcriptCount)/\(reducedCount)/\(nativeCount) composerRegionAny/Other=\(composerCount)/\(composerOtherCount) inputView=\(inputCount) assistant=\(assistantCount) tab=\(tabCount)")
        guard keyboardCount == 1, contentWindowCount == 1, navigationCount == 1, dispatcherCount == 1,
              transcriptCount == 2, reducedCount == 1, nativeCount == 1, composerCount == 1, composerOtherCount == 1,
              inputCount == 1, assistantCount <= 1, tabCount <= 1,
              previousCount <= 1, nextCount <= 1, latestCount <= 1 else {
            reject("Expected unique content-owning Dispatcher window/nav/composer/input and empirical transcript Other/ScrollView pair")
            return nil
        }
        // Chained containing queries require common Window ownership; no label or frame chooses a Window.
        let contentWindow = windows.element(boundBy: 0)
        let localNavigationCount = contentWindow.navigationBars.count
        let localDispatcherCount = contentWindow.navigationBars.matching(identifier: "Dispatcher").count
        let localTranscriptCount = contentWindow.descendants(matching: .any).matching(identifier: transcriptID).count
        let localReducedCount = contentWindow.otherElements.matching(identifier: transcriptID).count
        let localNativeCount = contentWindow.scrollViews.matching(identifier: transcriptID).count
        let localComposerCount = contentWindow.descendants(matching: .any).matching(identifier: composerID).count
        let localComposerOtherCount = contentWindow.otherElements.matching(identifier: composerID).count
        let localPreviousCount = contentWindow.buttons.matching(identifier: "companion-previous-message").count
        let localNextCount = contentWindow.buttons.matching(identifier: "companion-next-message").count
        let localLatestCount = contentWindow.buttons.matching(NSPredicate(format: "label == %@", "Latest")).count
        note("contentWindow overlay Button counts Previous/Next/Latest=\(localPreviousCount)/\(localNextCount)/\(localLatestCount)")
        note("contentWindow local nav/Dispatcher=\(localNavigationCount)/\(localDispatcherCount) transcriptAny/Other/ScrollView=\(localTranscriptCount)/\(localReducedCount)/\(localNativeCount) composerRegionAny/Other=\(localComposerCount)/\(localComposerOtherCount)")
        guard localNavigationCount == navigationCount, localDispatcherCount == dispatcherCount,
              localTranscriptCount == transcriptCount, localReducedCount == reducedCount, localNativeCount == nativeCount,
              localComposerCount == composerCount, localComposerOtherCount == composerOtherCount,
              localPreviousCount == previousCount, localNextCount == nextCount, localLatestCount == latestCount else {
            reject("Content Window must own the same unique global Dispatcher nav/transcript/composer exports before frame use")
            return nil
        }
        // The pair is a checked native export shape, not a source-guaranteed AX role/ancestor contract.
        let keyboard = keyboards.element(boundBy: 0)
        let navigation = dispatcherBars.element(boundBy: 0)
        let reduced = reducedTranscripts.element(boundBy: 0)
        let native = nativeTranscripts.element(boundBy: 0)
        let composer = composers.element(boundBy: 0)
        let input = inputViews.element(boundBy: 0)
        let appFrame = app.frame, windowFrame = contentWindow.frame
        let navigationFrame = navigation.frame, reducedFrame = reduced.frame, nativeFrame = native.frame
        let composerFrame = composer.frame, keyboardFrame = keyboard.frame, inputFrame = input.frame
        let assistantFrame: CGRect? = assistantCount == 1 ? assistants.element(boundBy: 0).frame : nil
        let tabFrame: CGRect? = tabCount == 1 ? tabs.element(boundBy: 0).frame : nil
        let overlayQueries = [("Previous", previous, previousCount), ("Next", next, nextCount), ("Latest", latest, latestCount)]
        var overlayFrames: [CGRect] = []
        for (name, query, count) in overlayQueries where count == 1 {
            let action = query.element(boundBy: 0)
            let exists = action.exists, frame = action.frame
            note("overlay \(name) exists=\(exists) frame=\(frame) finite=\(finite(frame))")
            guard exists, finite(frame) else {
                reject("Every present unique overlay action must have actual finite positive geometry")
                return nil
            }
            overlayFrames.append(frame)
        }
        let exists = [keyboard.exists, navigation.exists, reduced.exists, native.exists, composer.exists, input.exists]
        let frames = [appFrame, windowFrame, navigationFrame, reducedFrame, nativeFrame, composerFrame, keyboardFrame, inputFrame]
        let finiteFrames = frames.map(finite)
        let finiteAssistant = assistantFrame.map(finite) ?? true
        let finiteTab = tabFrame.map(finite) ?? true
        note("frames app=\(appFrame) window=\(windowFrame) nav=\(navigationFrame) transcriptOther=\(reducedFrame) transcriptScrollView=\(nativeFrame) composerRegion=\(composerFrame) keyboard=\(keyboardFrame) inputView=\(inputFrame) assistant=\(String(describing: assistantFrame)) tab=\(String(describing: tabFrame)) exists=\(exists) finite=\(finiteFrames) finiteAssistant=\(finiteAssistant) finiteTab=\(finiteTab)")
        guard exists.allSatisfy({ $0 }), finiteFrames.allSatisfy({ $0 }), finiteAssistant, finiteTab else {
            reject("Every required actual export and optional exported frame must exist with finite positive geometry")
            return nil
        }
        let window = windowFrame.intersection(appFrame)
        let composerVisible = composerFrame.intersection(window)
        let keyboardVisible = keyboardFrame.intersection(window)
        let inputVisible = inputFrame.intersection(window)
        let assistantVisible = assistantFrame.map { $0.intersection(window) }
        let tabVisible = tabFrame.map { $0.intersection(window) }
        let validWindow = finite(window), navigationInside = window.contains(navigationFrame)
        let reducedInsideNative = nativeFrame.contains(reducedFrame)
        let visibleComposer = finite(composerVisible), visibleKeyboard = finite(keyboardVisible), visibleInput = finite(inputVisible)
        let connectedInput = visibleKeyboard && visibleInput && finite(keyboardVisible.intersection(inputVisible))
        let connectedAssistant = assistantVisible.map { !finite($0) || finite($0.intersection(inputVisible)) } ?? true
        let visibleTab = tabVisible.map(finite) ?? true
        note("visible window=\(window) composer=\(composerVisible) keyboard=\(keyboardVisible) input=\(inputVisible) assistant=\(String(describing: assistantVisible)) tab=\(String(describing: tabVisible)) validWindow=\(validWindow) navigationInside=\(navigationInside) reducedInsideNative=\(reducedInsideNative) visibleComposer=\(visibleComposer) visibleKeyboard=\(visibleKeyboard) visibleInput=\(visibleInput) connectedInput=\(connectedInput) connectedAssistant=\(connectedAssistant) visibleTab=\(visibleTab)")
        guard validWindow, navigationInside, reducedInsideNative, visibleComposer, visibleKeyboard, visibleInput,
              connectedInput, connectedAssistant, visibleTab else {
            reject("Actual transcript pair/window/chrome/composer/full-input intersections must be consistent")
            return nil
        }
        // Include the whole exported input region, not just the key rectangle below its assistant.
        var bottom = min(window.maxY, min(composerVisible.minY, min(keyboardVisible.minY, inputVisible.minY)))
        if let assistantVisible, finite(assistantVisible) { bottom = min(bottom, assistantVisible.minY) }
        if let tabVisible { bottom = min(bottom, tabVisible.minY) }
        let top = max(window.minY, navigationFrame.maxY)
        let navToBottom = CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
        let clip = reducedFrame.intersection(nativeFrame).intersection(window).intersection(navToBottom)
        // Keep only the Y inset: a full horizontal inset12 would discard the source-padding gutter at X+8.
        let interior = CGRect(x: clip.minX, y: clip.minY + 12, width: clip.width, height: clip.height - 24)
        let validClip = finite(navToBottom) && finite(clip) && finite(interior)
        note("navToBottom=\(navToBottom) actualClip=\(clip) verticalInset12Interior=\(interior) validClip=\(validClip)")
        guard validClip else {
            reject("Actual reduced transcript must leave a finite positive vertically inset12 gutter region")
            return nil
        }
        // Source timeline padding is at least14; clipping must retain this actual raw-left+8 candidate.
        let point = CGPoint(x: nativeFrame.minX + 8, y: interior.midY)
        let pointFinite = point.x.isFinite && point.y.isFinite
        let inSourceGutter = point.x > nativeFrame.minX && point.x < nativeFrame.minX + 14
        let insideBoth = reducedFrame.contains(point) && nativeFrame.contains(point)
        let insideClip = interior.contains(point) && clip.contains(point)
        let insideWindow = window.contains(point)
        let belowNavigation = point.y > navigationFrame.maxY
        let aboveComposer = point.y < composerVisible.minY && !composerFrame.contains(point)
        let outsideInput = !keyboardVisible.contains(point) && !inputVisible.contains(point)
            && !(assistantVisible.map { finite($0) && $0.contains(point) } ?? false)
        let outsideTab = !(tabVisible.map { $0.contains(point) } ?? false)
        let outsideOverlay = overlayFrames.map { !$0.contains(point) }
        note("point=\(point) finite=\(pointFinite) sourceGutter=\(inSourceGutter) insideBothTranscripts=\(insideBoth) insideClip=\(insideClip) insideWindow=\(insideWindow) belowNav=\(belowNavigation) aboveWholeComposer=\(aboveComposer) outsideFullInput=\(outsideInput) outsideTab=\(outsideTab) outsideEachOverlay=\(outsideOverlay)")
        guard pointFinite, inSourceGutter, insideBoth, insideClip, insideWindow, belowNavigation, aboveComposer,
              outsideInput, outsideTab, outsideOverlay.allSatisfy({ $0 }) else {
            reject("The measured source-padding gutter must be inside both transcript exports and outside actual chrome/input/overlay actions")
            return nil
        }
        let fields = app.descendants(matching: .any).matching(identifier: "companion-composer")
        let fieldCount = fields.count
        note("diagnostic-only editor count=\(fieldCount)")
        if fieldCount == 1 {
            note("diagnostic-only editor frame=\(fields.element(boundBy: 0).frame)")
        }
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - appFrame.minX, dy: point.y - appFrame.minY))
    }

    private func assertDismissed(_ app: XCUIApplication, draft: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitFor(element(app, "companion-composer"), NSPredicate(format: "value == %@", draft), timeout: 5))
        XCTAssertFalse(element(app, "companion-composer").debugDescription.contains("Keyboard Focused"),
                       "Focus, not just the software keyboard, ends")
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists,
                       "The assistive control is scoped to editing")
    }
    private func dispatcher(_ flags: [String]) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"] + flags, allowance: 360)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        focus(composer, in: app)
        composer.typeText("Keep my Dispatcher draft")
        if app.tabBars.firstMatch.exists {
            XCTAssertFalse(tab(app, "Home").isHittable, "The software keyboard covers iPhone's bottom tabs")
        }
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists, "Sighted editing has no extra control")
        screenshot(app, "Dispatcher keyboard with transcript exit")
        // A single real tap in blank transcript space, with no rescue tap.
        guard let blankPoint = dispatcherTranscriptPoint(app, stage: "blank tap") else { return }
        blankPoint.tap()
        screenshot(app, "Dispatcher gutter original after blank tap")
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        XCTAssertTrue(tab(app, "Home").isHittable)
        tab(app, "Home").tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        tab(app, "Dispatcher").tap()
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 5))
        assertDismissed(app, draft: "Keep my Dispatcher draft")

        focus(composer, in: app)
        // Also cover the other end of the full-height blank hit area, just above the composer.
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let composerRegion = element(app, "companion-composer-region")
        XCTAssertTrue(composerRegion.exists)
        // The text field's AX frame excludes its outer padding; use the entire bottom bar's bounds.
        let bottom = min(transcript.maxY, composerRegion.frame.minY) - 12
        let point = CGPoint(x: transcript.minX + 8, y: bottom)
        XCTAssertGreaterThan(bottom, element(app, "companion-chat-header").frame.maxY)
        XCTAssertFalse(app.keyboards.firstMatch.frame.contains(point))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        // Native interactive dismissal is a user drag, never a streamed scrollTo.
        focus(composer, in: app)
        guard let start = dispatcherTranscriptPoint(app, stage: "interactive drag") else { return }
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        screenshot(app, "Dispatcher gutter original after interactive drag")
        assertDismissed(app, draft: "Keep my Dispatcher draft")
        XCTAssertTrue(tab(app, "Home").isHittable)
        screenshot(app, "Dispatcher draft kept and tabs reachable")
    }
    func testEmptyDispatcherCanDismissAndReturnHome() { dispatcher(["--companion-preview-empty-chat"]) }
    func testShortDispatcherCanDismissAndReturnHome() { dispatcher([]) }
    func testLongDispatcherCanDismissAndReturnHome() { dispatcher(["--companion-preview-long-reply"]) }

    func testStreamingInAnOrdinaryChatKeepsEditingUntilTheUserDismisses() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading", "--companion-preview-stream", "--companion-preview-long-reply", "--companion-preview-follow-trace"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-composer"))
        let replies = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Streaming preview reply."))
        XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(replies.count, 1, "The live fixture must exercise more than one text slice")
        let composer = element(app, "companion-composer")
        focus(composer, in: app); composer.typeText("Keep editing while streaming")
        let before = replies.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitFor(replies.firstMatch, NSPredicate { _, _ in
            replies.allElementsBoundByIndex.map(\.label) != before
        }, timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Programmatic following must never dismiss the keyboard")
        XCTAssertEqual(composer.value as? String, "Keep editing while streaming")
        // Tap real selectable text, rather than the blank gutter used above.
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let viewportTop = max(transcript.minY, element(app, "companion-chat-header").frame.maxY)
        let viewportBottom = min(transcript.maxY, app.buttons["companion-level-menu"].frame.minY)
        let viewport = CGRect(x: transcript.minX, y: viewportTop, width: transcript.width, height: max(0, viewportBottom - viewportTop))
        // The first slice can be offscreen once the reply grows. Choose the
        // largest actually visible text fragment, retaining the real-text tap.
        let live = replies.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.intersects(viewport) }
            .max { $0.frame.intersection(viewport).height < $1.frame.intersection(viewport).height }
        XCTContext.runActivity(named: "Streaming viewport \(viewport), keyboard \(app.keyboards.firstMatch.frame), transcript \(transcript)") { _ in }
        if live == nil { screenshot(app, "Stream viewport missing live text") }
        XCTAssertNotNil(live, "A streamed text fragment must be visible while typing")
        guard let live else { return }
        let band = viewport.intersection(live.frame)
        let top = band.minY + 12
        let bottom = band.maxY - 12
        XCTAssertGreaterThan(bottom, top)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: band.midX, dy: (top + bottom) / 2)).tap()
        assertDismissed(app, draft: "Keep editing while streaming")
        focus(composer, in: app); transcriptPoint(app).tap()
        assertDismissed(app, draft: "Keep editing while streaming")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(river.waitForExistence(timeout: 5))
        waitAndTap(river, until: composer)
        assertDismissed(app, draft: "Keep editing while streaming")
    }
    func testAssistiveDismissControlFitsTheComposerAndKeepsTheSlashWordClosed() {
        // This flag exercises the same button as VoiceOver/Switch Control without changing simulator settings.
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists)
        focus(composer, in: app)
        composer.typeText("/r")
        let menu = element(app, "companion-slash-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let dismiss = app.buttons["companion-dismiss-keyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertEqual(dismiss.label, "Dismiss Keyboard")
        screenshot(app, "Assistive composer row before geometry assertions")
        let interrupts = app.buttons.matching(identifier: "companion-interrupt")
        let interruptCount = interrupts.count
        XCTContext.runActivity(named: "Assistive canonical Interrupt count: \(interruptCount)") { _ in }
        XCTAssertEqual(interruptCount, 1, "The assistive row must expose one canonical Interrupt Button")
        guard interruptCount == 1 else { return }
        let interrupt = interrupts.element(boundBy: 0)
        XCTAssertEqual(interrupt.label, "Interrupt")
        let attach = app.buttons["companion-attach"]
        let send = app.buttons["companion-send"]
        let controls = app.buttons["companion-level-menu"]
        func editingViewport() -> CGRect? {
            func note(_ text: String) {
                XCTContext.runActivity(named: "Assistive stacked viewport — \(text)") { _ in }
            }
            func finite(_ frame: CGRect) -> Bool {
                !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                    && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
            }
            func reject(_ text: String) -> CGRect? {
                note("FAIL: \(text)")
                screenshot(app, "Assistive stacked viewport unsupported geometry")
                let tree = XCTAttachment(data: Data(app.debugDescription.utf8.prefix(65_536)), uniformTypeIdentifier: "public.plain-text")
                tree.name = "Assistive stacked public hierarchy (capped; later retrieval)"
                tree.lifetime = .keepAlways; add(tree)
                XCTFail(text)
                return nil
            }
            let navigationBars = app.navigationBars
            let riverBars = navigationBars.matching(identifier: "River")
            let regionID = "companion-composer-region"
            let regions = app.descendants(matching: .any).matching(identifier: regionID)
            let regionOthers = app.otherElements.matching(identifier: regionID)
            let editors = app.descendants(matching: .any).matching(identifier: "companion-composer")
            let actionIDs = ["companion-level-menu", "companion-interrupt", "companion-attach", "companion-send", "companion-dismiss-keyboard"]
            let actionCounts = actionIDs.map { app.buttons.matching(identifier: $0).count }
            let keyboards = app.keyboards
            let inputs = app.otherElements.matching(identifier: "inputView")
            let assistants = app.otherElements.matching(identifier: "SystemInputAssistantView")
            let tabs = app.tabBars
            let windows = app.windows.containing(.navigationBar, identifier: "River").containing(.other, identifier: regionID)
            let windowCount = app.windows.count, contentWindowCount = windows.count
            let navCount = navigationBars.count, riverCount = riverBars.count
            let regionCount = regions.count, regionOtherCount = regionOthers.count, editorCount = editors.count
            let keyboardCount = keyboards.count, inputCount = inputs.count, assistantCount = assistants.count, tabCount = tabs.count
            note("global windows(diagnostic)=\(windowCount) contentWindow=\(contentWindowCount) nav/River=\(navCount)/\(riverCount) regionAny/Other=\(regionCount)/\(regionOtherCount) editor=\(editorCount) actionIDs=\(actionIDs) counts=\(actionCounts) keyboard/input/assistant/tab=\(keyboardCount)/\(inputCount)/\(assistantCount)/\(tabCount)")
            guard contentWindowCount == 1, navCount == 1, riverCount == 1, regionCount == 1, regionOtherCount == 1,
                  editorCount == 1, actionCounts.allSatisfy({ $0 == 1 }), keyboardCount == 1, inputCount == 1,
                  assistantCount <= 1, tabCount <= 1 else { return reject("Expected unique current assistive River content and global input exports") }
            let contentWindow = windows.element(boundBy: 0)
            let localNavCount = contentWindow.navigationBars.count
            let localRiverCount = contentWindow.navigationBars.matching(identifier: "River").count
            let localRegionCount = contentWindow.descendants(matching: .any).matching(identifier: regionID).count
            let localRegionOtherCount = contentWindow.otherElements.matching(identifier: regionID).count
            let localEditorCount = contentWindow.descendants(matching: .any).matching(identifier: "companion-composer").count
            let localActionCounts = actionIDs.map { contentWindow.buttons.matching(identifier: $0).count }
            note("local nav/River=\(localNavCount)/\(localRiverCount) regionAny/Other=\(localRegionCount)/\(localRegionOtherCount) editor=\(localEditorCount) actions=\(localActionCounts)")
            guard localNavCount == navCount, localRiverCount == riverCount, localRegionCount == regionCount,
                  localRegionOtherCount == regionOtherCount, localEditorCount == editorCount, localActionCounts == actionCounts else {
                return reject("The actual content Window must own the same guarded global editor and action exports before frame use")
            }
            let appFrame = app.frame, windowFrame = contentWindow.frame
            let navFrame = riverBars.element(boundBy: 0).frame, regionFrame = regions.element(boundBy: 0).frame
            let keyboardFrame = keyboards.element(boundBy: 0).frame, inputFrame = inputs.element(boundBy: 0).frame
            let assistantFrame = assistantCount == 1 ? assistants.element(boundBy: 0).frame : nil
            let tabFrame = tabCount == 1 ? tabs.element(boundBy: 0).frame : nil
            let rawFrames = [appFrame, windowFrame, navFrame, regionFrame, keyboardFrame, inputFrame]
            let finiteFrames = rawFrames.map(finite), finiteAssistant = assistantFrame.map(finite) ?? true, finiteTab = tabFrame.map(finite) ?? true
            note("raw app/window/nav/region/keyboard/input=\(rawFrames) assistant=\(String(describing: assistantFrame)) tab=\(String(describing: tabFrame)) finite=\(finiteFrames) finiteAssistant=\(finiteAssistant) finiteTab=\(finiteTab)")
            guard finiteFrames.allSatisfy({ $0 }), finiteAssistant, finiteTab else { return reject("All actual viewport/input frames must be finite and positive") }
            let window = windowFrame.intersection(appFrame)
            let keyboardVisible = keyboardFrame.intersection(window), inputVisible = inputFrame.intersection(window)
            let assistantVisible = assistantFrame.map { $0.intersection(window) }, tabVisible = tabFrame.map { $0.intersection(window) }
            let validWindow = finite(window), navInside = window.contains(navFrame), regionInside = window.contains(regionFrame)
            let visibleKeyboard = finite(keyboardVisible), visibleInput = finite(inputVisible)
            let connectedInput = finite(keyboardVisible.intersection(inputVisible))
            let connectedAssistant = assistantVisible.map { !finite($0) || finite($0.intersection(inputVisible)) } ?? true
            let visibleTab = tabVisible.map(finite) ?? true
            note("visible window=\(window) keyboard=\(keyboardVisible) input=\(inputVisible) assistant=\(String(describing: assistantVisible)) tab=\(String(describing: tabVisible)) validWindow=\(validWindow) navInside=\(navInside) regionInside=\(regionInside) visibleKeyboard=\(visibleKeyboard) visibleInput=\(visibleInput) connectedInput=\(connectedInput) connectedAssistant=\(connectedAssistant) visibleTab=\(visibleTab)")
            guard validWindow, navInside, regionInside, visibleKeyboard, visibleInput, connectedInput, connectedAssistant, visibleTab else {
                return reject("Actual app/content-window/nav/composer/full-input intersections must agree")
            }
            var bottom = min(window.maxY, min(keyboardVisible.minY, inputVisible.minY))
            if let assistantVisible, finite(assistantVisible) { bottom = min(bottom, assistantVisible.minY) }
            if let tabVisible { bottom = min(bottom, tabVisible.minY) }
            let top = max(window.minY, navFrame.maxY)
            let viewport = CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
            note("actual nav-to-full-input viewport=\(viewport) finite=\(finite(viewport))")
            guard finite(viewport) else { return reject("The actual nav-to-full-input viewport must have positive area") }
            let regionInsideViewport = viewport.contains(regionFrame)
            note("whole composer region=\(regionFrame) viewport=\(viewport) regionInsideViewport=\(regionInsideViewport)")
            guard regionInsideViewport else { return reject("The whole composer region, including slash/pinned/attachments, must fit nav-to-full-input viewport") }
            return viewport
        }
        guard let viewport = editingViewport() else { return }
        for control in [controls, interrupt, attach, send, dismiss] {
            let frame = control.frame
            let finiteFrame = !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
            XCTContext.runActivity(named: "Assistive stacked target \(control.identifier): \(frame), viewport \(viewport), finite=\(finiteFrame)") { _ in }
            XCTAssertTrue(finiteFrame)
            guard finiteFrame else { return }
            XCTAssertTrue(viewport.contains(frame), "The whole actual composer action stays inside nav-to-full-input viewport")
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(control.isHittable, "Every composer control remains reachable: \(control.label)")
            XCTAssertTrue(app.frame.contains(control.frame))
        }
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertGreaterThanOrEqual(composer.frame.width, 100, "Retain a useful text-entry width with every control visible")
        print("ASSISTIVE_COMPOSER window=\(app.frame) field=\(composer.frame) interrupt=\(interrupt.frame) send=\(send.frame) dismiss=\(dismiss.frame)")
        let editorFrame = composer.frame, interruptFrame = interrupt.frame, sendFrame = send.frame
        let interruptSendGap = sendFrame.minX - interruptFrame.maxX
        XCTContext.runActivity(named: "Assistive trailing actions — editor \(editorFrame), Interrupt \(interruptFrame), Send \(sendFrame), gap \(interruptSendGap)") { _ in }
        let dismissFrame = dismiss.frame, controlsFrame = controls.frame
        let finiteEditor = !editorFrame.isNull && !editorFrame.isInfinite && editorFrame.width > 0 && editorFrame.height > 0
            && [editorFrame.minX, editorFrame.minY, editorFrame.maxX, editorFrame.maxY].allSatisfy { $0.isFinite }
        XCTAssertTrue(finiteEditor)
        guard finiteEditor else { return }
        XCTAssertTrue(viewport.contains(editorFrame), "The full editor stays inside nav-to-full-input viewport")
        XCTAssertTrue(composer.isHittable)
        XCTAssertLessThanOrEqual(editorFrame.maxY, min(interruptFrame.minY, min(sendFrame.minY, min(dismissFrame.minY, controlsFrame.minY))),
                                 "Focused assistive editor is above its action rail")
        XCTAssertLessThanOrEqual(interruptFrame.maxX, sendFrame.minX)
        XCTAssertLessThanOrEqual(interruptSendGap, 16)
        XCTAssertLessThanOrEqual(send.frame.maxX, dismiss.frame.minX)
        XCTContext.runActivity(named: "Assistive row: window \(app.frame), input \(composer.frame), interrupt \(interrupt.frame), attach \(attach.frame), send \(send.frame), dismiss \(dismiss.frame)") { _ in }
        screenshot(app, "Assistive composer row with slash menu")
        dismiss.tap()
        assertDismissed(app, draft: "/r")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        focus(composer, in: app)
        composer.typeText("e")
        XCTAssertFalse(menu.waitForExistence(timeout: 1), "Refocusing keeps the dismissed slash word closed")
        composer.typeText(" /")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "A new slash word opens the menu")
    }

    func testTranscriptCardContentLinkAndCopyStillWorkWhileEditing() {
        let app = launchApp(["--companion-preview", "--companion-preview-keyboard-interactions"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        let group = app.buttons["companion-activity-tool:keyboard-tool"]
        focus(composer, in: app); composer.typeText("Draft beside a file link")
        XCTAssertTrue(group.isHittable)
        group.tap()
        XCTAssertTrue(waitFor(group, NSPredicate(format: "value == %@", "Expanded"), timeout: 5), "Ending editing must not swallow a card's toggle")
        group.tap()
        XCTAssertTrue(waitFor(group, NSPredicate(format: "value == %@", "Collapsed"), timeout: 5))
        focus(composer, in: app)
        let link = app.buttons.matching(identifier: "companion-content-link")
            .matching(NSPredicate(format: "label == %@", "Sources/Companion/Conversation.swift")).firstMatch
        XCTAssertTrue(link.isHittable)
        XCTAssertGreaterThan(link.frame.minY, element(app, "companion-chat-header").frame.maxY)
        XCTAssertLessThan(link.frame.maxY, composer.frame.minY)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["companion-preview-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Ending editing must not swallow the content link")
        done.tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "Draft beside a file link"), timeout: 5))
        // A long press still belongs to the message's selection/context menu.
        focus(composer, in: app)
        // Copy the final message, which remains above the composer on a phone
        // after the keyboard reduces the viewport.
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Open ")).firstMatch
        XCTAssertTrue(message.isHittable)
        message.press(forDuration: 1.2)
        let copy = app.buttons["Copy message"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "Draft beside a file link"), timeout: 5))
    }
}
