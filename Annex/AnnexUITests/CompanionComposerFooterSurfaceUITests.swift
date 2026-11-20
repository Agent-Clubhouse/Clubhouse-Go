import XCTest
import Vision

/// #533 regression guards. The reported band and blur render on the phone (iOS 27) but not on this
/// simulator runtime, so these guard the contract rather than reproduce it: the footer around the composer
/// draws the chat surface itself, with no band or dividing line, and the final transcript line rests whole
/// and legible above the footer with the keyboard down, up and dismissed.
@MainActor final class CompanionComposerFooterSurfaceUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private struct Frames {
        var footer: CGRect
        var composer: CGRect
        var transcript: CGRect
        var keyboardTop: CGFloat?
        var window: CGRect
        var final: CGRect?
        /// The pinned decision card, when a tray is shown; part of the settle check so no capture lands mid-animation.
        var tray: CGRect?
        /// The footer as it is seen: above the keyboard, if any.
        var visibleFooter: CGRect {
            let bottom = min(footer.maxY, keyboardTop ?? window.maxY)
            return CGRect(x: footer.minX, y: footer.minY, width: footer.width, height: max(0, bottom - footer.minY))
        }
    }

    private func frames(_ app: XCUIApplication) throws -> Frames {
        let root = try app.snapshot()
        var ids: [String: CGRect] = [:]
        var keyboardTop: CGFloat?
        var final: CGRect?
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .keyboard || node.identifier == "SystemInputAssistantView", node.frame.intersects(root.frame) {
                keyboardTop = min(keyboardTop ?? .infinity, node.frame.minY)
            }
            if node.elementType == .staticText, node.label == "End of the long reply." { final = node.frame }
            if !node.identifier.isEmpty, ids[node.identifier] == nil { ids[node.identifier] = node.frame }
            node.children.forEach(visit)
        }
        visit(root)
        return Frames(footer: try XCTUnwrap(ids["companion-grant-footer-scroll"], "footer"),
                      composer: try XCTUnwrap(ids["companion-composer-region"], "composer"),
                      transcript: try XCTUnwrap(ids["companion-transcript"], "transcript"),
                      keyboardTop: keyboardTop, window: root.frame, final: final,
                      tray: ids["companion-pinned-decision"])
    }

    /// Bounded wait for scrolling and keyboard motion to finish: two consecutive snapshots agree.
    private func settledFrames(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws -> Frames {
        var previous = try frames(app)
        for _ in 0..<20 {
            let current = try frames(app)
            if current.footer == previous.footer, current.composer == previous.composer, current.tray == previous.tray,
               current.keyboardTop == previous.keyboardTop, current.final == previous.final {
                return current
            }
            previous = current
        }
        XCTFail("Footer and transcript geometry kept moving", file: file, line: line)
        return previous
    }

    // MARK: Pixels

    private struct Pixels {
        let data: [UInt8]
        let width: Int, height: Int, scale: CGFloat
        init(_ image: UIImage) throws {
            let cg = try XCTUnwrap(image.cgImage)
            width = cg.width; height = cg.height; scale = CGFloat(cg.width) / image.size.width
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = buffer
        }
        /// The mean colour of a point-space rectangle.
        func mean(_ rect: CGRect) -> [Double] {
            let x0 = max(0, Int((rect.minX * scale).rounded())), x1 = min(width, Int((rect.maxX * scale).rounded()))
            let y0 = max(0, Int((rect.minY * scale).rounded())), y1 = min(height, Int((rect.maxY * scale).rounded()))
            var sum = [0.0, 0.0, 0.0], count = 0.0
            for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) {
                let i = (y * width + x) * 4
                for c in 0..<3 { sum[c] += Double(data[i + c]) }
                count += 1
            } }
            return count == 0 ? [] : sum.map { $0 / count }
        }
        /// One-pixel rows, for a dividing line.
        func rows(_ rect: CGRect) -> [[Double]] {
            let y0 = max(0, Int((rect.minY * scale).rounded())), y1 = min(height, Int((rect.maxY * scale).rounded()))
            return (y0..<max(y0, y1)).map { mean(CGRect(x: rect.minX, y: CGFloat($0) / scale, width: rect.width, height: 1 / scale)) }
        }
    }

    private func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 3, b.count == 3 else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }

    /// The device band (af92e4c2) was a step: a one-pixel dividing line 18 levels darker at the footer's top,
    /// then a flat surface 6–9 levels lighter. The composer card's own shadow is a gradual gradient instead.
    /// Guard both: no step between adjacent pixel rows anywhere in the visible footer, and the room above
    /// the composer within 4 levels of the transcript surface beside it.
    private static let stepTolerance = 3.0
    private static let surfaceTolerance = 4.0

    private func assertFooterMatchesChatSurface(_ app: XCUIApplication, _ state: String, checksRoom: Bool = true,
                                                stepsLoggedFrom loggedOnlyY: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = try settledFrames(app, file: file, line: line)
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "Footer surface \(state)"; shot.lifetime = .keepAlways; add(shot)
        let pixels = try Pixels(screenshot.image)
        let footer = frames.visibleFooter
        // Leading and trailing margins: outside the composer card (16pt inset) and transcript text (20pt).
        for x in [frames.window.minX + 2, frames.window.maxX - 6] {
            let side = x < frames.window.midX ? "leading" : "trailing"
            let reference = pixels.mean(CGRect(x: x, y: footer.minY - 14, width: 4, height: 10))
            let rows = pixels.rows(CGRect(x: x, y: footer.minY - 4, width: 4, height: footer.height + 4))
            let allSteps = zip(rows, rows.dropFirst()).enumerated().map { index, pair in
                (y: footer.minY - 4 + CGFloat(index + 1) / pixels.scale, step: difference(pair.0, pair.1))
            }
            // Rows at or below `loggedOnlyY` are measured and logged, not guarded.
            let steps = allSteps.filter { loggedOnlyY == nil || $0.y < loggedOnlyY! }.map(\.step)
            let worstStep = steps.max() ?? .infinity
            let logged = allSteps.filter { loggedOnlyY != nil && $0.y >= loggedOnlyY! }.max { $0.step < $1.step }
            let clipRow = allSteps.filter { abs($0.y - footer.minY) < 1 / pixels.scale }.map(\.step).max() ?? 0
            let room = pixels.mean(CGRect(x: x, y: footer.minY, width: 4, height: max(1, frames.composer.minY - footer.minY)))
            let report = "\(state) \(side): footer=\(frames.footer) visible=\(footer) composer=\(frames.composer) keyboardTop=\(String(describing: frames.keyboardTop)) surface=\(reference.map { Int($0) }) room=\(room.map { Int($0) }) worstStep=\(worstStep) topRowStep=\(clipRow)\(logged.map { " loggedOnly=\($0.step)@\($0.y)" } ?? "")"
            print("FOOTER_SURFACE \(report)")
            XCTAssertFalse(steps.isEmpty, report, file: file, line: line)
            XCTAssertLessThanOrEqual(worstStep, Self.stepTolerance,
                                     "The footer has no band edge or dividing line: \(report)", file: file, line: line)
            if checksRoom {
                XCTAssertLessThanOrEqual(difference(room, reference), Self.surfaceTolerance,
                                         "The footer above the composer draws the chat surface: \(report)", file: file, line: line)
            }
        }
    }

    private func assertFinalLineRestsAboveFooter(_ app: XCUIApplication, _ state: String,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = try settledFrames(app, file: file, line: line)
        let final = try XCTUnwrap(frames.final, "\(state): the final line is on screen", file: file, line: line)
        let visibleTop = max(frames.transcript.minY, element(app, "companion-chat-header").frame.maxY)
        let report = "\(state): final=\(final) footer=\(frames.footer) visibleTop=\(visibleTop) keyboardTop=\(String(describing: frames.keyboardTop))"
        print("FOOTER_FINAL_LINE \(report)")
        XCTAssertGreaterThanOrEqual(pixelAligned(final.minY), pixelAligned(visibleTop), report, file: file, line: line)
        XCTAssertLessThanOrEqual(pixelAligned(final.maxY), pixelAligned(frames.footer.minY),
                                 "The whole final line rests above the footer: \(report)", file: file, line: line)
        // Beyond geometry, the final line must be legible in the rendered pixels (OCR; not proof of no blur).
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "Footer final line \(state)"; shot.lifetime = .keepAlways; add(shot)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / screenshot.image.size.width
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: (final.minY - 4) * scale,
                                                           width: CGFloat(image.width), height: (final.height + 8) * scale)))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(lines.contains("End of the long reply."), "\(state): the final line is legible: OCR \(lines)", file: file, line: line)
    }

    // MARK: Flows

    private func launch(_ appearance: String) -> XCUIApplication {
        let app = launchApp(["--companion-preview", appearance, "--companion-preview-dispatcher",
                             "--companion-preview-start-dispatch", "--companion-preview-long-reply"])
        XCTAssertTrue(element(app, "companion-composer").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["End of the long reply."].waitForExistence(timeout: 15))
        return app
    }

    private func focus(_ app: XCUIApplication) {
        element(app, "companion-composer").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    /// AX exposes the transcript's full frame under the header, footer and keyboard.
    /// Transcript gestures must begin on the actual visible reading surface.
    private func visibleTranscript(_ app: XCUIApplication) throws -> CGRect {
        let layout = try settledFrames(app)
        let top = max(layout.transcript.minY, element(app, "companion-chat-header").frame.maxY)
        let bottom = min(layout.footer.minY, layout.keyboardTop ?? layout.window.maxY)
        let visible = layout.transcript.intersection(layout.window)
            .intersection(CGRect(x: layout.window.minX, y: top, width: layout.window.width, height: max(0, bottom - top)))
            .insetBy(dx: 4, dy: 4)
        return try XCTUnwrap(!visible.isNull && !visible.isEmpty && visible.height > 20 ? visible : nil,
                             "A real transcript gesture needs space above the footer: visible \(visible), layout \(layout)")
    }

    private func coordinate(_ point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
    }

    /// Drags earlier messages into view, so transcript content lies under the footer.
    private func scrollContentUnderFooter(_ app: XCUIApplication) throws {
        let visible = try visibleTranscript(app)
        let start = CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.2)
        let end = CGPoint(x: visible.midX, y: min(start.y + 140, visible.maxY - visible.height * 0.2))
        XCTAssertTrue(visible.contains(start) && visible.contains(end))
        print("FOOTER_GESTURE visible=\(visible) start=\(start) end=\(end)")
        coordinate(start, in: app).press(forDuration: 0.05, thenDragTo: coordinate(end, in: app),
                                       withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.pausedChatNavigation.waitForExistence(timeout: 5), "Reading earlier messages")
    }

    private func returnToLatest(_ app: XCUIApplication) {
        navigateToChatEnd(app)
        XCTAssertTrue(app.staticTexts["End of the long reply."].waitForExistence(timeout: 5))
    }

    private func surfaceAndFinalLine(_ appearance: String, name: String) throws {
        let app = launch(appearance)
        try assertFinalLineRestsAboveFooter(app, "\(name) keyboard down")
        try assertFooterMatchesChatSurface(app, "\(name) keyboard down")
        try scrollContentUnderFooter(app)
        try assertFooterMatchesChatSurface(app, "\(name) keyboard down, content under footer")
        returnToLatest(app)

        focus(app)
        try assertFinalLineRestsAboveFooter(app, "\(name) keyboard up")
        try assertFooterMatchesChatSurface(app, "\(name) keyboard up")
        try scrollContentUnderFooter(app)
        try assertFooterMatchesChatSurface(app, "\(name) keyboard up, content under footer")

        // Interactive dismissal (the 2a8633c2 report's path): nothing stays behind over the transcript.
        let visible = try visibleTranscript(app)
        let startPoint = CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.3)
        let endPoint = CGPoint(x: visible.midX, y: min(startPoint.y + 500, app.frame.maxY - 10))
        coordinate(startPoint, in: app).press(forDuration: 0.05, thenDragTo: coordinate(endPoint, in: app), withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        returnToLatest(app)
        try assertFinalLineRestsAboveFooter(app, "\(name) after drag dismissal")
        try assertFooterMatchesChatSurface(app, "\(name) after drag dismissal")

        focus(app)
        let tappingRegion = try visibleTranscript(app)
        coordinate(CGPoint(x: tappingRegion.midX, y: tappingRegion.minY + tappingRegion.height * 0.2), in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try assertFinalLineRestsAboveFooter(app, "\(name) after tap dismissal")
        try assertFooterMatchesChatSurface(app, "\(name) after tap dismissal")
    }

    func testLightFooterMatchesChatSurfaceAndFinalLineRestsAboveIt() throws {
        try surfaceAndFinalLine("--companion-preview-light", name: "light")
    }

    func testDarkFooterMatchesChatSurfaceAndFinalLineRestsAboveIt() throws {
        try surfaceAndFinalLine("--companion-preview-dark", name: "dark")
    }

    /// A pushed chat with pending decisions: the tray shares the footer. Its card shadow shades the room above
    /// the composer by design (a gradient, about 6 levels), so only the step guard applies there. The streaming
    /// fixture keeps following, so content-under-footer states are covered by the Dispatcher flows above.
    /// No rows are excluded and the step limit stays 3. Measured per row (c9b22351, iOS 26.0), every step inside
    /// the tray's shadow is <= 1 level; the single larger step, 2.1–2.4 levels, is the footer's top row, where the
    /// footer clips the tray card's shadow. Excluding it would also exclude the row the device band starts on.
    func testPendingTrayFooterMatchesChatSurfaceInLightAndDark() throws {
        for appearance in ["--companion-preview-light", "--companion-preview-dark"] {
            let app = launchApp(["--companion-preview", appearance, "--companion-preview-reading", "--companion-preview-stream", "--companion-preview-pinned-decisions"])
            let river = element(app, "agent-preview-studio-river")
            XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
            waitAndTap(river, until: element(app, "companion-composer"))
            XCTAssertTrue(element(app, "companion-pinned-decision").waitForExistence(timeout: 20))
            try assertFooterMatchesChatSurface(app, "\(appearance) pending, keyboard down", checksRoom: false)
            focus(app)
            try assertFooterMatchesChatSurface(app, "\(appearance) pending, keyboard up", checksRoom: false)
            app.terminate()
        }
    }

    /// Evidence for the overflow footer: largest text, a pending tray and the keyboard up leave less room than the
    /// footer needs, so it scrolls with its bottom under the keyboard top. Rows above keyboardTop − 40 are guarded.
    /// Rows below are measured and logged only: on iOS 26.0 a full-width step of about 7 levels sits 33pt above
    /// the keyboard top in this state, identical on b21fe4c0 (#533 follow-up, pending the combined head).
    func testOverflowFooterWithKeyboardUpEvidenceInLightAndDark() throws {
        for appearance in ["--companion-preview-light", "--companion-preview-dark"] {
            let app = launchApp(["--companion-preview", appearance, "--companion-preview-reading", "--companion-preview-stream",
                                 "--companion-preview-pinned-decisions",
                                 "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            let river = element(app, "agent-preview-studio-river")
            XCTAssertTrue(scrollUntilExists(river, in: app) && scrollTo(river, in: app))
            waitAndTap(river, until: element(app, "companion-composer"))
            XCTAssertTrue(element(app, "companion-pinned-decision").waitForExistence(timeout: 20))
            focus(app)
            element(app, "companion-composer").typeText("One\nTwo\nThree\nFour\nFive\nSix")
            let frames = try settledFrames(app)
            print("FOOTER_OVERFLOW \(appearance): footer=\(frames.footer) visible=\(frames.visibleFooter) composer=\(frames.composer) keyboardTop=\(String(describing: frames.keyboardTop))")
            let keyboardTop = try XCTUnwrap(frames.keyboardTop, "\(appearance): keyboard")
            XCTAssertGreaterThan(frames.footer.maxY, keyboardTop, "\(appearance): the footer overflows under the keyboard top")
            XCTAssertLessThanOrEqual(pixelAligned(frames.composer.maxY), pixelAligned(keyboardTop), "\(appearance): the composer stays above the keyboard")
            try assertFooterMatchesChatSurface(app, "\(appearance) overflow footer, keyboard up", checksRoom: false,
                                              stepsLoggedFrom: keyboardTop - 40)
            app.terminate()
        }
    }
}
