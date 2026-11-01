import XCTest
import UIKit

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

    func testARoutedBurstShowsEachSenderAndMessageSeparately() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
        waitAndTap(river, until: element(app, "companion-chat-header"), timeout: 10)
        let expected = [
            "Dispatcher: Finish the reconnect fix and open a PR. Report back when it's in review.",
            "Reviewer: The reconnect tests pass. The PR is ready for review.",
            "Clubhouse: All helper updates have been delivered.",
            "Another agent: The review notes are attached to the PR."
        ]
        for (index, label) in expected.enumerated() {
            let part = element(app, "companion-routed-relay-1-\(index)")
            XCTAssertTrue(scrollUntilExists(part, in: app, up: false, maxSwipes: 8))
            XCTAssertEqual(part.label, label, "VoiceOver names each message's own sender and body")
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-routed-relay-1-")).count, 4)
        XCTAssertFalse(text(app, containing: "[TASK:").exists)
        XCTAssertFalse(text(app, containing: "updates, oldest first:").exists)
        let part = element(app, "companion-routed-relay-1-1")
        XCTAssertTrue(scrollTo(part, in: app, up: false, maxSwipes: 8), "Bring the message on screen before copying")
        screenshot(app, "Routed burst with four senders")
        longPressUntilMenu(part, shows: app.buttons["Copy message"])
        XCTAssertTrue(app.buttons["Copy message"].exists, "Copy remains available on each routed message")
        app.buttons["Copy message"].tap()
        XCTAssertEqual(UIPasteboard.general.string, """
        4 updates, oldest first:

        --- 1 of 4 ---
        [TASK:dsp-42] [FROM:Dispatcher] Finish the reconnect fix and open a PR. Report back when it's in review.

        --- 2 of 4 ---
        [FROM:Reviewer] The reconnect tests pass. The PR is ready for review.

        --- 3 of 4 ---
        [Clubhouse] All helper updates have been delivered.

        --- 4 of 4 ---
        The review notes are attached to the PR.
        """, "Copy from one part keeps the entire raw delivery")
    }

    func testARelayedTaskIsCaptionedWithItsSender() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app), "River's row must be on screen")
        let header = element(app, "companion-chat-header")
        waitAndTap(river, until: header, timeout: 10)
        let body = element(app, "companion-routed-relay-1-0")
        XCTAssertTrue(scrollUntilExists(body, in: app, up: false, maxSwipes: 8), "The relayed task shows in River's chat")
        XCTAssertTrue(scrollTo(body, in: app, up: false, maxSwipes: 8), "Bring the relayed sender and body on screen")
        XCTAssertFalse(text(app, containing: "[TASK:").exists, "Without its tags")
        let part = element(app, "companion-routed-relay-1-0")
        XCTAssertTrue(part.exists && part.label.hasPrefix("Dispatcher:"), "Captioned with who sent it")
        screenshot(app, "Relayed task")
    }
}
