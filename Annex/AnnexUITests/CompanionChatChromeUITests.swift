import XCTest

@MainActor final class CompanionChatChromeUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testDispatcherTranscriptSpaceWithKeyboardDownAndUp() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls", "--companion-preview-context-window", "--companion-preview-long-reply"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        record(app, state: "keyboard-down")
        focus(composer, in: app)
        composer.typeText("A draft with more room")
        record(app, state: "keyboard-up")
    }

    func testSlashMenuAvailableHeight() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        focus(composer, in: app)
        composer.typeText("/")
        let menu = element(app, "companion-slash-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let readable = menu.frame.minY - max(transcript.minY, element(app, "companion-chat-header").frame.maxY)
        print("CHAT_CHROME slash menu=\(menu.frame) readableHeight=\(readable)")
        XCTAssertGreaterThanOrEqual(readable, 44)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome slash menu"; shot.lifetime = .keepAlways; add(shot)
    }

    func testEditingKeepsPermissionConfirmationAndModelAndEffortReachable() {
        let app = launchApp(["--companion-preview"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        focus(composer, in: app)
        composer.typeText("Keep this draft")
        let controls = app.buttons["companion-level-menu"]
        XCTAssertTrue(controls.label.contains("Chat controls"))
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Approval stays pinned while editing")
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"])
        waitAndTap(app.buttons["companion-permissions-menu"], until: app.buttons["companion-level-full_access"])
        let fullAccess = app.buttons["companion-level-full_access"]
        let confirmation = app.buttons["Switch to Full access"]
        waitAndTap(fullAccess, until: confirmation)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists)
        confirmation.tap()
        let error = app.staticTexts["Preview only. This action does not contact a desktop."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        app.buttons["Dismiss"].tap()
        // The confirmation may end editing. Refocus; all choices still belong to the compact control.
        composer.tap()
        waitAndTap(controls, until: app.buttons["companion-model-menu"])
        XCTAssertTrue(app.buttons["companion-effort-menu"].exists)
        waitAndTap(app.buttons["companion-model-menu"], until: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Haiku'")).firstMatch)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Haiku'")).firstMatch.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        app.buttons["Dismiss"].tap()
        composer.tap()
        waitAndTap(controls, until: app.buttons["companion-effort-menu"])
        waitAndTap(app.buttons["companion-effort-menu"], until: app.buttons["Extra high"])
        app.buttons["Extra high"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
    }

    func testOfflineCaptionAppearsOnlyWhileReconnecting() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let caption = app.staticTexts["Draft saved while you reconnect"]
        XCTAssertFalse(caption.exists)
        XCTAssertFalse(app.staticTexts["Runs on your desktop • ⌘ Return to send"].exists)
        waitAndTap(app.buttons["Settings"], until: app.buttons["Disconnect desktop"])
        app.buttons["Disconnect desktop"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        focus(composer, in: app)
        composer.typeText("A local offline draft")
        XCTAssertTrue(caption.exists)
        XCTAssertFalse(app.buttons["companion-send"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome offline caption and draft"; shot.lifetime = .keepAlways; add(shot)
        waitAndTap(app.buttons["Settings"], until: app.buttons["Reconnect desktop"])
        app.buttons["Reconnect desktop"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(caption.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A local offline draft"), timeout: 5))
    }

    func testLargestTextKeepsSafetyStatusAndControlsReachable() { largestText(hidePreviewBanner: false) }

    func testLargestTextWithoutPreviewBannerKeepsSafetyStatusAndControlsReachable() { largestText(hidePreviewBanner: true) }

    private func largestText(hidePreviewBanner: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                            + (hidePreviewBanner ? ["--companion-preview-hide-banner"] : []))
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let header = element(app, "companion-chat-header")
        XCTAssertTrue(header.label.contains("Full access") && header.label.contains("Free Agent"), header.label)
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["companion-level-menu"].isHittable)
        XCTAssertTrue(app.buttons["companion-context-settings"].isHittable)
        focus(composer, in: app)
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let region = element(app, "companion-composer-region").frame
        let readable = transcript.isNull ? 0 : max(0, min(transcript.maxY, region.minY) - max(transcript.minY, header.frame.maxY))
        print("CHAT_CHROME largest-text hiddenPreviewBanner=\(hidePreviewBanner) transcript=\(transcript) header=\(header.frame) composer=\(region) readableHeight=\(readable)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome largest accessibility text \(hidePreviewBanner ? "without preview banner" : "with preview banner")"
        shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["companion-level-menu"].isHittable)
        XCTAssertTrue(app.buttons["companion-send"].exists)
        XCTAssertTrue(header.label.contains("Full access") && header.label.contains("Free Agent"), "Safety stays visible while editing")
        XCTAssertGreaterThanOrEqual(readable, 44, "Largest text must keep a readable transcript band")
        XCTAssertFalse(app.buttons["companion-context-settings"].exists, "The ring yields its header row while editing")
        waitAndTap(app.buttons["Conversation actions"], until: app.buttons["companion-context-settings"])
        let picker = app.buttons["agent-settings-context-window"]
        waitAndTap(app.buttons["companion-context-settings"], until: picker)
        XCTAssertTrue(picker.isHittable, "Context remains reachable from Conversation actions")
    }

    private func focus(_ composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        // iPad may initially expose only the compact input palette.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    private func record(_ app: XCUIApplication, state: String) {
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let header = element(app, "companion-chat-header").frame
        let composer = element(app, "companion-composer-region").frame
        let visibleTop = max(transcript.minY, header.maxY)
        let visibleBottom = min(transcript.maxY, composer.minY)
        print("CHAT_CHROME \(state) transcript=\(transcript) header=\(header) composer=\(composer) visibleTop=\(visibleTop) visibleBottom=\(visibleBottom) height=\(visibleBottom - visibleTop)")
        XCTAssertGreaterThan(visibleBottom - visibleTop, 100)
        let end = app.staticTexts["End of the long reply."]
        let navigation = app.buttons["companion-next-message"]
        XCTAssertTrue(end.exists && navigation.exists)
        XCTAssertLessThanOrEqual(end.frame.maxY, navigation.frame.minY - 4, "The final text can sit clear of floating controls")
        print("CHAT_CHROME \(state) finalText=\(end.frame) nextButton=\(navigation.frame) send=\(app.buttons["companion-send"].frame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome \(state)"; shot.lifetime = .keepAlways; add(shot)
    }
}
