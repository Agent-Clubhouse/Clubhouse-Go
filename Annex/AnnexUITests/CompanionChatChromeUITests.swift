import XCTest

@MainActor final class CompanionChatChromeUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testDispatcherTranscriptSpaceWithKeyboardDownAndUp() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-dispatcher-controls", "--companion-preview-context-window", "--companion-preview-long-reply"])
        let composer = element(app, "companion-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        record(app, state: "keyboard-down")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("A draft with more room")
        record(app, state: "keyboard-up")
    }

    private func record(_ app: XCUIApplication, state: String) {
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let header = element(app, "companion-chat-header").frame
        let composer = element(app, "companion-composer-region").frame
        let visibleTop = max(transcript.minY, header.maxY)
        let visibleBottom = min(transcript.maxY, composer.minY)
        print("CHAT_CHROME \(state) transcript=\(transcript) header=\(header) composer=\(composer) visibleTop=\(visibleTop) visibleBottom=\(visibleBottom) height=\(visibleBottom - visibleTop)")
        XCTAssertGreaterThan(visibleBottom - visibleTop, 100)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat chrome \(state)"; shot.lifetime = .keepAlways; add(shot)
    }
}
