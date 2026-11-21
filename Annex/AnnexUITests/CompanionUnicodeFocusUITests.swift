import XCTest

@MainActor final class CompanionUnicodeFocusUITests: ReliableUITestCase {
    private static let draft = "\u{1F469}\u{200D}\u{1F4BB}\u{1F1FA}\u{1F1F3}\u{1F44D}\u{1F3FD}\u{20000}"
    private static let initialDrafts = [
        "\u{1F642}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F1FA}\u{1F1F3}",
        "\u{1F44D}\u{1F3FD}", "\u{20000}"
    ]

    private func openCreatedAgent(_ app: XCUIApplication) {
        let fold = app.descendants(matching: .any).matching(identifier: "fold-quiet-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(fold, in: app) && scrollTo(fold, in: app))
        let juniper = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-juniper").firstMatch
        if !juniper.exists { fold.tap() }
        XCTAssertTrue(juniper.waitForExistence(timeout: 5) && scrollTo(juniper, in: app))
        juniper.tap()
        XCTAssertTrue(app.buttons["companion-wake-with-message"].waitForExistence(timeout: 10))
    }

    private func launchUnicode(draft: String? = nil, expected: String? = nil, animations: Bool = false) -> XCUIApplication {
        let text = draft ?? Self.draft
        let arguments = ["--companion-preview", "--companion-preview-unicode-focus"]
        let environment = ["COMPANION_UNICODE_DRAFT": text, "COMPANION_UNICODE_EXPECTED": expected ?? text + "q"]
        let app: XCUIApplication
        if animations {
            continueAfterFailure = false
            executionTimeAllowance = 300
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = arguments
            app.launchEnvironment = environment
            app.launch()
        } else {
            app = launchApp(arguments, environment: environment, attempts: 1)
        }
        openCreatedAgent(app)
        return app
    }

    /// Same 5s bound and exact UTF-8 bytes as before. The shared helper re-reads about every 0.1s, where
    /// XCTNSPredicateExpectation polled about once a second: run 44776415205 timed out, then matched exact bytes.
    private func requireBytes(_ field: XCUIElement, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        assertTypedValue(field, equals: expected, timeout: 5, file: file, line: line)
    }

    func testCreatedNoticeFocusAndSendPreserveUnicodeBytes() {
        for draft in Self.initialDrafts {
            let app = launchUnicode(draft: draft, animations: true)
            let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
            requireBytes(composer, draft)
            app.buttons["companion-wake-with-message"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.typeText("q")
            requireBytes(composer, draft + "q")
            app.buttons["companion-send"].tap()
            XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testUserTapAndSendPreserveUnicodeBytes() {
        let app = launchUnicode()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        requireBytes(composer, Self.draft)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("q")
        requireBytes(composer, Self.draft + "q")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
    }

    func testSlashPickRefocusAndSendPreserveUnicodeBytes() {
        let app = launchApp(["--companion-preview", "--companion-preview-unicode-focus"],
            environment: ["COMPANION_UNICODE_EXPECTED": Self.draft + " /review q"], attempts: 1)
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        river.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        app.typeText(Self.draft + " /re")
        requireBytes(composer, Self.draft + " /re")
        let review = app.buttons["companion-slash-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        requireBytes(composer, Self.draft + " /review ")
        app.typeText("q")
        requireBytes(composer, Self.draft + " /review q")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
    }

    func testComposerReviewDismissalReactivationAndRotationPreserveUnicodeBytes() {
        let app = launchUnicode(expected: Self.draft + "qrs")
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("q")
        requireBytes(composer, Self.draft + "q")
        let review = app.buttons["companion-review-approval"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let close = app.buttons["companion-approval-review-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        requireBytes(composer, Self.draft + "q")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("r")
        requireBytes(composer, Self.draft + "qr")
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(composer, Self.draft + "qr")
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(composer, Self.draft + "qr")
        XCUIDevice.shared.orientation = .portrait
        requireBytes(composer, Self.draft + "qr")
        composer.typeText("s")
        requireBytes(composer, Self.draft + "qrs")
        app.buttons["companion-send"].tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
    }

    func testWakeSheetAutofocusReactivationRotationAndSendPreserveUnicodeBytes() {
        let app = launchApp(["--companion-preview", "--companion-preview-unicode-focus"],
            environment: ["COMPANION_UNICODE_EXPECTED": Self.draft + "q"], attempts: 1)
        let project = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        project.tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5))
        app.buttons["project-page-options"].tap()
        let wake = app.buttons["project-wake"]
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        wake.tap()
        let message = app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        message.typeText(Self.draft)
        requireBytes(message, Self.draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(message, Self.draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(message, Self.draft)
        XCUIDevice.shared.orientation = .portrait
        requireBytes(message, Self.draft)
        message.typeText("q")
        requireBytes(message, Self.draft + "q")
        app.buttons["wake-send"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
    }

    func testCancellingWakeSheetDoesNotChangeExistingComposerDraft() {
        let app = launchUnicode()
        app.navigationBars.buttons.firstMatch.tap()
        let project = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollTo(project, in: app))
        project.tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5))
        app.buttons["project-page-options"].tap()
        XCTAssertTrue(app.buttons["project-wake"].waitForExistence(timeout: 5))
        app.buttons["project-wake"].tap()
        let message = app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.typeText(Self.draft)
        requireBytes(message, Self.draft)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openCreatedAgent(app)
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        requireBytes(composer, Self.draft)
    }

    func testSearchTapReactivationAndRotationPreserveUnicodeBytes() {
        let app = launchApp(["--companion-preview"], attempts: 1)
        let searchTab = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(Self.draft)
        requireBytes(search, Self.draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(search, Self.draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(search, Self.draft)
        XCUIDevice.shared.orientation = .portrait
        search.typeText("q")
        requireBytes(search, Self.draft + "q")
    }

    func testSettingsNameTapReactivationRotationAndSubmitPreserveUnicodeBytes() {
        let app = launchUnicode(expected: Self.draft + "qr")
        app.buttons["Conversation actions"].tap()
        let settings = app.buttons["Agent settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let name = app.textFields["agent-settings-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        requireBytes(name, Self.draft)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("q")
        requireBytes(name, Self.draft + "q")
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(name, Self.draft + "q")
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(name, Self.draft + "q")
        XCUIDevice.shared.orientation = .portrait
        app.typeText("r")
        requireBytes(name, Self.draft + "qr")
        app.keyboards.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        requireBytes(composer, Self.draft)
    }

    func testReviewAnswerTapReactivationRotationAndSubmitPreserveUnicodeBytes() {
        let app = launchApp(["--companion-preview", "--companion-preview-questions", "--companion-preview-unicode-focus"],
            environment: ["COMPANION_UNICODE_EXPECTED": Self.draft + "q"], attempts: 1)
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        river.tap()
        let review = app.buttons["companion-decision-answer"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let answer = app.descendants(matching: .any).matching(identifier: "Answer: Unicode answer").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        answer.typeText(Self.draft)
        requireBytes(answer, Self.draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(answer, Self.draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(answer, Self.draft)
        XCUIDevice.shared.orientation = .portrait
        answer.typeText("q")
        requireBytes(answer, Self.draft + "q")
        let send = app.buttons["send-answers-unicode"]
        XCTAssertTrue(scrollTo(send, in: app))
        send.tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
        requireBytes(answer, Self.draft + "q")
        app.buttons["companion-approval-review-close"].tap()
        XCTAssertTrue(answer.waitForNonExistence(timeout: 5))
    }

    func testDispatcherNameTapReactivationRotationAndSubmitPreserveUnicodeBytes() {
        let original = "Dispatcher"
        let draft = original + Self.draft
        let app = launchApp(["--companion-preview", "--companion-preview-unicode-focus",
            "--companion-preview-dispatcher", "--companion-preview-start-dispatch", "--companion-preview-dispatcher-settings"],
            environment: ["COMPANION_UNICODE_EXPECTED": draft + "q"], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Conversation actions"].tap()
        XCTAssertTrue(app.buttons["Agent settings"].waitForExistence(timeout: 5))
        app.buttons["Agent settings"].tap()
        let name = app.textFields["dispatcher-name"]
        XCTAssertTrue(scrollUntilExists(name, in: app) && scrollTo(name, in: app))
        requireBytes(name, original)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        app.typeText(Self.draft)
        requireBytes(name, draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(name, draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(name, draft)
        XCUIDevice.shared.orientation = .portrait
        requireBytes(name, draft)
        app.typeText("q")
        requireBytes(name, draft + "q")
        app.keyboards.buttons["Done"].tap()
        let error = app.staticTexts["Unicode fixture: request bytes match."]
        XCTAssertTrue(scrollUntilExists(error, in: app, up: false) && scrollTo(error, in: app, up: false))
        XCTAssertTrue(error.exists)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }

    func testQuickAgentAutofocusReactivationRotationAndSubmitPreserveUnicodeBytes() {
        let app = launchApp(["--companion-preview", "--companion-preview-unicode-focus", "--companion-preview-unicode-quick"],
            environment: ["COMPANION_UNICODE_EXPECTED": Self.draft + "q"], attempts: 1)
        let newAgent = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(newAgent.waitForExistence(timeout: 10))
        newAgent.tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "Agent task").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        prompt.typeText(Self.draft)
        requireBytes(prompt, Self.draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        requireBytes(prompt, Self.draft)
        XCUIDevice.shared.orientation = .landscapeLeft
        requireBytes(prompt, Self.draft)
        XCUIDevice.shared.orientation = .portrait
        prompt.typeText("q")
        requireBytes(prompt, Self.draft + "q")
        let start = app.buttons["Start agent"]
        XCTAssertTrue(scrollTo(start, in: app))
        start.tap()
        XCTAssertTrue(app.staticTexts["Unicode fixture: request bytes match."].waitForExistence(timeout: 10))
        requireBytes(prompt, Self.draft + "q")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
    }

    func testTerminalAutofocusAndKeyboardTogglePreserveUnicodeInputBytes() {
        let app = launchApp(["--companion-preview", "--companion-preview-terminal-input-audit"], attempts: 1)
        let project = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        project.tap()
        XCTAssertTrue(app.buttons["project-terminal"].waitForExistence(timeout: 5))
        app.buttons["project-terminal"].tap()
        let output = app.descendants(matching: .any).matching(identifier: "terminal-output").firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        func requireInput(_ expected: String) {
            let hex = expected.utf8.map { String(format: "%02x", $0) }.joined()
            func received() -> String {
                (output.value as? String ?? "").split(separator: "\n")
                    .filter { $0.hasPrefix("INPUT_BYTES=") }
                    .map { String($0.dropFirst("INPUT_BYTES=".count)) }.joined()
            }
            let predicate = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in received() == hex }, object: output)
            let result = XCTWaiter.wait(for: [predicate], timeout: 5)
            XCTAssertEqual(received(), hex)
            XCTAssertEqual(result, .completed)
        }
        app.typeText(Self.draft)
        requireInput(Self.draft)
        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        app.typeText("q")
        requireInput(Self.draft + "q")
        app.buttons["terminal-done"].tap()
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
    }
}
