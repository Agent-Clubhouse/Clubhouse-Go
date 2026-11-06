import XCTest

/// Synthetic full conversation UI screenshots; RootView/tab integration has separate coverage.
@MainActor final class CompanionChatHeaderVisualUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags, attempts: 1)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // These are synthetic-only test attachments. Original feedback captures never enter the test bundle.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Header synthetic \(Int(app.frame.width))pt — \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func focus(_ app: XCUIApplication) {
        let composer = element(app, "companion-composer")
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3)); show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        composer.typeText("Synthetic header draft")
    }

    private func unique(_ app: XCUIApplication, _ id: String) throws -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: id)
        XCTAssertEqual(matches.count, 1, "Exactly one exported \(id)")
        guard matches.count == 1 else { throw HeaderGeometryFailure.invalid }
        return matches.firstMatch
    }

    private enum HeaderGeometryFailure: Error { case invalid }

    private func finite(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    /// Keyboard keys alone omit the system assistant row. Include every on-screen public
    /// inputView/assistant frame conservatively; an invalid/disjoint occluder fails this test.
    private func editingRegion(_ app: XCUIApplication) throws -> (content: CGRect, navigation: CGRect) {
        XCTAssertEqual(app.keyboards.count, 1)
        XCTAssertEqual(app.navigationBars.count, 1)
        guard app.keyboards.count == 1, app.navigationBars.count == 1 else { throw HeaderGeometryFailure.invalid }
        let window = app.frame, navigation = app.navigationBars.firstMatch.frame
        let keyboard = app.keyboards.firstMatch.frame.intersection(window)
        XCTAssertTrue(finite(window) && finite(navigation) && finite(keyboard))
        guard finite(window), finite(navigation), finite(keyboard) else { throw HeaderGeometryFailure.invalid }
        var bottom = keyboard.minY
        for id in ["inputView", "SystemInputAssistantView"] {
            for candidate in app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex {
                let frame = candidate.frame
                XCTAssertTrue(finite(frame), "Invalid \(id): \(frame)")
                guard finite(frame) else { throw HeaderGeometryFailure.invalid }
                let occlusion = frame.intersection(window)
                if occlusion.isNull || occlusion.isEmpty { continue }
                // Assistant and input container must join/overlap the actual keyboard, not
                // be an unrelated exported object elsewhere in the application.
                let joined = occlusion.maxY >= keyboard.minY && occlusion.minY <= keyboard.maxY
                    && occlusion.maxX > keyboard.minX && occlusion.minX < keyboard.maxX
                XCTAssertTrue(joined, "Ambiguous keyboard accessory: \(id), \(occlusion), keyboard \(keyboard)")
                guard joined else { throw HeaderGeometryFailure.invalid }
                bottom = min(bottom, occlusion.minY)
            }
        }
        let top = max(window.minY, navigation.maxY)
        let content = CGRect(x: window.minX, y: top, width: window.width, height: bottom - top)
        XCTAssertTrue(finite(content), "No positive nav-to-full-input region: \(content)")
        guard finite(content) else { throw HeaderGeometryFailure.invalid }
        return (content, navigation)
    }

    /// This is geometry/focus evidence for this synthetic state, not VoiceOver traversal proof.
    private func assertEditingViewport(_ app: XCUIApplication, expanded: Bool, largeText: Bool) throws -> CGRect? {
        let region = try editingRegion(app)
        let editor = try unique(app, "companion-composer")
        XCTAssertEqual(editor.value as? String, "Synthetic header draft")
        XCTAssertTrue(editor.debugDescription.contains("Keyboard Focused"), "Expansion/navigation must not end field focus")
        XCTAssertTrue(editor.isEnabled && editor.isHittable)
        XCTAssertTrue(finite(editor.frame) && region.content.contains(editor.frame), "Editor \(editor.frame), region \(region.content)")
        XCTAssertGreaterThanOrEqual(editor.frame.width, largeText ? app.frame.width * 0.7 : 44)
        let buttons = ["companion-level-menu", "companion-attach", "companion-interrupt", "companion-send"]
        var composerTop = editor.frame.minY
        for id in buttons {
            let button = try unique(app, id)
            XCTAssertTrue(button.isEnabled && button.isHittable, id)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
            XCTAssertTrue(region.content.contains(button.frame), "\(id): \(button.frame), region \(region.content)")
            composerTop = min(composerTop, button.frame.minY)
        }
        for id in ["companion-chat-header", "companion-context-usage"] {
            let button: XCUIElement
            if id == "companion-context-usage" {
                // Toolbar wrappers can share an identifier; the interaction contract is one Button.
                let controls = app.buttons.matching(identifier: id)
                XCTAssertEqual(controls.count, 1, "Exactly one actionable context Button")
                guard controls.count == 1 else { throw HeaderGeometryFailure.invalid }
                button = controls.element(boundBy: 0)
                XCTAssertEqual(button.label, "Context and plan limits")
                XCTAssertEqual(button.value as? String, "Latest reported context: 28% full")
            } else {
                button = try unique(app, id)
            }
            XCTAssertTrue(button.isEnabled && button.isHittable, id)
            XCTAssertTrue(region.navigation.contains(button.frame), "\(id) must stay in navigation: \(button.frame), \(region.navigation)")
        }
        guard expanded else {
            XCTAssertFalse(element(app, "companion-chat-details-viewport").exists)
            return nil
        }
        _ = try unique(app, "companion-chat-details") // Both natural and scroll paths expose one card root.
        let viewport = try unique(app, "companion-chat-details-viewport")
        XCTAssertEqual(viewport.label, "Synthetic header details viewport")
        XCTAssertTrue(finite(viewport.frame) && region.content.contains(viewport.frame), "Details viewport \(viewport.frame), region \(region.content)")
        XCTAssertLessThanOrEqual(viewport.frame.maxY, composerTop, "Disclosure must not cover any composer control")
        // Three rectangles: original raw frame, diagnostic inset-derived frame, used frame.
        // Inherited insets may yield zero diagnostic height; they are not subtracted twice.
        let values = (viewport.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 12, "Missing raw/inset-derived/used residual geometry witness")
        guard values.count == 12 else { throw HeaderGeometryFailure.invalid }
        let reported = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let insetDerived = CGRect(x: values[4], y: values[5], width: values[6], height: values[7])
        let used = CGRect(x: values[8], y: values[9], width: values[10], height: values[11])
        XCTContext.runActivity(named: "Header residual raw \(reported), inset-derived \(insetDerived), used \(used)") { _ in }
        XCTAssertTrue(values.allSatisfy(\.isFinite), "All diagnostic coordinates must remain finite")
        XCTAssertGreaterThanOrEqual(insetDerived.width, 0)
        XCTAssertGreaterThanOrEqual(insetDerived.height, 0)
        XCTAssertTrue(finite(reported) && finite(used) && reported.contains(used))
        XCTAssertTrue(region.content.contains(used), "Used residual must exclude navigation and all input occlusion: \(used), \(region.content)")
        XCTAssertLessThanOrEqual(used.maxY, composerTop, "Used boundary must already reserve the bottom bar")
        XCTAssertTrue(used.contains(viewport.frame), "Disclosure \(viewport.frame) must stay in used residual \(used)")
        return viewport.frame
    }

    /// The unchanged SwiftUI Label exports one image and one text node in retained evidence.
    /// Verify that exact composite under the unique product card; never choose an arbitrary match.
    private func permissionsFrame(_ app: XCUIApplication, label: String) throws -> CGRect {
        let id = "companion-header-level"
        let card = try unique(app, "companion-chat-details")
        let all = app.descendants(matching: .any).matching(identifier: id)
        let images = app.images.matching(identifier: id), texts = app.staticTexts.matching(identifier: id)
        let cardImages = card.images.matching(identifier: id), cardTexts = card.staticTexts.matching(identifier: id)
        let counts = [all.count, images.count, texts.count, cardImages.count, cardTexts.count]
        let countDescription = "globalAny/Image/Text/cardImage/cardText=\(counts)"
        func evidence(_ reason: String) {
            // Public evidence only, never parsed for selection. Cap output; SDK retrieval itself
            // is not caller-bounded and remains under the existing test allowance.
            let details = "\(reason)\n\(countDescription)\nMatches:\n\(all.debugDescription)\nCard ancestry:\n\(card.debugDescription)\nApplication:\n\(app.debugDescription)"
            let bytes = Array(details.utf8)
            let capped = bytes.count <= 65536 ? details
                : String(decoding: bytes.prefix(65480), as: UTF8.self) + "\n[truncated]"
            let attachment = XCTAttachment(string: capped)
            attachment.name = "Header permissions composite public evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTContext.runActivity(named: "Permissions composite cardinality — \(countDescription)") { _ in }
        let shape = counts == [2, 1, 1, 1, 1]
        if !shape { evidence("Invalid permissions role/card ancestry shape") }
        XCTAssertTrue(shape, "Permissions require exactly one Image and one StaticText globally and under the unique card: \(countDescription)")
        guard shape else { throw HeaderGeometryFailure.invalid }
        let image = cardImages.element(boundBy: 0), text = cardTexts.element(boundBy: 0)
        let imageLabel = image.label, textLabel = text.label
        let imageFrame = image.frame, textFrame = text.frame
        let union = imageFrame.union(textFrame)
        let diagnostic = "Image type=\(image.elementType), label=\(imageLabel), frame=\(imageFrame); Text type=\(text.elementType), label=\(textLabel), frame=\(textFrame); union=\(union)"
        XCTContext.runActivity(named: "Permissions composite geometry — \(diagnostic)") { _ in }
        let valid = imageLabel == label && textLabel == label && finite(imageFrame) && finite(textFrame) && finite(union)
        if !valid { evidence(diagnostic) }
        XCTAssertEqual(imageLabel, label)
        XCTAssertEqual(textLabel, label)
        XCTAssertTrue(finite(imageFrame) && finite(textFrame) && finite(union), diagnostic)
        guard valid else { throw HeaderGeometryFailure.invalid }
        return union
    }

    /// Traverse only the bounded details scroll. Track coverage of each full metadata label,
    /// allowing a multiline title taller than the viewport to be read over multiple positions.
    /// Sixteen is a finite navigation budget, never a repeated tap or focus/launch rescue.
    private func inspectMetadata(_ app: XCUIApplication, longName: Bool) throws {
        let expected = [
            ("companion-chat-details-name", longName ? "Alexandria — release coordination and simulator validation" : "Header worker"),
            ("companion-chat-host-tag", "Studio Mac / Header fixture"),
            ("companion-chat-details-status", "Working"),
            ("free-agent-badge", "Free Agent Mode: all permissions bypassed"),
            ("companion-header-level", "Permissions: Auto-accept edits"),
            ("companion-chat-details-model", "Opus")
        ]
        var coverage: [String: [(CGFloat, CGFloat)]] = [:]
        var heights: [String: CGFloat] = [:]
        func complete(_ id: String) -> Bool {
            guard let height = heights[id], let spans = coverage[id]?.sorted(by: { $0.0 < $1.0 }), !spans.isEmpty else { return false }
            var end: CGFloat = 0
            for span in spans {
                if span.0 > end { return false }
                end = max(end, span.1)
            }
            return end >= height
        }
        for step in 0...16 {
            guard let viewport = try assertEditingViewport(app, expanded: true, largeText: longName) else { throw HeaderGeometryFailure.invalid }
            // The viewport includes bottom6 padding; the native scroll frame is the content clip.
            let scrolls = app.scrollViews.matching(identifier: "companion-chat-details-scroll")
            XCTAssertLessThanOrEqual(scrolls.count, 1)
            guard scrolls.count <= 1 else { throw HeaderGeometryFailure.invalid }
            let visible = scrolls.count == 1 ? viewport.intersection(scrolls.firstMatch.frame) : viewport
            XCTAssertTrue(finite(visible))
            guard finite(visible) else { throw HeaderGeometryFailure.invalid }
            for (id, label) in expected {
                let frame: CGRect
                if id == "companion-header-level" {
                    frame = try permissionsFrame(app, label: label)
                } else {
                    let leaf = try unique(app, id)
                    XCTAssertEqual(leaf.label, label)
                    frame = leaf.frame
                }
                XCTAssertTrue(finite(frame), id)
                guard finite(frame) else { throw HeaderGeometryFailure.invalid }
                if let height = heights[id] { XCTAssertEqual(frame.height, height, "Metadata must not shrink while navigating") }
                heights[id] = frame.height
                let slice = frame.intersection(visible)
                if !slice.isNull && !slice.isEmpty && frame.minX >= visible.minX && frame.maxX <= visible.maxX {
                    coverage[id, default: []].append((max(0, slice.minY - frame.minY), min(frame.height, slice.maxY - frame.minY)))
                }
            }
            if expected.allSatisfy({ complete($0.0) }) {
                // Natural fit has no gratuitous empty cap; scrolling content has a separate viewport.
                if scrolls.count == 0 {
                    let card = try unique(app, "companion-chat-details")
                    XCTAssertEqual(viewport.height, card.frame.height + 6, accuracy: 1)
                }
                return
            }
            guard step < 16, scrolls.count == 1 else {
                XCTFail("Full metadata was not traversable in the bounded details viewport: \(coverage)")
                throw HeaderGeometryFailure.invalid
            }
            let gesture = visible.insetBy(dx: 8, dy: 8)
            guard finite(gesture), gesture.height > 2 else {
                XCTFail("Details viewport has no usable bounded gesture region")
                throw HeaderGeometryFailure.invalid
            }
            let start = CGPoint(x: gesture.midX, y: gesture.maxY - 1)
            let end = CGPoint(x: gesture.midX, y: gesture.minY + 1)
            XCTAssertTrue(visible.contains(start) && visible.contains(end) && app.frame.contains(start) && app.frame.contains(end))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY))
            XCTContext.runActivity(named: "Header details navigation \(step + 1): \(visible), \(start) → \(end)") { _ in
                from.press(forDuration: 0.05, thenDragTo: to)
            }
            capture(app, "metadata navigation \(step + 1), long name \(longName)")
            // No wait, focus gesture, or generic scroll helper repairs a failed post-navigation state.
        }
    }

    func testDarkWorkingKeyboardDownAndUp() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["companion-chat-activity"].exists)
        XCTAssertFalse(element(app, "companion-chat-details").exists)
        capture(app, "dark Working keyboard down")
        tapChatStatusBar(in: app)
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker 1.")).firstMatch
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 5), "Native top must reach the oldest fixture entry")
        capture(app, "dark Working native top keyboard down")
        focus(app)
        capture(app, "dark Working keyboard up")
        _ = try assertEditingViewport(app, expanded: false, largeText: false)
        waitAndTap(app.buttons["companion-chat-header"], until: element(app, "companion-chat-details"), attempts: 1)
        capture(app, "dark Working expanded keyboard up")
        try inspectMetadata(app, longName: false)
        waitAndTap(app.buttons["companion-chat-header"], untilGone: element(app, "companion-chat-details"), attempts: 1)
        capture(app, "dark Working collapsed again keyboard up")
        _ = try assertEditingViewport(app, expanded: false, largeText: false)
    }

    func testLightLongNameAccessibilityExpandedWithKeyboard() throws {
        let app = launch(["--companion-header-light", "--companion-header-long-name",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        focus(app)
        capture(app, "light AX Large long name collapsed before expansion keyboard up")
        _ = try assertEditingViewport(app, expanded: false, largeText: true)
        let details = element(app, "companion-chat-details")
        waitAndTap(app.buttons["companion-chat-header"], until: details, attempts: 1)
        capture(app, "light AX Large long name expanded keyboard up")
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(app.buttons["companion-context-usage"].isHittable)
        try inspectMetadata(app, longName: true)
        waitAndTap(app.buttons["companion-chat-header"], untilGone: details, attempts: 1)
        capture(app, "light AX Large long name collapsed keyboard up")
        _ = try assertEditingViewport(app, expanded: false, largeText: true)
    }

    func testIdleFallbackCustomImageVersionAndContextQuota() {
        let app = launch(["--companion-header-idle"])
        XCTAssertFalse(app.staticTexts["companion-chat-activity"].exists)
        capture(app, "idle fallback")
        for version in 1...2 {
            waitAndTap(app.buttons["header-fixture-menu"], until: app.buttons["header-fixture-image"], attempts: 1)
            waitAndTap(app.buttons["header-fixture-image"], untilGone: app.buttons["header-fixture-image"], attempts: 1)
            XCTAssertTrue(waitFor(app.buttons["header-fixture-menu"],
                                  NSPredicate(format: "value == %@", "Synthetic profile image version \(version)"), timeout: 5))
            capture(app, "idle synthetic custom image version \(version)")
        }
        waitAndTap(app.buttons["companion-context-usage"], until: element(app, "companion-context-reading-note"), attempts: 1)
        capture(app, "context editor with desktop quota route")
        waitAndTap(app.buttons["companion-context-plan-limits"], until: app.navigationBars["Plan limits"], attempts: 1)
        XCTAssertTrue(element(app, "plan-limits-preview-studio-claude-code").waitForExistence(timeout: 10))
        capture(app, "desktop plan limits")
    }
}
