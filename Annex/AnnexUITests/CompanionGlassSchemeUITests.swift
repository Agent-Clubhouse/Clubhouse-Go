import XCTest
import UIKit
import Vision

/// #534: actual header text and action glyphs must contrast with their own pill. Only numerical evidence is
/// emitted. A Light UIKit window with an independently dark app palette is a fixture condition, not proof
/// that an iOS 27 phone recurrence has been reproduced or fixed on that device.
@MainActor final class CompanionGlassSchemeUITests: ReliableUITestCase {
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            let ready = condition()
            if ready && ContinuousClock.now < deadline { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func nameRect(in image: CGImage, scale: CGFloat, identity: CGRect) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let candidates = (request.results ?? []).compactMap { observation -> CGRect? in
            guard let text = observation.topCandidates(1).first,
                  text.confidence >= 0.5,
                  text.string.lowercased().filter(\.isLetter) == "headerworker" else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * CGFloat(image.width) / scale,
                              y: (1 - box.maxY) * CGFloat(image.height) / scale,
                              width: box.width * CGFloat(image.width) / scale,
                              height: box.height * CGFloat(image.height) / scale)
            return identity.insetBy(dx: -2, dy: -2).contains(rect) ? rect : nil
        }
        return try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                             "Recognize the actual Header worker text once inside its native identity control")
    }

    private func check(theme: String, light: Bool, connection: String = "connected", independentLightSystem: Bool = false) throws {
        var flags = ["--companion-preview", "--companion-preview-header-fixture", "--companion-preview-toolbar-scheme-flip",
                     "--companion-header-contrast-evidence", theme]
        if light { flags.append("--companion-header-light") }
        if connection != "connected" { flags.append("--companion-header-" + connection) }
        if independentLightSystem { flags.append("--companion-header-independent-light-system") }
        let app = launchApp(flags, attempts: 1)
        defer { app.terminate() }
        let identity = app.buttons["companion-chat-header"]
        let menu = app.buttons["conversation-actions-menu"]
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10) && menu.waitForExistence(timeout: 10)
                      && context.waitForExistence(timeout: 10))
        let probe = app.otherElements["header-fixture-appearance"]
        XCTAssertTrue(waitUntil({
            guard probe.exists else { return false }
            let value = probe.value as? String ?? ""
            return value.contains("palette=" + (light ? "light" : "dark")) && value.contains("connection=" + connection)
                && (!independentLightSystem || (value.contains("window=light") && value.contains("screen=light")))
        }, timeout: 5), "Require the mounted palette, actual connection state and independently Light window")
        print("HEADER_CONTRAST_APPEARANCE \(probe.value as? String ?? "unavailable")")
        XCTAssertTrue(identity.isHittable && menu.isHittable && context.isHittable)
        // AX subtraction represented an exact 44pt native target as 43.99999999999999.
        // Admit only the adjacent floating-point value, not a pixel or point allowance below 44.
        XCTAssertGreaterThanOrEqual(menu.frame.width.nextUp, 44); XCTAssertGreaterThanOrEqual(menu.frame.height.nextUp, 44)
        XCTAssertGreaterThanOrEqual(context.frame.width.nextUp, 44); XCTAssertGreaterThanOrEqual(context.frame.height.nextUp, 44)
        let shot = app.screenshot()
        XCTAssertEqual(shot.image.imageOrientation, .up, "The fixture is portrait; do not silently rotate or move sample regions")
        let image = try XCTUnwrap(shot.image.cgImage)
        let raster = try XCTUnwrap(HeaderContrastPixels(image))
        let text = try nameRect(in: image, scale: shot.image.scale, identity: identity.frame)
        // OCR excludes the avatar and disclosure chevron: either could hide unreadable name text in a whole-pill statistic.
        // The other two 20pt regions contain only the actual ellipsis or 18pt context ring and its local fill.
        let regions = [("name text", text), ("ellipsis", menu.frame.insetBy(dx: 12, dy: 12)),
                       ("context ring", context.frame.insetBy(dx: 12, dy: 12))]
        for (part, rect) in regions {
            XCTAssertTrue(app.frame.contains(rect), "\(part): the entire measured region must be on screen")
            let sample = try XCTUnwrap(raster.sample(rect, scale: shot.image.scale, lightLabels: !light), "\(part): no complete pixels")
            print("HEADER_CONTRAST theme=\(theme) connection=\(connection) windowLight=\(independentLightSystem) part=\(part) rect=\(rect) fill=\(sample.background) ink=\(sample.foreground) contrast=\(sample.contrast) count=\(sample.count) enabled=\(identity.isEnabled)/\(menu.isEnabled)/\(context.isEnabled)")
            if light { XCTAssertGreaterThan(sample.background, 0.4, "\(part): light palette fill") }
            else { XCTAssertLessThan(sample.background, 0.2, "\(part): dark palette fill, not white") }
            XCTAssertGreaterThanOrEqual(sample.contrast, 4.5, "\(part): actual rendered contrast below AA")
        }
        if independentLightSystem && connection == "connected" {
            identity.tap()
            XCTAssertTrue(waitUntil({ (identity.value as? String ?? "").contains("Details expanded") }, timeout: 5))
            identity.tap()
            XCTAssertTrue(waitUntil({ (identity.value as? String ?? "").contains("Details collapsed") }, timeout: 5))
            menu.tap()
            XCTAssertTrue(app.buttons["Refresh conversation"].waitForExistence(timeout: 5), "Keep the real actions menu; do not invoke a mutation")
        }
    }

    // Existing theme identities remain selected; stronger text-specific sampling replaces their old fixed strip.
    func testBrightGreenDarkThemeKeepsDarkBarGlass() throws { try check(theme: "--companion-header-bright-wash", light: false) }
    func testMochaKeepsDarkBarGlass() throws { try check(theme: "--companion-header-mocha", light: false) }
    func testLatteKeepsLightBarGlass() throws { try check(theme: "--companion-header-latte", light: true) }

    func testDarkPaletteWithLightWindowConnectedHeaderContrast() throws {
        try check(theme: "--companion-header-bright-wash", light: false, independentLightSystem: true)
    }
    func testDarkPaletteWithLightWindowSynchronizingHeaderContrast() throws {
        try check(theme: "--companion-header-bright-wash", light: false, connection: "synchronizing", independentLightSystem: true)
    }
    func testDarkPaletteWithLightWindowOfflineHeaderContrast() throws {
        try check(theme: "--companion-header-bright-wash", light: false, connection: "offline", independentLightSystem: true)
    }
    func testBrightGreenDarkSynchronizingHeaderContrast() throws {
        try check(theme: "--companion-header-bright-wash", light: false, connection: "synchronizing")
    }
    func testBrightGreenDarkOfflineHeaderContrast() throws {
        try check(theme: "--companion-header-bright-wash", light: false, connection: "offline")
    }
    func testMochaSynchronizingHeaderContrast() throws {
        try check(theme: "--companion-header-mocha", light: false, connection: "synchronizing")
    }
    func testMochaOfflineHeaderContrast() throws {
        try check(theme: "--companion-header-mocha", light: false, connection: "offline")
    }
    func testLatteSynchronizingHeaderContrast() throws {
        try check(theme: "--companion-header-latte", light: true, connection: "synchronizing")
    }
    func testLatteOfflineHeaderContrast() throws {
        try check(theme: "--companion-header-latte", light: true, connection: "offline")
    }
}

