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

    func testARelayedTaskIsCaptionedWithItsSender() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app), "River's row must be on screen")
        let header = element(app, "companion-chat-header")
        waitAndTap(river, until: header, timeout: 10)
        let body = text(app, containing: "Finish the reconnect fix and open a PR")
        XCTAssertTrue(scrollUntilExists(body, in: app, up: false, maxSwipes: 8), "The relayed task shows in River's chat")
        XCTAssertFalse(text(app, containing: "[TASK:").exists, "Without its tags")
        let caption = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                                             "companion-message-source", "From Dispatcher")).firstMatch
        XCTAssertTrue(caption.exists, "Captioned with who sent it")
        screenshot(app, "Relayed task")
    }
}
