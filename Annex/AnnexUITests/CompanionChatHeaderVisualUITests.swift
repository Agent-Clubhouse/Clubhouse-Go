import XCTest

/// Synthetic full conversation UI screenshots; RootView/tab integration has separate coverage.
@MainActor final class CompanionChatHeaderVisualUITests: ReliableUITestCase {
    private let draft = "Synthetic header draft"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags, attempts: 1)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Synthetic fixture screenshots only.
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
        composer.typeText(draft)
    }

    /// Between the navigation bar and the top of the keyboard, including its assistant row.
    private func editingRegion(_ app: XCUIApplication) -> (content: CGRect, navigation: CGRect) {
        let window = app.frame, navigation = app.navigationBars.firstMatch.frame
        var bottom = app.keyboards.firstMatch.frame.minY
        let assistant = app.descendants(matching: .any).matching(identifier: "SystemInputAssistantView").firstMatch
        if assistant.exists, assistant.frame.intersects(window) { bottom = min(bottom, assistant.frame.minY) }
        let top = max(window.minY, navigation.maxY)
        return (CGRect(x: window.minX, y: top, width: window.width, height: bottom - top), navigation)
    }

    /// Editing keeps the draft, every composer action and the header controls usable. Returns the composer's top.
    @discardableResult
    private func assertEditingLayout(_ app: XCUIApplication, largeText: Bool) -> CGFloat {
        let region = editingRegion(app)
        let editor = element(app, "companion-composer")
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertTrue(editor.debugDescription.contains("Keyboard Focused"), "Expanding details must not end editing")
        XCTAssertTrue(editor.isHittable)
        XCTAssertTrue(pixelContains(region.content, editor.frame), "Editor \(editor.frame), region \(region.content)")
        XCTAssertGreaterThanOrEqual(editor.frame.width, largeText ? app.frame.width * 0.7 : 44)
        var composerTop = editor.frame.minY
        for id in ["companion-level-menu", "companion-attach", "companion-interrupt", "companion-send"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isEnabled && button.isHittable, id)
            assertMinimumTarget(button, id)
            XCTAssertTrue(pixelContains(region.content, button.frame), "\(id): \(button.frame), region \(region.content)")
            composerTop = min(composerTop, button.frame.minY)
        }
        let context = app.buttons["companion-context-usage"]
        XCTAssertEqual(context.label, "Context and plan limits")
        XCTAssertEqual(context.value as? String, "Latest reported context: 28% full")
        for button in [app.buttons["companion-chat-header"], context] {
            XCTAssertTrue(button.isHittable, button.identifier)
            assertMinimumTarget(button, button.identifier)
            XCTAssertTrue(pixelContains(region.navigation, button.frame), "\(button.identifier) stays in navigation: \(button.frame)")
        }
        return composerTop
    }

    /// Every detail is reachable inside the disclosure, which stays between the navigation bar and the composer.
    private func assertDetails(_ app: XCUIApplication, longName: Bool, composerTop: CGFloat) {
        let card = element(app, "companion-chat-details")
        XCTAssertTrue(card.exists)
        let scroll = app.scrollViews["companion-chat-details-scroll"]
        let region = editingRegion(app)
        XCTAssertGreaterThanOrEqual(pixelAligned(card.frame.minY), pixelAligned(region.navigation.maxY), "Details start below the navigation bar")
        // Like the transcript, the details scroll view extends up under the navigation bar; what's readable is below it.
        let belowNavigation = CGRect(x: app.frame.minX, y: region.navigation.maxY, width: app.frame.width,
                                     height: app.frame.maxY - region.navigation.maxY)
        let clip = (scroll.exists ? scroll.frame : card.frame).intersection(belowNavigation)
        XCTAssertFalse(clip.isNull || clip.isEmpty, "Details have a visible region: \(clip)")
        XCTAssertLessThanOrEqual(pixelAligned(clip.maxY), pixelAligned(composerTop), "Details must not cover the composer")
        let expected = [
            ("companion-chat-details-name", longName ? "Alexandria — release coordination and simulator validation" : "Header worker"),
            ("companion-chat-host-tag", "Studio Mac / Header fixture"),
            ("companion-chat-details-status", "Working"),
            ("companion-header-level", "Permissions: Auto-accept edits"),
            ("companion-chat-details-model", "Opus"),
        ]
        // A known live level is the one Access badge; the Auto-or-Full boolean doesn't add a second.
        XCTAssertFalse(element(app, "elevated-access-badge").exists)
        for (id, label) in expected {
            let leaf = card.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertEqual(leaf.label, label, id)
            // The details scroll within their cap; each line must be reachable there. A line taller than the cap
            // (a long name at accessibility sizes) is read across scroll positions, so it only needs to be in view.
            func visible() -> Bool {
                let frame = leaf.frame
                let tall = pixelAligned(frame.height) > pixelAligned(clip.height)
                return leaf.isHittable && (tall ? clip.intersects(frame) : pixelContains(clip, frame))
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            func point(_ fraction: CGFloat) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: clip.midX - app.frame.minX, dy: clip.minY + clip.height * fraction - app.frame.minY))
            }
            var swipes = 0
            while swipes < 8, scroll.exists, !visible() {
                // A short drag inside the visible details toward the line, held at the end so it doesn't fling past.
                let above = leaf.frame.maxY <= clip.minY
                point(above ? 0.3 : 0.7).press(forDuration: 0.05, thenDragTo: point(above ? 0.7 : 0.3),
                                               withVelocity: .slow, thenHoldForDuration: 0.3)
                swipes += 1
            }
            XCTAssertTrue(visible(), "\(id) is reachable in the details: \(leaf.frame), clip \(clip)")
        }
    }

    func testDarkWorkingKeyboardDownAndUp() {
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
        let composerTop = assertEditingLayout(app, largeText: false)
        waitAndTap(app.buttons["companion-chat-header"], until: element(app, "companion-chat-details"), attempts: 1)
        capture(app, "dark Working expanded keyboard up")
        assertDetails(app, longName: false, composerTop: composerTop)
        assertEditingLayout(app, largeText: false)
        waitAndTap(app.buttons["companion-chat-header"], untilGone: element(app, "companion-chat-details"), attempts: 1)
        capture(app, "dark Working collapsed again keyboard up")
        assertEditingLayout(app, largeText: false)
    }

    func testLightLongNameAccessibilityExpandedWithKeyboard() {
        let app = launch(["--companion-header-light", "--companion-header-long-name",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        focus(app)
        capture(app, "light AX Large long name collapsed keyboard up")
        let composerTop = assertEditingLayout(app, largeText: true)
        let details = element(app, "companion-chat-details")
        waitAndTap(app.buttons["companion-chat-header"], until: details, attempts: 1)
        capture(app, "light AX Large long name expanded keyboard up")
        assertDetails(app, longName: true, composerTop: composerTop)
        capture(app, "light AX Large long name details scrolled")
        assertEditingLayout(app, largeText: true)
        waitAndTap(app.buttons["companion-chat-header"], untilGone: details, attempts: 1)
        capture(app, "light AX Large long name collapsed keyboard up")
        assertEditingLayout(app, largeText: true)
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
