import XCTest
import UIKit

@MainActor final class CompanionChatChromeUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testDispatcherTranscriptSpaceWithKeyboardDownAndUp() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-controls", "--companion-preview-context-window", "--companion-preview-long-reply"])
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
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome slash menu"; shot.lifetime = .keepAlways; add(shot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Chat chrome slash menu hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        // This is free transcript space, not a tap target. Native bar/AX edge rounding
        // can consume one display pixel (1/3pt at 3×); keep the menu/target checks strict.
        let onePixel = 1 / max(UIScreen.main.scale, 1)
        XCTAssertGreaterThanOrEqual(readable + onePixel, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        let first = app.buttons["companion-slash-compact"]
        assertMinimumTarget(first, "/compact")
        XCTAssertTrue(first.isHittable && pixelContains(menu.frame, first.frame))
        let last = app.buttons["companion-slash-frontend-design"]
        assertMinimumTarget(last, "/frontend-design")
        if !pixelContains(menu.frame, last.frame) {
            menu.swipeUp()
        }
        XCTAssertTrue(last.isHittable && pixelContains(menu.frame, last.frame), "Scrolling exposes the final command above the keyboard")
        last.tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "/frontend-design ")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Picking a scrolled command keeps editing")
    }

    func testEditingKeepsPermissionConfirmationAndModelAndEffortReachable() {
        let app = launchApp(["--companion-preview"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        let composer = element(app, "companion-composer")
        waitAndTap(river, until: composer)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The initial roomy phase has the keyboard down")
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists, "Roomy reading keeps inline decisions")
        focus(composer, in: app)
        composer.typeText("Keep this draft")
        let controls = app.buttons["companion-level-menu"]
        XCTAssertTrue(controls.label.contains("Chat controls"))
        // User-approved option A replaces #297's inline editing contract with compact Chat/Review.
        let pinned = element(app, "companion-pinned-decision")
        let chat = app.buttons["companion-decision-show-in-chat"]
        let review = app.buttons["companion-review-approval"]
        func assertCompactRequest() {
            XCTAssertTrue(pinned.exists, "The approval remains pinned while editing")
            // #448 merges the summary, queue position and Chat action into one title node.
            XCTAssertEqual(chat.label, "Run xcodebuild")
            XCTAssertEqual(chat.value as? String, "1 of 2 waiting · Bash")
            XCTAssertEqual(app.buttons.matching(identifier: "companion-decision-show-in-chat").count, 1)
            XCTAssertEqual(review.label, "Review approval: Run xcodebuild, 1 of 2")
            for action in [chat, review] {
                XCTAssertTrue(action.isEnabled && action.isHittable, "Compact Chat/Review stays reachable")
                assertMinimumTarget(action, action.label)
            }
            XCTAssertFalse(app.buttons["Deny"].exists, "Keyboard-up decisions are available through Review")
            XCTAssertFalse(app.buttons["Allow once"].exists, "Keyboard-up decisions are available through Review")
        }
        assertCompactRequest()
        let close = app.buttons["companion-approval-review-close"]
        waitAndTap(review, until: close, attempts: 1)
        let request = app.scrollViews["companion-approval-review-scroll"]
        XCTAssertTrue(request.exists)
        XCTAssertTrue(request.staticTexts["Run xcodebuild"].exists, "Review retains the request title")
        XCTAssertEqual(request.staticTexts["companion-approval-position"].label, "Request 1 of 2")
        XCTAssertTrue(request.staticTexts["Build the iOS application to verify the updated conversation layout."].exists,
                      "Review retains the full request summary")
        for label in ["Deny", "Allow once"] {
            let decision = request.buttons[label]
            for _ in 0..<8 {
                if decision.exists && decision.isEnabled && decision.isHittable && pixelContains(request.frame.intersection(app.frame), decision.frame) { break }
                request.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(decision.exists && decision.isEnabled && decision.isHittable, "Review keeps \(label) reachable")
            XCTAssertTrue(pixelContains(request.frame.intersection(app.frame), decision.frame), "The whole \(label) action is visible")
        }
        waitAndTap(close, untilGone: close, attempts: 1)
        XCTAssertFalse(app.staticTexts["Preview only. This action does not contact a desktop."].exists, "Reviewing and closing sends nothing")
        XCTAssertEqual(composer.value as? String, "Keep this draft", "Review preserves the draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Review preserves the editing keyboard")
        XCTAssertTrue(composer.debugDescription.contains("Keyboard Focused"), "Review preserves focus without refocusing")
        assertCompactRequest()
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
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-controls"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let caption = app.staticTexts["Draft saved while you reconnect"]
        XCTAssertFalse(caption.exists)
        XCTAssertFalse(app.staticTexts["Runs on your desktop • ⌘ Return to send"].exists)
        // #529 reverses #444: Dispatch offers the same Settings as Home, from its own leading gear.
        XCTAssertTrue(app.buttons["dispatcher-settings"].exists, "#529 keeps Settings reachable from Dispatch")
        func changeConnectionThroughHomeSettings(_ action: String) {
            let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            home.tap()
            XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let change = app.buttons[action]
            XCTAssertTrue(change.waitForExistence(timeout: 5))
            change.tap()
            let close = app.buttons["settings-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
            let dispatch = app.buttons.matching(NSPredicate(format: "label == %@", "Dispatch")).firstMatch
            XCTAssertTrue(dispatch.waitForExistence(timeout: 5))
            dispatch.tap()
            XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 5))
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["dispatcher-settings"].exists, "#529 keeps Settings reachable from Dispatch")
        }
        changeConnectionThroughHomeSettings("Disconnect desktop")
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        focus(composer, in: app)
        composer.typeText("A local offline draft")
        XCTAssertTrue(caption.exists)
        XCTAssertFalse(app.buttons["companion-send"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome offline caption and draft"; shot.lifetime = .keepAlways; add(shot)
        // Dismiss editing through the real transcript before using the native Home tab.
        // Its visible bounds avoid the header and preview banner, which are not scrollable.
        let transcript = app.scrollViews["companion-transcript"].frame
        let top = max(app.navigationBars.firstMatch.frame.maxY, transcript.minY)
        let bottom = min(element(app, "companion-composer-region").frame.minY, transcript.maxY)
        XCTAssertGreaterThan(bottom - top, 48)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width * 0.5, dy: (top + bottom) / 2 - app.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        changeConnectionThroughHomeSettings("Reconnect desktop")
        XCTAssertTrue(caption.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A local offline draft"), timeout: 5))
    }

    func testLargestTextKeepsSafetyStatusAndControlsReachable() { largestText(hidePreviewBanner: false) }

    func testLargestTextWithoutPreviewBannerKeepsSafetyStatusAndControlsReachable() { largestText(hidePreviewBanner: true) }

    private func largestText(hidePreviewBanner: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-context-window",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                            + (hidePreviewBanner ? ["--companion-preview-hide-banner"] : []))
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let header = element(app, "companion-chat-header")
        XCTAssertTrue(header.label.contains("Full access") && !header.label.contains("Auto or Full access") && !header.label.contains("Free Agent"), header.label)
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["companion-level-menu"].isHittable)
        assertMinimumTarget(app.buttons["companion-level-menu"], "Chat controls at XXXL")
        XCTAssertTrue(app.buttons["companion-context-usage"].isHittable)
        focus(composer, in: app)
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let region = element(app, "companion-composer-region").frame
        let readable = transcript.isNull ? 0 : max(0, min(transcript.maxY, region.minY) - max(transcript.minY, header.frame.maxY))
        print("CHAT_CHROME largest-text hiddenPreviewBanner=\(hidePreviewBanner) transcript=\(transcript) header=\(header.frame) composer=\(region) readableHeight=\(readable)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome largest accessibility text \(hidePreviewBanner ? "without preview banner" : "with preview banner")"
        shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["companion-level-menu"].isHittable)
        assertMinimumTarget(app.buttons["companion-level-menu"], "Chat controls while editing at XXXL")
        XCTAssertTrue(app.buttons["companion-send"].exists)
        XCTAssertTrue(header.label.contains("Full access") && !header.label.contains("Auto or Full access") && !header.label.contains("Free Agent"), "Safety stays visible while editing")
        XCTAssertTrue(app.buttons["View River, needs you"].isHittable, "The compact other-agent notice stays actionable")
        // The artificial preview banner had only 10pt in the baseline. Real chat must keep at least one readable band.
        XCTAssertGreaterThanOrEqual(readable, hidePreviewBanner ? 44 : 10, "Largest text must improve on the matching baseline")
        // Editing keeps the one context Button, whole, in the navigation bar.
        let navigation = app.navigationBars.firstMatch
        let context = navigation.buttons["companion-context-usage"]
        XCTAssertEqual(app.buttons.matching(identifier: "companion-context-usage").count, 1)
        XCTAssertEqual(context.label, "Context and plan limits")
        XCTAssertTrue(context.isEnabled && context.isHittable, "Editing keeps context enabled and reachable")
        XCTAssertTrue(pixelContains(navigation.frame, context.frame), "Context \(context.frame) stays in navigation \(navigation.frame)")
        waitAndTap(app.buttons["Conversation actions"], until: app.buttons["companion-context-settings-menu"])
        let picker = app.buttons["agent-settings-context-window"]
        let sheetTitle = app.navigationBars["Context and limits"]
        waitAndTap(app.buttons["companion-context-settings-menu"], until: sheetTitle, attempts: 1)
        let settings = app.buttons["companion-context-settings-row"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let beforeScroll = XCTAttachment(screenshot: app.screenshot())
        beforeScroll.name = "XXXL context sheet before normal List scroll, hidden preview banner \(hidePreviewBanner)"
        beforeScroll.lifetime = .keepAlways; add(beforeScroll)
        for _ in 0..<4 {
            let frame = list.frame.intersection(app.frame)
            let top = max(frame.minY, sheetTitle.frame.maxY)
            let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
            if settings.exists && settings.isHittable && pixelContains(visible, settings.frame) { break }
            // This gesture starts inside the sheet List, never in the background composer or tray.
            list.swipeUp(velocity: .slow)
        }
        let frame = list.frame.intersection(app.frame)
        let top = max(frame.minY, sheetTitle.frame.maxY)
        let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
        XCTAssertTrue(settings.exists && settings.isHittable, "Normal scrolling inside the sheet reaches Context settings at XXXL")
        XCTAssertTrue(pixelContains(visible, settings.frame), "Context settings is inside the sheet viewport, clear of background controls")
        let afterScroll = XCTAttachment(screenshot: app.screenshot())
        afterScroll.name = "XXXL context settings reached by normal List scroll, hidden preview banner \(hidePreviewBanner)"
        afterScroll.lifetime = .keepAlways; add(afterScroll)
        waitAndTap(settings, until: picker, attempts: 1)
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
        let navigation = app.pausedChatNavigation
        XCTAssertTrue(end.exists)
        XCTAssertFalse(navigation.exists, "#447 hides the replacement at the true bottom")
        XCTAssertFalse(app.buttons["companion-previous-message"].exists)
        XCTAssertFalse(app.buttons["companion-next-message"].exists)
        let visible = CGRect(x: transcript.minX, y: visibleTop, width: transcript.width, height: visibleBottom - visibleTop)
        XCTAssertTrue(pixelContains(visible, end.frame), "The entire final line stays above the composer")
        // At the true bottom there is no floating control to occlude the final line.
        // The replacement's actual bounds/44pt target are checked away from bottom
        // in CompanionLatestUITests and the streaming Reading test.
        if navigation.exists {
            XCTAssertLessThanOrEqual(end.frame.maxY, navigation.frame.minY - 4, "The final text can sit clear of floating controls")
        }
        let latestFrame = navigation.exists ? String(describing: navigation.frame) : "hidden while following"
        print("CHAT_CHROME \(state) finalText=\(end.frame) latest=\(latestFrame) send=\(app.buttons["companion-send"].frame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome \(state)"; shot.lifetime = .keepAlways; add(shot)
    }
}
