import notify
import XCTest

/// Drives the real editor from the real composer, opened by a simulator-injected shake. No network. The
/// harness's fake service hashes and counts the image it receives, so these compare delivered bytes.
final class ScreenshotEditorUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private func openComposer(_ arguments: String...) {
        app = XCUIApplication(); app.launchArguments = ["--callback", "--model-off"] + arguments; app.launch()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 0.5)
        notify_post("com.apple.UIKit.SimulatorShake")
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
    }
    private var attachment: XCUIElement { app.images["framebriar-attachment"] }
    private var canvas: XCUIElement { app.descendants(matching: .any)["framebriar-editor-canvas"] }
    private var undo: XCUIElement { app.buttons["framebriar-editor-undo"] }
    private var hint: XCUIElement { app.staticTexts["framebriar-editor-hint"] }
    private var canvasValue: String { canvas.value as? String ?? "" }

    /// Scrolls the form until `element`'s center is between the pinned bars, because a tap under one lands on the bar.
    /// With a long note or the keyboard up, either bar can be over it, and the form stays scrolled after the editor closes.
    private func clear(_ element: XCUIElement) -> XCUIElement {
        let form = app.collectionViews.firstMatch
        // The form's margin, so a drag never starts on the image or the notes.
        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        for _ in 0..<8 {
            var top = app.navigationBars["Send feedback"].frame.maxY
            for id in ["framebriar-error", "framebriar-send-reason"] where app.staticTexts[id].exists { top = max(top, app.staticTexts[id].frame.maxY) }
            let bottom = app.staticTexts["framebriar-included"].frame.minY, y = element.frame.midY
            if y < top + 8 { start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120))) }
            else if y > bottom - 8 { start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120))) }
            else { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return element
    }

    private func openEditor() {
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        clear(attachment).tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "The image opens the editor. Image at \(attachment.frame), summary at \(app.staticTexts["framebriar-included"].frame)")
    }
    private func choose(_ tool: String) { app.buttons[tool].tap() }
    private func drag(from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }
    private func marks(_ expected: String) {
        wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", expected), evaluatedWith: canvas)], timeout: 5)
    }
    private func send(expecting title: String = "Sent") {
        app.buttons["framebriar-send"].tap()
        let result = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "label == %@", title), evaluatedWith: result)], timeout: 15)
        app.buttons["framebriar-done"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
    }
    private func label(_ id: String) -> String { app.staticTexts[id].label }

    func testZoomIsReportedAndMarksDontMoveTheImage() {
        openComposer(); openEditor()
        XCTAssertTrue(canvasValue.hasSuffix("100% zoom"), canvasValue)
        canvas.pinch(withScale: 3, velocity: 3)
        Thread.sleep(forTimeInterval: 0.5)
        let pinched = canvasValue
        XCTAssertFalse(pinched.hasSuffix(" 100% zoom"), "Pinch zooms under Move: \(pinched)")
        canvas.doubleTap()
        wait(for: [expectation(for: NSPredicate(format: "value ENDSWITH '100% zoom'"), evaluatedWith: canvas)], timeout: 5)
        canvas.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(canvasValue.hasSuffix(" 100% zoom"), "Double-tap zooms in from the fit")

        // Under the pen a drag draws, and a pinch and a double-tap do nothing to the zoom.
        canvas.doubleTap()
        wait(for: [expectation(for: NSPredicate(format: "value ENDSWITH '100% zoom'"), evaluatedWith: canvas)], timeout: 5)
        choose("Pen")
        XCTAssertTrue(hint.label.contains("To hide something, choose Redact"), "The pen steers to the redaction tool")
        canvas.pinch(withScale: 3, velocity: 3)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(canvasValue.hasSuffix(" 100% zoom"), "No zoom while drawing: \(canvasValue)")
    }

    func testPenRedactUndoAndCancelKeepTheOriginalBytes() {
        openComposer(); openEditor()
        XCTAssertFalse(undo.isEnabled)
        choose("Pen")
        drag(from: CGVector(dx: 0.2, dy: 0.2), to: CGVector(dx: 0.8, dy: 0.3))
        marks("1 mark")
        choose("Redact")
        XCTAssertTrue(hint.label.contains("solid black") && hint.label.contains("only covers what you cover"))
        drag(from: CGVector(dx: 0.2, dy: 0.5), to: CGVector(dx: 0.8, dy: 0.7))
        marks("2 marks")
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        marks("1 mark")
        undo.tap()
        marks("0 marks")
        XCTAssertFalse(undo.isEnabled)
        drag(from: CGVector(dx: 0.2, dy: 0.5), to: CGVector(dx: 0.8, dy: 0.7))
        marks("1 mark")

        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["framebriar-captured-screen-note"].exists, "Still the capture")
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)

        send()
        XCTAssertEqual(label("delivered-sha"), label("capture-sha"), "Cancel keeps the original, byte for byte")
    }

    func testDoneWithNoMarksChangesNothing() {
        openComposer(); openEditor()
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)
        send()
        XCTAssertEqual(label("delivered-sha"), label("capture-sha"))
    }

    func testDoneReplacesTheImageAndSendDeliversTheFlattenedBytes() {
        openComposer(); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        let note = app.staticTexts["framebriar-edited-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), "The note says it's edited")
        XCTAssertTrue(note.label.contains("You edited this image") && note.label.contains("until you tap Send") && note.label.contains("Redact"))
        XCTAssertFalse(app.staticTexts["framebriar-captured-screen-note"].exists)

        // Coming back, the marks are still marks, until a Send.
        XCTAssertTrue(attachment.exists)
        openEditor()
        XCTAssertTrue(canvasValue.hasPrefix("1 mark"), "Still editable before any Send")
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Cancel on a later visit keeps the edit")

        send()
        XCTAssertNotEqual(label("delivered-sha"), label("capture-sha"))
        XCTAssertNotEqual(label("delivered-sha"), "none")
        let before = Int(label("capture-black")) ?? 0, after = Int(label("delivered-black")) ?? 0
        XCTAssertGreaterThan(after, before + 10_000, "The redaction is in the delivered pixels")
    }

    func testRemoveAfterAnEditStartsOver() {
        openComposer(); openEditor()
        choose("Pen")
        drag(from: CGVector(dx: 0.2, dy: 0.2), to: CGVector(dx: 0.8, dy: 0.3))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        app.buttons["framebriar-remove-attachment"].tap()
        XCTAssertFalse(attachment.exists)
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)
        XCTAssertFalse(app.buttons["framebriar-send"].isEnabled, "Nothing to send, and the original doesn't come back")
    }

    func testATallScreenshotCanBeZoomedAndRedacted() {
        openComposer("--tall-image"); openEditor()
        XCTAssertTrue(canvasValue.hasSuffix(" 100% zoom"), "Opens fitted: \(canvasValue)")
        canvas.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        let zoomed = Int(canvasValue.split(separator: " ").dropLast().last?.filter(\.isNumber) ?? "") ?? 0
        XCTAssertGreaterThan(zoomed, 300, "Double-tap fills the width, enough to read: \(canvasValue)")
        canvas.swipeUp()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.3), to: CGVector(dx: 0.9, dy: 0.5))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        send()
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, 10_000)
    }

    func testRotationKeepsMarksAndTheEditorUsable() {
        openComposer(); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.2, dy: 0.2), to: CGVector(dx: 0.8, dy: 0.4))
        marks("1 mark")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(canvas.exists && canvas.isHittable)
        marks("1 mark")
        XCTAssertTrue(app.buttons["framebriar-editor-done"].isHittable, "Done stays on screen in landscape")
        drag(from: CGVector(dx: 0.4, dy: 0.6), to: CGVector(dx: 0.6, dy: 0.9))
        marks("2 marks")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        marks("2 marks")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        send()
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, Int(label("capture-black")) ?? 0)
    }

    func testAShakeWhileTheEditorIsOpenOpensNothingAndCapturesNothing() {
        openComposer(); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.2, dy: 0.2), to: CGVector(dx: 0.8, dy: 0.4))
        marks("1 mark")
        Thread.sleep(forTimeInterval: 2.5) // Past the cooldown from opening, so only the guards can refuse it.
        notify_post("com.apple.UIKit.SimulatorShake")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(canvas.exists, "The editor is still in front")
        marks("1 mark")
        XCTAssertFalse(app.navigationBars["Send feedback"].isHittable, "No second composer over it")

        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        notify_post("com.apple.UIKit.SimulatorShake") // Back on the composer, which is also still open.
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "label != '0'"), evaluatedWith: app.staticTexts["count-chain"])], timeout: 5)
        XCTAssertEqual(label("count-perform"), "1", "Only the shake that opened the composer")
        XCTAssertEqual(label("count-capture"), "1", "Nothing captured the editor")
        XCTAssertEqual(label("composer-state"), "closed", "The open count balances after the cover")
    }

    /// A host's own composer doesn't count as open on the model, so only the editor's guard can refuse this.
    func testAShakeWhileTheEditorIsOpenWithNoComposerOpensNothing() {
        app = XCUIApplication(); app.launchArguments = ["--callback"]; app.launch()
        XCTAssertTrue(app.buttons["open-editor"].waitForExistence(timeout: 15))
        app.buttons["open-editor"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        notify_post("com.apple.UIKit.SimulatorShake")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.navigationBars["Send feedback"].exists, "No composer over the editor")
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "label != '0'"), evaluatedWith: app.staticTexts["count-chain"])], timeout: 5)
        XCTAssertEqual(label("count-perform"), "0")
        XCTAssertEqual(label("count-capture"), "0", "The editor was never captured")
    }

    func testAShakeAfterTheComposerClosesStillWorks() {
        openComposer(); openEditor()
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        notify_post("com.apple.UIKit.SimulatorShake")
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5), "The editor's guard ended with it")
    }

    func testOfflineSendAfterAnEditSaysSavedAndTheEditorIsGone() {
        openComposer("--offline"); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.2, dy: 0.2), to: CGVector(dx: 0.8, dy: 0.4))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        app.buttons["framebriar-send"].tap()
        let result = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "label == 'Saved, will send when online'"), evaluatedWith: result)], timeout: 15)
        XCTAssertFalse(attachment.exists, "After commit there's no image to open the editor from")
        XCTAssertFalse(canvas.exists)
    }

    func testEnrollmentChangeKeepsTheEditForANewSend() {
        openComposer("--reenroll-after-open"); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        app.buttons["framebriar-send"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["framebriar-edited-final-note"].exists, "The edited image stays, and is final now")
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)
        XCTAssertFalse(app.staticTexts["framebriar-result-title"].exists, "Nothing sends until a new Send")
        send()
        XCTAssertNotEqual(label("delivered-sha"), label("capture-sha"), "The original doesn't come back")
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, (Int(label("capture-black")) ?? 0) + 10_000)
    }

    // MARK: ink

    func testEachInkReachesTheDeliveredBytes() {
        openComposer("--tall-image"); openEditor()
        choose("Pen")
        var count = 0
        for (index, ink) in ["red", "yellow", "blue", "white"].enumerated() {
            let swatch = app.buttons["framebriar-editor-ink-\(ink)"]
            XCTAssertTrue(swatch.waitForExistence(timeout: 5), ink)
            swatch.tap()
            XCTAssertTrue(swatch.isSelected, "\(ink) is the selected ink")
            let y = 0.2 + Double(index) * 0.15
            drag(from: CGVector(dx: 0.3, dy: y), to: CGVector(dx: 0.7, dy: y))
            count += 1
            marks("\(count) mark")
        }
        XCTAssertTrue(hint.label.contains("To hide something, choose Redact"), "Any ink is still not redaction")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        send()
        XCTAssertEqual(label("delivered-inks"), "red yellow blue white")
    }

    // MARK: Clear edits

    private func clearEdits(confirming text: String) {
        let clear = app.buttons["framebriar-editor-clear"]
        XCTAssertTrue(clear.isEnabled)
        clear.tap()
        let title = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The confirmation says: \(text)")
        let confirm = app.buttons["framebriar-editor-clear-confirm"]
        // iOS 26 reports the id on more than one element of the dialog.
        (confirm.exists ? confirm.firstMatch : app.sheets.buttons["Clear edits"].firstMatch).tap()
    }

    func testClearEditsBeforeSendConfirmsAndBringsTheOriginalBack() {
        openComposer(); openEditor()
        XCTAssertFalse(app.buttons["framebriar-editor-clear"].isEnabled, "Nothing to clear yet")
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))

        openEditor()
        marks("1 mark")
        undo.tap()
        marks("0 marks")
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 5), "Cancel keeps the edit")

        openEditor()
        marks("1 mark")
        clearEdits(confirming: "including anything you covered")
        marks("0 marks")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-captured-screen-note"].waitForExistence(timeout: 15), "It's the capture again")
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)
        send()
        XCTAssertEqual(Int(label("delivered-black")), Int(label("capture-black")), "No redaction in the delivered pixels")
    }

    /// The boundary: once Send was tapped, covered pixels can never come back, whatever happens to that save.
    func testRedactThenAFailedSendThenClearKeepsTheRedaction() {
        openComposer("--fail-first-save"); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))

        app.buttons["framebriar-send"].tap()
        let error = app.staticTexts["framebriar-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.hasPrefix("Couldn't confirm this saved"), error.label)
        let final = app.staticTexts["framebriar-edited-final-note"]
        XCTAssertTrue(final.waitForExistence(timeout: 5))
        XCTAssertTrue(final.label.contains("can't be undone") && final.label.contains("stays covered"), final.label)

        openEditor()
        marks("0 marks")
        XCTAssertFalse(app.buttons["framebriar-editor-clear"].isEnabled, "Nothing here can be cleared: the redaction is part of the image")
        choose("Pen")
        drag(from: CGVector(dx: 0.2, dy: 0.1), to: CGVector(dx: 0.8, dy: 0.1))
        marks("1 mark")
        clearEdits(confirming: "stays covered")
        marks("0 marks")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(final.waitForExistence(timeout: 5))
        send()
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, (Int(label("capture-black")) ?? 0) + 10_000, "The redaction is still in the delivered pixels")
    }

    // MARK: Include screenshot

    private var includeSwitch: XCUIElement { app.switches["framebriar-screenshot-switch"].switches.firstMatch }
    private var included: String { app.staticTexts["framebriar-included"].label }

    func testAnUncheckedScreenshotSendsNoMediaAndTheSummarySaysSo() {
        openComposer()
        XCTAssertEqual(included, "Included: screenshot", "On by default when an image is attached")
        clear(includeSwitch).tap()
        XCTAssertEqual(included, "Included: screenshot left out")
        XCTAssertTrue(app.staticTexts["framebriar-screenshot-left-out-note"].exists)
        XCTAssertFalse(app.buttons["framebriar-send"].isEnabled, "Nothing left to send")
        XCTAssertEqual(app.staticTexts["framebriar-send-reason"].label, "Add a note or include a screenshot to send.")
        let notes = app.textViews["framebriar-notes"]
        clear(notes).tap(); notes.typeText("Just text")
        XCTAssertEqual(included, "Included: note · screenshot left out")
        send()
        XCTAssertEqual(label("reports-posted"), "1")
        XCTAssertEqual(label("reports-with-media"), "0")
        XCTAssertEqual(label("delivered-sha"), "none", "No image on the wire")
    }

    func testRecheckingBeforeSendRestoresTheSameEditWithItsMarks() {
        openComposer(); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        clear(includeSwitch).tap()
        XCTAssertFalse(app.staticTexts["framebriar-edited-note"].exists)
        clear(includeSwitch).tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 5))
        openEditor()
        marks("1 mark")
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        send()
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, (Int(label("capture-black")) ?? 0) + 10_000)
    }

    /// Send ends reversibility even for an image left out of that Send.
    func testAFailedSendWhileUncheckedLeavesOnlyTheFlattenedImageWhenRechecked() {
        openComposer("--fail-first-save"); openEditor()
        choose("Redact")
        drag(from: CGVector(dx: 0.1, dy: 0.2), to: CGVector(dx: 0.9, dy: 0.8))
        marks("1 mark")
        app.buttons["framebriar-editor-done"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-note"].waitForExistence(timeout: 15))
        clear(includeSwitch).tap()
        let notes = app.textViews["framebriar-notes"]
        clear(notes).tap(); notes.typeText("Just text")
        app.buttons["framebriar-send"].tap()
        XCTAssertTrue(app.staticTexts["framebriar-error"].waitForExistence(timeout: 10))

        clear(includeSwitch).tap()
        XCTAssertTrue(app.staticTexts["framebriar-edited-final-note"].waitForExistence(timeout: 5))
        openEditor()
        marks("0 marks")
        app.buttons["framebriar-editor-cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        send()
        XCTAssertGreaterThan(Int(label("delivered-black")) ?? 0, (Int(label("capture-black")) ?? 0) + 10_000)
    }
}
