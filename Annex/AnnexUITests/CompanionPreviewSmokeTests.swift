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

        // Swipe down.
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
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
        XCTAssertTrue(app.staticTexts["Choose this on your desktop"].exists, "Persistent options say where to choose them")
        XCTAssertFalse(app.buttons["Always allow"].exists, "A phone can't send a persistent option")
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
        XCTAssertTrue(element("fold-finished-preview-studio-clubhouse").label.contains("1 finished quick agent"))
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
}
