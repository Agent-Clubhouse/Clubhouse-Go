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

    /// The installed icon sits on one Home page; the page SpringBoard returns to varies. Hosted trees (run 44738003005)
    /// show it on "Page 2 of 2" while the first check ran mid Home transition: a blind swipe left from the last page
    /// opens App Library, and `isHittable` on a still-animating icon frame raised "Activation point invalid".
    /// Accept an icon only after two observations of one fully on-screen frame, and move between Home pages by the
    /// page control's own value, never past the last page.
    /// The monotonic deadline admits observations and successful returns; a synchronous AX request cannot be
    /// interrupted by this loop. Snapshot failures propagate instead of being mistaken for an absent icon.
    private struct HomeIcon {
        let element: XCUIElement
        let frame: CGRect
    }

    private func settledHomeIcon(_ springboard: XCUIApplication, timeout: TimeInterval = 10) throws -> HomeIcon? {
        let icons = springboard.icons.matching(identifier: "Clubhouse Go")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var previous: CGRect?
        while clock.now < deadline {
            let root: XCUIElementSnapshot
            do {
                root = try springboard.snapshot()
            } catch {
                print("SPRINGBOARD_ICON disposition=snapshot-failure deadlineExceeded=\(clock.now >= deadline) error=\(error)")
                throw error
            }
            guard clock.now < deadline else {
                print("SPRINGBOARD_ICON disposition=observation-finished-after-admission-deadline")
                return nil
            }
            let screen = root.frame
            guard screen.width > 0, screen.height > 0,
                  [screen.minX, screen.minY, screen.maxX, screen.maxY].allSatisfy({ $0.isFinite }) else {
                throw NSError(domain: "SpringBoardIconObservation", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "SpringBoard returned an invalid screen frame"])
            }
            var matches: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.elementType == .icon, node.identifier == "Clubhouse Go" || node.label == "Clubhouse Go" {
                    let frame = node.frame
                    if frame.width > 0, frame.height > 0,
                       [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite }),
                       screen.contains(frame) {
                        matches.append(frame)
                    }
                }
                node.children.forEach(walk)
            }
            walk(root)
            guard matches.count <= 1 else {
                throw NSError(domain: "SpringBoardIconObservation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Multiple visible Clubhouse Go icons"])
            }
            guard clock.now < deadline else { return nil }
            let current = matches.first
            if let current, current == previous {
                let candidates = icons.allElementsBoundByIndex
                guard clock.now < deadline else { return nil }
                let icon = try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                                         "A single live Clubhouse Go icon must own the stable snapshot frame")
                let liveFrame = icon.frame
                guard clock.now < deadline else { return nil }
                guard liveFrame == current else {
                    throw NSError(domain: "SpringBoardIconObservation", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The live icon frame \(liveFrame) does not match the stable snapshot \(current)"])
                }
                print("SPRINGBOARD_ICON disposition=stable-live-bound frame=\(current)")
                guard clock.now < deadline else { return nil }
                return HomeIcon(element: icon, frame: current)
            }
            previous = current
            let remaining = clock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(min(0.5, seconds)))
        }
        print("SPRINGBOARD_ICON disposition=absent-or-unsettled-at-admission-deadline")
        return nil
    }

    private func homePage(_ control: XCUIElement) -> (current: Int, count: Int)? {
        let words = (control.value as? String ?? "").split(separator: " ")
        guard words.count == 4, words[0] == "Page", words[2] == "of", let current = Int(words[1]), let count = Int(words[3]),
              (1...count).contains(current) else { return nil }
        return (current, count)
    }

    private func nativeAction() throws {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let pages = springboard.pageIndicators.matching(identifier: "Page control").firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "Home returns to an icon page")
        var icon = try settledHomeIcon(springboard)
        var visited = Set<Int>()
        while icon == nil, let page = homePage(pages) {
            visited.insert(page.current)
            guard visited.count < page.count else { break }
            // Later unvisited pages first, then earlier ones. Never swipe left from the last page: that is App Library.
            let forward = stride(from: page.current + 1, through: page.count, by: 1).contains { !visited.contains($0) }
            let before = pages.value as? String ?? ""
            if forward { springboard.swipeLeft() } else { springboard.swipeRight() }
            guard waitFor(pages, NSPredicate(format: "value != %@", before), timeout: 5) else {
                XCTFail("A Home swipe must change page from \(before)"); break
            }
            if let landed = homePage(pages), !visited.contains(landed.current) { icon = try settledHomeIcon(springboard) }
        }
        let tree = XCTAttachment(data: Data(springboard.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        tree.name = "SpringBoard before native quick action"; tree.lifetime = .keepAlways; add(tree)
        guard let icon else {
            XCTFail("No settled, on-screen Clubhouse Go icon on any Home page (\(pages.value as? String ?? "no page control")); native delivery unverified")
            return
        }
        guard waitFor(icon.element, NSPredicate(format: "hittable == true"), timeout: 5) else {
            XCTFail("The settled Home icon must be hittable before its native press")
            return
        }
        let candidates = springboard.icons.matching(identifier: "Clubhouse Go").allElementsBoundByIndex
        let current = try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                                   "The quick action still belongs to one live Clubhouse Go icon")
        let frame = current.frame
        guard frame == icon.frame, springboard.frame.contains(frame), current.isHittable else {
            XCTFail("The unique live icon must retain its settled on-screen frame before the native press")
            return
        }
        current.press(forDuration: 1)
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
        try nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let restoreError = app.alerts["Could not restore desktops"]
        let guidanceTitle = app.navigationBars["Message Dispatcher"]
        // Restoration finishes asynchronously after first paint (run 44738003005: foreground at 149.5s, first frame
        // ~153s, alert ~155s, after a fixed 3s alert check had ended). Guidance waits for the error to be acknowledged,
        // and success raises no alert, so wait for whichever terminal state the runtime actually publishes.
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in restoreError.exists || guidanceTitle.exists }, timeout: 20),
                      "Cold restore ends in its error alert or Dispatcher guidance")
        let unexpectedRestoreFailure = restoreError.exists
        if unexpectedRestoreFailure {
            screenshot(app, "native-cold-unexpected-restore-error")
            restoreError.buttons["OK"].tap()
            XCTAssertTrue(restoreError.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(guidanceTitle.waitForExistence(timeout: 20))
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

    func testColdSingleDispatcherFocusesWithoutSendingAndWarmNativeActionKeepsDraft() throws {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", cold], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Cold handoff focuses the composer")
        XCTAssertTrue(composer.exists)
        app.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        try nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Keep this draft", "Opening never sends or replaces the existing draft")
        screenshot(app, "native-warm-action-draft-preserved")
    }

    private func warmActionWhileSettingsIsPresented(multiple: Bool) throws {
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
        try nativeAction()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "The original sheet actually dismisses")
        XCTAssertTrue(app.navigationBars["Message Dispatcher"].waitForExistence(timeout: 10))
        if multiple {
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-laptop"].isHittable)
            XCTAssertTrue(app.buttons["dispatcher-launch-choose-preview-studio"].isHittable)
        } else { XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "dispatcher-launch-unavailable").firstMatch.exists) }
        screenshot(app, multiple ? "warm-settings-to-chooser" : "warm-settings-to-guidance")
    }
    func testWarmManyDispatcherActionDismissesExistingSettingsBeforeChoosing() throws { try warmActionWhileSettingsIsPresented(multiple: true) }
    func testWarmZeroDispatcherActionDismissesExistingSettingsBeforeGuidance() throws { try warmActionWhileSettingsIsPresented(multiple: false) }

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
