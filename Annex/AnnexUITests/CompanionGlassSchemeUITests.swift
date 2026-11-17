import XCTest
import UIKit

/// #534: the header's name pill and trailing actions pill must stay on the palette's side, with readable labels,
/// even when their environment's colorScheme is the opposite one.
///
/// SYNTHETIC: `--companion-preview-toolbar-scheme-flip` gives the conversation the opposite colorScheme to its
/// palette. These tests show the pinned bar glass wins over that environment. They don't show that this is how
/// iOS 27.2 drew the pills white; only a device install can confirm the phone.
@MainActor final class CompanionGlassSchemeUITests: ReliableUITestCase {
    private struct Sample { let background: Double; let contrast: Double }

    /// Median relative luminance of a pill (its fill dominates) and the WCAG contrast of its most distinct pixels.
    private func sample(_ shot: XCUIScreenshot, _ rect: CGRect) -> Sample? {
        guard let image = shot.image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let bgr = image.bitmapInfo.contains(.byteOrder32Little)
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var values: [Double] = []
        let scale = shot.image.scale
        let px = rect.applying(.init(scaleX: scale, y: scale)).integral
        for y in Int(px.minY)..<Int(px.maxY) where y >= 0 && y < image.height {
            for x in Int(px.minX)..<Int(px.maxX) where x >= 0 && x < image.width {
                let o = y * perRow + x * perPixel + (alphaFirst && !bgr ? 1 : 0)
                var (r, g, b) = (Double(bytes[o]) / 255, Double(bytes[o + 1]) / 255, Double(bytes[o + 2]) / 255)
                if bgr { swap(&r, &b) }
                values.append(0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b))
            }
        }
        guard !values.isEmpty else { return nil }
        let median = values.sorted()[values.count / 2]
        // The label's core: the 1% of pixels furthest from the fill, so antialiased edges don't decide it.
        let far = values.map { abs($0 - median) }.sorted()
        let spread = far[min(far.count - 1, Int(Double(far.count) * 0.99))]
        let other = median > 0.18 ? median - spread : median + spread
        return Sample(background: median, contrast: (max(median, other) + 0.05) / (min(median, other) + 0.05))
    }

    private func check(theme: String, light: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-preview-toolbar-scheme-flip",
                             theme] + (light ? ["--companion-header-light"] : []), attempts: 1)
        let identity = app.buttons["companion-chat-header"]
        let actions = app.descendants(matching: .any).matching(identifier: "companion-chat-header-actions").firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10) && actions.waitForExistence(timeout: 10))
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "534 flipped scheme \(theme)\(light ? " light" : "")"; attachment.lifetime = .keepAlways; add(attachment)
        // The name pill is the identity button's bottom strip, under the photo.
        let pill = CGRect(x: identity.frame.midX - 18, y: identity.frame.maxY - 16, width: 36, height: 12)
        for (part, rect) in [("name pill", pill), ("actions pill", actions.frame.insetBy(dx: 10, dy: 10))] {
            guard let s = sample(shot, rect) else { return XCTFail("\(part): no pixels") }
            print("GLASS_SCHEME \(theme) light=\(light) \(part) rect=\(rect) background=\(s.background) contrast=\(s.contrast)")
            if light {
                XCTAssertGreaterThan(s.background, 0.4, "\(part): a light palette needs light glass")
            } else {
                XCTAssertLessThan(s.background, 0.2, "\(part): a dark palette needs dark glass, not white")
            }
            XCTAssertGreaterThanOrEqual(s.contrast, 4.5, "\(part): label contrast is below WCAG AA")
        }
    }

    /// The reported condition: a dark theme with a bright green wash under the bar.
    func testBrightGreenDarkThemeKeepsDarkBarGlass() { check(theme: "--companion-header-bright-wash", light: false) }
    func testMochaKeepsDarkBarGlass() { check(theme: "--companion-header-mocha", light: false) }
    func testLatteKeepsLightBarGlass() { check(theme: "--companion-header-latte", light: true) }
}
