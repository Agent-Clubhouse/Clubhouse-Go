import notify
import XCTest

/// Real UIKit motion, SIMULATOR ONLY: the simulator's own shake notification (the same one its Device >
/// Shake menu uses) goes through UIKit's event delivery, but not through a device's motion sensors or
/// anything iOS does before that. These results say nothing about real devices.
/// "Hook received" is `count-chain`: the event reached UIApplication past every window. "Composer opened"
/// is the composer's navigation bar plus `count-perform`.
final class ShakeUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: String...) {
        app = XCUIApplication(); app.launchArguments = arguments; app.launch()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 15))
        // Enrollment status must have loaded, and the first-shake cooldown isn't in play yet.
        Thread.sleep(forTimeInterval: 0.5)
    }
    private func shake(settle: TimeInterval = 1.0) {
        XCTAssertEqual(notify_post("com.apple.UIKit.SimulatorShake"), UInt32(NOTIFY_STATUS_OK))
        Thread.sleep(forTimeInterval: settle)
    }
    // The root's strip stays in the accessibility tree under a sheet; every strip shows the same counters.
    private func count(_ name: String) -> Int { Int(app.staticTexts.matching(identifier: name).firstMatch.label) ?? -1 }
    private var composer: XCUIElement { app.navigationBars["Send feedback"] }
    private var composerCount: Int { app.navigationBars.matching(identifier: "Send feedback").count }
    private let cooldown: TimeInterval = 2.2
    private func dismissUndoAlertIfAny() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 1) { alert.buttons["Cancel"].tap() }
    }

    func testHomeOpensTheComposerOnceWithACapture() {
        launch("--callback")
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].exists, "The screen is attached for review")
        XCTAssertFalse(app.staticTexts["framebriar-result-title"].exists, "Opening never sends")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        XCTAssertEqual(count("count-chain"), 1)
        XCTAssertEqual(count("count-perform"), 1)
        XCTAssertEqual(count("count-capture"), 1)
    }

    func testDefaultModifierOpensOverHomeAndOverASheet() {
        launch()
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: cooldown)
        app.buttons["open-sheet"].tap()
        XCTAssertTrue(app.buttons["close-sheet"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.7) // past the presentation transition, where a shake is deliberately ignored
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "shakeToOpenFeedback now works over a sheet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["close-sheet"].waitForExistence(timeout: 5), "Cancel returns to the host's sheet, which stayed open")
    }

    func testASecondComposerOpensAfterTheFirstCloses() {
        launch("--callback")
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.7)
        print("SHAKE-RESULT after-close composer-state=\(app.staticTexts["composer-state"].label)")
        Thread.sleep(forTimeInterval: cooldown)
        shake()
        print("SHAKE-RESULT second chain=\(count("count-chain")) perform=\(count("count-perform")) composer=\(composer.exists)")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
    }

    func testOverASheetRepeatedShakesAndAnOpenComposerGiveExactlyOnePresentation() {
        launch("--callback")
        app.buttons["open-sheet"].tap()
        XCTAssertTrue(app.buttons["close-sheet"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        shake(settle: 0.1); shake(settle: 0.1); shake(settle: 0.1) // inside the cooldown
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: cooldown)
        shake() // past the cooldown, with the composer already open
        XCTAssertEqual(composerCount, 1)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["close-sheet"].waitForExistence(timeout: 5))
        XCTAssertFalse(composer.exists, "No second composer was underneath")
        XCTAssertEqual(count("count-chain"), 4, "The hook saw every shake")
        XCTAssertEqual(count("count-perform"), 1, "Only one opened")
    }

    func testTypingInAPlainFieldHookReceivedComposerNotOpenedFocusAndDraftKept() {
        launch("--callback")
        let field = app.textFields["field-plain"]
        field.tap(); field.typeText("draft")
        shake()
        // The system's own Shake to Undo alert may offer "Undo Typing": not swallowed by the hook.
        let undoShown = app.alerts.firstMatch.waitForExistence(timeout: 1)
        print("SHAKE-RESULT plain-field undoAlertShown=\(undoShown)")
        if undoShown { app.alerts.firstMatch.buttons["Cancel"].tap() }
        XCTAssertFalse(composer.exists, "Composer stayed closed")
        XCTAssertEqual(count("count-chain"), 1, "The hook received the event and the chain continued")
        XCTAssertEqual(count("count-perform"), 0)
        XCTAssertEqual(count("count-capture"), 0)
        XCTAssertEqual(field.value as? String, "draft", "The draft is untouched")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Focus stayed on the field")
    }

    func testSecureFieldHookReceivedComposerNotOpenedNoCapture() {
        launch("--callback")
        let field = app.secureTextFields["field-secure"]
        field.tap(); field.typeText("hunter2")
        shake()
        let alert = app.alerts.firstMatch.waitForExistence(timeout: 1)
        if alert { app.alerts.firstMatch.buttons["Cancel"].tap() }
        print("SHAKE-RESULT sdk-secure undoAlertShown=\(alert) keyboardAfter=\(app.keyboards.firstMatch.waitForExistence(timeout: 3))")
        XCTAssertFalse(composer.exists)
        XCTAssertEqual(count("count-chain"), 1)
        XCTAssertEqual(count("count-perform"), 0)
        XCTAssertEqual(count("count-capture"), 0, "No capture while a secure field is active")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Focus stayed on the field")
    }

    /// Control, with no SDK shake code loaded: what the system alone does to a focused secure field.
    func testControlSecureFieldKeyboardWithoutTheSDK() {
        launch("--no-sdk")
        let field = app.secureTextFields["field-secure"]
        field.tap(); field.typeText("hunter2")
        shake()
        let alert = app.alerts.firstMatch.waitForExistence(timeout: 1)
        if alert { app.alerts.firstMatch.buttons["Cancel"].tap() }
        let keyboard = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        print("SHAKE-RESULT control-secure undoAlertShown=\(alert) keyboardAfter=\(keyboard)")
    }

    func testTypingInAFieldInsideASheetIsAlsoIgnored() {
        launch("--callback")
        app.buttons["open-sheet"].tap()
        let field = app.textFields["sheet-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.7)
        field.tap(); field.typeText("draft")
        shake()
        dismissUndoAlertIfAny()
        XCTAssertFalse(composer.exists)
        XCTAssertEqual(field.value as? String, "draft")
        XCTAssertEqual(count("count-chain"), 1)
        XCTAssertEqual(count("count-perform"), 0)
    }

    func testAfterTheKeyboardIsDismissedAShakeOpens() {
        launch("--callback")
        let field = app.textFields["field-plain"]
        field.tap(); field.typeText("x")
        app.buttons["resign"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["framebriar-attachment"].exists)
    }

    func testAHostResponderStillGetsItsMotionEndedAndTheComposerStillOpens() {
        launch("--callback")
        app.buttons["toggle-responder"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        XCTAssertEqual(count("count-probe"), 1, "The host's own motionEnded ran")
        XCTAssertEqual(count("count-chain"), 1, "and the chain continued past the window, once")
        XCTAssertEqual(count("count-perform"), 1)
    }

    func testANonKeyPassthroughOverlayChangesNothing() {
        launch("--callback", "--passthrough-window")
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["open-sheet"].waitForExistence(timeout: 5))
        XCTAssertEqual(count("count-perform"), 1)
        XCTAssertEqual(count("count-chain"), 1)
    }

    func testNotEnrolledExplainsInsteadOfOpening() {
        launch("--callback", "--not-enrolled")
        shake()
        XCTAssertFalse(composer.exists)
        XCTAssertEqual(count("count-not-enrolled"), 1)
        XCTAssertEqual(count("count-perform"), 0)
    }

    func testCaptureOffOpensWithNoImage() {
        launch("--callback", "--no-capture")
        shake()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["framebriar-attachment"].exists)
    }
}

