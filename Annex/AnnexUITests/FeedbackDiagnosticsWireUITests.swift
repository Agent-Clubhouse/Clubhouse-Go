import XCTest
import UIKit

/// Actual SDK FeedbackView, Go entry points and memory-only fake HTTP/telemetry. No live endpoint.
final class FeedbackDiagnosticsWireUITests: ReliableUITestCase {
    @MainActor private func launch(image: Bool = false) -> XCUIApplication {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing"] + (image ? ["--framebriar-wire-image"] : []))
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func wire(_ app: XCUIApplication) throws -> [String: Any] {
        let text = app.staticTexts["fixture-wire-summary"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        return try JSONSerialization.jsonObject(with: Data(text.label.utf8)) as! [String: Any]
    }
    @MainActor private func settings(_ app: XCUIApplication) {
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
        notes.tap(); notes.typeText(text)
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
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        note("ordinary button", in: app)
        toggle(app); toggle(app) // OFF stays OFF under either switch position.
        sendAndClose(app); closeSettings(app)
        var snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
        XCTAssertNil((snapshot["reports"] as? [[String: Any]])?.first?["diagnostics"])

        _ = app.navigationBars["Send feedback"].waitForExistence(timeout: 2.5)
        app.buttons["fixture-shake"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        note("ordinary shake", in: app); toggle(app)
        sendAndClose(app)
        snapshot = try wire(app)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0)
        XCTAssertEqual((snapshot["reports"] as? [Any])?.count, 2)

        let screenshot = app.buttons["fixture-screenshot"]
        XCTAssertTrue(scrollTo(screenshot, in: app, maxSwipes: 3)); screenshot.tap()
        let prompt = app.buttons["screenshot-feedback-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5)); prompt.tap()
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        note("ordinary screenshot", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy { $0["diagnostics"] == nil })
        XCTAssertTrue(reports.allSatisfy { $0["media"] is [String: Any] }, "All three routes keep the reviewed image")
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 3)
        XCTAssertEqual((snapshot["captures"] as? [Any])?.count, 0, "No provider call on any ordinary route")
        XCTAssertNil(reports[1]["incident"], "OFF's user switch still removes incident and flat trace fields")
        XCTAssertNil(reports[1]["traceId"]); XCTAssertNil(reports[1]["spanId"])
    }

    @MainActor func testOneLabeledDraftCancelDoesNotCarryAndFrozenFailuresDoNotDuplicateExcerpt() throws {
        let app = launch()
        settings(app); testDraft(app)
        XCTAssertFalse(app.images["framebriar-attachment"].exists, "The scoped diagnostics test must not inherit Settings' screen")
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
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        note("Diagnostics test enrollment race", in: app)
        app.buttons["Change fixture enrollment"].tap()
        let banner = app.staticTexts["feedback-diagnostics-test-banner"]
        expectation(for: NSPredicate(format: "label CONTAINS 'enrollment changed'"), evaluatedWith: banner)
        waitForExpectations(timeout: 5)
        app.buttons["framebriar-send"].tap()
        XCTAssertTrue(app.images["framebriar-attachment"].exists)
        XCTAssertEqual(app.textViews["framebriar-notes"].value as? String, "Diagnostics test enrollment race")
        XCTAssertFalse(app.staticTexts["framebriar-included"].label.contains("recent diagnostics"))
        let notice = app.staticTexts["framebriar-error"]
        // The SDK places this below the image, in a lazy Form. Scroll the visible Form margin,
        // above its pinned summary/keyboard, rather than swiping on the focused text editor.
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

    @MainActor func testMenuPreAttachesUnderlyingScreenAndRemovePreventsImageUpload() throws {
        let app = launch()
        let marker = app.otherElements["fixture-screen-marker"].firstMatch
        let markerFrame = marker.frame, screen = app.frame
        menu(app)
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Cancel"].tap()
        note("menu removed image", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        let reports = try XCTUnwrap(snapshot["reports"] as? [[String: Any]])
        XCTAssertTrue(reports.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 1, "Removed image must never upload")
        XCTAssertTrue(reports.allSatisfy { $0["diagnostics"] == nil })
    }

    @MainActor func testNativeMenuEventAndLongPressPreAttachWithoutSaving() throws {
        let app = launch()
        let activate = app.buttons["fixture-activate-feedback-menu"]
        XCTAssertTrue(scrollTo(activate, in: app, maxSwipes: 4)); activate.tap()
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let send = app.buttons["Send feedback"]
        app.buttons["fixture-feedback-menu"].press(forDuration: 1.2)
        XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }

    @MainActor func testSettingsUsesScreenBeforeSheetAndDoesNotUseShakeAttachmentPreference() throws {
        let app = launch()
        let marker = app.otherElements["fixture-screen-marker"].firstMatch.frame, screen = app.frame
        settings(app)
        let toggle = app.switches["Attach a screenshot when you shake"]
        XCTAssertTrue(scrollTo(toggle, in: app, maxSwipes: 6))
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        ordinaryButton(app)
        XCTAssertTrue(app.images["framebriar-attachment"].waitForExistence(timeout: 5))
        note("settings underlying screen", in: app)
        sendAndClose(app); closeSettings(app)
        let snapshot = try wire(app)
        try assertUnderlyingPixels(snapshot, marker: marker, screen: screen)
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
        note("failed capture menu", in: app)
        sendAndClose(app)
        snapshot = try wire(app)
        XCTAssertTrue((snapshot["reports"] as? [[String: Any]])?.last?["media"] is NSNull)
        XCTAssertEqual((snapshot["media"] as? [Any])?.count, 0)
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
