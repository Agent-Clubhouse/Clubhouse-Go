import XCTest

/// Synthesized hardware events in a preview-only conversation; never sends to a desktop.
/// This checks simulator event delivery, not a physical keyboard or iPhone Mirroring session.
@MainActor
final class CompanionHardwareKeyboardUITests: ReliableUITestCase {
    func testHardwareReturnSelectsSlashThenSendsAndShiftReturnKeepsNewline() {
        let app = launchApp(["--companion-preview"])
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollTo(river, in: app))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(river, until: composer)
        composer.tap()
        let refusal = app.staticTexts["Preview only. Pair a desktop to send messages."]
        let emptyValue = composer.value as? String
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(composer.value as? String, emptyValue, "Empty hardware Return must not alter the draft")
        XCTAssertFalse(refusal.exists)

        composer.typeText("/fr")
        let menu = app.otherElements["companion-slash-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "/frontend-design "), timeout: 5))
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        XCTAssertFalse(refusal.exists, "Return selects an active partial command before sending")

        composer.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", "/frontend-design \n"), timeout: 5))
        composer.typeText("Keyboard preview")
        XCTAssertFalse(refusal.exists, "Shift Return only edits the draft")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(refusal.waitForExistence(timeout: 5), "Hardware Return reaches the guarded preview Send path")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Hardware Return reaches preview-only Send"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
