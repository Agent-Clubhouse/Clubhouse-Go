import XCTest

/// Exercises the new SwiftUI navigation on a real simulator without enrolling
/// any desktop, storing credentials, or pretending preview commands succeeded.
@MainActor
final class CompanionPreviewSmokeTests: XCTestCase {
    func testPreviewOpensScopedConversationAndKeepsCommandsNonLive() {
        continueAfterFailure = false
        // The launch-configuration matrix can leave the shared device in landscape.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Selecting an agent must open its conversation")
        XCTAssertTrue(app.navigationBars["River"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native companion conversation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        composer.tap()
        composer.typeText("Preview smoke message")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 5), "Preview must never claim a command reached a desktop")
    }

    /// A one-line composer shorter than its text view's content scrolls to the caret as you type,
    /// which reads as the text jittering until it wraps. One line must be exactly half of two lines.
    func testComposerSingleLineHeightMatchesWrappedLineHeight() {
        continueAfterFailure = false
        // Each keystroke and frame read is a slow round trip on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let send = app.buttons["companion-send"]
        XCTAssertEqual(composer.frame.midY, send.frame.midY, accuracy: 0.5, "The placeholder must be centred against the send button")
        composer.tap()
        composer.typeText("Hey")
        let oneLine = composer.frame.height
        XCTAssertEqual(composer.frame.midY, send.frame.midY, accuracy: 0.5, "One line of text must be centred against the send button")
        // Two words at a time: fewer round trips, and still far short of a whole line, so it stops at two lines.
        for _ in 0..<10 where composer.frame.height <= oneLine + 1 {
            composer.typeText(" steady steady")
        }
        let twoLines = composer.frame.height
        XCTAssertGreaterThan(twoLines, oneLine + 1, "Composer must grow when the draft wraps")
        XCTAssertEqual(oneLine, twoLines / 2, accuracy: 0.5, "A single line must use the same line height as wrapped lines")
        // The field's padding, not the row, sets the bottom of a long draft, so allow the ~1pt difference.
        XCTAssertEqual(composer.frame.maxY - send.frame.maxY, (oneLine - send.frame.height) / 2, accuracy: 1.5,
                       "As the draft grows, Send must stay level with the last line")
    }

    /// Dynamic Type changes the line height but not the send button, so check centring at a large size too.
    func testComposerCentresOneLineAtLargeText() {
        continueAfterFailure = false
        // Keystrokes and frame reads at accessibility sizes are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<6 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let send = app.buttons["companion-send"]
        XCTAssertEqual(composer.frame.midY, send.frame.midY, accuracy: 0.5, "The placeholder must be centred against the send button")
        composer.tap()
        composer.typeText("Hey")
        XCTAssertEqual(composer.frame.midY, send.frame.midY, accuracy: 0.5, "One line of text must be centred against the send button")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer at accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// A preview opened from a tool card must close while the agent keeps streaming, even as the card is
    /// re-projected and lookups around it fold into "Explored…" (#134).
    func testContentPreviewDismissesWhileToolUpdatesStream() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview", "--companion-preview-stream"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "build/test-log.txt")).firstMatch
        let done = app.buttons["companion-preview-done"]
        let title = app.navigationBars["test-log.txt"]

        // Done: wait through several updates, including a fold, before closing.
        XCTAssertTrue(link.waitForExistence(timeout: 15), "The streaming tool card must offer its log")
        link.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done must show while the preview loads")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The sample file must load")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(done.isHittable, "Done must stay reachable while updates stream")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done must close the preview while updates stream")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "After closing preview with Done"
        add(screenshot)

