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
        // Leave real history text on screen before the keyboard reduces the transcript viewport.
        XCTAssertTrue(bringTranscriptRowIntoView(app.staticTexts["Reading marker 170."], in: app))
        return composer
    }
    private func item(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "companion-slash-\(name)").firstMatch
    }
    private func value(_ composer: XCUIElement) -> String { composer.value as? String ?? "" }
    /// Tap actual transcript content; the keyboard has its own ScrollView and bottom bars cover part of the AX frame.
    private func tapTranscript(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        let transcript = app.scrollViews.containing(.any, identifier: "companion-tool-preview-reading-failure").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let header = any.matching(identifier: "companion-chat-header").firstMatch
        let menu = app.descendants(matching: .any).matching(identifier: "companion-slash-menu").firstMatch
        let controls = app.buttons["companion-level-menu"]
        let frame = transcript.frame.intersection(app.windows.firstMatch.frame)
        let top = max(frame.minY, header.frame.maxY) + 12
        // Controls and their inset sit above the slash menu; AX can report text
        // behind that inset as hittable. Keep the touch clear of the entire band.
        let bottom = min(frame.maxY, menu.frame.minY, controls.frame.minY) - 16
        let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
        let readableHeight = min(frame.maxY, menu.frame.minY, controls.frame.minY) - max(frame.minY, header.frame.maxY)
        XCTContext.runActivity(named: "Slash layout: transcript \(frame), controls \(controls.frame), menu \(menu.frame), composer \(any.matching(identifier: "companion-composer").firstMatch.frame), readable height \(readableHeight)") { _ in }
        XCTAssertGreaterThanOrEqual(readableHeight, 44, "Typing with the slash menu must leave room to read transcript text")
        // A paragraph can have a clear visible portion when its neighboring
        // heading is clipped. Require a readable band before choosing its center.
        let target = transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
            "Reading marker ", "A stable preview paragraph for testing history"))
            .allElementsBoundByIndex.first { $0.frame.intersection(visible).height >= 16 && $0.isHittable }
        if target == nil {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Slash dismissal target hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertNotNil(target, "Transcript content must be visible above the menu")
        guard let target else { return }
        let hit = target.frame.intersection(visible)
        let point = CGPoint(x: hit.midX, y: hit.midY)
        XCTAssertGreaterThan(frame.height, 44, "The transcript must not be the keyboard's 44pt top strip")
        XCTAssertGreaterThanOrEqual(hit.height, 16, "The tap must land in readable transcript text")
        XCTAssertTrue(frame.contains(point) && target.frame.contains(point))
        XCTAssertFalse(header.frame.contains(point) || app.keyboards.firstMatch.frame.contains(point) || menu.frame.contains(point) || controls.frame.contains(point))
        XCTAssertTrue(menu.exists, "The menu must still be open immediately before the outside tap")
        XCTContext.runActivity(named: "Tap real transcript content at \(point), content frame \(target.frame), visible band \(visible)") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
    }

    func testTypingSlashSuggestsCommandsAndTappingOneInsertsIt() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading"])
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
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "A tap outside dismisses the menu")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A transcript tap also ends editing")
    }

    func testKeyboardMovesAndPicksAndADismissedWordStaysClosed() {
        let app = launchApp(["--companion-preview", "--companion-preview-reading"])
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
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        XCTAssertEqual(value(composer), "/commit ")

        // Return picks once a name is started. (A synthesized hardware Return never reaches the field, so type it.)
        composer.typeText("then /fr")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        composer.typeText("\n")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "Return picks the highlighted command")
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
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "A tap outside dismisses the menu")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A transcript tap also ends editing")
        // Refocus at the end of the last line; a center tap can move the caret
        // into an earlier word in this multiline draft.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("r")
        XCTAssertFalse(menu.waitForExistence(timeout: 1), "It stays closed for the dismissed word")
        composer.typeText(" /")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "A new word opens it again")
    }
}
