import XCTest

/// The composer keeps a full-width draft above one action row: Options and Attach on the left, Interrupt beside Send.
@MainActor final class CompanionCompactComposerUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ state: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact composer \(state)"; shot.lifetime = .keepAlways; add(shot)
    }

    // MARK: One accessibility snapshot per checked state

    /// Frames and values from a single snapshot of the app. Querying each element separately costs a round trip
    /// apiece, which made the eight-line flow run out of time on hosted runners.
    private struct Layout {
        var frames: [String: CGRect] = [:]
        /// How many elements carry each identifier; the native draft field must stay unique.
        var counts: [String: Int] = [:]
        var values: [String: String] = [:]
        var enabled: [String: Bool] = [:]
        var window = CGRect.null
        var navigation = CGRect.null
        /// The top of the keyboard and its assistant row, when editing.
        var keyboardTop: CGFloat?
        subscript(_ id: String) -> CGRect? { frames[id] }
    }

    private func layout(_ app: XCUIApplication, navigationBar: String? = nil) throws -> Layout {
        var result = Layout()
        let root = try app.snapshot()
        result.window = root.frame
        func visit(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if node.elementType == .keyboard || id == "SystemInputAssistantView", node.frame.intersects(root.frame) {
                result.keyboardTop = min(result.keyboardTop ?? .infinity, node.frame.minY)
            }
            if node.elementType == .navigationBar, result.navigation.isNull, navigationBar == nil || id == navigationBar {
                result.navigation = node.frame
            }
            if !id.isEmpty { result.counts[id, default: 0] += 1 }
            // Prefer the Button when a wrapper shares its identifier.
            if !id.isEmpty, result.frames[id] == nil || node.elementType == .button {
                result.frames[id] = node.frame
                result.values[id] = node.value as? String
                result.enabled[id] = node.isEnabled
            }
            node.children.forEach(visit)
        }
        visit(root)
        return result
    }

    /// The area between the navigation bar and the keyboard (or the bottom of the window).
    private func visibleRegion(_ layout: Layout) -> CGRect {
        let top = max(layout.window.minY, layout.navigation.isNull ? layout.window.minY : layout.navigation.maxY)
        let bottom = min(layout.window.maxY, layout.keyboardTop ?? layout.window.maxY)
        return CGRect(x: layout.window.minX, y: top, width: layout.window.width, height: max(0, bottom - top))
    }

    // MARK: Row assertions

    /// The action row sits below the full-width draft, in order, with full targets and no overlaps.
    private func assertRow(_ app: XCUIApplication, working: Bool, state: String, editing: Bool = false,
                           dismissButton: Bool = false, reviewButton: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        capture(app, state)
        let layout = try layout(app)
        if editing { XCTAssertNotNil(layout.keyboardTop, "\(state): keyboard", file: file, line: line) }
        XCTAssertEqual(layout.counts["companion-composer"], 1, "\(state): one native draft field", file: file, line: line)
        let region = visibleRegion(layout)
        guard let composerRegion = layout["companion-composer-region"], let editor = layout["companion-composer"] else {
            XCTFail("\(state): composer region and editor must be exported", file: file, line: line); return
        }
        XCTAssertTrue(pixelContains(region, composerRegion),
                      "\(state): the whole composer, approval and attachments fit: \(composerRegion) in \(region)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(editor.width, layout.window.width * 0.7, "\(state): the draft keeps the full text row", file: file, line: line)
        var ids = ["companion-level-menu", "companion-send"]
        if layout["companion-attach"] != nil { ids.insert("companion-attach", at: 1) }
        if working { ids.insert("companion-interrupt", at: ids.count - 1) }
        if dismissButton { ids.append("companion-dismiss-keyboard") }
        if reviewButton {
            let review = try XCTUnwrap(layout["companion-review-approval"])
            XCTAssertTrue(pixelContains(region, review), "\(state): approval review stays visible", file: file, line: line)
            XCTAssertLessThanOrEqual(review.maxY, composerRegion.minY, "\(state): review stays above the composer", file: file, line: line)
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).height, 44, file: file, line: line)
        }
        XCTAssertEqual(layout["companion-interrupt"] != nil, working, "\(state): Interrupt shows only while Working", file: file, line: line)
        XCTAssertEqual(layout["companion-dismiss-keyboard"] != nil, dismissButton, "\(state): assistive dismiss", file: file, line: line)
        var previous: (id: String, frame: CGRect)?
        for id in ids {
            guard let frame = layout[id] else { XCTFail("\(state): \(id) must be exported", file: file, line: line); continue }
            let aligned = pixelAligned(rect: frame)
            XCTAssertGreaterThanOrEqual(aligned.width, 44, "\(state): \(id) width \(frame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(aligned.height, 44, "\(state): \(id) height \(frame)", file: file, line: line)
            XCTAssertTrue(pixelContains(composerRegion, frame), "\(state): \(id) stays in the composer: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(pixelAligned(editor.maxY), aligned.minY, "\(state): \(id) stays below the draft", file: file, line: line)
            if let previous {
                XCTAssertLessThanOrEqual(pixelAligned(previous.frame.maxX), aligned.minX,
                                         "\(state): \(previous.id) precedes \(id) without overlap", file: file, line: line)
            }
            previous = (id, frame)
        }
        if working, let interrupt = layout["companion-interrupt"], let send = layout["companion-send"] {
            XCTAssertLessThanOrEqual(pixelAligned(send.minX - interrupt.maxX), 16, "\(state): Interrupt sits beside Send", file: file, line: line)
            XCTAssertEqual(pixelAligned(interrupt.midY), pixelAligned(send.midY), accuracy: 3, state, file: file, line: line)
        }
    }

    private func focus(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.debugDescription.contains("Keyboard Focused"), "One tap focuses the draft")
    }

    // MARK: Menus and confirmation

    private let chatControlIDs = ["companion-permissions-menu", "companion-model-menu", "companion-effort-menu"]
        + ["full_access", "auto", "auto_edit", "ask", "plan"].map { "companion-level-\($0)" }

    /// Closes the chat-controls menu with one tap outside it, inside `preferred` when that has room (the draft, so
    /// editing continues), otherwise anywhere in the visible region.
    private func dismissChatControls(_ app: XCUIApplication, preferring preferred: CGRect? = nil) throws {
        let menu = app.collectionViews.containing(.button, identifier: "companion-permissions-menu").firstMatch
        XCTAssertTrue(menu.exists, "The chat-controls menu is open")
        let menuFrame = menu.frame
        let region = visibleRegion(try layout(app))
        func outside(_ bounds: CGRect) -> CGPoint? {
            let candidates = [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: menuFrame.minY - bounds.minY),
                CGRect(x: menuFrame.maxX, y: bounds.minY, width: bounds.maxX - menuFrame.maxX, height: bounds.height),
                CGRect(x: bounds.minX, y: menuFrame.maxY, width: bounds.width, height: bounds.maxY - menuFrame.maxY),
            ].map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 24 && $0.height > 24 }
            return candidates.max { $0.width * $0.height < $1.width * $1.height }.map { CGPoint(x: $0.midX, y: $0.midY) }
        }
        let point = preferred.flatMap { outside($0.intersection(region)) } ?? outside(region)
        guard let point else { XCTFail("No room outside the menu \(menuFrame) to dismiss it"); return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        let closed = waitFor(app, NSPredicate { _, _ in
            app.collectionViews.count == 0 && app.buttons.matching(NSPredicate(format: "identifier IN %@", self.chatControlIDs)).count == 0
        }, timeout: 5)
        XCTAssertTrue(closed, "The chat-controls menu closes")
    }

    /// Cancels the Interrupt confirmation through its own Cancel button, scrolling the alert's actions at large sizes.
    private func cancelInterruptConfirmation(_ app: XCUIApplication) {
        let alert = app.alerts.containing(.staticText, identifier: "Interrupt this turn?").firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 1)
        XCTAssertTrue(alert.buttons["Interrupt turn"].exists, "Interrupt stays a separate destructive action")
        let cancel = alert.buttons["Cancel"]
        var swipes = 0
        while swipes < 2, !(cancel.isHittable && pixelContains(alert.frame, cancel.frame)) {
            alert.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(cancel.isEnabled && cancel.isHittable)
        XCTAssertTrue(pixelContains(alert.frame, cancel.frame), "Cancel \(cancel.frame) is inside its alert \(alert.frame)")
        assertMinimumTarget(cancel, "Cancel")
        cancel.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Cancel closes the confirmation")
    }

    /// Large text shows a prominent review action instead of pinned decisions; opening and closing it decides nothing.
    private func reviewApprovalWithoutAnswering(_ app: XCUIApplication, editing: Bool) {
        let composer = element(app, "companion-composer")
        let originalDraft = composer.value as? String
        let images = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail")
        let imageCount = images.count
        let trigger = app.buttons["companion-review-approval"]
        XCTAssertEqual(trigger.label, "Review approval: Run xcodebuild, 1 of 2")
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(trigger, until: close, attempts: 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Run xcodebuild")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Request 1 of 2")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Build the iOS application to verify the updated conversation layout."].exists)
        for label in ["Allow once", "Deny"] {
            let decision = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(scrollTo(decision, in: app, maxSwipes: 8))
            capture(app, "approval review \(label), editing \(editing)")
            XCTAssertTrue(decision.isEnabled && decision.isHittable, label)
            assertMinimumTarget(decision, label)
            if let review = try? layout(app, navigationBar: "Review approval") {
                XCTAssertTrue(pixelContains(visibleRegion(review), decision.frame), "\(label) is fully visible: \(decision.frame)")
            }
        }
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, originalDraft)
        XCTAssertEqual(images.count, imageCount)
        XCTAssertEqual(trigger.label, "Review approval: Run xcodebuild, 1 of 2", "The approval stays pending after closing review")
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        if editing {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Closing review keeps the keyboard")
        }
    }

    // MARK: Pixels

    private func luminance(_ c: [Int]) -> Double {
        func channel(_ v: Int) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2])
    }
    private func contrast(_ a: [Int], _ b: [Int]) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// sRGB pixels of `rect` (points) in a fresh screenshot.
    private func pixels(_ app: XCUIApplication, in rect: CGRect) -> [[Int]] {
        guard let image = app.screenshot().image.cgImage else { XCTFail("No screenshot"); return [] }
        let scale = CGFloat(image.width) / app.frame.width
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop) else { XCTFail("Bad crop \(crop)"); return [] }
        let (width, height) = (cropped.width, cropped.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { [Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2])] }
    }

    // MARK: Tests

    func testIdleControlsStayCollapsedBeforeAndAfterTyping() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window"], attempts: 1)
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["companion-level-menu"].label.contains("Chat controls"))
        try assertRow(app, working: false, state: "idle empty unfocused")
        waitAndTap(app.buttons["companion-level-menu"], until: app.buttons["companion-permissions-menu"], attempts: 1)
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        XCTAssertTrue(app.buttons["companion-effort-menu"].exists)
        try dismissChatControls(app)
        focus(composer, in: app)
        composer.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue(app.buttons["companion-send"].isEnabled && app.buttons["companion-send"].isHittable)
        try assertRow(app, working: false, state: "idle typed focused", editing: true)
    }

    func testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation() throws {
        try workingRow(largestText: false)
    }

    func testLargestTextWorkingAttachmentRowFits() throws {
        try workingRow(largestText: true)
    }

    private func workingRow(largestText: Bool) throws {
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard", "--companion-sample-images"]
                            + (largestText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []), attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer, attempts: 1)
        let send = app.buttons["companion-send"]
        XCTAssertFalse(send.isEnabled, "An empty draft cannot steer")
        try assertRow(app, working: true, state: "working empty unfocused", reviewButton: largestText)
        if largestText {
            // The inline history has no duplicate decisions; the bounded tray opens the shared review.
            XCTAssertFalse(app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval needed: ")).firstMatch.exists,
                           "Large text reviews the approval instead of pinning decisions")
            reviewApprovalWithoutAnswering(app, editing: false)
        } else {
            XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Approval stays pinned")
        }
        waitAndTap(app.buttons["companion-attach"], until: element(app, "companion-attachment-thumbnail"), attempts: 1)
        XCTAssertTrue(send.isEnabled, "An image-only draft can steer")
        try assertRow(app, working: true, state: "working image-only unfocused", reviewButton: largestText)
        focus(composer, in: app)
        let direction = largestText ? "Keep this direction\nAnd this detail" : "Keep this direction"
        composer.typeText(direction)
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertTrue(send.isEnabled)
        try assertRow(app, working: true, state: "working typed focused", editing: true, dismissButton: true, reviewButton: largestText)
        for id in ["companion-level-menu", "companion-attach", "companion-interrupt", "companion-send", "companion-dismiss-keyboard"] {
            XCTAssertTrue(app.buttons[id].isEnabled && app.buttons[id].isHittable, id)
        }
        if largestText { reviewApprovalWithoutAnswering(app, editing: true) }
        XCTAssertFalse(app.staticTexts["Your direction will be sent to the running agent."].exists, "No redundant steering caption")
        XCTAssertEqual(send.label, "Send steering message")
        let imageCount = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count
        waitAndTap(app.buttons["companion-interrupt"], until: app.buttons["Interrupt turn"], attempts: 1)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists,
                       "Interrupt only asks; nothing is sent while the confirmation is open")
        capture(app, "Interrupt confirmation largest \(largestText)")
        cancelInterruptConfirmation(app)
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").count, imageCount)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        // The alert can end editing; refocus so the real assistive dismiss action is exercised.
        if !app.keyboards.firstMatch.exists { focus(composer, in: app) }
        let dismiss = app.buttons["companion-dismiss-keyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), "The assistive action leaves editing")
        XCTAssertEqual(composer.value as? String, direction)
        XCTAssertTrue(element(app, "companion-attachment-thumbnail").exists, "Dismissal keeps the image draft")
        try assertRow(app, working: true, state: "working typed unfocused", reviewButton: largestText)
    }

    /// In dark mode the draft keeps the dark theme: its prompt and typed text stay readable (WCAG AA) on the field,
    /// and the keyboard is the dark one. A composer glass that adapted to light left white text at about 2:1, and the
    /// system placeholder colour at 1.13:1.
    func testDarkModeDraftTextAndKeyboardStayDark() {
        assertDraftReadable(dark: true)
    }

    /// Light mode keeps the same guarantees for the prompt and typed text.
    func testLightModeDraftPromptAndTextStayReadable() {
        assertDraftReadable(dark: false)
    }

    private func assertDraftReadable(dark: Bool) {
        let mode = dark ? "dark" : "light"
        // The appearance is set for this launch; setting the simulator's from a test doesn't reach the app everywhere.
        let app = launchApp(["--companion-preview", "--companion-preview-working-composer", "--companion-preview-\(mode)"], attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer, attempts: 1)
        // Guard: the conversation's own background must really be in this appearance, so a failed switch fails loudly.
        let navigation = app.navigationBars.firstMatch.frame
        let ground = pixels(app, in: CGRect(x: 0, y: navigation.maxY + 4, width: 12, height: 40)).sorted { luminance($0) < luminance($1) }
        guard !ground.isEmpty else { return }
        let groundLuminance = luminance(ground[ground.count / 2])
        if dark { XCTAssertLessThan(groundLuminance, 0.2, "The app must launch dark: background \(ground[ground.count / 2])") }
        else { XCTAssertGreaterThan(groundLuminance, 0.5, "The app must launch light: background \(ground[ground.count / 2])") }

        /// The editor's text row: its median is the field, its most distant pixel the glyphs.
        func assertReadable(_ what: String) {
            let field = pixels(app, in: composer.frame.insetBy(dx: 4, dy: 4)).sorted { luminance($0) < luminance($1) }
            guard !field.isEmpty else { return }
            let background = field[field.count / 2]
            let text = [field.first!, field.last!].max { contrast($0, background) < contrast($1, background) }!
            XCTAssertGreaterThanOrEqual(contrast(text, background), 4.5, "\(mode) \(what) \(text) on field \(background)")
            if dark { XCTAssertLessThan(luminance(background), 0.2, "The dark theme's field stays dark: \(background)") }
            else { XCTAssertGreaterThan(luminance(background), 0.5, "The light theme's field stays light: \(background)") }
        }
        XCTAssertEqual(composer.value as? String ?? "", "", "The empty field shows its prompt")
        capture(app, "\(mode) mode empty prompt")
        assertReadable("prompt")
        focus(composer, in: app)
        composer.typeText("Readable draft WWWWWWWW")
        capture(app, "\(mode) mode typed draft")
        assertReadable("typed text")
        guard dark else { return }
        let keyboard = pixels(app, in: app.keyboards.firstMatch.frame).sorted { luminance($0) < luminance($1) }
        guard !keyboard.isEmpty else { return }
        XCTAssertLessThan(luminance(keyboard[keyboard.count / 2]), 0.2, "Dark mode keeps the dark keyboard: \(keyboard[keyboard.count / 2])")
    }

    // Report 3277d430: ordinary Working editing keeps the draft full width above the action row.
    func testOrdinaryWorkingOneThroughEightLinesKeepFullWidthAndFit() throws {
        try ordinaryWorkingDraft(softWrap: false)
    }

    func testOrdinaryWorkingSoftWrappedDraftKeepsFullWidthAndFit() throws {
        try ordinaryWorkingDraft(softWrap: true)
    }

    func testPendingGrantEightLineDraftKeepsReviewAndComposerAboveKeyboard() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-working-composer",
                             "--companion-preview-grant-requests"], attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer, attempts: 1)
        focus(composer, in: app)
        let draft = (1...8).map { "Line \($0)" }.joined(separator: "\n")
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        try assertRow(app, working: true, state: "pending grant eight lines", editing: true)
        let snapshot = try layout(app)
        let review = app.buttons["companion-grant-review"]
        XCTAssertTrue(review.exists && review.isEnabled && review.isHittable)
        assertMinimumTarget(review, "Review")
        XCTAssertTrue(pixelContains(visibleRegion(snapshot), review.frame), "Review stays entirely above the keyboard")
        XCTAssertLessThanOrEqual(review.frame.maxY, try XCTUnwrap(snapshot["companion-composer-region"]).minY)
        for id in ["companion-level-menu", "companion-attach", "companion-interrupt", "companion-send"] {
            XCTAssertTrue(app.buttons[id].isEnabled && app.buttons[id].isHittable, id)
        }
        let close = app.buttons["companion-grant-review-close"]
        waitAndTap(review, until: close, attempts: 1)
        waitAndTap(close, untilGone: close, attempts: 1)
        XCTAssertEqual(composer.value as? String, draft, "Review keeps the entire draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        try assertRow(app, working: true, state: "pending grant after Review", editing: true)
    }

    private func ordinaryWorkingDraft(softWrap: Bool) throws {
        let app = launchApp(["--companion-preview", "--companion-preview-working-composer"], attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer, attempts: 1)
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "The pinned approval shares the space")
        XCTAssertFalse(app.scrollViews["companion-grant-footer-scroll"].exists, "No grants use the ordinary composer layout")
        XCTAssertTrue(app.buttons["companion-interrupt"].exists, "The fixture is Working before typing")
        XCTAssertEqual(composer.label, "Steering message")
        XCTAssertEqual(app.buttons["companion-send"].label, "Send steering message")
        XCTAssertFalse(app.buttons["companion-send"].isEnabled)
        focus(composer, in: app)
        XCTAssertFalse(app.buttons["companion-dismiss-keyboard"].exists, "Ordinary editing, not the assistive layout")
        var draft = "Line 1"
        composer.typeText(draft)
        var editorHeight = try XCTUnwrap(layout(app)["companion-composer"]).height

        /// One snapshot per state: the draft, the row below it, and the pinned approval all fit above the keyboard.
        func check(_ state: String, grows: Bool) throws {
            checkTimeLeft("checking the ordinary draft with \(state)")
            let snapshot = try layout(app)
            XCTAssertEqual(snapshot.values["companion-composer"], draft, state)
            let height = try XCTUnwrap(snapshot["companion-composer"], state).height
            if grows { XCTAssertGreaterThan(pixelAligned(height), pixelAligned(editorHeight), "\(state): the draft grows") }
            editorHeight = height
            try assertRow(app, working: true, state: "ordinary \(state)", editing: true)
        }

        if softWrap {
            let suffix = String(repeating: " steady detail", count: 12)
            composer.typeText(suffix); draft += suffix
            try check("soft wrapped", grows: true)
        } else {
            try check("1 line", grows: false)
            for count in 2...8 {
                let next = "\nLine \(count)"
                composer.typeText(next); draft += next
                try check("\(count) lines", grows: true)
            }
        }
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "The approval doesn't disappear to make space")
        // The pinned request itself, not just some approval: its text and each decision's enabled state.
        let approvals = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval needed: "))
        XCTAssertEqual(approvals.count, 1)
        let approval = approvals.firstMatch
        func pinned() -> [String] {
            [approval.label] + approval.staticTexts.allElementsBoundByIndex.map(\.label)
                + approval.buttons.allElementsBoundByIndex.map { "\($0.label): \($0.isEnabled ? "enabled" : "disabled")" }
        }
        let pinnedBefore = pinned()
        XCTAssertTrue(pinnedBefore.contains("Allow once: enabled") && pinnedBefore.contains("Deny: enabled"), "\(pinnedBefore)")

        // Opening Options keeps the whole draft and sends nothing.
        waitAndTap(app.buttons["companion-level-menu"], until: app.buttons["companion-permissions-menu"], attempts: 1)
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        try dismissChatControls(app, preferring: composer.frame)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(pinned(), pinnedBefore, "Options leaves the pinned request and its decisions unchanged")
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(composer.debugDescription.contains("Keyboard Focused"), "Dismissing Options inside the draft keeps editing")
        try assertRow(app, working: true, state: "ordinary after Options", editing: true)

        waitAndTap(app.buttons["companion-interrupt"], until: app.buttons["Interrupt turn"], attempts: 1)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        capture(app, "ordinary long draft confirmation")
        cancelInterruptConfirmation(app)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(pinned(), pinnedBefore, "Cancelling Interrupt leaves the pinned request and its decisions unchanged")
        if !app.keyboards.firstMatch.exists { focus(composer, in: app) }
        try assertRow(app, working: true, state: "ordinary after Cancel", editing: true)
    }
}
