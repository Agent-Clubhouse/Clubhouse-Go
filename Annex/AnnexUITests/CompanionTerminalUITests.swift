import XCTest

/// Terminals (#182) against the preview desktop, whose fake shell echoes what's typed and answers `echo`, `pwd` and
/// `stty size`. Nothing reaches a desktop.
@MainActor
final class CompanionTerminalUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the terminal's text to contain `text`.
    @discardableResult
    private func waitForOutput(_ output: XCUIElement, containing text: String, timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let found = waitFor(output, NSPredicate(format: "value CONTAINS %@", text), timeout: timeout)
        XCTAssertTrue(found, "The terminal must show \"\(text)\"; it shows \(String(describing: output.value))", file: file, line: line)
        return found
    }

    private func openProjectTerminal(_ app: XCUIApplication) -> XCUIElement {
        let header = element(app, "open-project-preview-studio-clubhouse")
        scrollTo(header, in: app, maxSwipes: 4)
        let terminal = app.buttons["project-terminal"]
        waitAndTap(header, until: terminal, timeout: 10, "The project page must offer Terminal")
        let output = element(app, "terminal-output")
        waitAndTap(terminal, until: output, timeout: 10, "Terminal must open a full-screen terminal")
        return output
    }

    func testProjectTerminalEchoesTypingAndOffersTheKeyBar() {
        let app = launchApp(["--companion-preview"])
        let output = openProjectTerminal(app)
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5), "The terminal is titled with its project")
        waitForOutput(output, containing: "Preview shell")
        waitForOutput(output, containing: "clubhouse %")

        for key in ["esc", "tab", "ctrl", "interrupt", "left", "up", "down", "right", "|", "~", "/"] {
            XCTAssertTrue(element(app, "terminal-key-\(key)").exists, "The key bar offers \(key)")
        }
        XCTAssertTrue(element(app, "terminal-paste").exists, "The key bar offers Paste")
        let ctrl = element(app, "terminal-key-ctrl")
        ctrl.tap()
        XCTAssertTrue(ctrl.isSelected, "Ctrl stays down for the next key")
        ctrl.tap()
        XCTAssertFalse(ctrl.isSelected, "Tapping Ctrl again releases it")

        // The keyboard comes up with the terminal; typing goes straight to the shell, which echoes it.
        app.typeText("echo hello from the phone\n")
        // The echoed command may wrap at the phone's width; its output is on a line of its own.
        waitForOutput(output, containing: "\nhello from the phone\n")
        app.typeText("pwd\n")
        waitForOutput(output, containing: "/Users/river/clubhouse")

        // ⌃C interrupts the line, and symbols from the bar go in as typed.
        app.typeText("sleep")
        element(app, "terminal-key-interrupt").tap()
        waitForOutput(output, containing: "sleep^C")
        element(app, "terminal-key-~").tap()
        element(app, "terminal-key-|").tap()
        app.typeText("\n")
        waitForOutput(output, containing: "command not found: ~|")

        screenshot(app, "Project terminal")

        // Long-pressing selects the output for copying.
        output.press(forDuration: 1.2)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists, "The output can be selected and copied")

        waitAndTap(element(app, "terminal-menu"), until: app.buttons["Copy all"], timeout: 5)
        app.buttons["Copy all"].tap()
        waitAndTap(app.buttons["terminal-done"], untilGone: output, timeout: 5, "Done closes the terminal")
    }

    func testTerminalFollowsRotation() {
        let app = launchApp(["--companion-preview"])
        let output = openProjectTerminal(app)
        waitForOutput(output, containing: "clubhouse %")
        app.typeText("stty size\n")
        waitForOutput(output, containing: "stty size\n")
        let portrait = String(describing: output.value)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        // Let the rotation and the debounced resize settle before asking again.
        _ = waitFor(app.windows.firstMatch, NSPredicate(format: "frame.size.width > frame.size.height"), timeout: 5)
        sleep(1)
        app.typeText("stty size\n")
        let changed = waitFor(output, NSPredicate { value, _ in
            guard let text = (value as? XCUIElement)?.value as? String else { return false }
            let sizes = text.components(separatedBy: "\n").filter { $0.range(of: #"^\d+ \d+$"#, options: .regularExpression) != nil }
            return sizes.count >= 2 && sizes[0] != sizes[1]
        }, timeout: 10)
        XCTAssertTrue(changed, "Rotating resizes the shell; before: \(portrait), after: \(String(describing: output.value))")
        screenshot(app, "Terminal in landscape")
    }

    func testAgentMenusOpenItsShellAndATerminalAgentShowsItsOwnTerminal() {
        let app = launchApp(["--companion-preview", "--companion-preview-terminal-agent"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app), "River's row must be on screen")
        let terminal = app.buttons["Terminal"]
        longPressUntilMenu(river, shows: terminal, "The long-press menu offers Terminal")
        let output = element(app, "terminal-output")
        waitAndTap(terminal, until: output, timeout: 10)
        waitForOutput(output, containing: "river %")
        app.typeText("pwd\n")
        waitForOutput(output, containing: "/Users/river/clubhouse/.clubhouse/agents/river")
        XCTAssertTrue(app.navigationBars["River"].exists, "An agent's shell is titled with the agent")
        waitAndTap(app.buttons["terminal-done"], untilGone: output, timeout: 5)

        // A terminal-mode agent's chat is its own terminal, not the "runs in a terminal" notice.
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        let sequoia = element(app, "agent-preview-studio-sequoia")
        XCTAssertTrue(scrollUntilExists(sequoia, in: app) && scrollTo(sequoia, in: app), "Sequoia's row must be on screen")
        waitAndTap(sequoia, until: output, timeout: 10, "Sequoia's chat shows its terminal")
        waitForOutput(output, containing: "Welcome to Claude Code")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "runs in a terminal on your desktop")).firstMatch.exists)
        XCTAssertTrue(element(app, "terminal-key-interrupt").exists, "The agent's terminal takes input")
        screenshot(app, "Terminal agent")

        // The chat ⋯ menu opens a shell in the agent's worktree.
        let actions = app.navigationBars.buttons["Conversation actions"]
        waitAndTap(actions, until: terminal, timeout: 5, "The chat menu offers Terminal")
    }
}
