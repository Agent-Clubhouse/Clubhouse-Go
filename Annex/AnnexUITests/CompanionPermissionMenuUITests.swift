import XCTest

/// Native menu geometry and VoiceOver content, using the socket-free conversation fixture.
@MainActor final class CompanionPermissionMenuUITests: ReliableUITestCase {
    private let levels: [(id: String, fullLabel: String)] = [
        ("plan", "Plan, Reads and plans, changes nothing · plan"),
        ("ask", "Ask first, Asks before edits and commands · default"),
        ("auto_edit", "Auto-accept edits, Edits files, asks before commands · acceptEdits"),
        ("auto", "Auto, Decides what needs approval · auto"),
        ("full_access", "Full access, No prompts · bypassPermissions"),
    ]

    private func openMenu(_ flags: [String] = [], landscape: Bool = false) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-header-no-leading"] + flags, attempts: 1)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        XCTAssertTrue(waitFor(app.windows.firstMatch, NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }, timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Permission menu draft")
        let controls = app.buttons["companion-level-menu"]
        assertMinimumTarget(controls, "Chat controls")
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"], attempts: 1)
        waitAndTap(app.buttons["companion-permissions-menu"], until: app.buttons["companion-level-plan"], attempts: 1)
        return app
    }

    /// UIKit exposes the menu's collection at its full content height. Its containing native pane clips it.
    /// Find that ancestor, excluding the larger shadow container, rather than treating offscreen cells as visible.
    private func visiblePane(_ app: XCUIApplication) -> CGRect {
        let menu = app.collectionViews.firstMatch
        XCTAssertTrue(menu.exists)
        let content = menu.frame
        let ancestors = app.otherElements.containing(.collectionView, identifier: menu.identifier).allElementsBoundByIndex
        var panes: [CGRect] = []
        for ancestor in ancestors {
            let frame: CGRect = ancestor.frame
            let matchesOrigin = abs(frame.minX - content.minX) < 1 && abs(frame.minY - content.minY) < 1
            let matchesWidth = abs(frame.width - content.width) < 1
            let clipsContent = frame.height > 44 && frame.height < content.height
            if matchesOrigin && matchesWidth && clipsContent { panes.append(frame) }
        }
        guard let pane = panes.min(by: { $0.height < $1.height }) else {
            XCTFail("The native menu must expose a clipping pane: \(app.debugDescription)")
            return .zero
        }
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists, "Menu reachability is checked while editing")
        var visible = pane.intersection(CGRect(x: app.frame.minX, y: app.frame.minY,
                                              width: app.frame.width, height: keyboard.frame.minY - app.frame.minY))
        // Native submenu headers can remain above scrolled cells. A row behind one isn't readable.
        let back = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Auto-accept edits", "")).firstMatch
        let section = app.staticTexts["Permissions"]
        for header in [back, section] where header.exists && header.frame.intersects(visible) {
            let top = min(visible.maxY, max(visible.minY, header.frame.maxY))
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
        }
        return visible
    }

    private func assertFullText(_ row: XCUIElement, expected: String) {
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.label, expected, "VoiceOver keeps the complete meaning and driver name")
    }

    private func capture(_ app: XCUIApplication, _ state: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Permission menu \(state)"; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Permission menu hierarchy \(state)"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func confirmFullAccess(_ app: XCUIApplication) {
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertEqual(composer.value as? String, "Permission menu draft")
        let confirmation = app.buttons["Switch to Full access"]
        waitAndTap(app.buttons["companion-level-full_access"], until: confirmation, attempts: 1)
        XCTAssertTrue(confirmation.isHittable)
        confirmation.tap()
        let receipt = app.staticTexts["Preview only. This action does not contact a desktop."]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5), "The confirmed choice reaches the unchanged permission action")
        XCTAssertEqual(composer.value as? String, "Permission menu draft")
    }

    func testPortraitEveryLevelFitsWithoutScrollingAcrossThemes() {
        for (name, flags) in [
            ("Light", ["--companion-header-light"]),
            ("Dark", []),
            ("Catppuccin Latte", ["--companion-header-latte", "--companion-header-light"]),
            ("Catppuccin Mocha", ["--companion-header-mocha"]),
        ] {
            let app = openMenu(flags)
            let full = app.buttons["companion-level-full_access"]
            XCTAssertTrue(waitFor(full, NSPredicate(format: "hittable == true"), timeout: 5))
            let pane = visiblePane(app)
            for level in levels {
                let row = app.buttons["companion-level-\(level.id)"]
                assertFullText(row, expected: level.fullLabel)
                XCTAssertTrue(row.isHittable)
                XCTAssertTrue(pixelContains(pane, row.frame), "\(name) \(level.id) \(row.frame) must fit wholly in \(pane), without scrolling")
                print("PERMISSION_GEOMETRY state=portrait-\(name) level=\(level.id) pane=\(pane) row=\(row.frame)")
            }
            capture(app, "portrait \(name)")
            confirmFullAccess(app)
            app.terminate()
        }
    }

    /// Swipes stay inside the clipped native pane; the collection's oversized frame extends over the keyboard.
    private func reveal(_ row: XCUIElement, in app: XCUIApplication, accessibility: Bool) {
        for step in 0...8 {
            checkTimeLeft("revealing a permission level")
            let pane = visiblePane(app)
            if row.exists {
                let frame = row.frame
                let fits = pixelContains(pane, frame)
                let oversized = accessibility && frame.height > pane.height
                    && frame.intersection(pane).height >= 44
                if row.isHittable && (fits || oversized) {
                    print("PERMISSION_GEOMETRY state=\(accessibility ? "XXXL" : "landscape") level=\(row.identifier) pane=\(pane) row=\(frame) scrolls=\(step) oversized=\(oversized)")
                    return
                }
            }
            guard step < 8 else { break }
            let downward = row.exists && row.frame.minY < pane.minY
            let startY = downward ? pane.minY + pane.height * 0.3 : pane.maxY - pane.height * 0.2
            let endY = downward ? pane.maxY - pane.height * 0.2 : pane.minY + pane.height * 0.3
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: pane.midX, dy: startY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: pane.midX, dy: endY)))
        }
        XCTFail("Every permission level must be readable and reachable by native menu scrolling: \(row)")
    }

    func testLandscapeEveryLevelIsReachableAndFullAccessStillConfirms() {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = openMenu(landscape: true)
        for level in levels {
            let row = app.buttons["companion-level-\(level.id)"]
            reveal(row, in: app, accessibility: false)
            assertFullText(row, expected: level.fullLabel)
            if level.id == "plan" || level.id == "full_access" { capture(app, "landscape \(level.id)") }
        }
        confirmFullAccess(app)
    }

    func testLargestTextEveryLevelKeepsFullVoiceOverTextAndRemainsReachable() {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        for landscape in [false, true] {
            let app = openMenu(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], landscape: landscape)
            for level in levels {
                let row = app.buttons["companion-level-\(level.id)"]
                reveal(row, in: app, accessibility: true)
                assertFullText(row, expected: level.fullLabel)
                if level.id == "plan" || level.id == "full_access" {
                    capture(app, "XXXL \(landscape ? "landscape" : "portrait") \(level.id)")
                }
            }
            confirmFullAccess(app)
            app.terminate()
        }
    }
}
