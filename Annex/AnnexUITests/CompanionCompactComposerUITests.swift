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
        var labels: [String: String] = [:]
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
                result.labels[id] = node.label
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

    private func captureGeometry(_ layout: Layout, state: String) {
        let frames = layout.frames.keys.sorted().map { "\($0): \(layout.frames[$0]!)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "window: \(layout.window)\nnavigation: \(layout.navigation)\nkeyboard top: \(String(describing: layout.keyboardTop))\n\(frames)")
        attachment.name = "Compact composer geometry \(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The action row sits below the full-width draft, in order, with full targets and no overlaps.
    private func assertRow(_ app: XCUIApplication, working: Bool, state: String, editing: Bool = false,
                           dismissButton: Bool = false, reviewButton: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        capture(app, state)
        let layout = try layout(app)
        captureGeometry(layout, state: state)
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
            let tray = try XCTUnwrap(layout["companion-pinned-decision"])
            let reviewOnly = layout.values["companion-pinned-decision"] == "Review-only request controls"
            // #543: the fallback follows the product's own measured fit on every OS and device, never the screen width.
            // Collapse when the full rows + 2pt insets exceed the offered room; expand only with one caption line spare.
            let fitValue = try XCTUnwrap(layout.values["companion-pinned-decision-fit"], "\(state): fit metrics are exported", file: file, line: line)
            if let fitFrame = layout["companion-pinned-decision-fit"] {
                XCTAssertTrue(pixelContains(tray, fitFrame), "\(state): the metrics element stays inside the card: \(fitFrame) in \(tray)", file: file, line: line)
            }
            assertFitInvariant(reviewOnly: reviewOnly, Self.fitMetrics(fitValue), state: state, file: file, line: line)
            if reviewOnly {
                XCTAssertNil(layout["companion-decision-show-in-chat"], "\(state): one Review control replaces the rows", file: file, line: line)
                XCTAssertEqual(layout.labels["companion-review-approval"], "Review approval: Run xcodebuild, 1 of 2",
                               "\(state): VoiceOver keeps the full request title", file: file, line: line)
                XCTAssertEqual(layout.values["companion-review-approval"], "1 of 2 waiting · Bash",
                               "\(state): position and tool stay complete for VoiceOver", file: file, line: line)
            } else {
                let title = try XCTUnwrap(layout["companion-decision-show-in-chat"])
                XCTAssertTrue(pixelContains(region, title), "\(state): the title is not clipped by navigation or keyboard", file: file, line: line)
                let footerViewport = region.intersection(layout["companion-grant-footer-scroll"] ?? region)
                XCTAssertTrue(pixelContains(footerViewport, title), "\(state): the title is not clipped by its actual footer viewport", file: file, line: line)
                XCTAssertTrue(pixelContains(tray, title), "\(state): the entire title stays in its card", file: file, line: line)
                XCTAssertEqual(layout.values["companion-decision-show-in-chat"], "1 of 2 waiting · Bash",
                               "\(state): compact metadata stays complete for VoiceOver", file: file, line: line)
            }
            if editing, let keyboardTop = layout.keyboardTop {
                XCTAssertLessThanOrEqual(composerRegion.maxY, keyboardTop, "\(state): composer bottom stays above keyboard", file: file, line: line)
                XCTAssertGreaterThan(pixelAligned(keyboardTop - composerRegion.maxY), 0,
                                     "\(state): composer keeps a measured visible keyboard margin", file: file, line: line)
                XCTAssertLessThanOrEqual(tray.maxY, keyboardTop, "\(state): tray bottom stays above keyboard", file: file, line: line)
            }
            let review = try XCTUnwrap(layout["companion-review-approval"])
            XCTAssertTrue(pixelContains(region, review), "\(state): approval review stays visible", file: file, line: line)
            XCTAssertLessThanOrEqual(review.maxY, composerRegion.minY, "\(state): review stays above the composer", file: file, line: line)
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(pixelAligned(rect: review).height, 44, file: file, line: line)
            if editing, let keyboardTop = layout.keyboardTop {
                print("AX_COMPACT_GEOMETRY state=\(state) reviewOnly=\(reviewOnly) tray=\(tray) review=\(review) composer=\(composerRegion) keyboardTop=\(keyboardTop) clearance=\(keyboardTop - composerRegion.maxY)")
            }
        }
        XCTAssertEqual(layout["companion-interrupt"] != nil, working, "\(state): Interrupt shows only while Working", file: file, line: line)
        XCTAssertEqual(layout["companion-dismiss-keyboard"] != nil, dismissButton, "\(state): assistive dismiss", file: file, line: line)
        let options = try XCTUnwrap(layout["companion-level-menu"])
        let send = try XCTUnwrap(layout["companion-send"])
        XCTAssertEqual(options.width, options.height, accuracy: 1, "\(state): Options is a circle", file: file, line: line)
        let card = try XCTUnwrap(layout["companion-composer-card-bounds"])
        let bottomInset: CGFloat = layout.values["companion-composer-card-bounds"] == "Compact" ? 4 : 6
        for circle in [options, send] {
            XCTAssertLessThanOrEqual(pixelAligned(circle.maxY), pixelAligned(card.maxY - bottomInset),
                                     "\(state): circle clears the card bottom by \(bottomInset)pt", file: file, line: line)
        }
        let leadingInset = options.minX - card.minX
        let trailingInset = card.maxX - send.maxX
        XCTAssertGreaterThanOrEqual(leadingInset, 6, "\(state): Options clears the card edge", file: file, line: line)
        // The assistive keyboard action follows Send when present; otherwise the circles mirror each other.
        if !dismissButton {
            XCTAssertEqual(leadingInset, trailingInset, accuracy: 1, "\(state): equal Options/Send insets", file: file, line: line)
        }
        var previous: (id: String, frame: CGRect)?
        for id in ids {
            guard let frame = layout[id] else { XCTFail("\(state): \(id) must be exported", file: file, line: line); continue }
            let aligned = pixelAligned(rect: frame)
            XCTAssertGreaterThanOrEqual(aligned.width, 44, "\(state): \(id) width \(frame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(aligned.height, 44, "\(state): \(id) height \(frame)", file: file, line: line)
            XCTAssertTrue(pixelContains(composerRegion, frame), "\(state): \(id) stays in the composer: \(frame) in \(composerRegion), visible \(region)", file: file, line: line)
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
        dismissQuickPathIntroductionIfPresent(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.debugDescription.contains("Keyboard Focused"), "One tap focuses the draft")
    }

    /// A fresh isolated simulator can present this one-time system keyboard tutorial instead of the keys.
    /// Do not treat any other missing keyboard as onboarding or change simulator keyboard settings.
    private func dismissQuickPathIntroductionIfPresent(in app: XCUIApplication) {
        let introduction = app.descendants(matching: .any).matching(identifier: "UIContinuousPathIntroductionView").firstMatch
        if introduction.waitForExistence(timeout: 1) {
            let proceed = introduction.buttons["Continue"]
            XCTAssertTrue(proceed.waitForExistence(timeout: 3), "The exact QuickPath tutorial offers Continue")
            proceed.tap()
            XCTAssertTrue(introduction.waitForNonExistence(timeout: 3), "Continue dismisses only the QuickPath tutorial")
        }
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
        dismissQuickPathIntroductionIfPresent(in: app)
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

    /// Regression for #530: one native circle, current settings in AX, and effort in the pop-out menu.
    private func circleMenu(_ flags: [String], state: String) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags, attempts: 1)
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let options = app.buttons["companion-level-menu"]
        let send = app.buttons["companion-send"]
        assertMinimumTarget(options, "Chat controls")
        XCTAssertEqual(options.frame.width, options.frame.height, accuracy: 1, "An icon-only circle")
        XCTAssertTrue(options.staticTexts.allElementsBoundByIndex.isEmpty, "No visible model/access capsule")
        XCTAssertTrue(options.label.contains("Auto-accept edits") && options.label.contains("Opus"), options.label)
        XCTAssertTrue((options.value as? String ?? "").contains("High effort"))
        // Measure the actual glass card, independently of the editor's internal text padding.
        let bounds = element(app, "companion-composer-card-bounds")
        XCTAssertTrue(bounds.exists)
        let card = bounds.frame
        let bottomInset: CGFloat = bounds.value as? String == "Compact" ? 4 : 6
        for circle in [options.frame, send.frame] {
            XCTAssertLessThanOrEqual(pixelAligned(circle.maxY), pixelAligned(card.maxY - bottomInset),
                                     "The circle clears the card bottom by \(bottomInset)pt")
        }
        let leading = options.frame.minX - card.minX
        let trailing = card.maxX - send.frame.maxX
        XCTAssertGreaterThanOrEqual(leading, 6, "Options is inset from the composer card")
        XCTAssertEqual(leading, trailing, accuracy: 1, "Options and Send mirror each other's inset")
        capture(app, "circle \(state)")
        waitAndTap(options, until: app.buttons["companion-permissions-menu"], attempts: 1)
        XCTAssertTrue(app.buttons["companion-model-menu"].exists)
        let effort = app.buttons["companion-effort-menu"]
        XCTAssertTrue(effort.exists && effort.isEnabled)
        capture(app, "native controls menu \(state)")
        waitAndTap(effort, until: app.buttons["Low"], attempts: 1)
        capture(app, "effort choices \(state)")
        // Choosing effort uses the existing model command; merely opening menus sends nothing.
        let receipt = app.staticTexts["Preview only. This action does not contact a desktop."]
        XCTAssertFalse(receipt.exists)
        app.buttons["Low"].tap()
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    }

    func testCircleMenuLight() {
        circleMenu(["--companion-header-light"], state: "light")
    }

    func testCircleMenuDark() {
        circleMenu([], state: "dark")
    }

    func testCircleMenuAccessibilityXXXL() {
        circleMenu(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], state: "XXXL")
    }

    func testIdleControlsStayCollapsedBeforeAndAfterTyping() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-context-window"], attempts: 1)
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
        // The captured equal-edge case must pass, while a real display-pixel overflow must fail.
        let outer = CGRect(x: 16, y: 312, width: 370, height: 211.66668701171875)
        let target = CGRect(x: 16, y: 479.66666666666663, width: 166.33333333333331, height: 44)
        XCTAssertTrue(pixelContains(outer, target), "Equal pixel-rounded edges are contained")
        XCTAssertFalse(pixelContains(outer, target.offsetBy(dx: 0, dy: 1 / max(UIScreen.main.scale, 1))), "A real one-pixel overflow fails")
        try workingRow(largestText: true)
    }

    // MARK: #543 fit invariant, shared by every check and its negative controls

    struct FitMetrics {
        var natural: Double, offered: Double, caption: Double, measured: Bool, raw: String
    }

    /// Parses the DEBUG-only `companion-pinned-decision-fit` value: "natural=… offered=… caption=… measured=…".
    static func fitMetrics(_ raw: String) -> FitMetrics {
        let pairs = Dictionary(uniqueKeysWithValues: raw.split(separator: " ").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        })
        return FitMetrics(natural: Double(pairs["natural"] ?? "") ?? 0, offered: Double(pairs["offered"] ?? "") ?? 0,
                          caption: Double(pairs["caption"] ?? "") ?? 0, measured: pairs["measured"] == "true", raw: raw)
    }

    /// The product's own rule, with its hysteresis: collapse when the full rows + 2pt insets exceed the offered room;
    /// stay collapsed until one caption line of room is spare. So Review-only ⇒ natural + 2 > offered − caption,
    /// and full rows (when measured) ⇒ natural + 2 ≤ offered.
    static func fitInvariantFailures(reviewOnly: Bool, _ m: FitMetrics) -> [String] {
        if reviewOnly {
            if !m.measured { return ["Review-only without a measurement: \(m.raw)"] }
            if m.natural <= 0 { return ["Review-only before the full rows were measured: \(m.raw)"] }
            if !(m.natural + 2 > m.offered - m.caption) { return ["Review-only while the full rows fit: \(m.raw)"] }
        } else if m.measured, m.natural > 0, m.natural + 2 > m.offered {
            return ["Full rows shown that don't fit their offered room: \(m.raw)"]
        }
        return []
    }

    func assertFitInvariant(reviewOnly: Bool, _ m: FitMetrics, state: String, file: StaticString = #filePath, line: UInt = #line) {
        for failure in Self.fitInvariantFailures(reviewOnly: reviewOnly, m) {
            XCTFail("\(state): \(failure)", file: file, line: line)
        }
    }

    /// D2: both wrong states fail the shared assertion, deterministically and without the app; correct states pass.
    func testFitInvariantCatchesWronglyCollapsedAndWronglyFullTrays() {
        let fits = FitMetrics(natural: 100, offered: 140, caption: 20, measured: true, raw: "synthetic: rows fit")
        let tooTall = FitMetrics(natural: 120, offered: 117.33, caption: 20, measured: true, raw: "synthetic: rows don't fit")
        XCTAssertTrue(Self.fitInvariantFailures(reviewOnly: false, fits).isEmpty, "Full rows that fit pass")
        XCTAssertTrue(Self.fitInvariantFailures(reviewOnly: true, tooTall).isEmpty, "Review-only for rows that don't fit passes")
        let strict = XCTExpectedFailure.Options()
        strict.isStrict = true
        XCTExpectFailure("A wrongly collapsed tray must fail the invariant", options: strict) {
            assertFitInvariant(reviewOnly: true, fits, state: "synthetic wrongly collapsed")
        }
        XCTExpectFailure("A wrongly full tray must fail the invariant", options: strict) {
            assertFitInvariant(reviewOnly: false, tooTall, state: "synthetic wrongly full")
        }
    }

    /// D1 + independence: in the typed-focused AX state, force each tray state (DEBUG launch arguments; measurement is
    /// unaffected). The forced state that contradicts the measured fit must fail the invariant (strict expected failure);
    /// the one that agrees must pass. The forced-full launch also checks the product's numbers against XCUI geometry.
    func testForcedTrayStatesAreCaughtAndFitMetricsMatchRenderedGeometry() throws {
        var sawWrong = false
        var bandMetrics: [String] = []
        for forced in ["--companion-ui-test-force-full-rows", "--companion-ui-test-force-review-only"] {
            let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard", "--companion-sample-images",
                                 "--companion-ui-test-fit-metrics", forced,
                                 "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], attempts: 1)
            // Caught (expected) failures must not stop the remaining checks.
            continueAfterFailure = true
            let river = element(app, "agent-preview-studio-river")
            XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
            let composer = element(app, "companion-composer")
            waitAndTap(river, until: composer, attempts: 1)
            waitAndTap(app.buttons["companion-attach"], until: element(app, "companion-attachment-thumbnail"), attempts: 1)
            focus(composer, in: app)
            composer.typeText("Keep this direction")
            let state = "forced \(forced)"
            capture(app, state)
            let layout = try layout(app)
            captureGeometry(layout, state: state)
            let keyboardTop = try XCTUnwrap(layout.keyboardTop, "\(state): keyboard")
            let tray = try XCTUnwrap(layout["companion-pinned-decision"], "\(state): tray")
            let composerRegion = try XCTUnwrap(layout["companion-composer-region"], "\(state): composer")
            let footer = try XCTUnwrap(layout["companion-grant-footer-scroll"], "\(state): footer")
            let m = Self.fitMetrics(try XCTUnwrap(layout.values["companion-pinned-decision-fit"], "\(state): metrics"))
            XCTAssertTrue(m.measured && m.natural > 0, "\(state): measured: \(m.raw)")
            let reviewOnly = layout.values["companion-pinned-decision"] == "Review-only request controls"
            XCTAssertEqual(reviewOnly, forced == "--companion-ui-test-force-review-only", "\(state): the forced state is shown")
            if !reviewOnly {
                // Independence: the rendered tight card is the full rows + 1pt insets; the composer block runs from the
                // card's bottom (no outer inset under tight rows) to the composer's content bottom + its 10pt padding.
                let naturalRendered = Double(tray.height) - 2
                XCTAssertEqual(m.natural, naturalRendered, accuracy: 2, "\(state): natural matches the rendered rows: \(m.raw) tray=\(tray)")
                let composerBlock = Double(composerRegion.maxY + 10 - tray.maxY)
                let visibleFooter = Double(keyboardTop - footer.minY)
                let content = Double(composerRegion.maxY + 10 - tray.minY)
                let offeredRendered = visibleFooter - composerBlock
                if content >= visibleFooter - 0.5 {
                    // The footer is at its maximum (its content overflows), so the room it offers is observable.
                    XCTAssertEqual(m.offered, offeredRendered, accuracy: 2,
                                   "\(state): offered matches XCUI geometry (footer at max): \(m.raw) visible=\(visibleFooter) composerBlock=\(composerBlock)")
                    let fitsRendered = naturalRendered + 2 <= offeredRendered
                    if abs((naturalRendered + 2) - offeredRendered) > 2 {
                        XCTAssertEqual(fitsRendered, m.natural + 2 <= m.offered,
                                       "\(state): the independent fit agrees with the product's: rendered \(naturalRendered)+2 vs \(offeredRendered); \(m.raw)")
                    }
                } else {
                    // Footer below its maximum: the observed room is only a LOWER BOUND for the offered room.
                    XCTAssertGreaterThanOrEqual(m.offered, offeredRendered - 2,
                                                "\(state): offered is at least the observed room (LOWER BOUND only; footer not at max): \(m.raw) observed=\(offeredRendered)")
                }
            }
            let wrong = reviewOnly ? !(m.natural + 2 > m.offered - m.caption) : m.natural + 2 > m.offered
            print("FIT_NEGATIVE_CONTROL \(state) reviewOnly=\(reviewOnly) wrong=\(wrong) \(m.raw)")
            bandMetrics.append("\(state): \(m.raw)")
            if wrong {
                sawWrong = true
                let strict = XCTExpectedFailure.Options()
                strict.isStrict = true
                XCTExpectFailure("\(state) contradicts the measured fit and must be caught", options: strict) {
                    assertFitInvariant(reviewOnly: reviewOnly, m, state: state)
                }
            } else {
                assertFitInvariant(reviewOnly: reviewOnly, m, state: state)
            }
            app.terminate()
        }
        // Inside the hysteresis band (offered − caption < natural + 2 ≤ offered) both forced states are legitimate, so
        // nothing on this device can be shown to be caught: record that as a skip with the metrics, never a silent pass.
        if !sawWrong {
            // Cross-check failures must stand: never convert a failed run into a skip.
            if (testRun?.totalFailureCount ?? 0) > 0 { return }
            throw XCTSkip("Measured fit is inside the hysteresis band; no forced state contradicts it on this device: \(bandMetrics.joined(separator: "; "))")
        }
        XCTAssertTrue(sawWrong, "At least one forced state contradicted the measured fit")
    }

    private func workingRow(largestText: Bool) throws {
        let app = launchApp(["--companion-preview", "--companion-preview-assistive-keyboard", "--companion-sample-images", "--companion-ui-test-fit-metrics"]
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
        XCTAssertTrue(app.scrollViews["companion-grant-footer-scroll"].exists, "Approvals reuse the combined request/composer layout")
        XCTAssertFalse(element(app, "companion-chat-grant-requests").exists, "No Clubhouse grant card is fabricated")
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
            captureGeometry(snapshot, state: "ordinary \(state) before growth check")
            XCTAssertNotNil(snapshot["companion-pinned-decision"], "\(state): growth is measured with the decision still pinned")
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
        let review = app.buttons["companion-review-approval"]
        if !app.buttons["Deny"].exists || !app.buttons["Allow once"].exists {
            XCTAssertTrue(review.isEnabled && review.isHittable, "The bounded approval stays reachable beside the long draft")
            assertMinimumTarget(review, "Review")
            let close = app.buttons["companion-approval-review-close"]
            waitAndTap(review, until: close, attempts: 1)
            let viewport = app.scrollViews["companion-approval-review-scroll"]
            XCTAssertTrue(viewport.buttons["Deny"].isEnabled && viewport.buttons["Allow once"].isEnabled)
            waitAndTap(close, untilGone: close, attempts: 1)
            XCTAssertEqual(composer.value as? String, draft, "Review preserves the entire draft")
            if !app.keyboards.firstMatch.exists { focus(composer, in: app) }
        } else {
            XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "The approval doesn't disappear to make space")
        }
        // The pinned request itself, not just some approval: its text and each decision's enabled state.
        let approvals = app.otherElements.matching(identifier: "companion-pinned-decision")
        XCTAssertEqual(approvals.count, 1)
        let approval = approvals.firstMatch
        func pinned() -> [String] {
            [approval.label] + approval.staticTexts.allElementsBoundByIndex.map(\.label)
                + approval.buttons.allElementsBoundByIndex.map { "\($0.label): \($0.isEnabled ? "enabled" : "disabled")" }
        }
        let pinnedBefore = pinned()
        XCTAssertTrue(
            app.buttons["Deny"].exists && app.buttons["Allow once"].exists
                ? pinnedBefore.contains("Allow once: enabled") && pinnedBefore.contains("Deny: enabled")
                : review.isEnabled,
            "\(pinnedBefore)"
        )

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
