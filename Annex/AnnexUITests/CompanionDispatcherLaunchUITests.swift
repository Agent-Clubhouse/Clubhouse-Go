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

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    private func nativeAction() {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icons = springboard.icons.matching(identifier: "Clubhouse Go")
        func visibleIcon() -> XCUIElement? {
            icons.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable }
        }
        // One bounded navigation attempt, not another launch/action attempt. Cold Home can
        // expose an App Library placeholder with a zero frame before the app's actual page.
        if visibleIcon() == nil { springboard.swipeLeft() }
        let tree = XCTAttachment(data: Data(springboard.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        tree.name = "SpringBoard before native quick action"; tree.lifetime = .keepAlways; add(tree)
        guard let icon = visibleIcon() else {
            XCTFail("No visible, hittable Clubhouse Go icon after one Home-page navigation; native delivery unverified")
            return
        }
        XCTAssertFalse(icon.frame.isEmpty)
        XCTAssertTrue(icon.isHittable)
        icon.press(forDuration: 1)
        let action = springboard.buttons["Message Dispatcher"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), "Info.plist registers the native quick action")
        action.tap()
    }

    func testARealSpringBoardColdQuickActionSurvivesRestoreWithNoPairings() throws {
        // XCTest installs and opens the app once. The NEXT launch comes from SpringBoard,
        // with a terminated process, not an injected intent or a synthesized ConnectionOptions.
        let app = launchApp(["--companion-preview"], attempts: 1)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let restoreError = app.alerts["Could not restore desktops"]
        let unexpectedRestoreFailure = restoreError.waitForExistence(timeout: 3)
        if unexpectedRestoreFailure {
            screenshot(app, "native-cold-unexpected-restore-error")
            restoreError.buttons["OK"].tap()
            XCTAssertTrue(restoreError.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 20))
        let guidance = app.descendants(matching: .any).matching(identifier: "dispatcher-launch-unavailable").firstMatch
        XCTAssertTrue(guidance.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        screenshot(app, "native-cold-quick-action-no-pairings")
        let json = try XCTUnwrap(guidance.value as? String, "The actual Runtime must publish status-only probe/restore evidence")
        let data = Data(json.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Actual Runtime Keychain capability probe and restore statuses"
        attachment.lifetime = .keepAlways; add(attachment)
        let statuses = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let probeAdd = try XCTUnwrap(statuses["probeAdd"] as? Int)
        let probeDelete = statuses["probeDelete"] as? Int
        let restoreKind = try XCTUnwrap(statuses["restoreKind"] as? String)
        let restoreStatus = statuses["restoreStatus"] as? Int
        if probeAdd == -34018 {
            XCTContext.runActivity(named: "Entitlement-recovery coverage; not a production cold-restore PASS") { _ in
                XCTAssertNil(probeDelete, "A rejected add created no probe item")
                XCTAssertEqual(restoreKind, "persistenceFailed")
                XCTAssertEqual(restoreStatus, -34018, "Probe and real restore must match exactly")
                XCTAssertTrue(unexpectedRestoreFailure, "The entitlement error must remain visible before guidance")
            }
        } else {
            XCTAssertEqual(probeAdd, 0, "Every other probe error fails; no signing or environment opt-out")
            XCTAssertEqual(probeDelete, 0, "A capable probe must remove its throwaway item")
            XCTAssertEqual(restoreKind, "success", "A capable probe cannot excuse a restore failure")
            XCTAssertNil(restoreStatus)
            XCTAssertFalse(unexpectedRestoreFailure, "Clean-install production restoration failed; the error is a separate finding even if the external handoff recovers")
        }
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

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The terminal from the project page, which stays where it was after the terminal is cleared from outside.
    private func openProjectTerminal(_ app: XCUIApplication) -> XCUIElement {
        let terminal = app.buttons["project-terminal"]
        if !terminal.exists {
            let header = element(app, "open-project-preview-studio-clubhouse")
            scrollTo(header, in: app, maxSwipes: 4)
            waitAndTap(header, until: terminal, timeout: 10, "The project page must offer Terminal")
        }
        let output = element(app, "terminal-output")
        waitAndTap(terminal, until: output, timeout: 10, "Terminal must open a full-screen terminal")
        return output
    }

    private func openLinkInTheInAppBrowser(_ app: XCUIApplication, _ output: XCUIElement, round: String) {
        app.typeText("links\n")
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "Paste code here"), timeout: 10))
        let links = element(app, "terminal-links")
        XCTAssertTrue(links.waitForExistence(timeout: 5), "\(round): a shown link adds the Links action")
        links.tap()
        let open = element(app, "terminal-link-open-0")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "\(round): Links offers Open")
        open.tap()
        XCTAssertTrue(element(app, "TopBrowserBar").waitForExistence(timeout: 15), "\(round): Open shows the in-app browser")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "\(round): the in-app browser has its Done button")
    }

    /// B1 in the real app, where presentations really complete (a hosted unit test cannot model an outside dismissal on
    /// iOS 26.5: its presentation never finishes). The Message Dispatcher action clears every presentation from
    /// outside while the real in-app Safari is up over the terminal; Safari never reports back, and Open must still
    /// work afterwards, in a fresh shell.
    func testClearingPresentationsFromOutsideLeavesOpenWorkingAndClosesTheOldShell() {
        let app = launchApp(["--companion-preview"], attempts: 1)
        var output = openProjectTerminal(app)
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "clubhouse %"), timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("echo old shell marker\n")
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "\nold shell marker\n"), timeout: 10))
        openLinkInTheInAppBrowser(app, output, round: "First")
        screenshot(app, "in-app browser before the outside clear")

        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 15), "The action reaches the dispatcher guidance")
        XCTAssertTrue(element(app, "terminal-output").waitForNonExistence(timeout: 10), "The terminal went with the browser")
        XCTAssertFalse(app.buttons["Close"].exists, "The in-app browser is gone")
        screenshot(app, "after the outside clear")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForNonExistence(timeout: 10))

        // The stale-browser oracle: Open presents Safari again, though the old page never reported back.
        output = openProjectTerminal(app)
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "clubhouse %"), timeout: 10))
        XCTAssertFalse((output.value as? String ?? "").contains("old shell marker"), "The old shell was closed: this is a new one")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        openLinkInTheInAppBrowser(app, output, round: "Second")
        screenshot(app, "in-app browser after the outside clear")
        app.buttons["Close"].tap()
        XCTAssertTrue(output.waitForExistence(timeout: 10), "Done returns to the terminal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The keyboard comes back with the terminal")
        app.typeText("echo after done\n")
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "\nafter done\n"), timeout: 10))
        XCTAssertTrue((output.value as? String ?? "").contains("Paste code here"), "Done returns to the same shell, still showing the link")
    }

    private func warmActionWhileSettingsIsPresented(multiple: Bool) {
        var flags = ["--companion-preview"]
        if multiple { flags += ["--companion-preview-dispatcher", "--companion-preview-multiple-dispatchers", "--companion-preview-named-dispatchers"] }
        let app = launchApp(flags, attempts: 1)
        let river = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollTo(river, in: app, maxSwipes: 6))
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(river, shows: settings, attempts: 1)
        settings.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "agent-settings-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "The original sheet actually dismisses")
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 10))
        if multiple {
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-laptop"].isHittable)
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-studio"].isHittable)
        } else { XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "dispatcher-launch-unavailable").firstMatch.exists) }
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
