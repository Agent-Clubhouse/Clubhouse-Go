import XCTest

@MainActor final class CompanionDispatchChipsUITests: ReliableUITestCase {
    private func open(_ flags: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
            "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"] + flags, attempts: 1)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func appearance(_ flags: [String], _ name: String) {
        let app = open(flags)
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        let echo = app.buttons["dispatcher-desktop-preview-laptop"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15) && echo.exists)
        XCTAssertEqual(navi.label, "Navi")
        XCTAssertEqual(echo.label, "Echo")
        XCTAssertTrue(navi.isHittable && navi.frame.height >= 44)
        XCTAssertTrue(echo.isHittable && echo.frame.height >= 44)
        XCTAssertFalse(app.buttons["dispatcher-desktop-switcher"].exists)
        // #529 reverses #444's no-gear rule: Settings stays reachable beside expanded chips.
        let settings = app.buttons["dispatcher-settings"]
        XCTAssertTrue(settings.exists)
        // The same system bar button as Home's Settings; the bar supplies its touch target.
        XCTAssertTrue(settings.isHittable, "\(settings.frame)")
        XCTAssertEqual(settings.label, "Settings")
        capture(app, "444 Dispatch chips - \(name)")
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(navi.isSelected)
    }
    func testLight() { appearance(["--companion-preview-light"], "light") }
    func testDark() { appearance(["--companion-preview-dark"], "dark") }
    func testLatte() { appearance(["--companion-preview-light", "--companion-preview-theme-latte"], "Catppuccin Latte") }
    func testMocha() { appearance(["--companion-preview-dark", "--companion-preview-theme-mocha"], "Catppuccin Mocha") }
    func testAccessibilityXXXL() {
        appearance(["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "accessibility XXXL")
    }
    func testCachedReplyDotsAndStreamingStackCanExpandWithReduceMotion() {
        let app = open(["--companion-preview-dispatch-reports", "--companion-preview-dispatch-reduce-motion"])
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        let echo = app.buttons["dispatcher-desktop-preview-laptop"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15))
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        echo.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 5))
        XCTAssertFalse(navi.label.contains("New reply"), "Initial cached history is the baseline")
        app.buttons["dispatcher-preview-other-reply"].tap()
        XCTAssertTrue(waitFor(navi, NSPredicate(format: "label CONTAINS %@", "New reply"), timeout: 5))
        capture(app, "444 Cached new reply")
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(navi, NSPredicate(format: "NOT (label CONTAINS %@)", "New reply"), timeout: 5))
        app.buttons["dispatcher-preview-start-reply"].tap()
        let stack = app.buttons["dispatcher-desktop-switcher"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["dispatcher-chips"].exists, "Streaming uses no chip-row reading space")
        capture(app, "444 Streaming stack - Reduce Motion")
        waitAndTap(stack, until: app.buttons["dispatcher-expand-chips"], attempts: 1)
        app.buttons["dispatcher-expand-chips"].tap()
        XCTAssertTrue(navi.waitForExistence(timeout: 5))
        app.buttons["Collapse Dispatchers"].tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        app.buttons["dispatcher-preview-finish-reply"].tap()
        XCTAssertTrue(navi.waitForExistence(timeout: 5), "Resting returns to discoverable chips")
    }
    func testLastDispatcherRestoresIndependentlyOfHomeSelection() {
        let args = ["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
            "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"]
        let app = launchApp(args, attempts: 1)
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15)); navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        let otherAgent = app.buttons["agent-preview-laptop-river"]
        XCTAssertTrue(scrollTo(otherAgent, in: app, maxSwipes: 12))
        otherAgent.tap()
        XCTAssertTrue(app.navigationBars["River"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = args + ["--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-studio"].isSelected)
        capture(app, "444 Saved Dispatcher restored after Home selection")
        // A connected report with no Dispatchers is authoritative and clears the saved choice.
        app.terminate()
        // This existing fixture makes both desktops connected, so neither has an unknown offline catalog.
        app.launchArguments = ["--companion-preview", "--companion-preview-needs-you-multiple-desktops",
            "--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Dispatch"].waitForNonExistence(timeout: 15))
        // Existing cold-launch mirroring may change the legacy host before that report arrives.
        // Set H after removal: cleared D gives Laptop/Echo, while stale Studio D would give Navi.
        XCTAssertTrue(scrollTo(otherAgent, in: app, maxSwipes: 12))
        otherAgent.tap()
        XCTAssertTrue(app.navigationBars["River"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = args + ["--companion-preview-keep-preferences", "--ui-testing-fast"]
        app.launch()
        // A known-empty cache stays on Home; enter the newly available tab before checking its saved choice.
        let dispatch = app.tabBars.buttons["Dispatch"]
        XCTAssertTrue(dispatch.waitForExistence(timeout: 15))
        XCTAssertTrue(dispatch.isHittable)
        dispatch.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 15), "A cleared choice uses the independent Home-host fallback")
        XCTAssertTrue(app.buttons["dispatcher-desktop-preview-laptop"].isSelected)
        capture(app, "444 Removed Dispatcher preference falls back safely")
    }

    // MARK: - #529 / #537

    private func chipStates(_ app: XCUIApplication, samples: Int = 10) -> [String] {
        (0..<samples).map { _ in
            defer { usleep(100_000) }
            return (app.scrollViews["dispatcher-chips"].exists ? "chips" : "-") + "/"
                + (app.buttons["dispatcher-desktop-switcher"].exists ? "stack" : "-")
        }
    }

    /// #537: the reader's Show chips choice holds for the whole turn. A turn streams several messages and the
    /// Dispatcher stays working between them; neither the gap nor the next message collapses the chips again.
    func testShowChipsSurvivesStreamedMessagesWithinTurn() {
        let app = open(["--companion-preview-dispatch-reports", "--companion-preview-dark"])
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15))
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        app.buttons["dispatcher-preview-start-turn"].tap()
        app.buttons["dispatcher-preview-start-reply"].tap()
        let stack = app.buttons["dispatcher-desktop-switcher"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5), "A working turn collapses the chips")
        capture(app, "537 Working turn collapsed")
        waitAndTap(stack, until: app.buttons["dispatcher-expand-chips"], attempts: 1)
        XCTAssertTrue(app.buttons["dispatcher-settings"].exists, "The Dispatcher menu offers Settings")
        app.buttons["dispatcher-expand-chips"].tap()
        let chips = app.scrollViews["dispatcher-chips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 5))
        XCTAssertTrue(stack.waitForNonExistence(timeout: 5))
        let shownFrame = chips.frame
        app.buttons["dispatcher-preview-finish-reply"].tap()
        XCTAssertEqual(Set(chipStates(app)), ["chips/-"], "The gap between messages keeps the reader's choice")
        app.buttons["dispatcher-preview-start-reply"].tap()
        XCTAssertEqual(Set(chipStates(app)), ["chips/-"], "The next message in the turn doesn't collapse the chips again")
        XCTAssertEqual(chips.frame, shownFrame, "The chips never moved or re-animated within the turn")
        capture(app, "537 Show chips held across messages")
        app.buttons["dispatcher-preview-finish-reply"].tap()
        app.buttons["dispatcher-preview-finish-turn"].tap()
        XCTAssertEqual(Set(chipStates(app, samples: 5)), ["chips/-"], "Resting keeps the chips")
        app.buttons["dispatcher-preview-start-turn"].tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5), "The choice lasts one turn; the next turn collapses again")
    }

    /// #529: reading back never changes the header. The chips stay, no bar item appears, and the transcript keeps its
    /// frame, so the reading position doesn't jump and the header doesn't flap near the latest message.
    func testScrollingBackKeepsChipsHeaderAndTranscriptStill() {
        let app = open(["--companion-preview-long-reply", "--companion-preview-dark"])
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15))
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        let chips = app.scrollViews["dispatcher-chips"]
        let transcript = app.scrollViews["companion-transcript"]
        let identity = app.buttons["companion-chat-header"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5) && identity.exists)
        let restTranscript = transcript.frame, restIdentity = identity.frame, restChips = chips.frame
        for distance in [0.03, 0.05, 0.08] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + distance)))
            XCTAssertEqual(Set(chipStates(app)), ["chips/-"], "Reading back \(distance) leaves the chips and bar alone")
            XCTAssertEqual(transcript.frame, restTranscript)
            XCTAssertEqual(identity.frame, restIdentity)
            XCTAssertEqual(chips.frame, restChips)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            XCTAssertEqual(Set(chipStates(app)), ["chips/-"], "Returning to the latest doesn't flap the header")
        }
        capture(app, "529 Reading back keeps the header")
    }

    /// #529: the chip bar sits over the transcript. Collapsing or expanding it swaps only the leading item's content;
    /// the reading position and the centred identity stay where they were, rather than jumping by the row's height.
    func testChipCollapseKeepsReadingPositionAndHeader() {
        let app = open(["--companion-preview-dispatch-reports", "--companion-preview-long-reply", "--companion-preview-light"])
        let navi = app.buttons["dispatcher-desktop-preview-studio"]
        XCTAssertTrue(navi.waitForExistence(timeout: 15))
        navi.tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        // A working turn also adds the footer's activity line; start it first so only the chips change below.
        app.buttons["dispatcher-preview-start-turn"].tap()
        let stack = app.buttons["dispatcher-desktop-switcher"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        waitAndTap(stack, until: app.buttons["dispatcher-expand-chips"], attempts: 1)
        app.buttons["dispatcher-expand-chips"].tap()
        let chips = app.scrollViews["dispatcher-chips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["companion-transcript"]
        let identity = app.buttons["companion-chat-header"]
        // A row on screen in the transcript, found again by its unique text.
        let visible = transcript.staticTexts.allElementsBoundByIndex.last {
            $0.frame.minY > chips.frame.maxY + 60 && $0.frame.maxY < transcript.frame.maxY - 160 && !$0.label.isEmpty
        }
        let label = try? XCTUnwrap(visible?.label)
        XCTAssertNotNil(label)
        let row = transcript.staticTexts[label ?? ""]
        let expandedRow = row.frame, expandedIdentity = identity.frame
        func held(_ state: String) {
            XCTAssertTrue(waitFor(row, NSPredicate { _, _ in abs(row.frame.minY - expandedRow.minY) <= 1 }, timeout: 3),
                          "\(state): the reading position stays put: \(row.frame) vs \(expandedRow)")
            XCTAssertTrue(waitFor(identity, NSPredicate { _, _ in identity.frame == expandedIdentity }, timeout: 3),
                          "\(state): the identity stays centred: \(identity.frame) vs \(expandedIdentity)")
        }
        app.buttons["Collapse Dispatchers"].tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertTrue(chips.waitForNonExistence(timeout: 5))
        held("Collapsed")
        capture(app, "529 Chip collapse keeps reading position")
        waitAndTap(stack, until: app.buttons["dispatcher-expand-chips"], attempts: 1)
        app.buttons["dispatcher-expand-chips"].tap()
        XCTAssertTrue(chips.waitForExistence(timeout: 5))
        held("Expanded again")
    }

    /// #529: Settings is reachable from Dispatch, through the same Settings as Home, whether the chips are
    /// expanded (leading gear) or collapsed (an item in the Dispatcher menu).
    func testSettingsReachableExpandedAndCollapsed() {
        let app = open(["--companion-preview-dispatch-reports", "--companion-preview-light"])
        let settings = app.buttons["dispatcher-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertTrue(settings.isHittable, "\(settings.frame)")
        XCTAssertEqual(settings.label, "Settings")
        waitAndTap(settings, until: app.navigationBars["Settings"], attempts: 1)
        waitAndTap(app.buttons["settings-close"], untilGone: app.navigationBars["Settings"], attempts: 1)
        app.buttons["dispatcher-preview-start-turn"].tap()
        let stack = app.buttons["dispatcher-desktop-switcher"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dispatcher-settings"].exists, "Collapsed, Settings moves into the menu")
        waitAndTap(stack, until: app.buttons["dispatcher-settings"], attempts: 1)
        capture(app, "529 Dispatcher menu with Settings")
        app.buttons["dispatcher-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings-close"].tap()
    }
}
