import XCTest
import UIKit

/// The edges around a conversation: the theme wash behind the header and chips (#529), and layout and keyboard
/// regression guards for the transcript's bottom edge.
@MainActor final class CompanionHeaderEdgeUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Relative luminance of the screenshot pixel at a point in app coordinates.
    private func luminance(_ image: UIImage, at point: CGPoint) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        let scale = CGFloat(cgImage.width) / image.size.width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
    }

    /// f2cd07ab (2.0.0 2026111620): with two Dispatchers at rest, the header and chips sat on a flat band and the
    /// wash started with a hard seam under the chips. The chips are now a bar over the conversation, so its wash
    /// runs up behind them without a step at their lower edge.
    private func washRunsBehindChips(_ flags: [String], _ name: String) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers",
                             "--companion-preview-hide-banner"] + flags, attempts: 1)
        let chips = app.scrollViews["dispatcher-chips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 15))
        app.buttons["dispatcher-desktop-preview-studio"].tap()
        XCTAssertTrue(app.navigationBars["Navi"].waitForExistence(timeout: 5))
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "529 Wash behind chips - \(name)"; attachment.lifetime = .keepAlways; add(attachment)
        // The trailing margin, clear of the chips, banners and transcript text.
        let x = app.frame.maxX - 4
        let above = luminance(screenshot.image, at: CGPoint(x: x, y: chips.frame.maxY - 6))
        let below = luminance(screenshot.image, at: CGPoint(x: x, y: chips.frame.maxY + 6))
        XCTAssertGreaterThanOrEqual(above, 0)
        XCTAssertLessThan(abs(above - below), 0.02, "No seam at the chips' lower edge: \(above) above vs \(below) below")
    }
    func testWashRunsBehindChipsDark() { washRunsBehindChips(["--companion-preview-dark"], "dark") }
    func testWashRunsBehindChipsMocha() {
        washRunsBehindChips(["--companion-preview-dark", "--companion-preview-theme-mocha"], "Catppuccin Mocha")
    }
    func testWashRunsBehindChipsLight() { washRunsBehindChips(["--companion-preview-light"], "light") }

    /// A layout and keyboard regression guard, not a test of #533's soft edge (iOS 26.0 draws both edge styles alike):
    /// the newest message stays fully above the composer with the keyboard hidden, shown and hidden again, and returns
    /// to the same place.
    private func latestClearsComposer(_ flags: [String], _ name: String) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags, attempts: 1)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 15))
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker 18.")).firstMatch
        let composerRegion = element(app, "companion-composer-region")
        XCTAssertTrue(latest.waitForExistence(timeout: 10) && composerRegion.exists)
        func clears(_ state: String) {
            XCTAssertTrue(waitFor(latest, NSPredicate { _, _ in latest.frame.maxY <= composerRegion.frame.minY }, timeout: 5),
                          "\(state): the newest message ends above the composer: \(latest.frame) vs \(composerRegion.frame)")
        }
        clears("Keyboard hidden")
        let rest = latest.frame
        capture(app, "Bottom edge guard - latest above composer - \(name)")
        let composer = element(app, "companion-composer")
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3)); show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        clears("Keyboard shown")
        XCTAssertLessThanOrEqual(composerRegion.frame.maxY, keyboard.frame.minY + 1, "The composer sits above the keyboard")
        capture(app, "Bottom edge guard - latest above composer with keyboard - \(name)")
        // A tap in the timeline's blank leading padding just above the composer dismisses without scrolling.
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let point = CGPoint(x: transcript.minX + 8, y: min(transcript.maxY, composerRegion.frame.minY) - 12)
        XCTAssertFalse(keyboard.frame.contains(point))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        clears("Keyboard hidden again")
        XCTAssertTrue(waitFor(latest, NSPredicate { _, _ in abs(latest.frame.maxY - rest.maxY) <= 1 }, timeout: 5),
                      "The reading position returns: \(latest.frame) vs \(rest)")
    }
    func testLatestClearsComposerDark() { latestClearsComposer(["--companion-header-idle"], "dark") }
    func testLatestClearsComposerLight() { latestClearsComposer(["--companion-header-idle", "--companion-header-light"], "light") }
}
