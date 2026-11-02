import XCTest

/// The desktop's Dispatcher (#2533) on the preview desktop (`--companion-preview-dispatcher`): its pinned row above
/// the projects, its chat with no project actions, its settings, and the task it relayed in River's chat.
@MainActor
final class CompanionDispatcherUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    func testPinnedRowOpensTheDispatchersChatAndSettings() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15), "Dispatcher is the default start screen")
        XCTAssertTrue(app.tabBars.buttons["Agents"].exists, "All five tabs remain available")
        app.tabBars.buttons["Home"].tap()
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
        XCTAssertFalse(element(app, "agent-settings-persona").exists, "It has no persona")
        XCTAssertFalse(element(app, "agent-settings-orchestrate").exists, "Its orchestration is locked")
        screenshot(app, "Dispatcher settings")
    }

    func testARoutedBurstShowsEachSenderAndMessageSeparately() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"), timeout: 10)
        let expected = [
            "Dispatcher: Finish the reconnect fix and open a PR. Report back when it's in review.",
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
        XCTAssertTrue(scrollTo(part, in: app, up: false, maxSwipes: 8), "Bring the message on screen before copying")
        screenshot(app, "Routed burst with four senders")
        longPressUntilMenu(part, shows: app.buttons["Copy message"])
        XCTAssertTrue(app.buttons["Copy message"].exists, "Copy remains available on each routed message")
        app.buttons["Copy message"].tap()
        let raw = """
        4 updates, oldest first:

        --- 1 of 4 ---
        [TASK:dsp-42] [FROM:Dispatcher] Finish the reconnect fix and open a PR. Report back when it's in review.

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
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", raw), timeout: 5),
                      "Copy from one part keeps the entire raw delivery")
    }

    func testDraftSurvivesTabSwitchAndDisconnectAndOffMovesHomeOnce() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("A draft for this desktop")
        screenshot(app, "Dispatcher composer and keyboard")
        app.scrollViews.firstMatch.swipeDown()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Dispatcher"].tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
        // Opening Settings also dismisses the keyboard before the desktop report.
        app.buttons["Settings"].tap()
        app.buttons["Disconnect desktop"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Dispatcher"].exists, "A dropped connection isn't off")
        XCTAssertTrue(app.navigationBars["Dispatcher"].exists)
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
        XCTAssertFalse(app.buttons["companion-send"].isEnabled)
        screenshot(app, "Dispatcher disconnected with cached conversation")
        app.buttons["Settings"].tap()
        app.buttons["Reconnect desktop"].tap()
        app.buttons["Report Dispatcher off"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Dispatcher"].exists)
        app.tabBars.buttons["Agents"].tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "The off fallback runs only once")
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Report Dispatcher on"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].exists, "Turning on never switches tabs during use")
        app.tabBars.buttons["Dispatcher"].tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "A draft for this desktop"), timeout: 5))
    }

    func testStartScreenSettingAppliesOnlyOnNextLaunch() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        let picker = app.buttons["companion-start-screen"]
        picker.tap()
        XCTAssertTrue(app.navigationBars["Start screen"].waitForExistence(timeout: 5))
        app.staticTexts["Home"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Dispatcher"].exists, "Changing the preference doesn't navigate")
        app.terminate()
        app.launchArguments = ["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-keep-preferences"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15), "Home preference applies on the next launch")
        XCTAssertTrue(app.tabBars.buttons["Dispatcher"].exists)
        screenshot(app, "Home start screen preference")
    }

    func testFlagOffRemovesDispatcherTab() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        app.buttons["Report flag off"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Dispatcher"].exists)
    }

    func testDesktopSwitcherKeepsSeparateDraftsAndScrollPositions() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-multiple-dispatchers", "--companion-preview-long-reply"], allowance: 300)
        let switcher = app.buttons["dispatcher-desktop-switcher"]
        let composer = element(app, "companion-composer")
        XCTAssertTrue(switcher.waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "companion-chat-header").label.contains("Studio Mac / Dispatcher"))
        composer.tap()
        composer.typeText("For Studio")
        // Dismiss the keyboard, then scroll away from the latest on A.
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(app.buttons["Latest"].waitForExistence(timeout: 10))
        screenshot(app, "Dispatcher long reply away from latest")
        waitAndTap(switcher, until: app.buttons["Travel MacBook"])
        app.buttons["Travel MacBook"].tap()
        XCTAssertTrue(waitFor(element(app, "companion-chat-header"), NSPredicate(format: "label CONTAINS %@", "Travel MacBook / Dispatcher"), timeout: 10))
        XCTAssertNotEqual(composer.value as? String, "For Studio", "B starts with its own empty draft")
        composer.tap()
        composer.typeText("For Travel")
        waitAndTap(switcher, until: app.buttons["Studio Mac"])
        app.buttons["Studio Mac"].tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "For Studio"), timeout: 5))
        XCTAssertTrue(app.buttons["Latest"].exists, "A keeps its scroll position away from the latest")
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Dispatcher"].tap()
        XCTAssertTrue(app.buttons["Latest"].exists, "Switching tabs keeps A’s scroll position too")
        screenshot(app, "Dispatcher restored after tab and desktop switches")
        waitAndTap(switcher, until: app.buttons["Travel MacBook"])
        app.buttons["Travel MacBook"].tap()
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

    func testSenderAvatarAndIndependentFoldsSurviveScrollingRefreshAndNavigation() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"], allowance: 360)
        let home = app.tabBars.buttons["Home"]
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
        XCTAssertTrue(first.label.contains("Cedar sent a long message"), "The helper resolves to its live name")
        XCTAssertEqual(first.value as? String, "Collapsed")
        XCTAssertTrue(first.label.contains("Mission") && first.label.contains("Steered into the running turn"))
        XCTAssertTrue(first.label.contains("collapsed"))
        XCTAssertTrue(element(app, "companion-sender-avatar-sender-preview-0").exists)
        bringCaptionIntoView(second, in: app)
        XCTAssertEqual(second.value as? String, "Collapsed")
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
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        let home = app.tabBars.buttons["Home"]
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
        XCTAssertTrue(part.exists && part.label.hasPrefix("Dispatcher:"), "Captioned with who sent it")
        screenshot(app, "Relayed task")
    }
}
