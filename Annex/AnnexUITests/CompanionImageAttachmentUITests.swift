import XCTest

/// Picks, removes and sends images in the preview conversation. `--companion-sample-images` replaces the system
/// photo picker with generated images, so the test never depends on the photo library.
@MainActor
final class CompanionImageAttachmentUITests: ReliableUITestCase {
    func testPickRemoveAndSendImages() {
        let app = launchApp(["--companion-preview", "--companion-sample-images"])
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: 15), "Preview agent must appear")

        let attach = app.buttons["companion-attach"]
        let send = app.buttons["companion-send"]
        let thumbnails = app.images.matching(identifier: "companion-attachment-thumbnail")
        waitAndTap(agent, until: attach, timeout: 10, "The preview desktop advertises attachments, so the attach button shows")
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
        // The keyboard and pinned request leave a shorter transcript than a fixed screen-fraction drag assumes.
        XCTContext.runActivity(named: "Sent image before reveal: \(sentImage.frame), header \(app.navigationBars.firstMatch.frame), composer \(composer.frame)") { _ in }
        let beforeReveal = XCTAttachment(screenshot: app.screenshot())
        beforeReveal.name = "Sent image before reveal"
        beforeReveal.lifetime = .keepAlways
        add(beforeReveal)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Sent image before reveal hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(revealSentImage(sentImage, in: app), "The sent image must be visible before tapping")
        let frame = sentImage.frame
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, composer.frame.minY - 12)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertFalse(keyboard.frame.contains(point)) }
        let sent = XCTAttachment(screenshot: app.screenshot())
        sent.name = "Sent message with its image"
        sent.lifetime = .keepAlways
        add(sent)

        let done = app.buttons["companion-preview-done"]
        XCTContext.runActivity(named: "Tap fully visible sent image at \(point), frame \(frame)") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Tapping the image opens the preview")
        XCTAssertTrue(app.images["Image you sent"].waitForExistence(timeout: 5), "The phone's own copy shows without a desktop")
        waitAndTap(done, untilGone: done)
    }

    private func revealSentImage(_ image: XCUIElement, in app: XCUIApplication) -> Bool {
        // The ScrollView's AX frame extends under the footer; its Other container is the visible viewport.
        let transcript = app.otherElements.matching(identifier: "companion-transcript").firstMatch
        func isVisible(in viewport: CGRect) -> Bool {
            image.exists && image.isHittable && image.frame.minY >= viewport.minY && image.frame.maxY <= viewport.maxY
        }
        for _ in 0..<12 {
            checkTimeLeft("revealing the sent image inside the transcript")
            let viewport = transcript.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
            if isVisible(in: viewport) { return true }
            guard viewport.height > image.frame.height else { return false }
            let above = image.frame.minY < viewport.minY
            // A larger step can oscillate past the narrow interval where the whole image fits.
            let distance = min(viewport.height / 2, viewport.height - image.frame.height)
            let start = CGPoint(x: viewport.minX, y: viewport.midY + (above ? -distance / 2 : distance / 2))
            let end = CGPoint(x: start.x, y: viewport.midY + (above ? distance / 2 : -distance / 2))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            XCTContext.runActivity(named: "Reveal sent image \(image.frame) in transcript \(viewport), drag \(start) to \(end)") { _ in
                origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.05,
                    thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        }
        return isVisible(in: transcript.frame.intersection(app.frame).insetBy(dx: 8, dy: 8))
    }
}
