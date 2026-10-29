import XCTest
import UIKit

/// Pastes into the preview conversation's composer through the system edit menu. The pasteboard is shared with the
/// simulator, so the runner sets it and the app pastes it as a person would, without a paste permission prompt.
@MainActor
final class CompanionComposerPasteUITests: ReliableUITestCase {
    private func sampleImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        }
    }

    private func openConversation(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let agent = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        scrollUntilExists(agent, in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "\(identifier) must appear")
        scrollTo(agent, in: app)
        // The field itself: a container with the same identifier isn't hittable, so it can't be tapped again.
        let composer = app.textFields["companion-composer"]
        waitAndTap(agent, until: composer, timeout: 10, "Opening the agent shows the composer")
        return composer
    }

    /// Focuses the composer, then taps it again for its edit menu and chooses Paste.
    private func paste(into composer: XCUIElement, in app: XCUIApplication) {
        let pasteItem = app.menuItems["Paste"]
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the composer focuses it")
        // A second tap straight after the first is a double tap, which selects instead of showing the menu.
        _ = pasteItem.waitForExistence(timeout: 1)
        waitAndTap(composer, until: pasteItem, timeout: 3, "The composer offers Paste")
        pasteItem.tap()
    }

    func testPastingImagesAddsAttachmentsAndTextStillPastes() {
        let app = launchApp(["--companion-preview"])
        let composer = openConversation("agent-preview-studio-river", in: app)
        let thumbnails = app.images.matching(identifier: "companion-attachment-thumbnail")
        let send = app.buttons["companion-send"]
        XCTAssertFalse(send.isEnabled, "Nothing to send yet")

        UIPasteboard.general.image = sampleImage()
        paste(into: composer, in: app)
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 10), "A pasted image shows above the field")
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertTrue(send.isEnabled, "A pasted image can be sent")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer with a pasted image"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        UIPasteboard.general.string = "Pasted words"
        paste(into: composer, in: app)
        let pasted = NSPredicate(format: "value CONTAINS %@", "Pasted words")
        XCTAssertTrue(waitFor(composer, pasted, timeout: 5), "Text still pastes into the field")
        XCTAssertEqual(thumbnails.count, 1, "Text never becomes an attachment")
    }

    func testPastingAnImageWhereTheAgentCantTakeImagesExplains() {
        let app = launchApp(["--companion-preview"])
        let composer = openConversation("agent-preview-studio-cedar", in: app)
        UIPasteboard.general.image = sampleImage()
        paste(into: composer, in: app)
        XCTAssertTrue(app.staticTexts["This agent can't take images. Send your message as text."].waitForExistence(timeout: 10),
                      "An agent without images says why the paste did nothing")
        XCTAssertFalse(app.images["companion-attachment-thumbnail"].exists)
    }
}
