import XCTest

@MainActor final class CompanionDispatcherLaunchUITests: ReliableUITestCase {
    private let cold = "--companion-preview-external-dispatch-shortcut"
    private var composer: XCUIElement { XCUIApplication().textFields.matching(identifier: "companion-composer").firstMatch }

    override func tearDown() {
        let app = XCUIApplication()
        let hierarchy = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        hierarchy.name = "External Dispatcher final hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        super.tearDown()
    }

    private func nativeAction() {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Clubhouse Go"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "The installed app has a native Home Screen icon")
        icon.press(forDuration: 1)
        let action = springboard.buttons["Message Dispatcher"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), "Info.plist registers the native quick action")
        action.tap()
    }

    func testARealSpringBoardColdQuickActionSurvivesRestoreWithNoPairings() {
        // XCTest installs and opens the app once. The NEXT launch comes from SpringBoard,
        // with a terminated process, not an injected intent or a synthesized ConnectionOptions.
        let app = launchApp(["--companion-preview"], attempts: 1)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "dispatcher-launch-unavailable").exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        screenshot(app, "native-cold-quick-action-no-pairings")
    }

    func testColdSingleDispatcherFocusesWithoutSendingAndWarmNativeActionKeepsDraft() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", cold], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Cold handoff focuses the composer")
        XCTAssertTrue(composer.exists)
        app.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Keep this draft", "Opening never sends or replaces the existing draft")
        screenshot(app, "native-warm-action-draft-preserved")
    }

    private func warmActionWhileSettingsIsPresented(multiple: Bool) {
        var flags = ["--companion-preview"]
        if multiple { flags += ["--companion-preview-dispatcher", "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"] }
        let app = launchApp(flags, attempts: 1)
        let river = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollTo(river, in: app, maxSwipes: 6))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(river, shows: settings, attempts: 1)
        settings.tap()
        let summary = element(app, "agent-settings-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "The original sheet actually dismisses")
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 10))
        if multiple {
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-laptop"].isHittable)
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-studio"].isHittable)
        } else { XCTAssertTrue(element(app, "dispatcher-launch-unavailable").exists) }
        screenshot(app, multiple ? "warm-settings-to-chooser" : "warm-settings-to-guidance")
    }
    func testWarmManyDispatcherActionDismissesExistingSettingsBeforeChoosing() { warmActionWhileSettingsIsPresented(multiple: true) }
    func testWarmZeroDispatcherActionDismissesExistingSettingsBeforeGuidance() { warmActionWhileSettingsIsPresented(multiple: false) }

    private func chooser(_ appearance: [String], name: String, colors: [String: String] = [:]) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-multiple-dispatchers",
                             "--companion-preview-named-dispatchers", cold] + appearance, environment: colors.isEmpty ? [:] : ["CLUBHOUSE_PREVIEW_THEME": String(decoding: try! JSONEncoder().encode(colors), as: UTF8.self)], attempts: 1)
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 15))
        let echo = app.buttons["dispatcher-launch-choose-preview-laptop"]
        let navi = app.buttons["dispatcher-launch-choose-preview-studio"]
        for button in [echo, navi] {
            XCTAssertTrue(button.exists && button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.frame.contains(button.frame), "Full choice is visible, including at XXXL")
        }
        XCTAssertTrue(echo.label.contains("Echo") && navi.label.contains("Navi"))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Disambiguation precedes composer focus")
        screenshot(app, name)
        echo.tap()
        XCTAssertTrue(app.navigationBars["Echo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.typeText("Echo draft")
        XCTAssertEqual(composer.value as? String, "Echo draft")
    }
    func testChooserLight() { chooser(["--companion-preview-light"], name: "chooser-light") }
    func testChooserDark() { chooser(["--companion-preview-dark"], name: "chooser-dark") }
    func testChooserLatte() { chooser(["--companion-preview-light"], name: "chooser-latte", colors: ["base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85", "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "accent2": "#209fb5"]) }
    func testChooserMocha() { chooser(["--companion-preview-dark"], name: "chooser-mocha", colors: ["base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4", "subtext0": "#a6adc8", "surface0": "#313244", "surface1": "#45475a", "accent": "#cba6f7", "accent2": "#89b4fa"]) }
    func testChooserAccessibilityXXXL() { chooser(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], name: "chooser-accessibility-xxxl") }
}
