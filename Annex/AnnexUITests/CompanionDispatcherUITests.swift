import XCTest
import Vision

/// The desktop's Dispatcher (#2533) on the preview desktop (`--companion-preview-dispatcher`): its pinned row above
/// the projects, its chat with no project actions, its settings, and the task it relayed in River's chat.
@MainActor
final class CompanionDispatcherUITests: ReliableUITestCase {
    private static let unicodeDraft = "\u{1F642}\u{1F469}\u{200D}\u{1F4BB}\u{1F1FA}\u{1F1F3}\u{1F44D}\u{1F3FD}\u{20000}"

    private func openDispatcherSettings() -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-settings"], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Conversation actions"].tap()
        XCTAssertTrue(app.buttons["Agent settings"].waitForExistence(timeout: 5))
        app.buttons["Agent settings"].tap()
        XCTAssertTrue(element(app, "dispatcher-behavior-standard").waitForExistence(timeout: 10))
        return app
    }

    private func requireBytes(_ field: XCUIElement, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let matched = waitFor(field, NSPredicate(format: "value == %@", expected), timeout: 5)
        XCTAssertEqual(Array((field.value as? String ?? "").utf8), Array(expected.utf8), file: file, line: line)
        XCTAssertTrue(matched, file: file, line: line)
    }

    private func scrollSettings(to target: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<20 {
            let top = (app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0) + 10
            let keyboard = app.keyboards.firstMatch
            // The keyboard's AX frame omits its prediction/accessory strip.
            let bottom = keyboard.exists ? keyboard.frame.minY - 100 : app.frame.maxY - 10
            if target.exists && target.isHittable && target.frame.minY >= top && target.frame.maxY <= bottom { return }
            XCTAssertGreaterThan(bottom - top, 80)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.5, dy: (top + bottom) / 2))
            let movingUp = target.exists ? target.frame.midY > (top + bottom) / 2 : up
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: movingUp ? -120 : 120)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        screenshot(app, "Settings scrolling failure")
        let hierarchy = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        hierarchy.name = "Settings scrolling hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("The settings row must be visible above the keyboard")
    }

    func testNameDraftSurvivesLazySectionsAndUnrelatedSaves() {
        let app = openDispatcherSettings()
        let name = app.textFields["dispatcher-name"]
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let draft = "Dispatcher" + Self.unicodeDraft
        app.typeText(Self.unicodeDraft)
        requireBytes(name, draft)

        let clear = element(app, "dispatcher-clear-chat")
        scrollSettings(to: clear, in: app)
        let behavior = element(app, "dispatcher-behavior-thorough")
        XCTAssertFalse(behavior.isHittable, "The lifecycle's Behavior section is offscreen")
        scrollSettings(to: behavior, in: app, up: false)
        scrollSettings(to: name, in: app)
        requireBytes(name, draft)

        scrollSettings(to: behavior, in: app, up: false)
        behavior.tap()
        XCTAssertTrue(behavior.wait(for: \.isSelected, toEqual: true, timeout: 5))
        let models = app.switches["dispatcher-models-by-hand"]
        scrollSettings(to: models, in: app)
        models.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(models, NSPredicate(format: "value == %@", "1"), timeout: 5))
        scrollSettings(to: name, in: app)
        requireBytes(name, draft)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        app.keyboards.buttons["Done"].tap()
        requireBytes(name, draft)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars[draft].waitForExistence(timeout: 5), "The saved name reaches the conversation")
    }

    func testNewSettingsPresentationStartsWithSavedNameNotDiscardedDraft() {
        let app = openDispatcherSettings()
        let name = app.textFields["dispatcher-name"]
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        app.typeText(Self.unicodeDraft)
        requireBytes(name, "Dispatcher" + Self.unicodeDraft)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons["Conversation actions"].tap()
        app.buttons["Agent settings"].tap()
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        requireBytes(name, "Dispatcher")
    }

    func testEmojiDraftSurvivesRotationAndSaves() {
        let app = openDispatcherSettings()
        let emoji = app.textFields["dispatcher-emoji"]
        XCTAssertTrue(scrollUntilExists(emoji, in: app) && scrollTo(emoji, in: app))
        emoji.tap()
        let draft = "\u{1F469}\u{200D}\u{1F4BB}"
        app.typeText(draft)
        requireBytes(emoji, draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(emoji, draft)
        XCUIDevice.shared.orientation = .portrait
        requireBytes(emoji, draft)
        emoji.tap()
        app.keyboards.buttons["Done"].tap()
        requireBytes(emoji, draft)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Clear emoji")).firstMatch.waitForExistence(timeout: 5),
            "The saved emoji is returned by the preview desktop")
    }

    func testPersonalityDraftSurvivesRotationAndSaves() {
        let app = openDispatcherSettings()
        let personality = element(app, "dispatcher-personality-text")
        XCTAssertTrue(scrollUntilExists(personality, in: app, maxSwipes: 8) && scrollTo(personality, in: app))
        let original = personality.value as? String ?? ""
        personality.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.9)).tap()
        app.typeText(Self.unicodeDraft)
        let draft = original + Self.unicodeDraft
        requireBytes(personality, draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(personality, draft)
        XCUIDevice.shared.orientation = .portrait
        requireBytes(personality, draft)
        let save = app.buttons["dispatcher-personality-save"]
        scrollSettings(to: save, in: app)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "A successful save retires the pending personality draft")
        requireBytes(personality, draft)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// iPad exposes its top tabs as buttons outside a UITabBar.
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        return app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        // The header lives in the navigation bar now: start halfway between it and the composer, in the transcript.
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = element(app, "companion-composer-region").frame.minY
        XCTAssertGreaterThan(bottom - top, 48, "Some transcript stays visible above the composer")
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width * 0.5, dy: (top + bottom) / 2 - app.frame.minY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Drag in the transcript dismisses the keyboard")
    }

    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func visibleText(_ app: XCUIApplication) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        return try XCTUnwrap(request.results).compactMap { $0.topCandidates(1).first?.string }
    }

    func testPinnedRowOpensTheDispatchersChatAndSettings() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15), "The fixture restores Dispatch")
        XCTAssertFalse(tab(app, "Agents").exists, "Agents has moved into Search")
        let sidebar = app.buttons["ToggleSideBar"]
        if sidebar.exists {
            sidebar.tap()
            screenshot(app, "Home first in iPad sidebar")
            app.buttons["Hide Sidebar"].tap()
        }
        tab(app, "Home").tap()
        let row = element(app, "dispatcher-row-preview-studio")
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app), "The Dispatcher's row is pinned on Home")
        XCTAssertTrue(row.label.contains("Dispatcher"), "Its row is named Dispatcher: \(row.label)")
        screenshot(app, "Home with the Dispatcher")

        let title = app.navigationBars["Dispatcher"]
        waitAndTap(row, until: title, timeout: 10, "The row opens the Dispatcher's chat")
        XCTAssertTrue(text(app, containing: "finish the reconnect fix").waitForExistence(timeout: 10), "Its conversation loads")
        XCTAssertTrue(element(app, "companion-chat-header").label.contains("Studio Mac / Dispatcher"), "No project in its header")
        screenshot(app, "Dispatcher chat")

        let actions = app.navigationBars.buttons["Conversation actions"]
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings, timeout: 5)
        XCTAssertFalse(app.buttons["Terminal"].exists, "No project shell for the Dispatcher")
        let enabled = element(app, "dispatcher-enabled-preview-studio")
        waitAndTap(settings, until: enabled, timeout: 10, "Its settings start with Turn on Dispatcher")
        XCTAssertTrue(element(app, "agent-settings-model").waitForExistence(timeout: 10), "Its model can change")
        XCTAssertFalse(element(app, "agent-settings-name").exists, "Its name is the desktop's")
        XCTAssertFalse(element(app, "agent-settings-orchestrate").exists, "Its orchestration is locked")
        screenshot(app, "Dispatcher settings")
    }

    /// Settings > Dispatcher (#338): Behavior replaces its raw model and Access rows, and Clear chat and Forget
    /// everything each ask on their own before anything happens.
    func testBehaviorClearChatAndForgetEverything() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-settings"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15), "The fixture restores Dispatch")
        let actions = app.navigationBars.buttons["Conversation actions"]
        let settings = app.buttons["Agent settings"]
        waitAndTap(actions, until: settings, timeout: 5)
        let standard = element(app, "dispatcher-behavior-standard")
        waitAndTap(settings, until: standard, timeout: 10, "Its settings show Behavior")
        XCTAssertTrue(standard.isSelected, "Standard is its Behavior")
        XCTAssertFalse(element(app, "agent-settings-model").exists, "Behavior owns its model")
        XCTAssertFalse(element(app, "agent-settings-runtime").exists, "Settings > Dispatcher doesn't offer its runtime")
        XCTAssertFalse(element(app, "agent-settings-free-agent-mode").exists, "Settings > Dispatcher doesn't offer Access")
        screenshot(app, "Dispatcher Behavior")

        let thorough = element(app, "dispatcher-behavior-thorough")
        XCTAssertTrue(scrollTo(thorough, in: app))
        thorough.tap()
        XCTAssertTrue(thorough.wait(for: \.isSelected, toEqual: true, timeout: 5), "Thorough is saved")
        XCTAssertFalse(standard.isSelected)

        // Clear chat: Cancel does nothing, then confirming clears it.
        let clear = element(app, "dispatcher-clear-chat")
        let notice = element(app, "dispatcher-reset-notice")
        XCTAssertTrue(scrollUntilExists(clear, in: app, maxSwipes: 8) && scrollTo(clear, in: app, maxSwipes: 8), "Clear chat is in its settings")
        let clearAlert = app.alerts["Clear chat?"]
        waitAndTap(clear, until: clearAlert, timeout: 5, "Clear chat asks first")
        XCTAssertTrue(clearAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "The conversation starts over.")).firstMatch.exists,
                      "It says exactly what goes and what stays")
        screenshot(app, "Clear chat confirmation")
        waitAndTap(clearAlert.buttons["Cancel"], untilGone: clearAlert)
        XCTAssertFalse(notice.waitForExistence(timeout: 1), "Cancel clears nothing")
        waitAndTap(clear, until: clearAlert, timeout: 5)
        waitAndTap(clearAlert.buttons["Clear chat"], untilGone: clearAlert)
        // The result is the section's last row, which a Form only keeps while it is on screen.
        XCTAssertTrue(scrollUntilExists(notice, in: app), "Clearing says what it did")
        XCTAssertEqual(notice.label, "Its conversation started over.")

        // Forget everything is asked separately, with its own words.
        let forget = element(app, "dispatcher-forget-everything")
        XCTAssertTrue(scrollTo(forget, in: app))
        let forgetAlert = app.alerts["Forget everything?"]
        waitAndTap(forget, until: forgetAlert, timeout: 5, "Forget everything asks first")
        XCTAssertTrue(forgetAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "This can’t be undone.")).firstMatch.exists)
        screenshot(app, "Forget everything confirmation")
        waitAndTap(forgetAlert.buttons["Cancel"], untilGone: forgetAlert)
        XCTAssertFalse(notice.waitForExistence(timeout: 1), "Asking clears the last result, and Cancel forgets nothing")
        waitAndTap(forget, until: forgetAlert, timeout: 5)
        waitAndTap(forgetAlert.buttons["Forget everything"], untilGone: forgetAlert)
        XCTAssertTrue(scrollUntilExists(notice, in: app), "Forgetting says what it did")
        XCTAssertTrue(notice.wait(for: \.label, toEqual: "Its memory was cleared.", timeout: 5))
        screenshot(app, "Dispatcher after both resets")
    }

    func testARoutedBurstShowsEachSenderAndMessageSeparately() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch"], environment: ["CLUBHOUSE_PREVIEW_TYPING_PROBE": "1"])
        let home = tab(app, "Home")
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"), timeout: 10)
        let expected = [
            "Dispatcher controller: Finish the reconnect fix and open a PR. Report back when it's in review.",
            "Reviewer: The reconnect tests pass. The PR is ready for review.",
            "Clubhouse: All helper updates have been delivered.",
            "Another agent: The review notes are attached to the PR."
        ]
        for (index, label) in expected.enumerated() {
            let part = element(app, "companion-routed-relay-1-\(index)")
            XCTAssertTrue(scrollUntilExists(part, in: app, up: false, maxSwipes: 8))
            XCTAssertEqual(part.label, label, "VoiceOver names each message's own sender and body")
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-routed-relay-1-")).count, 4)
        XCTAssertFalse(text(app, containing: "[TASK:").exists)
        XCTAssertFalse(text(app, containing: "updates, oldest first:").exists)
        let part = element(app, "companion-routed-relay-1-1")
        XCTAssertTrue(bringTranscriptRowIntoView(part, in: app), "Bring the message inside the transcript before copying")
        XCTContext.runActivity(named: "Copy target frame: \(part.frame)") { _ in }
        screenshot(app, "Routed burst with four senders")
        longPressUntilMenu(part, shows: app.buttons["Copy message"])
        XCTAssertTrue(app.buttons["Copy message"].exists, "Copy remains available on each routed message")
        app.buttons["Copy message"].tap()
        let raw = """
        4 updates, oldest first:

        --- 1 of 4 ---
        [TASK:dsp-42] [FROM:Dispatcher controller] Finish the reconnect fix and open a PR. Report back when it's in review.

        --- 2 of 4 ---
        [FROM:Reviewer] The reconnect tests pass. The PR is ready for review.

        --- 3 of 4 ---
        [Clubhouse] All helper updates have been delivered.

        --- 4 of 4 ---
        The review notes are attached to the PR.
        """
        // Read through the system Paste action: reading the runner's pasteboard directly asks for cross-app permission.
        let composer = element(app, "companion-composer")
        let paste = app.menuItems["Paste"]
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        _ = paste.waitForExistence(timeout: 1)
        waitAndTap(composer, until: paste, timeout: 3, "The composer offers Paste")
        paste.tap()
        // Focused UITextView AX values can lag the visibly pasted text on iOS 26.5. Reopening also proves
        // the complete raw delivery reached the draft binding, rather than only the UIKit editor.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(river.waitForExistence(timeout: 10))
        XCTAssertTrue(scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"), timeout: 10)
        let restored = app.textFields["companion-composer"]
        XCTAssertTrue(waitFor(restored, NSPredicate(format: "value == %@", raw), timeout: 5),
                      "Copy from one part preserves the entire raw delivery in the draft after navigation")
    }

    func testDraftSurvivesTabSwitchAndDisconnectAndOffMovesHomeOnce() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-controls", "--companion-preview-dispatch-reports"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("A draft for this desktop")
        screenshot(app, "Dispatcher composer and keyboard")
        dismissKeyboard(app)
        tab(app, "Home").tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        tab(app, "Dispatch").tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
        // The synthetic report preserves the selected Dispatch tab; Settings lives on Home.
        app.buttons["dispatcher-preview-disconnect"].tap()
        XCTAssertTrue(tab(app, "Dispatch").exists, "A dropped connection isn't off")
        XCTAssertTrue(app.navigationBars["Dispatcher"].exists)
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
        XCTAssertFalse(app.buttons["companion-send"].isEnabled)
        screenshot(app, "Dispatcher disconnected with cached conversation")
        app.buttons["dispatcher-preview-reconnect"].tap()
        app.buttons["dispatcher-preview-off"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        XCTAssertFalse(tab(app, "Dispatch").exists)
        tab(app, "Search").tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5), "The off fallback runs only once")
        tab(app, "Home").tap()
        app.buttons["Settings"].tap()
        app.buttons["Report Dispatcher on"].tap()
        app.buttons["settings-close"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].exists, "Turning on never switches tabs during use")
        tab(app, "Dispatch").tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
    }

    func testEveryLastTabRestoresAfterRelaunch() {
        let arguments = ["--companion-preview", "--companion-preview-dispatcher"]
        let app = launchApp(arguments, allowance: 360, attempts: 1)
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15), "A fresh launch starts on Home")
        if app.tabBars.firstMatch.exists {
            let labels = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
            XCTAssertEqual(labels, ["Home", "Dispatch", "Needs you", "Search"])
        }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["companion-start-screen"].exists)
        XCTAssertFalse(app.staticTexts["Start screen"].exists)
        app.buttons["settings-close"].tap()
        func assertSelectedTab(_ title: String) {
            if title == "Search" {
                // The native Search role replaces its collapsed tab button with the search field.
                XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 15))
                let field = app.searchFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertTrue(field.isHittable, "Search restores its native search control")
            } else {
                let selected = tab(app, title)
                XCTAssertTrue(selected.waitForExistence(timeout: 15))
                XCTAssertTrue(selected.wait(for: \.isSelected, toEqual: true, timeout: 5),
                              "\(title) restores without a Start screen preference")
            }
        }
        // Search expands the bar around the previous tab, so exercise it last.
        for title in ["Dispatch", "Needs you", "Home", "Search"] {
            let selected = tab(app, title)
            XCTAssertTrue(selected.waitForExistence(timeout: 10))
            selected.tap()
            assertSelectedTab(title)
            app.terminate()
            app.launchArguments = arguments + ["--companion-preview-keep-preferences", "--ui-testing-fast"]
            app.launch()
            assertSelectedTab(title)
            screenshot(app, "Restored \(title) tab")
        }
    }

    func testUnavailableRestoredDispatchFallsBackToHomeWithoutStealingSelection() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher",
                             "--companion-preview-start-dispatch"], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--companion-preview", "--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15))
        XCTAssertFalse(tab(app, "Dispatch").exists, "The current desktop report supersedes the cached tab")
        screenshot(app, "Unavailable Dispatch falls back to Home")
        tab(app, "Needs you").tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(tab(app, "Needs you").isSelected, "Foregrounding does not reapply restoration")
        screenshot(app, "Foregrounding preserves Needs you after Dispatch fallback")
    }

    func testTabBarAppearanceMatrix() {
        let variants: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName",
                                     "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"] + flags,
                                allowance: 360, attempts: 1)
            XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15))
            for title in ["Home", "Dispatch", "Needs you", "Search"] {
                XCTAssertTrue(tab(app, title).isHittable, "\(title) is reachable in \(name)")
            }
            screenshot(app, "Tabs \(name) Home")
            tab(app, "Dispatch").tap()
            XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 5))
            screenshot(app, "Tabs \(name) Dispatch")
            app.terminate()
        }
    }

    private func dispatcherChoice(_ app: XCUIApplication, host: String) -> XCUIElement {
        let choice = app.buttons["dispatcher-desktop-\(host)"]
        if !choice.exists { waitAndTap(app.buttons["dispatcher-desktop-switcher"], until: choice, attempts: 1) }
        if !choice.isHittable, app.scrollViews["dispatcher-chips"].exists {
            app.scrollViews["dispatcher-chips"].swipeLeft()
            if !choice.isHittable { app.scrollViews["dispatcher-chips"].swipeRight() }
        }
        XCTAssertTrue(choice.isEnabled && choice.isHittable)
        return choice
    }

    func testDesktopSwitcherUsesDispatcherNamesWithoutMachineChrome() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"], attempts: 1)
        let studio = dispatcherChoice(app, host: "preview-studio")
        XCTAssertEqual(studio.label, "Navi")
        XCTAssertEqual(app.buttons["dispatcher-desktop-preview-laptop"].label, "Echo")
        XCTAssertTrue(app.navigationBars["Echo"].exists, "Names retain the existing initial sort order")
        XCTAssertFalse(app.buttons["Settings"].exists)
        screenshot(app, "Dispatch chips use chat names only")
        studio.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-studio"].isSelected)
    }

    func testSnapshotChatNameIsPreservedBeforeSettingsLoad() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-controller-name"], attempts: 1)
        let studio = dispatcherChoice(app, host: "preview-studio")
        XCTAssertEqual(studio.label, "Dispatcher controller, 1 of 2")
        XCTAssertEqual(app.buttons["dispatcher-desktop-preview-laptop"].label, "Dispatcher controller, 2 of 2")
        studio.tap()
        XCTAssertTrue(app.navigationBars["Dispatcher controller"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "companion-chat-header").label.hasPrefix("Dispatcher controller,"))
        screenshot(app, "Cached chosen names before settings load")
    }

    func testSettingsChatNameOverridesTheSnapshotChatName() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-controller-name",
                             "--companion-preview-named-dispatchers", "--companion-preview-dispatcher-settings"], attempts: 1)
        let studio = dispatcherChoice(app, host: "preview-studio")
        XCTAssertEqual(studio.label, "Navi")
        XCTAssertEqual(app.buttons["dispatcher-desktop-preview-laptop"].label, "Dispatcher controller")
        studio.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "companion-chat-header").label.hasPrefix("Navi,"))
        let settings = app.buttons["Agent settings"]
        waitAndTap(app.navigationBars.buttons["Conversation actions"], until: settings)
        let name = element(app, "dispatcher-name")
        waitAndTap(settings, until: element(app, "dispatcher-behavior-standard"), timeout: 10)
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        XCTAssertEqual(name.value as? String, "Navi")
        screenshot(app, "Chosen Dispatcher chat name in settings")
    }

    func testAnExplicitControllerChatNameIsNotTreatedAsALegacyRoleLabel() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-controller-name",
                             "--companion-preview-dispatcher-settings", "--companion-preview-chosen-controller-name"], attempts: 1)
        let studio = dispatcherChoice(app, host: "preview-studio")
        XCTAssertEqual(studio.label, "Dispatcher controller, 1 of 2", "The authoritative chosen name is preserved")
        XCTAssertEqual(app.buttons["dispatcher-desktop-preview-laptop"].label, "Dispatcher controller, 2 of 2")
        studio.tap()
        XCTAssertTrue(app.navigationBars["Dispatcher controller"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "companion-chat-header").label.hasPrefix("Dispatcher controller,"))
        let settings = app.buttons["Agent settings"]
        waitAndTap(app.navigationBars.buttons["Conversation actions"], until: settings)
        let name = element(app, "dispatcher-name")
        waitAndTap(settings, until: element(app, "dispatcher-behavior-standard"), timeout: 10)
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        XCTAssertEqual(name.value as? String, "Dispatcher controller")
    }

    func testPresenceOmitsUnpairedRemotesWithOnePairedDispatcher() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-presence"], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["dispatcher-desktop-switcher"].exists, "A single paired Dispatcher needs no stack")
        XCTAssertFalse(app.scrollViews["dispatcher-chips"].exists)
        XCTAssertFalse(app.buttons["Settings"].exists)
        for remote in ["office", "mini", "off"] { XCTAssertFalse(app.buttons["dispatcher-remote-preview-\(remote)"].exists) }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Office Mac")).firstMatch.exists)
        screenshot(app, "Single paired Dispatcher excludes unknown remotes")
    }

    func testLegacyControllerPresenceCannotReplacePairedChatNames() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers",
                             "--companion-preview-dispatcher-presence", "--companion-preview-controller-presence"], attempts: 1)
        let travel = dispatcherChoice(app, host: "preview-laptop")
        XCTAssertEqual(travel.label, "Echo")
        for remote in ["office", "mini", "off"] { XCTAssertFalse(app.buttons["dispatcher-remote-preview-\(remote)"].exists) }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Dispatcher controller")).firstMatch.exists)
        dispatcherChoice(app, host: "preview-studio").tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        screenshot(app, "Legacy presence cannot replace paired chip names")
    }

    func testPairedPresenceDoesNotDuplicateOrDisableAChip() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers",
                             "--companion-preview-dispatcher-presence"], attempts: 1)
        let travel = dispatcherChoice(app, host: "preview-laptop")
        XCTAssertEqual(travel.label, "Echo")
        XCTAssertTrue(travel.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "dispatcher-desktop-preview-laptop").count, 1)
        XCTAssertFalse(app.buttons["dispatcher-remote-preview-laptop"].exists)
        dispatcherChoice(app, host: "preview-studio").tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        dispatcherChoice(app, host: "preview-laptop").tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 5), "Paired chips retain navigation")
    }

    func testDesktopSwitcherKeepsSeparateDraftsAndScrollPositions() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-multiple-dispatchers", "--companion-preview-long-reply"], allowance: 300, attempts: 1)
        var composer: XCUIElement { app.textFields.matching(identifier: "companion-composer").firstMatch }
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "companion-chat-header").label.contains("Studio Mac / Dispatcher"))
        composer.tap()
        composer.typeText("For Studio")
        dismissKeyboard(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["dispatcher-desktop-switcher"].waitForExistence(timeout: 5), "Reading earlier collapses chips into the stack")
        XCTAssertFalse(app.scrollViews["dispatcher-chips"].exists)
        screenshot(app, "Dispatch collapsed while reading earlier")
        let travel = dispatcherChoice(app, host: "preview-laptop")
        XCTAssertEqual(travel.label, "Dispatcher, 2 of 2", "Duplicate chosen names are distinguished without machine chrome")
        travel.tap()
        let travelHeader = app.descendants(matching: .any).matching(identifier: "companion-chat-header")
            .matching(NSPredicate(format: "label CONTAINS %@", "Travel MacBook / Dispatcher")).firstMatch
        XCTAssertTrue(travelHeader.waitForExistence(timeout: 10) && travelHeader.isHittable)
        XCTAssertNotEqual(composer.value as? String, "For Studio", "B starts with its own empty draft")
        composer.tap()
        composer.typeText("For Travel")
        dispatcherChoice(app, host: "preview-studio").tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "For Studio"), timeout: 5))
        XCTAssertTrue(app.pausedChatNavigation.exists, "A keeps its scroll position away from the latest")
        tab(app, "Home").tap()
        tab(app, "Dispatch").tap()
        XCTAssertTrue(app.pausedChatNavigation.exists, "Switching tabs keeps A’s scroll position too")
        screenshot(app, "Dispatcher restored after tab and desktop switches")
        dispatcherChoice(app, host: "preview-laptop").tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "For Travel"), timeout: 5))
    }

    /// SwiftUI can report a caption below the scroll viewport as hittable. Keep taps inside the transcript,
    /// above the approval/composer dock, and drag within the transcript rather than across that dock.
    private func bringCaptionIntoView(_ caption: XCUIElement, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<20 {
            checkTimeLeft("bringing the sender caption into view", file: file, line: line)
            if caption.exists && caption.frame.minY > height * 0.25 && caption.frame.maxY < height * 0.62 { return }
            let older = caption.exists && caption.frame.minY <= height * 0.25
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: older ? 0.35 : 0.60))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: older ? 0.60 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Sender caption must be inside the transcript: \(caption.frame)", file: file, line: line)
    }

    private func expandSender(_ caption: XCUIElement) {
        let expanded = NSPredicate(format: "value BEGINSWITH %@", "Expanded")
        for _ in 0..<3 {
            if (caption.value as? String)?.hasPrefix("Expanded") == true { return }
            caption.tap()
            if waitFor(caption, expanded, timeout: 3) { return }
        }
        XCTFail("Sender part must expand")
    }

    func testSenderMessagesStartExpandedAndExplicitFoldsSurviveRefreshAndNavigation() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch"], allowance: 360)
        let home = tab(app, "Home")
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"))
        let short = element(app, "companion-routed-sender-preview-2")
        bringCaptionIntoView(short, in: app)
        XCTAssertEqual(short.label, "Maple: Short helper update.")
        let shortValue = short.value as? String ?? ""
        XCTAssertTrue(shortValue.contains("Mission") && shortValue.contains("Steered into the running turn"))
        XCTAssertTrue(shortValue.contains(":"), "The source and steer value also keeps the timestamp")
        let first = app.buttons["companion-routed-sender-preview-0"]
        let second = app.buttons["companion-routed-sender-preview-1"]
        bringCaptionIntoView(first, in: app)
        XCTAssertTrue(first.label.hasPrefix("Cedar: ## Helper report"), "Long helper replies start readable with the live name")
        XCTAssertTrue((first.value as? String)?.hasPrefix("Expanded") == true)
        first.tap()
        XCTAssertTrue(waitFor(first, NSPredicate(format: "value == %@", "Collapsed"), timeout: 5))
        XCTAssertTrue(element(app, "companion-sender-avatar-sender-preview-0").exists)
        bringCaptionIntoView(second, in: app)
        XCTAssertTrue((second.value as? String)?.hasPrefix("Expanded") == true)
        second.tap()
        XCTAssertTrue(waitFor(second, NSPredicate(format: "value == %@", "Collapsed"), timeout: 5))
        bringCaptionIntoView(first, in: app)
        expandSender(first)
        XCTAssertTrue(first.label.hasPrefix("Cedar: ## Helper report"), "An open part keeps the sender/body accessibility label")
        let openValue = first.value as? String ?? ""
        XCTAssertTrue(openValue.contains("Mission") && openValue.contains("Steered into the running turn"))
        XCTAssertTrue(openValue.contains(":"), "Open long parts keep their timestamp with the source and steer metadata")
        XCTAssertEqual(second.value as? String, "Collapsed", "Each part folds independently")
        let body = element(app, "companion-routed-body-sender-preview-0")
        XCTAssertTrue(body.exists)
        screenshot(app, "Helper avatar and expanded long message")

        // Leave the row's viewport, then return. A fold must not depend on a row's lifetime.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let top = text(app, containing: "Preview conversation")
        XCTAssertTrue(scrollTo(top, in: app, up: false, maxSwipes: 12))
        bringCaptionIntoView(first, in: app)
        XCTAssertTrue((first.value as? String)?.hasPrefix("Expanded") == true)

        let actions = app.navigationBars.buttons["Conversation actions"]
        let refresh = app.buttons["Refresh conversation"]
        waitAndTap(actions, until: refresh)
        refresh.tap()
        bringCaptionIntoView(first, in: app)
        XCTAssertTrue((first.value as? String)?.hasPrefix("Expanded") == true, "A new history snapshot keeps the fold open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"))
        bringCaptionIntoView(first, in: app)
        XCTAssertTrue((first.value as? String)?.hasPrefix("Expanded") == true, "Leaving the conversation keeps its open state")
        first.tap()
        XCTAssertTrue(waitFor(first, NSPredicate(format: "value == %@", "Collapsed"), timeout: 5))
        XCTAssertFalse(body.exists, "Collapsed parts do not build their markdown")
        longPressUntilMenu(first, shows: app.buttons["Copy message"])
    }

    func testARelayedTaskIsCaptionedWithItsSender() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch"])
        let home = tab(app, "Home")
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app), "River's row must be on screen")
        let header = element(app, "companion-chat-header")
        waitAndTap(river, until: header, timeout: 10)
        let body = element(app, "companion-routed-relay-1-0")
        XCTAssertTrue(scrollUntilExists(body, in: app, up: false, maxSwipes: 8), "The relayed task shows in River's chat")
        XCTAssertTrue(scrollTo(body, in: app, up: false, maxSwipes: 8), "Bring the relayed sender and body on screen")
        XCTAssertFalse(text(app, containing: "[TASK:").exists, "Without its tags")
        let part = element(app, "companion-routed-relay-1-0")
        XCTAssertTrue(part.exists && part.label.hasPrefix("Dispatcher controller:"), "Captioned with the actual controller sender")
        screenshot(app, "Relayed task")
    }
}
