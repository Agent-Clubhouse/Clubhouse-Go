import XCTest

/// The composer's `/` menu in the preview conversation, whose session lists two CLI commands (start only), a skill
/// and two custom commands. Typing never reaches a desktop.
@MainActor
final class CompanionSlashCommandUITests: ReliableUITestCase {
    private func openRiver(_ app: XCUIApplication) -> XCUIElement {
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "River must appear")
        scrollTo(agent, in: app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(agent, until: composer, timeout: 15, "Opening River shows the composer")
        return composer
    }
    private func item(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "companion-slash-\(name)").firstMatch
    }
    private func value(_ composer: XCUIElement) -> String { composer.value as? String ?? "" }
    /// Near the top of the transcript, clear of the approval's buttons.
    private func tapTranscript(_ app: XCUIApplication) {
        // The keyboard also exposes a ScrollView. Identify the transcript by its own notice, not query order.
        let transcript = app.scrollViews.containing(.staticText, identifier: "Preview conversation · no desktop commands are sent").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let frame = transcript.frame.intersection(app.windows.firstMatch.frame)
        let point = CGPoint(x: frame.midX, y: frame.minY + 12)
        XCTAssertGreaterThan(frame.height, 44, "The transcript must not be the keyboard's 44pt top strip")
        XCTAssertTrue(frame.contains(point))
        XCTAssertFalse(app.keyboards.firstMatch.frame.contains(point))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "companion-slash-menu").firstMatch.frame.contains(point))
        XCTContext.runActivity(named: "Tap actual transcript at \(point), viewport \(frame)") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
    }

    func testTypingSlashSuggestsCommandsAndTappingOneInsertsIt() {
        let app = launchApp(["--companion-preview"])
        let composer = openRiver(app)
        XCTAssertEqual(composer.placeholderValue, "Message River… / for commands")
        let menu = app.descendants(matching: .any).matching(identifier: "companion-slash-menu").firstMatch
        XCTAssertFalse(menu.exists, "No menu before typing")

        composer.tap()
        composer.typeText("/")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Typing / opens the menu")
        for name in ["compact", "clear", "review", "commit", "frontend-design"] {
            XCTAssertTrue(item(name, app).exists, "/\(name) is offered at the start")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer slash menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        composer.typeText("re")
        XCTAssertTrue(waitFor(item("compact", app), NSPredicate(format: "exists == false"), timeout: 5), "Only prefix matches stay")
        XCTAssertTrue(item("review", app).exists)
        waitAndTap(item("review", app), untilGone: menu, "Tapping a command picks it and closes the menu")
        XCTAssertEqual(value(composer), "/review ")
        composer.typeText("42")
        XCTAssertEqual(value(composer), "/review 42", "The caret stays after the inserted command")

        // Mid-message, the CLI's own commands aren't offered.
        composer.typeText(" and /c")
        XCTAssertTrue(item("commit", app).waitForExistence(timeout: 5))
        XCTAssertFalse(item("compact", app).exists, "/compact runs only at the start of a message")
        XCTAssertFalse(item("clear", app).exists)

        // A tap outside the composer closes it.
        tapTranscript(app)
        XCTAssertTrue(waitFor(menu, NSPredicate(format: "exists == false"), timeout: 5), "A tap outside dismisses the menu")
    }

    func testKeyboardMovesAndPicksAndADismissedWordStaysClosed() {
        let app = launchApp(["--companion-preview"])
        let composer = openRiver(app)
        let menu = app.descendants(matching: .any).matching(identifier: "companion-slash-menu").firstMatch
        composer.tap()
        composer.typeText("/c")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // compact, clear, commit: Down twice highlights commit, Tab picks it.
        composer.typeKey(.downArrow, modifierFlags: [])
        composer.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(item("commit", app).isSelected, "The arrows move the highlight")
        composer.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitFor(menu, NSPredicate(format: "exists == false"), timeout: 5))
        XCTAssertEqual(value(composer), "/commit ")

        // Return picks once a name is started. (A synthesized hardware Return never reaches the field, so type it.)
        composer.typeText("then /fr")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        composer.typeText("\n")
        XCTAssertTrue(waitFor(menu, NSPredicate(format: "exists == false"), timeout: 5), "Return picks the highlighted command")
        XCTAssertEqual(value(composer), "/commit then /frontend-design ")
        // With no name started, Return is a new line.
        composer.typeText("/")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        composer.typeText("\n")
        XCTAssertEqual(value(composer), "/commit then /frontend-design /\n")

        // XCUITest can't send Esc to an iOS app, so a tap outside dismisses here. It stays closed for that word,
        // and a new word opens it again.
        composer.typeText("/")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        tapTranscript(app)
        XCTAssertTrue(waitFor(menu, NSPredicate(format: "exists == false"), timeout: 5), "A tap outside dismisses the menu")
        composer.typeText("r")
        XCTAssertFalse(menu.waitForExistence(timeout: 1), "It stays closed for the dismissed word")
        composer.typeText(" /")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "A new word opens it again")
    }
}
