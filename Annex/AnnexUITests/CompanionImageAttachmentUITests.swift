import XCTest

/// Picks, removes and sends images in the preview conversation. `--companion-sample-images` replaces the system
/// photo picker with generated images, so the test never depends on the photo library.
@MainActor
final class CompanionImageAttachmentUITests: XCTestCase {
    func testPickRemoveAndSendImages() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--companion-preview", "--companion-sample-images"]
        app.launch()
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        for _ in 0..<4 where !agent.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")
        agent.tap()

        let attach = app.buttons["companion-attach"]
        let send = app.buttons["companion-send"]
        let thumbnails = app.images.matching(identifier: "companion-attachment-thumbnail")
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "The preview desktop advertises attachments, so the attach button shows")
        XCTAssertFalse(send.isEnabled, "Nothing to send yet")

        attach.tap()
        XCTAssertTrue(thumbnails.element(boundBy: 0).waitForExistence(timeout: 5), "A picked image shows above the field")
        attach.tap()
        XCTAssertTrue(thumbnails.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, 2)
        XCTAssertTrue(send.isEnabled, "Images alone can be sent")

        app.buttons.matching(identifier: "companion-attachment-remove").firstMatch.tap()
        XCTAssertTrue(thumbnails.element(boundBy: 1).waitForNonExistence(timeout: 5), "Remove takes one image off the strip")
        XCTAssertEqual(thumbnails.count, 1)

        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        composer.tap()
        composer.typeText("What do you see?")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer with an attached image"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        send.tap()

        XCTAssertTrue(thumbnails.firstMatch.waitForNonExistence(timeout: 5), "Sending clears the strip")
        let sentImage = app.buttons.matching(identifier: "companion-message-image").firstMatch
        XCTAssertTrue(sentImage.waitForExistence(timeout: 5), "The message shows its image")
        XCTAssertTrue(app.staticTexts["Preview only. Pair a desktop to send messages."].waitForExistence(timeout: 10),
                      "Preview must never claim a message reached a desktop")
        let sent = XCTAttachment(screenshot: app.screenshot())
        sent.name = "Sent message with its image"
        sent.lifetime = .keepAlways
        add(sent)

        sentImage.tap()
        let done = app.buttons["companion-preview-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Tapping the image opens the preview")
        XCTAssertTrue(app.images["Image you sent"].waitForExistence(timeout: 5), "The phone's own copy shows without a desktop")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
}
