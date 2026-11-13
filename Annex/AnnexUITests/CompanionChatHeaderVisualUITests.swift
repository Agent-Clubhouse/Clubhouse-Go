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

    func testOfflineHeaderKeepsFloatingGlassInLightAndDark() {
        recoveryAppearance("--companion-header-offline", title: "Offline")
    }

    func testReconnectingHeaderKeepsFloatingGlassInLightAndDark() {
        recoveryAppearance("--companion-header-reconnecting", title: "Reconnecting…")
    }

    func testRefreshRequiredHeaderKeepsFloatingGlassInLightAndDark() {
        for light in [false, true] {
            let app = launch(light ? ["--companion-header-light"] : [])
            waitAndTap(app.buttons["header-fixture-menu"], until: app.buttons["header-fixture-refresh"], attempts: 1)
            app.buttons["header-fixture-refresh"].tap()
            XCTAssertTrue(app.staticTexts["Conversation needs a refresh"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["companion-recovery-retry"].isHittable)
            capture(app, "\(light ? "light" : "dark") refresh required")
        }
    }

    private func recoveryAppearance(_ flag: String, title: String) {
        for light in [false, true] {
            let app = launch([flag] + (light ? ["--companion-header-light"] : []))
            let status = app.staticTexts[title]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            capture(app, "\(light ? "light" : "dark") \(title)")
            XCTAssertTrue(app.buttons["companion-recovery-details"].isHittable)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Recovery \(title) hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
    }

    func testLongIdentityIsScreenCenteredAndClearsBothSides() {
        for light in [false, true] {
            let app = launch(["--companion-header-long-name"] + (light ? ["--companion-header-light"] : []))
            capture(app, "\(light ? "light" : "dark") long identity centered")
            let identity = app.buttons["companion-chat-header"].frame
            let context = app.buttons["companion-context-usage"].frame
            let leading = app.buttons["header-fixture-menu"].frame
            XCTAssertGreaterThan(identity.width, 100, "The centered pill retains readable name space, not just an ellipsis")
            XCTAssertEqual(identity.midX, app.frame.midX, accuracy: 1, "The identity centers on the screen, not the remaining toolbar space")
            XCTAssertLessThanOrEqual(identity.maxX + 4, context.minX)
            XCTAssertGreaterThanOrEqual(identity.minX - 4, leading.maxX)
            XCTAssertTrue(app.buttons["companion-chat-header"].label.contains("Alexandria"))
            app.buttons["companion-chat-header"].tap()
            XCTAssertEqual(element(app, "companion-chat-details-name").label, "Alexandria — release coordination and simulator validation")
        }
    }

    /// The header avatar keeps the canonical identity colour (the fixture's indigo, #6366f1) in either appearance:
    /// glass must not restyle it. The 50pt photo is centred at the top of the identity control; sampled inside it,
    /// left of the initial and clear of the status dot.
    private func assertAvatarColour(_ app: XCUIApplication, _ state: String) {
        let identity = app.buttons["companion-chat-header"].frame
        guard let image = app.screenshot().image.cgImage else { return XCTFail("\(state): no screenshot") }
        let scale = CGFloat(image.width) / app.frame.width
        let x = Int(((identity.midX - 16) * scale).rounded()), y = Int(((identity.minY + 25) * scale).rounded())
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        let rgb = pixel.prefix(3).map(Int.init)
        for (channel, expected) in zip(rgb, [99, 102, 241]) {
            XCTAssertEqual(channel, expected, accuracy: 12, "\(state): avatar renders \(rgb), not the canonical indigo")
        }
    }

    /// The name pill under the photo floats over whatever transcript is behind it; its text stays at WCAG AA.
    /// Sampled across the bottom of the identity control, where the pill is, away from the photo.
    private func assertNamePillContrast(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let identity = app.buttons["companion-chat-header"].frame
        let pill = CGRect(x: identity.midX - 30, y: identity.maxY - 13, width: 60, height: 9)
        guard let image = app.screenshot().image.cgImage else { return XCTFail("No screenshot", file: file, line: line) }
        let scale = CGFloat(image.width) / app.frame.width
        guard let cropped = image.cropping(to: CGRect(x: pill.minX * scale, y: pill.minY * scale,
                                                      width: pill.width * scale, height: pill.height * scale).integral) else {
            return XCTFail("Bad pill crop \(pill)", file: file, line: line)
        }
        let (width, height) = (cropped.width, cropped.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func luminance(_ i: Int) -> Double {
            func channel(_ v: UInt8) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(bytes[i]) + 0.7152 * channel(bytes[i + 1]) + 0.0722 * channel(bytes[i + 2])
        }
        let values = stride(from: 0, to: bytes.count, by: 4).map(luminance).sorted()
        guard !values.isEmpty else { return }
        let background = values[values.count / 2]
        let text = abs(values.first! - background) > abs(values.last! - background) ? values.first! : values.last!
        let ratio = (max(text, background) + 0.05) / (min(text, background) + 0.05)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "Name pill text contrast over the transcript", file: file, line: line)
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
        let editors = app.descendants(matching: .any).matching(identifier: "companion-composer")
        XCTAssertEqual(editors.count, 1, "One native draft field keeps its identity")
        let editor = editors.firstMatch
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
        XCTAssertTrue(context.isHittable)
        assertMinimumTarget(context, "context usage")
        XCTAssertTrue(pixelContains(region.navigation, context.frame), "Context usage stays in navigation: \(context.frame)")
        // Like Messages, the photo sits centred in the bar and its name pill may hang just below it, over the
        // transcript; it never reaches the composer.
        let identity = app.buttons["companion-chat-header"]
        XCTAssertTrue(identity.isHittable)
        assertMinimumTarget(identity, "identity")
        XCTAssertTrue(region.navigation.contains(CGPoint(x: identity.frame.midX, y: identity.frame.midY)), "Identity sits on the bar: \(identity.frame)")
        XCTAssertEqual(identity.frame.midX, app.frame.midX, accuracy: 1, "Identity remains screen-centered while editing")
        XCTAssertLessThanOrEqual(pixelAligned(identity.frame.maxX), pixelAligned(context.frame.minX), "Identity clears the trailing controls")
        XCTAssertLessThanOrEqual(pixelAligned(identity.frame.maxY), pixelAligned(composerTop), "Identity never reaches the composer")
        // XCUI's landscape screenshots come back rotated and half black on this runtime, so pixels are read in portrait.
        if app.frame.height > app.frame.width { assertNamePillContrast(app) }
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
            // The details scroll within their cap. Every line must be read in full there: a line taller than the cap
            // (a long name at accessibility sizes) across several scroll positions. Lines never shrink to fit.
            let height = pixelAligned(leaf.frame.height)
            var spans: [(CGFloat, CGFloat)] = []
            func record() {
                let frame = leaf.frame
                XCTAssertEqual(pixelAligned(frame.height), height, "\(id) keeps its height while the details scroll")
                let shown = frame.intersection(clip)
                if !shown.isNull, shown.height > 0, leaf.isHittable { spans.append((shown.minY - frame.minY, shown.maxY - frame.minY)) }
            }
            func readTo() -> CGFloat {
                var end: CGFloat = 0
                for span in spans.sorted(by: { $0.0 < $1.0 }) where pixelAligned(span.0) <= pixelAligned(end) { end = max(end, span.1) }
                return pixelAligned(end)
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            func point(_ fraction: CGFloat) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: clip.midX - app.frame.minX, dy: clip.minY + clip.height * fraction - app.frame.minY))
            }
            record()
            var drags = 0
            while drags < 10, scroll.exists, readTo() < height {
                // A short drag inside the visible details, held at the end so it doesn't fling past unread text.
                let above = leaf.frame.maxY <= clip.minY
                point(above ? 0.3 : 0.7).press(forDuration: 0.05, thenDragTo: point(above ? 0.7 : 0.3),
                                               withVelocity: .slow, thenHoldForDuration: 0.3)
                drags += 1
                record()
            }
            XCTAssertGreaterThanOrEqual(readTo(), height, "\(id) is read in full in the details: \(spans), height \(height), clip \(clip)")
        }
    }

    func testDarkWorkingKeyboardDownAndUp() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["companion-chat-activity"].exists)
        XCTAssertFalse(element(app, "companion-chat-details").exists)
        capture(app, "dark Working keyboard down")
        assertAvatarColour(app, "dark collapsed")
        tapChatStatusBar(in: app)
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker 1.")).firstMatch
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 5), "Native top must reach the oldest fixture entry")
        capture(app, "dark Working native top keyboard down")
        focus(app)
        capture(app, "dark Working keyboard up")
        let composerTop = assertEditingLayout(app, largeText: false)
        waitAndTap(app.buttons["companion-chat-header"], until: element(app, "companion-chat-details"), attempts: 1)
        capture(app, "dark Working expanded keyboard up")
        assertAvatarColour(app, "dark expanded")
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
        assertAvatarColour(app, "light collapsed")
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

    /// Landscape with the keyboard up leaves no room for a usable disclosure: expanding keeps the choice but shows
    /// nothing over the bar or composer, and the details appear once there is room again.
    func testLandscapeKeyboardDetailsStayBetweenBarAndComposer() {
        let app = launch()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(app.windows.firstMatch, NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, timeout: 5))
        focus(app)
        let composerTop = assertEditingLayout(app, largeText: false)
        let room = composerTop - app.navigationBars.firstMatch.frame.maxY
        XCTAssertLessThan(room, 100, "This case needs a window too short for the details: \(room)pt")
        let identity = app.buttons["companion-chat-header"]
        identity.tap()
        XCTAssertTrue(waitFor(identity, NSPredicate(format: "value == %@", "Details hidden, no room while editing"), timeout: 5),
                      "VoiceOver hears why nothing expanded: \(identity.value ?? "")")
        let details = element(app, "companion-chat-details")
        XCTAssertFalse(details.waitForExistence(timeout: 1), "No details squeezed between the bar and the composer")
        XCTAssertFalse(app.scrollViews["companion-chat-details-scroll"].exists)
        assertEditingLayout(app, largeText: false)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(details.waitForExistence(timeout: 5), "The kept choice shows the details once there is room")
        XCTAssertTrue(waitFor(identity, NSPredicate(format: "value == %@", "Details expanded"), timeout: 5))
        let navigation = app.navigationBars.firstMatch.frame
        XCTAssertGreaterThanOrEqual(pixelAligned(details.frame.minY), pixelAligned(navigation.maxY))
        XCTAssertLessThanOrEqual(pixelAligned(details.frame.maxY), pixelAligned(element(app, "companion-composer-region").frame.minY),
                                 "Details end above the composer")
        capture(app, "portrait again with kept details")
    }

    /// With only the desktop's Auto-or-Full boolean (no known live level), one elevated badge says so.
    func testBooleanOnlyAccessShowsOneAutoOrFullBadge() {
        let app = launch(["--companion-header-idle", "--companion-header-boolean-access"])
        let identity = app.buttons["companion-chat-header"]
        XCTAssertTrue(identity.label.contains("Access: Auto or Full access"), identity.label)
        waitAndTap(identity, until: element(app, "companion-chat-details"), attempts: 1)
        let badges = app.descendants(matching: .any).matching(identifier: "elevated-access-badge")
        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.firstMatch.label, "Access: Auto or Full access")
        XCTAssertFalse(element(app, "companion-header-level").exists, "No live level is invented")
        capture(app, "boolean-only Access expanded")
    }

    func testEverySavedAccessLevelUsesTheSingleExistingBadge() {
        for (id, label) in [("plan", "Plan"), ("ask", "Ask first"), ("auto_edit", "Auto-accept edits"),
                            ("auto", "Auto"), ("full_access", "Full access")] {
            let app = launch(["--companion-header-idle", "--companion-header-saved-access=\(id)"])
            let identity = app.buttons["companion-chat-header"]
            XCTAssertTrue(identity.label.contains("Access: \(label)"), identity.label)
            XCTAssertFalse(identity.label.contains("Auto or Full access"))
            waitAndTap(identity, until: element(app, "companion-chat-details"), attempts: 1)
            let badges = app.staticTexts.matching(identifier: "companion-header-level")
            XCTAssertEqual(badges.count, 1, "One visible level label: \(app.debugDescription)")
            XCTAssertEqual(badges.firstMatch.label, "Permissions: \(label)")
            XCTAssertFalse(element(app, "elevated-access-badge").exists)
            app.terminate()
        }
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
