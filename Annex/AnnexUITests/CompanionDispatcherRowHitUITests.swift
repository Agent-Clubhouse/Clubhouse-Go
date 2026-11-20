import XCTest
import Vision

/// Actual Home rows and navigation; OCR locates synthetic name glyphs so a
/// trailing-space tap cannot accidentally pass by landing on status text.
@MainActor final class CompanionDispatcherRowHitUITests: ReliableUITestCase {
    private struct Dispatcher {
        let host: String
        let desktop: String
        let name: String
        var identifier: String { "dispatcher-row-\(host)" }
    }
    private let dispatchers = [
        Dispatcher(host: "preview-studio", desktop: "Studio Mac", name: "Navi"),
        Dispatcher(host: "preview-laptop", desktop: "Travel MacBook", name: "Echo"),
    ]

    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-start-home", "--companion-preview-dispatcher",
                             "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers",
                             "--companion-preview-home-row-hit-area"] + flags, attempts: 1)
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[dispatchers[0].identifier].waitForExistence(timeout: 10))
        return app
    }

    private func visibleCell(_ dispatcher: Dispatcher, in app: XCUIApplication) throws -> XCUIElement {
        let row = app.buttons[dispatcher.identifier]
        for step in 0...8 {
            XCTAssertTrue(app.navigationBars["Clubhouse"].exists, "Home must own the foreground rows")
            XCTAssertFalse(app.buttons["companion-chat-header"].exists)
            XCTAssertTrue(row.exists)
            let owners = app.cells.containing(.button, identifier: dispatcher.identifier).allElementsBoundByAccessibilityElement
            let cell = try XCTUnwrap(owners.count == 1 ? owners.first : nil, "One real Home cell owns this Dispatcher")
            let viewport = CGRect(x: app.frame.minX, y: app.navigationBars["Clubhouse"].frame.maxY,
                                  width: app.frame.width,
                                  height: app.tabBars.firstMatch.frame.minY - app.navigationBars["Clubhouse"].frame.maxY)
            let frame = cell.frame
            XCTAssertLessThanOrEqual(frame.height, viewport.height, "The full row must fit before a tap")
            if viewport.contains(frame) {
                XCTAssertTrue(row.isHittable && row.isEnabled)
                XCTAssertEqual(cell.buttons.matching(identifier: dispatcher.identifier).count, 1)
                XCTAssertTrue(row.label.contains(dispatcher.name) && row.label.contains(dispatcher.desktop), row.label)
                return cell
            }
            guard step < 8 else { break }
            let upwards = frame.maxY > viewport.maxY
            let distance = min(viewport.height * 0.3,
                               (upwards ? frame.maxY - viewport.maxY : viewport.minY - frame.minY) + 12)
            let y = viewport.minY + viewport.height * (upwards ? 0.8 : 0.2)
            let start = coordinate(CGPoint(x: viewport.midX, y: y), in: app)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: upwards ? -distance : distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        return try XCTUnwrap(nil as XCUIElement?, "The requested Home cell did not become fully visible in eight drags")
    }

    private func points(_ dispatcher: Dispatcher, in app: XCUIApplication) throws -> (text: CGPoint, middleBlank: CGPoint, blank: CGPoint) {
        let cell = try visibleCell(dispatcher, in: app)
        let frame = cell.frame
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "Synthetic Home row before tap \(dispatcher.host)"
        shot.lifetime = .keepAlways; add(shot)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        XCTAssertEqual(CGFloat(image.width) / CGFloat(image.height), app.frame.width / app.frame.height, accuracy: 0.001)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: app.frame.minX + box.minX * app.frame.width,
                              y: app.frame.minY + (1 - box.maxY) * app.frame.height,
                              width: box.width * app.frame.width, height: box.height * app.frame.height)
            return frame.intersects(rect) ? (text, rect) : nil
        }
        let names = lines.filter { $0.0 == dispatcher.name && frame.contains($0.1) }
        let name = try XCTUnwrap(names.count == 1 ? names.first?.1 : nil, "Exactly one visible synthetic name glyph run: \(lines)")
        let blank = CGPoint(x: frame.maxX - 20, y: name.midY)
        let middleBlank = CGPoint(x: frame.minX + frame.width * 0.68, y: name.midY)
        for point in [middleBlank, blank] {
            XCTAssertGreaterThan(point.x, name.maxX + 44, "There must be genuine trailing space, rather than another text tap")
            XCTAssertFalse(lines.contains { $0.1.insetBy(dx: -4, dy: -2).contains(point) }, "The blank tap must be outside every recognized text run")
            XCTAssertTrue(frame.contains(point))
        }
        XCTAssertEqual(cell.frame, frame, "No row movement between screenshot and gesture")
        let geometry = "host=\(dispatcher.host) agent=durable_dispatcher name=\(dispatcher.name) cell=\(frame) row=\(app.buttons[dispatcher.identifier].frame) glyphs=\(name) middleBlank=\(middleBlank) blank=\(blank)"
        print("HOME_ROW_HIT \(geometry)")
        let note = XCTAttachment(string: geometry); note.name = "Synthetic Home tap geometry"; note.lifetime = .keepAlways; add(note)
        return (CGPoint(x: name.midX, y: name.midY), middleBlank, blank)
    }

    private func coordinate(_ point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
    }

    private func assertChat(_ dispatcher: Dispatcher, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars[dispatcher.name].waitForExistence(timeout: 10), "The actual tap must open the requested Dispatcher")
        let identity = app.buttons["companion-chat-header"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(identity.label.contains(dispatcher.name) && identity.label.contains(dispatcher.desktop), identity.label)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Actual Dispatcher destination \(dispatcher.host)"; shot.lifetime = .keepAlways; add(shot)
        print("HOME_ROW_OPEN host=\(dispatcher.host) agent=durable_dispatcher identity=\(identity.label)")
    }

    private func backHome(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForNonExistence(timeout: 5))
    }

    func testTrailingBlankSpaceOpensEachPinnedDispatcherOnItsDesktop() throws {
        let app = launch(["--companion-preview-dark"])
        for dispatcher in dispatchers {
            for trailing in [false, true] {
                let locations = try points(dispatcher, in: app)
                coordinate(trailing ? locations.blank : locations.middleBlank, in: app).tap()
                assertChat(dispatcher, in: app)
                backHome(app)
            }
        }
    }

    func testNameTapsAndIndependentHomeControls() throws {
        let app = launch(["--companion-preview-light"])
        for dispatcher in dispatchers {
            let locations = try points(dispatcher, in: app)
            coordinate(locations.text, in: app).tap()
            assertChat(dispatcher, in: app)
            backHome(app)
        }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["companion-chat-header"].exists)
        app.buttons["settings-close"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        let laptop = app.buttons["desktop-chip-host-preview-laptop"]
        laptop.tap()
        XCTAssertTrue(waitFor(laptop, NSPredicate(format: "selected == true"), timeout: 5))
        XCTAssertTrue(app.buttons[dispatchers[0].identifier].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[dispatchers[1].identifier].exists)
        XCTAssertFalse(app.buttons["companion-chat-header"].exists, "The independent scope control must not open a row")
        app.buttons["desktop-chip-all"].tap()
        XCTAssertTrue(app.buttons[dispatchers[0].identifier].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[dispatchers[1].identifier].exists)
    }

    func testNativeMenuAndBlankTapAtLargestTextKeepTheDispatcherTarget() throws {
        let app = launch(["--companion-preview-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let dispatcher = dispatchers[0]
        let locations = try points(dispatcher, in: app)
        coordinate(locations.text, in: app).press(forDuration: 1.2)
        let details = app.buttons["Agent details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["companion-chat-header"].exists, "Long-press must keep its independent menu gesture")
        details.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "agent-details-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[dispatcher.name].exists, "Details must belong to the pressed Dispatcher")
        app.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let afterMenu = try points(dispatcher, in: app)
        coordinate(afterMenu.blank, in: app).tap()
        assertChat(dispatcher, in: app)
    }
}
