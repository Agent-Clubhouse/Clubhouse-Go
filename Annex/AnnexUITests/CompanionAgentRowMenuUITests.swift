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
            assertItems(["Wake & Resume", "Start New Session", "Agent details", "Agent settings", "Terminal"], in: app, allowScroll: accessibility)
            capture(app, "Sleeping native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
            reveal(details, in: app, allowScroll: accessibility)
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
            assertItems(["Agent details", "Agent settings", "Terminal"], in: app, allowScroll: accessibility)
            XCTAssertFalse(app.buttons["Wake & Resume"].exists, "A running agent must not offer a stale Wake")
            XCTAssertFalse(app.buttons["Start New Session"].exists)
            capture(app, "Running native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
            reveal(details, in: app, allowScroll: accessibility)
            details.tap()
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["Cedar"].exists, "The action keeps the real running agent target")
            app.buttons["Done"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    private func assertItems(_ labels: [String], in app: XCUIApplication, allowScroll: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        capture(app, "Native menu before validation")
        let menu = app.collectionViews.containing(.button, identifier: "Agent details").firstMatch
        XCTAssertTrue(menu.exists, "The native menu has its own collection", file: file, line: line)
        // Native accessibility order is stable while on-screen positions change with scrolling.
        XCTAssertEqual(menu.buttons.allElementsBoundByIndex.map(\.label), labels,
                       "Every full menu label appears once in its original order", file: file, line: line)
        for label in labels {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "The native menu has one \(label)", file: file, line: line)
            let item = matches.firstMatch
            reveal(item, in: app, allowScroll: allowScroll, file: file, line: line)
            XCTAssertTrue(item.exists && item.isHittable && item.isEnabled, label, file: file, line: line)
            let frame = item.frame
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite && frame.width > 0 && frame.height > 0, label, file: file, line: line)
            XCTAssertTrue(app.frame.contains(frame), "Native item remains on screen at this text size: \(label)", file: file, line: line)
            XCTAssertTrue(menuViewport(in: app).contains(frame), "Full item is inside the menu's actual clip: \(label)", file: file, line: line)
        }
    }

    private func menuViewport(in app: XCUIApplication) -> CGRect {
        let menu = app.collectionViews.containing(.button, identifier: "Agent details").firstMatch
        // UIKit's native collection reports a full-screen height even when its enclosing
        // panel clips it. Use the smallest public AX ancestor containing the menu buttons.
        return app.otherElements.containing(.button, identifier: "Agent details").allElementsBoundByIndex
            .map { $0.frame.intersection(menu.frame).intersection(app.frame) }
            .filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
            .min { $0.width * $0.height < $1.width * $1.height } ?? .null
    }

    private func reveal(_ item: XCUIElement, in app: XCUIApplication, allowScroll: Bool,
                        file: StaticString = #filePath, line: UInt = #line) {
        for step in 0...8 {
            let viewport = menuViewport(in: app)
            let frame = item.frame
            let geometry = "step=\(step) label=\(item.label) item=\(frame) viewport=\(viewport) hittable=\(item.isHittable) enabled=\(item.isEnabled)"
            let record = XCTAttachment(string: geometry); record.name = "Native menu reveal geometry"; record.lifetime = .keepAlways
            add(record)
            capture(app, "Native menu reveal \(step) — \(item.label)")
            XCTAssertFalse(viewport.isNull, "A public native menu clip is required", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.height, viewport.height, "This item must fit without truncating its full label", file: file, line: line)
            if viewport.contains(frame) { return }
            XCTAssertTrue(allowScroll, "Standard-size native menus must need zero drags: " + geometry, file: file, line: line)
            guard allowScroll, step < 8 else { break }
            let upwards = frame.maxY > viewport.maxY
            let overflow = upwards ? frame.maxY - viewport.maxY : viewport.minY - frame.minY
            let distance = min(overflow + viewport.height * 0.08, viewport.height * 0.4)
            let startY = viewport.minY + viewport.height * (upwards ? 0.85 : 0.15)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = start.withOffset(CGVector(dx: 0, dy: upwards ? -distance : distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("Native menu did not fully reveal \(item.label) within eight slow drags", file: file, line: line)
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