/// Decode to one known RGBA layout. A missing/out-of-bounds region fails rather than clipping the oracle.
/// Median fill and the 2% ink core are measured within each separate text/glyph region, not borrowed from palette values.
private struct HeaderContrastPixels {
    struct Sample {
        let background: Double
        let foreground: Double
        let count: Int
        var contrast: Double { (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) }
    }
    let width: Int
    let height: Int
    private let rgba: [UInt8]
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }
        rgba = bytes
    }
    func sample(_ rect: CGRect, scale: CGFloat, lightLabels: Bool) -> Sample? {
        guard scale.isFinite, scale > 0, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let px = rect.applying(.init(scaleX: scale, y: scale)).integral
        guard !px.isEmpty, !px.isInfinite,
              px.minX.isFinite, px.minY.isFinite,
              CGRect(x: 0, y: 0, width: width, height: height).contains(px) else { return nil }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var values: [Double] = []
        for y in Int(px.minY)..<Int(px.maxY) {
            for x in Int(px.minX)..<Int(px.maxX) {
                let i = (y * width + x) * 4
                values.append(0.2126 * linear(Double(rgba[i]) / 255) + 0.7152 * linear(Double(rgba[i + 1]) / 255)
                              + 0.0722 * linear(Double(rgba[i + 2]) / 255))
            }
        }
        guard values.count >= 20 else { return nil }
        values.sort()
        return Sample(background: values[values.count / 2],
                      foreground: values[min(values.count - 1, Int(Double(values.count) * (lightLabels ? 0.98 : 0.02)))],
                      count: values.count)
    }
}
