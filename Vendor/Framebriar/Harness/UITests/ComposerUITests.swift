import notify
import XCTest

/// Drives the real composer against the harness's fake transport. No network. Opened by a simulator-injected shake.
final class ComposerUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false }

    private func open(_ arguments: String...) {
        app = XCUIApplication(); app.launchArguments = ["--callback"] + arguments; app.launch()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 0.5)
        notify_post("com.apple.UIKit.SimulatorShake")
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
    }
    private var send: XCUIElement { app.buttons["framebriar-send"] }
    private var included: String { app.staticTexts["framebriar-included"].label }

    func testOneScreenSummarySwitchAndAlwaysVisibleSend() {
        open()
        XCTAssertTrue(send.isHittable, "Send is in the top bar")
        XCTAssertFalse(app.buttons["Review feedback"].exists, "There is no Review step")
        XCTAssertEqual(included, "Included: screenshot · recent diagnostics (2 events)")
        XCTAssertTrue(send.isEnabled, "The attached screenshot alone is sendable")

        let toggle = app.switches["framebriar-diagnostics-switch"]
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(included, "Included: screenshot · diagnostics left out")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(included, "Included: screenshot · recent diagnostics (2 events)", "Switching back doesn't recapture")
    }

    func testRemovingTheOnlyContentDisablesSendAndSaysWhy() {
        open()
        app.buttons["framebriar-remove-attachment"].tap()
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(app.staticTexts["framebriar-send-reason"].label, "Add a note or a screenshot to send.")
        let notes = app.textViews["framebriar-notes"]
        notes.tap(); notes.typeText("It broke")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(app.staticTexts["framebriar-send-reason"].exists)
        XCTAssertEqual(included, "Included: note · recent diagnostics (2 events)")
    }

    func testSendShowsSent() {
        open()
        send.tap()
        let title = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let sent = NSPredicate(format: "label == 'Sent'")
        wait(for: [expectation(for: sent, evaluatedWith: title)], timeout: 10)
        XCTAssertEqual(app.staticTexts["framebriar-result-detail"].label, "The service confirmed it received your report.")
        app.buttons["framebriar-done"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
    }

    func testOfflineSendSaysSaved() {
        open("--offline")
        send.tap()
        let title = app.staticTexts["framebriar-result-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "label == 'Saved, will send when online'"), evaluatedWith: title)], timeout: 10)
        app.buttons["framebriar-done"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
    }
}