        // Swipe down. New runs keep pushing older cards up under the header, so open the newest card's log,
        // which stays next to the composer.
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        let links = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "build/test-log.txt"))
        links.element(boundBy: max(0, links.count - 1)).tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Swiping down must close the preview while updates stream")
    }

    /// Agent replies render block Markdown natively: the sample reply's heading, table and list
    /// appear as elements, and none of the raw syntax (`## `, `|---|`) reaches the screen.
    func testAgentReplyRendersBlockMarkdown() {
        continueAfterFailure = false
        // Element queries over a long conversation are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10))

        // The conversation opens at the latest item; the reply sits just above the approval.
        let heading = app.staticTexts["Reconnect status"]
        if !heading.waitForExistence(timeout: 10) {
            for _ in 0..<3 where !heading.exists { app.swipeDown() }
        }
        XCTAssertTrue(heading.exists, "The heading must render without its hashes")
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Row 1.' AND label CONTAINS 'Check: Resume after sleep'")).firstMatch
        XCTAssertTrue(row.exists, "The table must render as rows VoiceOver reads cell by cell")
        XCTAssertTrue(app.staticTexts["Keep drafts per agent"].exists, "The task list item must render")
        XCTAssertTrue(app.images["Done"].exists, "A checked task shows its checkbox")

        let raw = NSPredicate(format: "label CONTAINS '|---' OR label CONTAINS '|:--' OR label CONTAINS '| Check' OR label BEGINSWITH '## ' OR label BEGINSWITH '- ['")
        XCTAssertEqual(app.staticTexts.matching(raw).count, 0, "No raw Markdown syntax may reach the screen")
        XCTAssertFalse(app.staticTexts["Agent"].exists, "Agent replies carry no author label, like the desktop")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Block Markdown reply"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Desktop parity (#149): read-only lookups fold into "Explored 2 files, 1 search" and keep their links;
    /// the approval card shows its own title, "1 of 2", and the persistent option the desktop answers;
    /// the header shows what the agent waits on and its context fill.
    func testExploredFoldAndApprovalCardMatchDesktop() {
        continueAfterFailure = false
        // Scrolling and element queries over a long conversation are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.placeholderValue, "Message River…", "The placeholder names the agent, like the desktop")

        // Header: what River waits on, and how full its context is.
        let activity = app.staticTexts.matching(identifier: "companion-chat-activity").firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertEqual(activity.label, "Run xcodebuild", "The activity line names the oldest waiting request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-context-usage").firstMatch.label.contains("42%"))

        // The approval card: the request's title, its place in the queue, and the desktop-only option.
        let position = app.staticTexts.matching(identifier: "companion-approval-position").firstMatch
        if !position.waitForExistence(timeout: 5) {
            for _ in 0..<3 where !position.exists { app.swipeUp() }
        }
        XCTAssertTrue(position.exists, "Two waiting approvals must show their count")
        XCTAssertTrue(app.staticTexts["Run xcodebuild"].exists, "The card uses the request's title")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'Always allow' AND label CONTAINS 'xcodebuild:*'")).firstMatch.exists,
                      "Persistent options stay listed, with their scope")
        XCTAssertTrue(app.buttons["companion-approval-option-allow-always"].exists, "A desktop that takes lasting options gets a button")
        XCTAssertFalse(app.staticTexts["Choose this on your desktop"].exists)
        XCTAssertFalse(app.staticTexts["Your approval is needed"].exists)
        let approvalShot = XCTAttachment(screenshot: app.screenshot())
        approvalShot.name = "Approval card with title, count and persistent option"
        approvalShot.lifetime = .keepAlways
        add(approvalShot)

        // The explored fold sits above the replies: scroll up to it.
        let fold = app.buttons.matching(identifier: "companion-explore-group").firstMatch
        for _ in 0..<8 where !(fold.exists && fold.isHittable) { app.swipeDown() }
        XCTAssertTrue(fold.isHittable, "Read-only lookups must fold into one row")
        XCTAssertTrue(fold.label.contains("Explored 2 files, 1 search"), "The fold counts like the desktop: \(fold.label)")
        XCTAssertFalse(any.matching(NSPredicate(format: "label BEGINSWITH 'Ran '")).firstMatch.exists, "The old \"Ran N tools\" fold is gone")
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Run' AND label CONTAINS 'swift test --filter'")).firstMatch.exists,
                      "The test run stays unfolded, labelled with the desktop's verb")
        let links = app.buttons.matching(identifier: "companion-content-link")
        XCTAssertTrue(links.matching(NSPredicate(format: "label == %@", "/Users/river/clubhouse/.build/test.log")).firstMatch.exists,
                      "An absolute path inside the agent's content roots is offered")
        XCTAssertFalse(links.matching(NSPredicate(format: "label == %@", "/tmp/scratch.txt")).firstMatch.exists, "A path outside the roots is not")

        // Each lookup's link opens from inside the fold, and its preview closes.
        fold.tap()
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", "Sources/Companion/Conversation.swift")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "An expanded fold offers each lookup's links")
        let foldShot = XCTAttachment(screenshot: app.screenshot())
        foldShot.name = "Explored fold expanded"
        foldShot.lifetime = .keepAlways
        add(foldShot)
        // The expanded calls open under the composer: bring the fold's header up near the top first.
        fold.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)))
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let done = app.buttons["companion-preview-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "A link inside the fold opens its preview")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "The preview closes")
    }

    /// Home matches the desktop sidebar: idle projects fold into one section, sleeping and finished
    /// quick agents fold inside a project, and a pinned project moves to the top.
    func testHomeFoldsIdleProjectsAndPinsToTop() {
        continueAfterFailure = false
        // Scrolling and element queries are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
        func reveal(_ target: XCUIElement) {
            for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        }
        func scrollToTop() { for _ in 0..<3 { app.swipeDown(velocity: .fast) } }

        XCTAssertTrue(element("agent-preview-studio-river").waitForExistence(timeout: 15), "Preview desktop must load")
        let cedar = element("agent-preview-studio-cedar")
        reveal(cedar)
        XCTAssertTrue(cedar.label.contains("Free Agent Mode"), "A Free Agent Mode agent must say so on its row")

        let sleeping = element("fold-sleeping-preview-studio-clubhouse")
        reveal(sleeping)
        XCTAssertTrue(sleeping.label.contains("1 sleeping"))
        XCTAssertFalse(element("agent-preview-studio-juniper").exists, "Sleeping agents start folded")
        XCTAssertTrue(element("fold-finished-preview-studio-clubhouse").label.contains("3 finished quick agents"))
        sleeping.tap()
        XCTAssertTrue(element("agent-preview-studio-juniper").waitForExistence(timeout: 5), "Opening the fold shows the sleeping agent")

        let idle = element("idle-projects-fold")
        reveal(idle)
        XCTAssertTrue(idle.label.contains("1 idle project"))
        XCTAssertFalse(element("project-preview-studio-prototype").exists, "Idle projects start folded")
        idle.tap()
        XCTAssertTrue(element("project-preview-studio-prototype").waitForExistence(timeout: 5), "Opening the idle section shows the project")

        scrollToTop()
        let menu = element("project-menu-preview-studio-website")
        reveal(menu)
        menu.tap()
        let pin = app.buttons["Pin project"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        scrollToTop()
        let website = element("project-preview-studio-website"), clubhouse = element("project-preview-studio-clubhouse")
        reveal(website)
        XCTAssertTrue(clubhouse.waitForExistence(timeout: 5))
        XCTAssertLessThan(website.frame.minY, clubhouse.frame.minY, "A pinned project goes first")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home with a pinned project and the idle section"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// A sleeping agent with a session offers both of the desktop's wake choices, in its chat and on its row.
    func testSleepingAgentOffersWakeAndResumeAndStartNewSession() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let juniper = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-juniper").firstMatch
        // Home folds sleeping agents; open the fold to reach Juniper.
        func unfoldJuniper() {
            let fold = app.descendants(matching: .any).matching(identifier: "fold-sleeping-preview-studio-clubhouse").firstMatch
            for _ in 0..<4 where !(fold.waitForExistence(timeout: 2) && fold.isHittable) { app.swipeUp() }
            if !juniper.exists { fold.tap() }
            for _ in 0..<4 where !juniper.waitForExistence(timeout: 2) { app.swipeUp() }
        }
        unfoldJuniper()
        XCTAssertTrue(juniper.waitForExistence(timeout: 15), "The sleeping preview agent must appear")

        juniper.tap()
        let resume = app.buttons["companion-wake"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "The asleep bar must appear")
        XCTAssertEqual(resume.label, "Wake & Resume")
        let fresh = app.buttons["companion-wake-newSession"]
        XCTAssertTrue(fresh.exists)
        XCTAssertEqual(fresh.label, "Start New Session")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Wake choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        if !juniper.waitForExistence(timeout: 5) { unfoldJuniper() }
        XCTAssertTrue(juniper.waitForExistence(timeout: 10))
        juniper.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Wake & Resume"].waitForExistence(timeout: 5), "The long-press menu offers Wake & Resume")
        XCTAssertTrue(app.buttons["Start New Session"].exists, "The long-press menu offers Start New Session")
        XCTAssertTrue(app.buttons["Agent settings"].exists)
    }

    /// Needs you says why in the desktop's words, and shows how long an approval has.
    func testNeedsYouUsesTheDesktopWords() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        XCTAssertTrue(app.staticTexts["Needs permission to use Bash"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Run xcodebuild"].exists, "The request's title goes under the reason")
        let countdown = app.descendants(matching: .any).matching(identifier: "companion-approval-countdown").firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertTrue(countdown.label.contains("Times out in"), countdown.label)
    }

    /// Agent details opens from the chat header and the long-press menu, shows the hover card's fields, and links to settings.
    func testAgentDetailsSheetMatchesTheDesktopHoverCard() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let any = app.descendants(matching: .any)
        func element(_ id: String) -> XCUIElement { any.matching(identifier: id).firstMatch }
        func scrollTo(_ target: XCUIElement) { for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp() } }

        let river = element("agent-preview-studio-river")
        for _ in 0..<4 where !river.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(river.waitForExistence(timeout: 15), "Preview agent must appear")
        river.tap()
        let actions = app.buttons["Conversation actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        let details = app.buttons["Agent details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), "The chat header offers the agent's details")
        details.tap()

        // The settings route's details fill in the workspace and changes.
        let branch = element("agent-details-branch")
        XCTAssertTrue(branch.waitForExistence(timeout: 10))
        XCTAssertTrue(branch.label.contains("river/companion"), branch.label)
        XCTAssertTrue(element("agent-details-worktree").label.contains(".clubhouse/agents/river"))
        XCTAssertTrue(element("agent-details-cli").label.contains("Claude Code 2.1.4"), "Runs on with the session's CLI version")
        XCTAssertTrue(element("agent-details-effort").label.contains("High"))
        XCTAssertTrue(element("agent-details-access").label.contains("Auto-accept edits"), "The live permission level")
        let freeAgent = element("agent-details-free-agent-mode")
        scrollTo(freeAgent)
        XCTAssertTrue(freeAgent.label.contains("Off"))
        let autoSleep = element("agent-details-auto-sleep")
        scrollTo(autoSleep)
        XCTAssertTrue(autoSleep.label.contains("Sleeps after 30 min"))
        let mcp = element("agent-details-mcp-summary")
        scrollTo(mcp)
        XCTAssertEqual(mcp.label, "2 connected · 1 needs sign-in · 1 configured", "The MCP card's summary")
        let changes = element("agent-details-changes")
        scrollTo(changes)
        XCTAssertTrue(changes.label.contains("6 files +94 −51"), changes.label)
        XCTAssertTrue(app.staticTexts["2 commits ahead of main · 1 uncommitted"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Agent details"
        shot.lifetime = .keepAlways
        add(shot)

        // Agent settings opens from the sheet, for editing.
        let openSettings = element("agent-details-open-settings")
        scrollTo(openSettings)
        openSettings.tap()
        XCTAssertTrue(element("agent-settings-summary").waitForExistence(timeout: 10), "Details links to the agent's settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(openSettings.waitForNonExistence(timeout: 5))

        // From an agent row's long-press menu: Juniper works in the project folder, with nothing changed.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Sleeping agents start folded on Home.
        let sleeping = element("fold-sleeping-preview-studio-clubhouse")
        for _ in 0..<4 where !(sleeping.exists && sleeping.isHittable) { app.swipeUp() }
        sleeping.tap()
        let juniper = element("agent-preview-studio-juniper")
        for _ in 0..<4 where !juniper.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(juniper.waitForExistence(timeout: 10))
        juniper.press(forDuration: 1.2)
        let rowDetails = app.buttons["Agent details"]
        XCTAssertTrue(rowDetails.waitForExistence(timeout: 5), "The long-press menu offers the agent's details")
        rowDetails.tap()
        let worktree = element("agent-details-worktree")
        XCTAssertTrue(worktree.waitForExistence(timeout: 10))
        XCTAssertTrue(worktree.label.contains("Works in the project folder"), worktree.label)
        XCTAssertFalse(element("agent-details-effort").exists, "No session, so no effort is guessed")
        let juniperChanges = element("agent-details-changes")
        scrollTo(juniperChanges)
        XCTAssertTrue(juniperChanges.label.contains("No changes"), juniperChanges.label)
    }

    /// The desktop composer's pills (#155): level, model and effort menus with the desktop's labels, a confirmation
    /// before raising to Full access, and "Always allow" as a confirmed secondary action. Preview refuses every change.
    func testChatControlsMenusAndPersistentApproval() {
        continueAfterFailure = false
        // Menus, dialogs and scrolling are slow round trips on CI runners.
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()
        let any = app.descendants(matching: .any)
        func item(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch }
        let previewError = app.staticTexts["Preview only. This action does not contact a desktop."]
        let dismissError = app.buttons["Dismiss"]

        // The header shows the current level.
        let header = any.matching(identifier: "companion-chat-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("Auto-accept edits"), "The header shows the level: \(header.label)")

        // Level: the ladder, with the driver's names, and a confirmation before Full access.
        let level = any.matching(identifier: "companion-level-menu").firstMatch
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        level.tap()
        let fullAccess = item("Full access")
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5), "Every live level is offered")
        for label in ["Plan", "Ask first", "Auto-accept edits", "Auto"] { XCTAssertTrue(item(label).exists, label) }
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'bypassPermissions'")).firstMatch.exists, "The driver's own name is the subtitle")
        let levelShot = XCTAttachment(screenshot: app.screenshot())
        levelShot.name = "Permission level menu"
        levelShot.lifetime = .keepAlways
        add(levelShot)
        fullAccess.tap()
        let confirmLevel = app.buttons["Switch to Full access"]
        XCTAssertTrue(confirmLevel.waitForExistence(timeout: 5), "Raising to Full access asks first")
        confirmLevel.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5), "Preview must never claim the level changed")
        dismissError.tap()

        // Model: the session's models, and when a change applies.
        let model = any.matching(identifier: "companion-model-menu").firstMatch
        XCTAssertTrue(model.exists)
        XCTAssertTrue(model.label.contains("Opus"), "The chip names the model: \(model.label)")
        model.tap()
        let mini = item("Haiku")
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertTrue(any.matching(NSPredicate(format: "label == 'Applies from the next message.'")).firstMatch.exists, "The switch note shows under the menu")
        let modelShot = XCTAttachment(screenshot: app.screenshot())
        modelShot.name = "Model menu"
        modelShot.lifetime = .keepAlways
        add(modelShot)
        mini.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5))
        dismissError.tap()

        // Effort: sentence case, with Default when the provider has one.
        let effort = any.matching(identifier: "companion-effort-menu").firstMatch
        XCTAssertTrue(effort.exists)
        XCTAssertTrue(effort.label.contains("High effort"), "The chip names the effort: \(effort.label)")
        effort.tap()
        let extraHigh = item("Extra high")
        XCTAssertTrue(extraHigh.waitForExistence(timeout: 5), "xhigh reads as Extra high")
        XCTAssertTrue(item("Default").exists, "Default is offered when the provider has one")
        extraHigh.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5))
        dismissError.tap()

        // Always allow: a secondary action, confirmed first.
        let always = app.buttons["companion-approval-option-allow-always"]
        for _ in 0..<4 where !(always.exists && always.isHittable) { app.swipeUp() }
        XCTAssertTrue(always.isHittable, "Always allow is tappable on a desktop that takes it")
        always.tap()
        let confirmAlways = app.buttons.matching(NSPredicate(format: "label == 'Always allow'")).firstMatch
        XCTAssertTrue(confirmAlways.waitForExistence(timeout: 5), "Always allow asks first")
        let approvalShot = XCTAttachment(screenshot: app.screenshot())
        approvalShot.name = "Always allow confirmation"
        approvalShot.lifetime = .keepAlways
        add(approvalShot)
        confirmAlways.tap()
        XCTAssertTrue(previewError.waitForExistence(timeout: 5), "Preview must never claim the approval was sent")
    }

    /// Helper requests show in Needs you with the desktop's line. A dispose with work at risk is "Dispose anyway",
    /// asks first as the desktop's dispose dialog does, and the preview never claims it reached a desktop.
    func testNeedsYouAnswersHelperRequestsWithTheDesktopRules() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview", "--companion-preview-helper-requests"]
        app.launch()
        let tab = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        XCTAssertTrue(app.staticTexts["Wants to start the helper docs-pass"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Update the reconnect section of the README"].exists, "A start shows the helper's task")
        let summary = app.staticTexts["River asked to dispose this helper. 2 uncommitted files, 1 unpushed commit."]
        let disposeAnyway = app.buttons.matching(identifier: "helper-request-approve").matching(NSPredicate(format: "label == 'Dispose anyway'")).firstMatch
        for _ in 0..<4 where !(disposeAnyway.exists && disposeAnyway.isHittable) { app.swipeUp() }
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dispose anyway deletes this work. To keep it, commit and push from Cedar first."].exists)
        XCTAssertTrue(disposeAnyway.waitForExistence(timeout: 5), "Work at risk makes the dispose \"Dispose anyway\"")
        disposeAnyway.tap()
        XCTAssertTrue(app.staticTexts["Dispose of Cedar?"].waitForExistence(timeout: 5), "Disposing asks first")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Helper dispose confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Dispose anyway' AND identifier != 'helper-request-approve'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let error = app.descendants(matching: .any).matching(identifier: "helper-request-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Preview must never claim a command reached a desktop")
        XCTAssertEqual(error.label, "Preview only. This action does not contact a desktop.")
    }

    /// The project page (#158): a project header on Home opens it. Finished quick agents can be dismissed, the
    /// Changes list opens a native diff that scrolls sideways, agents open and come back, and a sleeping agent wakes
    /// with a message.
    func testProjectPageFinishedChangesAndWake() {
        continueAfterFailure = false
        // Swipes, sheets and element queries are slow round trips on CI runners.
        executionTimeAllowance = 300
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview"]
        app.launch()
        let any = app.descendants(matching: .any)
        let header = any.matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        for _ in 0..<4 where !(header.waitForExistence(timeout: 2) && header.isHittable) { app.swipeUp() }
        XCTAssertTrue(header.isHittable, "A project header must open its page")
        // A tap while the list is still settling from the swipes only stops it, so tap again if nothing opened.
        let finishedHeader = app.staticTexts["Finished, waiting on you"]
        for _ in 0..<3 where !finishedHeader.exists {
            header.tap()
            _ = finishedHeader.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(finishedHeader.waitForExistence(timeout: 10))
        let willow = any.matching(identifier: "finished-quick-willow").firstMatch
        let aspen = any.matching(identifier: "finished-quick-aspen").firstMatch
        XCTAssertTrue(willow.waitForExistence(timeout: 5) && aspen.exists)
        XCTAssertLessThan(willow.frame.minY, aspen.frame.minY, "The newest run comes first")
        XCTAssertTrue(willow.label.contains("Tidy the onboarding copy") && willow.label.contains("m ago"), willow.label)
        XCTAssertTrue(aspen.label.contains("Exited with code 1"), aspen.label)
        XCTAssertTrue(app.buttons["project-new-agent"].isEnabled)
        XCTAssertTrue(app.buttons["project-wake"].isEnabled, "Juniper is asleep, so Wake with a message is offered")
        let pageShot = XCTAttachment(screenshot: app.screenshot())
        pageShot.name = "Project page"
        pageShot.lifetime = .keepAlways
        add(pageShot)

        willow.swipeLeft()
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "A finished run swipes to Dismiss")
        dismiss.tap()
        XCTAssertTrue(willow.waitForNonExistence(timeout: 5), "A dismissed run leaves the list")
        XCTAssertTrue(aspen.exists)

        // An agent opens from the page and Back returns to it.
        let river = any.matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<3 where !(river.exists && river.isHittable) { app.swipeUp() }
        river.tap()
        XCTAssertTrue(any.matching(identifier: "companion-composer").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["project-changes"].waitForExistence(timeout: 5), "Back returns to the project page")

        // Changes: each file with its status, and a tap opens its diff.
        let changes = app.buttons["project-changes"]
        for _ in 0..<3 where !changes.isHittable { app.swipeUp() }
        changes.tap()
        let modified = any.matching(identifier: "changed-file-Sources/Companion/Conversation.swift").firstMatch
        XCTAssertTrue(modified.waitForExistence(timeout: 10))
        XCTAssertTrue(modified.label.hasPrefix("Modified, Conversation.swift"), modified.label)
        XCTAssertTrue(any.matching(identifier: "changed-file-Sources/Companion/ProjectPage.swift").firstMatch.label.hasPrefix("Added"))
        XCTAssertTrue(any.matching(identifier: "changed-file-Docs/Old notes.md").firstMatch.label.hasPrefix("Deleted"))
        XCTAssertTrue(any.matching(identifier: "changed-file-Sources/Companion/Reconnect.swift").firstMatch.label.contains("Renamed, Reconnect.swift, from Sources/Companion/Retry.swift"))
        let changesShot = XCTAttachment(screenshot: app.screenshot())
        changesShot.name = "Project changes"
        changesShot.lifetime = .keepAlways
        add(changesShot)
        modified.tap()

        let summary = any.matching(identifier: "diff-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("+2") && summary.label.contains("−1"), summary.label)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Added, line 3: ' AND label CONTAINS 'let target: ConversationTarget'")).firstMatch.exists)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Removed, line 7: '")).firstMatch.exists)
        let long = any.matching(NSPredicate(format: "label CONTAINS 'edited to explain why'")).firstMatch
        XCTAssertTrue(long.exists)
        let before = long.frame.minX
        let diffShot = XCTAttachment(screenshot: app.screenshot())
        diffShot.name = "File diff"
        diffShot.lifetime = .keepAlways
        add(diffShot)
        any.matching(identifier: "diff-lines").firstMatch.swipeLeft()
        XCTAssertLessThan(long.frame.minX, before - 20, "Long lines scroll sideways rather than wrapping")

        // Wake with a message: Juniper's chat opens with the message, which a preview never delivers.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(modified.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let wake = app.buttons["project-wake"]
        for _ in 0..<3 where !(wake.exists && wake.isHittable) { app.swipeDown() }
        wake.tap()
        let message = any.matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wake-agent-picker"].label.contains("Juniper") || any.matching(NSPredicate(format: "label CONTAINS 'Juniper'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["wake-send"].isEnabled, "Wake needs a message")
        message.typeText("Draft the release notes")
        let send = app.buttons["wake-send"]
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5), "A message enables Wake")
        send.tap()
        XCTAssertTrue(app.navigationBars["Juniper"].waitForExistence(timeout: 10), "Waking opens the agent's chat")
        // DIAGNOSTIC (do not merge): what iOS 26.5 shows after the wake, and whether scrolling materialises the rows.
        func snap(_ name: String) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "DIAG \(name) tree"; tree.lifetime = .keepAlways; add(tree)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DIAG \(name) shot"; shot.lifetime = .keepAlways; add(shot)
        }
        snap("0s")
        sleep(3); snap("3s")
        let scroll = app.scrollViews.firstMatch
        scroll.swipeDown(); sleep(1); snap("after swipe down")
        scroll.swipeUp(); scroll.swipeUp(); sleep(1); snap("after swipe up")
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 10),
                      "The message is sent, and a preview says it never reached a desktop")
    }
}
