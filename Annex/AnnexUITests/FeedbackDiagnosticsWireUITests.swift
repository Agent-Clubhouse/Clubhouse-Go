import XCTest
import UIKit
import CryptoKit

/// Actual SDK FeedbackView, Go entry points and memory-only fake HTTP/telemetry. No live endpoint.
final class FeedbackDiagnosticsWireUITests: ReliableUITestCase {
    @MainActor private func launch(image: Bool = false) -> XCUIApplication {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing"] + (image ? ["--framebriar-wire-image"] : []))
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func wire(_ app: XCUIApplication) throws -> [String: Any] {
        let text = app.staticTexts["fixture-wire-summary"]
        XCTAssertTrue(scrollUntilExists(text, in: app, maxSwipes: 8, wait: 0.3))
        return try JSONSerialization.jsonObject(with: Data(text.label.utf8)) as! [String: Any]
    }
    @MainActor private func settings(_ app: XCUIApplication, beforeOpen: (() -> Void)? = nil) {
        XCTAssertTrue(scrollTo(app.buttons["Settings"], in: app, maxSwipes: 8))
        beforeOpen?()
        waitAndTap(app.buttons["Settings"], until: app.navigationBars["Fixture settings"], timeout: 5)
    }
    @MainActor private func ordinaryButton(_ app: XCUIApplication) {
        leaveConfirmation(app)
        let button = app.buttons["Send feedback"]
        XCTAssertTrue(scrollTo(button, in: app, up: false, maxSwipes: 6))
        button.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
    }
    @MainActor private func testDraft(_ app: XCUIApplication) {
        leaveConfirmation(app)
        let group = app.buttons["Feedback diagnostics test"]
        XCTAssertTrue(scrollTo(group, in: app, maxSwipes: 6))
        let prepare = app.buttons["feedback-prepare-diagnostics-test"]
        if !prepare.exists { group.tap() }
        XCTAssertTrue(scrollTo(prepare, in: app, maxSwipes: 3))
        prepare.tap()
        let confirm = app.buttons["Prepare test report"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["feedback-diagnostics-test-banner"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedback-diagnostics-test-banner"].label, "Diagnostics test report")
    }
    @MainActor private func note(_ text: String, in app: XCUIApplication) {
        let notes = app.textViews["framebriar-notes"]
        XCTAssertTrue(scrollTo(notes, in: app, up: false, maxSwipes: 4))
        revealComposerElement(notes, in: app).tap(); notes.typeText(text)
    }
    @MainActor private func toggle(_ app: XCUIApplication) {
        let row = app.switches["framebriar-diagnostics-switch"]
        XCTAssertTrue(row.exists, "Telemetry-enabled OFF still has its disclosed excerpt switch")
        if row.switches.firstMatch.exists { row.switches.firstMatch.tap() }
        else { row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
    }
    @MainActor private func sendAndClose(_ app: XCUIApplication) {
        app.buttons["framebriar-send"].tap()
        let title = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == 'Sent'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
        app.buttons["framebriar-done"].tap()
    }
    @MainActor private func leaveConfirmation(_ app: XCUIApplication) {
        if app.navigationBars["Diagnostics test"].exists {
            app.navigationBars["Diagnostics test"].buttons.element(boundBy: 0).tap()
        }
    }
    @MainActor private func closeSettings(_ app: XCUIApplication) {
        leaveConfirmation(app)
        XCTAssertTrue(app.navigationBars["Fixture settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    @MainActor func testTelemetryEnabledOrdinaryButtonShakeAndScreenshotNeverCaptureOrAttachDiagnostics() throws {
        let app = launch()
        settings(app); ordinaryButton(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        note("ordinary button", in: app)
        toggle(app); toggle(app) // OFF stays OFF under either switch position.
        sendAndClose(app); closeSettings(app)
        var snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
        XCTAssertNil((snapshot["reports"] as? [[String: Any]])?.first?["diagnostics"])
        XCTAssertEqual(snapshot["initialScreenshotSHA"] as? String, (snapshot["media"] as? [[String: Any]])?.last?["sha256"] as? String)

        _ = app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5)
        app.buttons["fixture-shake"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        note("ordinary shake", in: app); toggle(app)
        sendAndClose(app)
        snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
        XCTAssertEqual((snapshot["reports"] as? [Any])?.count, 2)
        XCTAssertEqual(snapshot["initialScreenshotSHA"] as? String, (snapshot["media"] as? [[String: Any]])?.last?["sha256"] as? String)

        let screenshot = app.buttons["fixture-screenshot"]
        XCTAssertTrue(scrollTo(screenshot, in: app, maxSwipes: 3)); screenshot.tap()
        let prompt = app.buttons["screenshot-feedback-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5)); prompt.tap()
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        note("ordinary screenshot", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy { $0["diagnostics"] == nil })
        XCTAssertTrue(reports.allSatisfy { $0["media"] is [String: Any] }, "All three routes keep the reviewed image")
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 3)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0, "No provider call on any ordinary route")
        XCTAssertEqual(snapshot["initialScreenshotSHA"] as? String, (snapshot["media"] as? [[String: Any]])?.last?["sha256"] as? String)
        XCTAssertNil(reports[1]["incident"], "OFF's user switch still removes incident and flat trace fields")
        XCTAssertNil(reports[1]["traceId"]); XCTAssertNil(reports[1]["spanId"])
    }

    @MainActor func testScreenshotCaptureFailureExplainsTextOnlyAndNeverUploadsMedia() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--feedback-capture-failure"])
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        let screenshot = app.buttons["fixture-screenshot"]
        XCTAssertTrue(scrollTo(screenshot, in: app, maxSwipes: 6)); screenshot.tap()
        let prompt = app.buttons["screenshot-feedback-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5)); prompt.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        let reason = app.staticTexts["framebriar-screenshot-unavailable"]
        XCTAssertTrue(scrollTo(reason, in: app, maxSwipes: 6))
        XCTAssertTrue(reason.label.contains("couldn't be captured"))
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        XCTAssertTrue(app.buttons["Add screenshot"].exists)
        note("screenshot capture failed", in: app)
        sendAndClose(app)
        let snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["notes"] as? String, "screenshot capture failed")
        XCTAssertTrue(reports[0]["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
        XCTAssertNil(reports[0]["diagnostics"])
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
    }

    @MainActor func testOneLabeledDraftCancelDoesNotCarryAndFrozenFailuresDoNotDuplicateExcerpt() throws {
        let app = launch()
        settings(app); testDraft(app)
        XCTAssertFalse(app.images["framebriar-attachment"].exists, "The scoped diagnostics test must not inherit Settings' screen")
        XCTAssertFalse(app.staticTexts["framebriar-screenshot-unavailable"].exists, "This route never expected a capture")
        XCTAssertTrue(app.staticTexts["framebriar-included"].label.contains("recent diagnostics (2 events)"))
        app.buttons["Cancel"].tap()
        ordinaryButton(app); note("ordinary after cancelled test", in: app)
        sendAndClose(app); closeSettings(app)
        var snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 1)
        XCTAssertNil((snapshot["reports"] as? [[String: Any]])?.first?["diagnostics"])

        settings(app); testDraft(app)
        app.buttons["Record later retry"].tap()
        toggle(app); toggle(app)
        note("Diagnostics test frozen transport failure", in: app)
        XCTAssertTrue(app.staticTexts["framebriar-included"].label.contains("recent diagnostics (2 events)"))
        sendAndClose(app); closeSettings(app)
        snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        let captures = try XCTUnwrap(snapshot["captures"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 2); XCTAssertEqual(captures.count, 2, "Toggling doesn't recapture")
        let report = reports[1], attached = try XCTUnwrap(report["diagnostics"] as? [String: Any])
        XCTAssertEqual(attached["state"] as? String, "attached")
        XCTAssertEqual(try canonical(attached["entries"]!), try canonical(captures[1]["entries"]!))
        let entries = try XCTUnwrap(attached["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries.first?["attrs"] as? [String: Any])?["failure"] as? String, "timeout")
        XCTAssertEqual((entries.last?["attrs"] as? [String: Any])?["backoffMs"] as? Int, 30_000)
        let reportID = try XCTUnwrap(report["id"] as? String)
        let tagged = dictionaries(snapshot["telemetry"] ?? []).filter { attributes($0)["feedback.report.id"] == reportID }
        XCTAssertEqual(tagged.count, 1, "Only the marker gets this report ID; attached entries get no second excerpt")
        XCTAssertEqual((tagged.first?["body"] as? [String: Any])?["stringValue"] as? String, "feedback.submitted")
        XCTAssertTrue(dictionaries(snapshot["telemetry"] ?? []).contains { attributes($0)["app.error.class"] == "timeout" }, "Ordinary consented telemetry stays independent")
    }

    @MainActor func testEnrollmentChangeKeepsNotesAndImageButNewSendUsesOffAndFreshIncidentBytes() throws {
        let app = launch(image: true)
        settings(app); testDraft(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        note("Diagnostics test enrollment race", in: app)
        app.buttons["Change fixture enrollment"].tap()
        let banner = app.staticTexts["feedback-diagnostics-test-banner"]
        expectation(for: NSPredicate(format: "label CONTAINS 'enrollment changed'"), evaluatedWith: banner)
        waitForExpectations(timeout: 5)
        app.buttons["framebriar-send"].tap()
        // The pinned recovery notice/keyboard can hide the preview; verify its submitted bytes below.
        XCTAssertEqual(app.textViews["framebriar-notes"].value as? String, "Diagnostics test enrollment race")
        XCTAssertFalse(app.staticTexts["framebriar-included"].label.contains("recent diagnostics"))
        let notice = app.staticTexts["framebriar-error"]
        // The SDK pins errors above the Form. Keep the bounded fallback for slow UI snapshots.
        for _ in 0..<8 {
            if notice.exists { break }
            let bottom = app.staticTexts["framebriar-included"].frame.minY - 16
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width - 12, dy: bottom))
            let end = origin.withOffset(CGVector(dx: app.frame.width - 12, dy: max(200, bottom - 240)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.label.contains("nothing was saved or sent"))
        sendAndClose(app); closeSettings(app)
        var snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        let incidents = try XCTUnwrap(snapshot["incidents"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 1, "First Send must save/send nothing; only the second deliberate Send posts")
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 1, "Enrollment recovery uses model OFF, without provider recapture")
        XCTAssertGreaterThanOrEqual(incidents.count, 2)
        let report = reports[0], incident = try XCTUnwrap(report["incident"] as? [String: Any])
        XCTAssertNil(report["diagnostics"])
        XCTAssertEqual(report["notes"] as? String, "Diagnostics test enrollment race")
        XCTAssertNotNil(report["media"] as? [String: Any])
        XCTAssertEqual((report["media"] as? [String: Any])?["sha256"] as? String, snapshot["initialScreenshotSHA"] as? String, "Enrollment recovery preserves the exact image")
        XCTAssertEqual(incident["id"] as? String, incidents.last?["id"] as? String)
        XCTAssertNotEqual(incident["id"] as? String, incidents.first?["id"] as? String)
        XCTAssertNotEqual(try canonical(incident["traces"]!), try canonical(incidents.first!["traces"]!))
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(report["id"] as? String)))

        settings(app); testDraft(app) // A fresh explicit confirmation is needed to grant ON again.
        app.buttons["Cancel"].tap(); closeSettings(app)
        snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 2)
        XCTAssertEqual((snapshot["reports"] as? [Any])?.count, 1)
    }

    @MainActor private func menu(_ app: XCUIApplication, captureMenu: ((CGRect, Data) -> Void)? = nil) {
        let menu = app.buttons["fixture-feedback-menu"]
        XCTAssertTrue(scrollTo(menu, in: app, up: false, maxSwipes: 6))
        menu.tap()
        let send = app.buttons["Send feedback"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        if let captureMenu { captureMenu(send.frame, app.screenshot().pngRepresentation) }
        send.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
    }

    /// The sampled pixels come from the PNG PUT to the fake endpoint; its SHA/length must match
    /// the SDK report metadata. The bright app-content marker is underneath the opening menu.
    @MainActor private func assertUnderlyingPixels(_ snapshot: [String: Any], marker: CGRect, screen: CGRect,
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let report = try XCTUnwrap((snapshot["reports"] as? [[String: Any]])?.last, file: file, line: line)
        let metadata = try XCTUnwrap(report["media"] as? [String: Any], file: file, line: line)
        let upload = try XCTUnwrap((snapshot["media"] as? [[String: Any]])?.last, file: file, line: line)
        XCTAssertEqual(snapshot["initialScreenshotSHA"] as? String, upload["sha256"] as? String, "Unedited host PNG must reach upload byte-for-byte", file: file, line: line)
        XCTAssertEqual(metadata["sha256"] as? String, upload["sha256"] as? String, file: file, line: line)
        XCTAssertEqual(metadata["bytes"] as? Int, upload["bytes"] as? Int, file: file, line: line)
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(upload["samplePNG"] as? String)))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for fraction in [0.25, 0.5, 0.75] {
            let x = Int((marker.minX + marker.width * fraction) / screen.width * CGFloat(image.width))
            let y = Int(marker.midY / screen.height * CGFloat(image.height))
            let offset = (y * image.width + x) * 4
            XCTAssertEqual(Double(pixels[offset]) / 255, 0.9, accuracy: 0.04, file: file, line: line)
            XCTAssertEqual(Double(pixels[offset + 1]) / 255, 0.05, accuracy: 0.04, file: file, line: line)
            XCTAssertEqual(Double(pixels[offset + 2]) / 255, 0.7, accuracy: 0.04, file: file, line: line)
        }
    }

    @MainActor private func assertMenuExcluded(_ snapshot: [String: Any], underlying: Data, covered: Data,
                                              rect: CGRect, screen: CGRect) throws {
        let upload = try XCTUnwrap((snapshot["media"] as? [[String: Any]])?.last)
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(upload["samplePNG"] as? String)))
        let sample = try XCTUnwrap(UIImage(data: data)?.cgImage)
        func pixels(_ png: Data) throws -> [UInt8] {
            let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
            var bytes = [UInt8](repeating: 0, count: sample.width * sample.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: sample.width, height: sample.height,
                bitsPerComponent: 8, bytesPerRow: sample.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            return bytes
        }
        let actual = try pixels(data), before = try pixels(underlying), menu = try pixels(covered)
        let area = rect.insetBy(dx: 6, dy: 6)
        let x0 = Int(area.minX / screen.width * CGFloat(sample.width))
        let x1 = Int(area.maxX / screen.width * CGFloat(sample.width))
        let y0 = Int(area.minY / screen.height * CGFloat(sample.height))
        let y1 = Int(area.maxY / screen.height * CGFloat(sample.height))
        var actualDifference = 0.0, menuDifference = 0.0, count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                for channel in 0..<3 {
                    let i = (y * sample.width + x) * 4 + channel
                    actualDifference += abs(Double(actual[i]) - Double(before[i])) / 255
                    menuDifference += abs(Double(menu[i]) - Double(before[i])) / 255
                    count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(menuDifference / Double(count), 0.015, "Control image must detect the visible menu")
        XCTAssertLessThan(actualDifference, menuDifference * 0.4, "Uploaded pixels must match the app before the menu, not its overlay")
    }

    private func assertCapturedScreen(_ snapshot: [String: Any], matches original: Data) throws {
        let upload = try XCTUnwrap((snapshot["media"] as? [[String: Any]])?.last)
        XCTAssertEqual(snapshot["initialScreenshotSHA"] as? String, upload["sha256"] as? String)
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(upload["samplePNG"] as? String)))
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        func pixels(_ data: Data) throws -> [UInt8] {
            let cg = try XCTUnwrap(UIImage(data: data)?.cgImage)
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &result, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return result
        }
        let actual = try pixels(png), expected = try pixels(original)
        var difference = 0.0, count = 0
        for i in stride(from: image.width * 4 * image.height / 10, to: actual.count, by: 4) {
            for channel in 0..<3 { difference += abs(Double(actual[i + channel]) - Double(expected[i + channel])) / 255; count += 1 }
        }
        XCTAssertLessThan(difference / Double(count), 0.04, "Uploaded screen must match the app before Settings, with no Settings overlay")
    }

    @MainActor func testMenuPreAttachesUnderlyingScreenAndRemovePreventsImageUpload() throws {
        let app = launch()
        let marker = app.otherElements["fixture-screen-marker"].firstMatch
        let markerFrame = marker.frame, screen = app.frame
        menu(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        XCTAssertTrue(app.buttons["Replace screenshot"].exists)
        app.buttons["Cancel"].tap()
        var snapshot = try wire(app)
        XCTAssertEqual((snapshot["reports"] as? [Any])?.count, 0, "Opening/cancelling saves and sends nothing")
        let underlying = app.screenshot().pngRepresentation
        var menuFrame: CGRect = .zero, covered = Data()
        menu(app) { menuFrame = $0; covered = $1 }
        note("menu underlying screen", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        try assertUnderlyingPixels(snapshot, marker: markerFrame, screen: screen)
        try assertMenuExcluded(snapshot, underlying: underlying, covered: covered, rect: menuFrame, screen: screen)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0, "Ordinary report diagnostics remain OFF")

        menu(app)
        let remove = app.buttons["Remove"]
        XCTAssertTrue(scrollTo(remove, in: app, maxSwipes: 4)); remove.tap()
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        let photos = app.buttons["Add screenshot"]
        XCTAssertTrue(photos.exists); photos.tap()
        let picker = app.navigationBars["Photos"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "Photos may still be loading after presentation")
        picker.buttons["Cancel"].tap()
        note("menu removed image", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        XCTAssertTrue(reports.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 1, "Removed image must never upload")
        XCTAssertTrue(reports.allSatisfy { $0["diagnostics"] == nil })
    }

    @MainActor func testMenuCancelReleasesFrozenPixelsWithoutEncoding() throws {
        let app = launch()
        let state = app.staticTexts["fixture-capture-state"]
        func expectState(_ text: String) {
            expectation(for: NSPredicate(format: "label == %@", text), evaluatedWith: state)
            waitForExpectations(timeout: 5)
        }
        expectState("Pending: false · Alive: false · Encodes: 0")
        for longPress in [false, true] {
            func openMenu() {
                let source = app.buttons["fixture-feedback-menu"]
                if longPress { source.press(forDuration: 1.2) } else { source.tap() }
                XCTAssertTrue(app.buttons["Send feedback"].waitForExistence(timeout: 5))
            }
            openMenu()
            expectState("Pending: true · Alive: true · Encodes: 0")
            // Dismiss outside the menu, without selecting an action or taking another screenshot.
            app.navigationBars["Shake fixture"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            expectState("Pending: false · Alive: false · Encodes: 0")
            openMenu()
            app.buttons["Do nothing"].tap()
            expectState("Pending: false · Alive: false · Encodes: 0")
        }
        menu(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        app.buttons["Cancel"].tap()
        expectState("Pending: false · Alive: false · Encodes: 1")
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    @MainActor func testEarlyHighlightEndOpensTextOnlyWithoutReusingPixels() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--feedback-early-highlight-end"])
        XCTAssertTrue(app.buttons["fixture-feedback-menu"].waitForExistence(timeout: 10))
        menu(app)
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        XCTAssertTrue(app.buttons["Add screenshot"].exists)
        XCTAssertFalse(app.staticTexts["framebriar-screenshot-unavailable"].exists, "Early cleanup is not a capture failure")
        note("early menu dismissal", in: app)
        sendAndClose(app)
        let snapshot = try wire(app)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
    }

    @MainActor func testSettingsDoesNotEncodeUntilFeedbackIsChosen() throws {
        let app = launch()
        let state = app.staticTexts["fixture-capture-state"]
        settings(app); closeSettings(app)
        expectation(for: NSPredicate(format: "label == 'Pending: false · Alive: false · Encodes: 0'"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        settings(app); ordinaryButton(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        app.buttons["Cancel"].tap(); closeSettings(app)
        expectation(for: NSPredicate(format: "label == 'Pending: false · Alive: false · Encodes: 1'"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
    }

    @MainActor func testNativeMenuEventAndLongPressPreAttachWithoutSaving() throws {
        let app = launch()
        let activate = app.buttons["fixture-activate-feedback-menu"]
        XCTAssertTrue(scrollTo(activate, in: app, maxSwipes: 4)); activate.tap()
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        app.buttons["Cancel"].tap()
        let send = app.buttons["Send feedback"]
        app.buttons["fixture-feedback-menu"].press(forDuration: 1.2)
        XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    @MainActor func testSettingsUsesScreenBeforeSheetAndDoesNotUseShakeAttachmentPreference() throws {
        let app = launch()
        let screen = app.frame
        var marker = CGRect.zero, underlying = Data()
        settings(app) {
            underlying = app.screenshot().pngRepresentation
            let top = app.navigationBars["Shake fixture"].frame.maxY
            marker = app.otherElements["fixture-screen-marker"].firstMatch.frame.intersection(
                CGRect(x: 0, y: top + 8, width: screen.width, height: screen.height - top - 8))
        }
        let toggle = app.switches["Attach a screenshot when you shake"]
        XCTAssertTrue(scrollTo(toggle, in: app, maxSwipes: 6))
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        ordinaryButton(app)
        _ = revealComposerElement(app.images["framebriar-attachment"], in: app)
        note("settings underlying screen", in: app)
        sendAndClose(app); closeSettings(app)
        let snapshot = try wire(app)
        if marker.height > 0 { try assertUnderlyingPixels(snapshot, marker: marker, screen: screen) }
        try assertCapturedScreen(snapshot, matches: underlying)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
    }

    @MainActor func testMenuSecureFieldAndCaptureFailureStayTextOnlyWithPhotos() throws {
        var app = launch()
        let password = app.secureTextFields["Fixture password"]
        XCTAssertTrue(scrollTo(password, in: app, maxSwipes: 4)); password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        menu(app)
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        XCTAssertTrue(app.buttons["Add screenshot"].exists)
        XCTAssertTrue(app.staticTexts["framebriar-screenshot-unavailable"].label.contains("secure text field"))
        note("secure field menu", in: app)
        sendAndClose(app)
        var snapshot = try wire(app)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
        app.terminate()
        app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--feedback-capture-failure"])
        XCTAssertTrue(app.buttons["fixture-feedback-menu"].waitForExistence(timeout: 10))
        menu(app)
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        XCTAssertTrue(app.buttons["Add screenshot"].exists)
        XCTAssertFalse(app.staticTexts["framebriar-error"].exists)
        XCTAssertTrue(app.staticTexts["framebriar-screenshot-unavailable"].label.contains("couldn't be captured"))
        note("failed capture menu", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
    }

    @MainActor func testSettingsAndMenuExplainDeferredEncodingFailure() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--feedback-encode-failure"])
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        for route in ["menu", "settings"] {
            if route == "menu" { menu(app) } else { settings(app); ordinaryButton(app) }
            XCTAssertFalse(app.images["framebriar-attachment"].exists)
            let reason = app.staticTexts["framebriar-screenshot-unavailable"]
            XCTAssertTrue(scrollTo(reason, in: app, maxSwipes: 6))
            XCTAssertTrue(reason.label.contains("couldn't be captured"))
            XCTAssertTrue(app.buttons["Add screenshot"].exists)
            note("deferred encoding failed \(route)", in: app)
            sendAndClose(app)
            if route == "settings" { closeSettings(app) }
        }
        let snapshot = try wire(app)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.allSatisfy { $0["media"] is NSNull && $0["diagnostics"] == nil } == true)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
    }

    @MainActor func testSettingsSecureAndRenderFailureSayWhyWithoutUploading() throws {
        for secure in [true, false] {
            let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing"] + (secure ? [] : ["--feedback-capture-failure"]))
            XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
            if secure {
                let field = app.secureTextFields["Fixture password"]
                XCTAssertTrue(scrollTo(field, in: app, maxSwipes: 6)); field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            }
            settings(app); ordinaryButton(app)
            let reason = app.staticTexts["framebriar-screenshot-unavailable"]
            XCTAssertTrue(scrollTo(reason, in: app, maxSwipes: 6))
            XCTAssertTrue(reason.label.contains(secure ? "secure text field" : "couldn't be captured"))
            XCTAssertFalse(app.images["framebriar-attachment"].exists)
            note(secure ? "settings secure input" : "settings renderer failure", in: app)
            sendAndClose(app); closeSettings(app)
            let snapshot = try wire(app)
            XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
            XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
            XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
        }
    }

    @MainActor func testSettingsComposerKeepsNoteAndEditsUntilExplicitCancel() throws {
        let app = launch(image: true)
        settings(app); ordinaryButton(app)
        note("Keep this note until Cancel", in: app)
        let navigation = app.navigationBars["Send feedback"]
        XCTAssertFalse(navigation.buttons["Fixture settings"].exists, "Only explicit Cancel leaves a composer")
        let start = navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: navigation.frame.width * 0.8, dy: 20)))
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(navigation.exists)
        XCTAssertEqual(app.textViews["framebriar-notes"].value as? String, "Keep this note until Cancel")
        app.buttons["Cancel"].tap()
        testDraft(app)
        var canvas = editor(app)
        app.buttons["Redact"].tap()
        mark(canvas, from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.8, y: 0.8))
        finishEditor(app)
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(navigation.exists)
        canvas = editor(app)
        XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("1 mark"))
        app.buttons["framebriar-editor-cancel"].tap()
        app.buttons["Cancel"].tap(); closeSettings(app)
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    /// Keep taps between the SDK's pinned summary and navigation bars, including at accessibility sizes.
    @MainActor private func revealComposerElement(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for attempt in 0..<16 {
            var top = app.navigationBars["Send feedback"].frame.maxY
            for id in ["framebriar-error", "framebriar-send-reason"] where app.staticTexts[id].exists {
                top = max(top, app.staticTexts[id].frame.maxY)
            }
            let explanation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Start your note with ‘Diagnostics test’")).firstMatch
            if explanation.exists { top = max(top, explanation.frame.maxY) }
            let bottom = app.staticTexts["framebriar-included"].frame.minY
            if element.exists, element.frame.midY > top + 10, element.frame.midY < bottom - 10 { break }
            let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.maxX - 12, dy: (top + bottom) / 2))
            let delta: CGFloat = element.exists ? (element.frame.midY < top + 10 ? 110 : -110) : (attempt < 8 ? -110 : 110)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
        XCTAssertTrue(element.isHittable)
        return element
    }
    @MainActor private func editor(_ app: XCUIApplication) -> XCUIElement {
        revealComposerElement(app.images["framebriar-attachment"], in: app).tap()
        let canvas = app.descendants(matching: .any)["framebriar-editor-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        return canvas
    }
    /// The synthetic image is square, fitted inside a possibly tall canvas.
    @MainActor private func mark(_ canvas: XCUIElement, from: CGPoint, to: CGPoint) {
        let side = min(canvas.frame.width, canvas.frame.height)
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        func point(_ p: CGPoint) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: (canvas.frame.width - side) / 2 + side * p.x,
                                       dy: (canvas.frame.height - side) / 2 + side * p.y))
        }
        point(from).press(forDuration: 0.1, thenDragTo: point(to))
    }
    @MainActor private func finishEditor(_ app: XCUIApplication) {
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 10))
    }
    private func uploadedPixels(_ snapshot: [String: Any]) throws -> (Int, Int, [UInt8]) {
        let upload = try XCTUnwrap((snapshot["media"] as? [[String: Any]])?.last)
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(upload["uploadedPNG"] as? String)))
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let artifact = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        artifact.name = "actual-upload-\(digest)"; artifact.lifetime = .keepAlways; add(artifact)
        XCTAssertEqual(digest, upload["sha256"] as? String)
        let report = try XCTUnwrap((snapshot["reports"] as? [[String: Any]])?.last)
        let media = try XCTUnwrap(report["media"] as? [String: Any])
        XCTAssertEqual(media["sha256"] as? String, digest)
        XCTAssertEqual(media["bytes"] as? Int, png.count)
        let binding = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["reportMedia": media, "uploadSHA256": digest, "uploadBytes": png.count], options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        binding.name = "upload-binding-\(digest)"; binding.lifetime = .keepAlways; add(binding)
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        // The editor sends an opaque PNG, with no source image or separate mark payload.
        XCTAssertTrue(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    @MainActor func testEditorPinchZoomOnHostCapturedScreen() throws {
        let app = launch()
        menu(app)
        let canvas = editor(app)
        func capture(_ name: String) throws -> (Int, Int, [UInt8]) {
            let shot = canvas.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let cg = try XCTUnwrap(UIImage(data: shot.pngRepresentation)?.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (cg.width, cg.height, pixels)
        }
        let beforeAX = canvas.value as? String ?? "", before = try capture("before-pinch")
        XCTAssertTrue(beforeAX.hasSuffix("100% zoom"))
        canvas.pinch(withScale: 2, velocity: 2)
        let after = try capture("after-pinch"), afterAX = canvas.value as? String ?? ""
        XCTAssertEqual(before.0, after.0); XCTAssertEqual(before.1, after.1)
        let changed = zip(before.2, after.2).filter { $0 != $1 }.count
        let evidence: [String: Any] = ["beforeAX": beforeAX, "afterAX": afterAX,
            "width": before.0, "height": before.1, "changedChannels": changed, "channels": before.2.count]
        print("PINCH_EVIDENCE \(evidence)")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "pinch-pixel-evidence"; attachment.lifetime = .keepAlways; add(attachment)
        expectation(for: NSPredicate(format: "NOT value ENDSWITH ' 100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(changed, 0, "Zoom must change rendered pixels independently of the AX value")
        canvas.doubleTap()
        expectation(for: NSPredicate(format: "value ENDSWITH '100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        app.buttons["framebriar-editor-cancel"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    @MainActor func testEditorUploadsFourInksAndDestructiveOpaqueRedaction() throws {
        let app = launch(image: true)
        settings(app); testDraft(app)
        let canvas = editor(app)
        XCTAssertTrue((canvas.value as? String ?? "").hasSuffix("100% zoom"))
        canvas.doubleTap()
        expectation(for: NSPredicate(format: "NOT value ENDSWITH ' 100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        canvas.doubleTap()
        expectation(for: NSPredicate(format: "value ENDSWITH '100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        app.buttons["Pen"].tap()
        for (index, color) in ["red", "yellow", "blue", "white"].enumerated() {
            let ink = app.buttons["framebriar-editor-ink-\(color)"]
            XCTAssertTrue(ink.isHittable); ink.tap()
            let y = 0.15 + Double(index) * 0.12
            mark(canvas, from: CGPoint(x: 0.15, y: y), to: CGPoint(x: 0.85, y: y))
        }
        app.buttons["Redact"].tap()
        mark(canvas, from: CGPoint(x: 0.25, y: 0.65), to: CGPoint(x: 0.75, y: 0.85))
        XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("5 marks"))
        finishEditor(app)
        sendAndClose(app); closeSettings(app)
        let snapshot = try wire(app)
        let (width, height, pixels) = try uploadedPixels(snapshot)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (255, 204, 0), (0, 122, 255), (255, 255, 255)]
        for (r, g, b) in colors {
            func near(_ value: UInt8, _ target: UInt8) -> Bool { abs(Int(value) - Int(target)) < 12 }
            var count = 0
            for i in stride(from: 0, to: pixels.count, by: 4) where near(pixels[i], r) && near(pixels[i + 1], g) && near(pixels[i + 2], b) {
                count += 1
            }
            XCTAssertGreaterThan(count, 10, "Ink \(r),\(g),\(b) must be in decoded PUT bytes")
        }
        for y in Int(Double(height) * 0.69)..<Int(Double(height) * 0.81) {
            for x in Int(Double(width) * 0.3)..<Int(Double(width) * 0.7) {
                let i = (y * width + x) * 4
                XCTAssertEqual(Array(pixels[i..<i + 4]), [0, 0, 0, 255], "Covered source pixels must be replaced, not translucent")
            }
        }
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 1, "Editing never recaptures frozen diagnostics")
    }

    @MainActor func testEditorClearRestoresOriginalPixelsBeforeFirstSend() throws {
        let app = launch(image: true)
        settings(app); testDraft(app)
        var canvas = editor(app)
        app.buttons["Redact"].tap()
        mark(canvas, from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.8, y: 0.8))
        finishEditor(app)
        canvas = editor(app)
        XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("1 mark"))
        app.buttons["framebriar-editor-clear"].tap()
        let confirm = app.buttons["framebriar-editor-clear-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("0 marks"))
        finishEditor(app)
        sendAndClose(app); closeSettings(app)
        let (_, _, pixels) = try uploadedPixels(wire(app))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Array(pixels[i..<i + 4]), [255, 0, 255, 255], "Clear restores every original magenta pixel")
        }
    }

    @MainActor func testExcludeEditedScreenshotSendsNoMediaAndReincludeKeepsImage() throws {
        let app = launch(image: true)
        settings(app); testDraft(app)
        let canvas = editor(app)
        app.buttons["Redact"].tap()
        mark(canvas, from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.8, y: 0.8))
        finishEditor(app)
        let screenshot = app.switches["framebriar-screenshot-switch"]
        func toggleScreenshot() {
            _ = revealComposerElement(screenshot, in: app)
            if screenshot.switches.firstMatch.exists { screenshot.switches.firstMatch.tap() }
            else { screenshot.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        toggleScreenshot()
        XCTAssertTrue(app.staticTexts["framebriar-included"].label.contains("screenshot left out"))
        toggleScreenshot()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].exists, "Reinclude retains the edit")
        toggleScreenshot()
        note("deliberately text only", in: app)
        sendAndClose(app); closeSettings(app)
        let snapshot = try wire(app)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
    }

    @MainActor func testFailedSaveRetryKeepsFlattenedPixelsAndDraftID() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--framebriar-wire-image", "--feedback-save-failure"])
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        settings(app); testDraft(app)
        let canvas = editor(app)
        app.buttons["Redact"].tap()
        mark(canvas, from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.8, y: 0.8))
        finishEditor(app)
        app.buttons["framebriar-send"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["framebriar-error"].label.contains("Couldn't confirm"))
        let reopened = editor(app)
        XCTAssertTrue((reopened.value as? String ?? "").hasPrefix("0 marks"), "First Send drops original and marks even on failure")
        XCTAssertFalse(app.buttons["framebriar-editor-clear"].isEnabled, "Earlier covered pixels cannot be restored")
        app.buttons["framebriar-editor-cancel"].tap()
        sendAndClose(app); closeSettings(app)
        let snapshot = try wire(app)
        let saves = try XCTUnwrap(snapshot["saves"] as? [[String: String]])
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0], saves[1], "Same-enrollment retry keeps the ID and exact flattened bytes")
        let report = try XCTUnwrap((snapshot["reports"] as? [[String: Any]])?.first)
        XCTAssertEqual(report["id"] as? String, saves[0]["id"])
        XCTAssertEqual((report["media"] as? [String: Any])?["sha256"] as? String, saves[0]["sha256"])
        _ = try uploadedPixels(snapshot)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 1)
    }

    @MainActor func testLargestTypeAttachmentIsReachableAndOpensEditor() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["fixture-feedback-menu"].waitForExistence(timeout: 10))
        menu(app)
        let image = app.images["framebriar-attachment"]
        let canvas = app.descendants(matching: .any)["framebriar-editor-canvas"]
        var tapPoint: CGPoint?
        for _ in 0..<16 {
            let navigation = app.navigationBars["Send feedback"]
            guard navigation.exists else { XCTFail("Composer must stay open while revealing its attachment"); return }
            let top = navigation.frame.maxY + 8
            let bottom = app.staticTexts["framebriar-included"].frame.minY - 8
            let visible = image.exists ? image.frame.intersection(CGRect(x: 0, y: top, width: app.frame.width, height: max(0, bottom - top))) : .null
            if !visible.isNull, visible.width >= 44, visible.height >= 44 {
                // On 26.5 the AX image frame spans the cell, but the portrait
                // thumbnail is aspect-fit at its leading edge. Its midpoint is
                // blank space. Tap the visible thumbnail, above the pinned summary.
                tapPoint = CGPoint(x: visible.minX + 40, y: visible.midY)
                break
            }
            let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.maxX - 12, dy: (top + bottom) / 2))
            let delta: CGFloat = image.exists && image.frame.maxY < top + 44 ? 100 : -100
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
        let point = try XCTUnwrap(tapPoint, "Attachment must be reachable above the summary at largest type")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "largest-type-visible-attachment"; before.lifetime = .keepAlways; add(before)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "Tapping the visible attachment must open the editor at largest type")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "largest-type-editor"; after.lifetime = .keepAlways; add(after)
        guard canvas.exists else { return }
        app.buttons["framebriar-editor-cancel"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    @MainActor func testEditorControlsReachableAtAccessibilitySize() throws {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing", "--framebriar-wire-image", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons["fixture-feedback-menu"].waitForExistence(timeout: 10))
        menu(app)
        let canvas = editor(app)
        XCTAssertGreaterThan(canvas.frame.height, 80)
        for id in ["framebriar-editor-cancel", "framebriar-editor-undo", "framebriar-editor-done", "framebriar-editor-clear"] {
            XCTAssertTrue(app.buttons[id].exists)
            XCTAssertTrue(app.frame.contains(app.buttons[id].frame), "\(id) must fit on screen")
        }
        for tool in ["Move", "Pen", "Redact"] { XCTAssertTrue(app.buttons[tool].isHittable); app.buttons[tool].tap() }
        app.buttons["Pen"].tap()
        for color in ["red", "yellow", "blue", "white"] { XCTAssertTrue(app.buttons["framebriar-editor-ink-\(color)"].isHittable) }
        app.buttons["framebriar-editor-cancel"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    private func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func dictionaries(_ value: Any) -> [[String: Any]] {
        if let list = value as? [Any] { return list.flatMap(dictionaries) }
        if let dict = value as? [String: Any] { return [dict] + dict.values.flatMap(dictionaries) }
        return []
    }
    private func attributes(_ value: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for attribute in value["attributes"] as? [[String: Any]] ?? [] {
            if let key = attribute["key"] as? String, let text = (attribute["value"] as? [String: Any])?["stringValue"] as? String { result[key] = text }
        }
        return result
    }
}
