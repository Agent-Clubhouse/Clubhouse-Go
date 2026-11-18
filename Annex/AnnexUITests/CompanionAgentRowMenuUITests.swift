import XCTest

/// Native system-menu proof is deliberately live Home only. Frozen Home is behind a
/// pushed route. Hosted OCR proves its actual content; the unchanged callback tests
/// prove live guards. Hosted native button activation and telemetry are not claimed.
@MainActor final class CompanionAgentRowMenuUITests: ReliableUITestCase {
    func testNativeHomeAgentMenuAtDefaultTypeAcrossThemes() {
        checkNativeMenu(accessibility: false)
    }

    func testNativeHomeAgentMenuAtAccessibilityXXXLAcrossThemes() {
        checkNativeMenu(accessibility: true)
    }

    private func checkNativeMenu(accessibility: Bool) {
        for scheme in ["light", "dark"] {
            let flags = ["--companion-preview", "--companion-preview-" + scheme]
                + (accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            let app = launchApp(flags, attempts: 1)
            let home = app.navigationBars["Clubhouse"]
            XCTAssertTrue(home.waitForExistence(timeout: 15))
            let quiet = element(app, "fold-quiet-preview-studio-clubhouse")
            let sleeping = element(app, "agent-preview-studio-juniper")
            XCTAssertTrue(scrollUntilExists(quiet, in: app) && scrollTo(quiet, in: app))
            expandFold(quiet, revealing: sleeping, in: app)
            XCTAssertTrue(scrollTo(sleeping, in: app) && sleeping.isHittable)
            let details = app.buttons["Agent details"]
            longPressUntilMenu(sleeping, shows: details, attempts: 1, "A single native long-press must present this Home row's menu")
            assertItems(["Wake & Resume", "Start New Session", "Agent details", "Agent settings", "Terminal"], in: app)
            capture(app, "Sleeping native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
            details.tap()
            let sheet = element(app, "agent-details-sheet")
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The native item invokes Root's inherited Details action")
            XCTAssertTrue(app.navigationBars["Juniper"].exists, "Details belongs to the long-pressed sleeping agent")
            app.buttons["Done"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            XCTAssertTrue(home.exists)
            let running = element(app, "agent-preview-studio-cedar")
            XCTAssertTrue(scrollUntilExists(running, in: app, up: false) && scrollTo(running, in: app, up: false))
            longPressUntilMenu(running, shows: details, attempts: 1, "The active agent retains its native menu")
            assertItems(["Agent details", "Agent settings", "Terminal"], in: app)
            XCTAssertFalse(app.buttons["Wake & Resume"].exists, "A running agent must not offer a stale Wake")
            XCTAssertFalse(app.buttons["Start New Session"].exists)
            capture(app, "Running native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
            details.tap()
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["Cedar"].exists, "The action keeps the real running agent target")
            app.buttons["Done"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    private func assertItems(_ labels: [String], in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        var previous: CGFloat?
        for label in labels {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "The native menu has one \(label)", file: file, line: line)
            let item = matches.firstMatch
            XCTAssertTrue(item.exists && item.isHittable && item.isEnabled, label, file: file, line: line)
            let frame = item.frame
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite && frame.width > 0 && frame.height > 0, label, file: file, line: line)
            XCTAssertTrue(app.frame.contains(frame), "Native item remains on screen at this text size: \(label)", file: file, line: line)
            if let previous { XCTAssertGreaterThan(frame.minY, previous, "Native item order is preserved", file: file, line: line) }
            previous = frame.minY
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let pixels = XCTAttachment(screenshot: app.screenshot()); pixels.name = name; pixels.lifetime = .keepAlways
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " native AX"; tree.lifetime = .keepAlways
        add(pixels); add(tree)
    }
}