/// Run on an iPad simulator with multitasking that keeps two scenes active. Skips otherwise, and says so.
final class ShakeMultiSceneUITests: XCTestCase {
    func testTwoScenesOnlyTheKeyWindowFiresOnce() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
        let app = XCUIApplication(); app.launchArguments = ["--callback"]; app.launch()
        XCTAssertTrue(app.buttons["new-scene"].waitForExistence(timeout: 15))
        app.buttons["new-scene"].tap()
        Thread.sleep(forTimeInterval: 3)
        let buttons = app.buttons.matching(identifier: "new-scene").count
        print("SHAKE-RESULT multiscene visibleSceneRoots=\(buttons)")
        try XCTSkipIf(buttons < 2, "This simulator didn't keep two scenes on screen, so only the hosted routing tests cover it")
        XCTAssertEqual(notify_post("com.apple.UIKit.SimulatorShake"), UInt32(NOTIFY_STATUS_OK))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.navigationBars.matching(identifier: "Send feedback").count, 1, "One composer across both scenes")
        app.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.navigationBars.matching(identifier: "Send feedback").count, 0, "None left in the other scene")
        let perform = app.staticTexts.matching(identifier: "count-perform").firstMatch.label
        let chain = app.staticTexts.matching(identifier: "count-chain").firstMatch.label
        print("SHAKE-RESULT multiscene perform=\(perform) chain=\(chain) sceneCount=\(app.staticTexts.matching(identifier: "scene-count").firstMatch.label)")
        XCTAssertEqual(perform, "1", "Acted once")
        XCTAssertEqual(chain, "1", "Delivered once, to one window")
    }
}
