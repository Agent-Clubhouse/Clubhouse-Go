import XCTest

/// Native menu geometry and VoiceOver content, using the socket-free conversation fixture.
@MainActor final class CompanionPermissionMenuUITests: ReliableUITestCase {
    private var expectedBackTitle = "Auto-accept edits"
    private let levels: [(id: String, fullLabel: String)] = [
        ("plan", "Plan, Reads and plans, changes nothing · plan"),
        ("ask", "Ask first, Asks before edits and commands · default"),
        ("auto_edit", "Auto-accept edits, Edits files, asks before commands · acceptEdits"),
        ("auto", "Auto, Decides what needs approval · auto"),
        ("full_access", "Full access, No prompts · bypassPermissions"),
    ]

    private func openMenu(_ flags: [String] = [], landscape: Bool = false) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture"] + flags, attempts: 1)
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        XCTAssertTrue(waitFor(app.windows.firstMatch, NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }, timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        composer.tap()
        // An offscreen keyboard can remain in the AX tree after rotation or relaunch.
        // Require the software keyboard to occupy the screen before measuring above it.
        if !waitFor(app, NSPredicate { _, _ in self.visibleKeyboardFrame(app) != nil }, timeout: 2),
           app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.tap()
        }
        XCTAssertTrue(waitFor(app, NSPredicate { _, _ in self.visibleKeyboardFrame(app) != nil }, timeout: 5),
                      "A software keyboard must visibly occupy the screen, not merely exist in AX")
        composer.typeText("Permission menu draft")
        assertTypedValue(composer, equals: "Permission menu draft")
        XCTAssertNotNil(visibleKeyboardFrame(app), "The draft starts with a visibly onscreen keyboard")
        print("PERMISSION_KEYBOARD before-menu=\(String(describing: visibleKeyboardFrame(app)))")
        let controls = app.buttons["companion-level-menu"]
        assertMinimumTarget(controls, "Chat controls")
        XCTAssertTrue(controls.label.contains("Auto-accept edits") && controls.label.contains("Opus"),
                      "The circle names the current access and model for VoiceOver and Voice Control: \(controls.label)")
        XCTAssertTrue(controls.label.contains("Permissions: Auto-accept edits"),
                      "The circle retains the current permission level when the short menu entry shows only its context")
        let appearance = flags.contains("--companion-header-latte") ? "Latte"
            : flags.contains("--companion-header-mocha") ? "Mocha"
            : flags.contains("--companion-header-light") ? "Light" : "Dark"
        capture(app, "composer \(landscape ? "landscape" : "portrait") \(appearance) \(flags.contains("UICTContentSizeCategoryAccessibilityXXXL") ? "XXXL" : "standard")")
        waitAndTap(controls, until: app.buttons["companion-permissions-menu"], attempts: 1)
        let permissions = app.buttons["companion-permissions-menu"]
        let entryTitle = permissions.label
        let entryHasShield = permissions.images.matching(identifier: "shield").firstMatch.exists
        let context = ([permissions.label, permissions.value as? String ?? ""]
                       + permissions.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " · ")
        print("PERMISSION_MENU_CONTEXT \(context)")
        capture(app, "native permissions entry \(appearance)")
        waitAndTap(permissions, until: app.buttons["companion-level-plan"], attempts: 1)
        capture(app, "expanded permissions \(appearance)")
        let menu = app.collectionViews.firstMatch
        let backButtons = menu.buttons.matching(NSPredicate(format: "identifier == %@", "")).allElementsBoundByIndex
        let firstRows = menu.buttons.matching(identifier: "companion-level-plan").allElementsBoundByIndex
        let sections = menu.staticTexts.matching(NSPredicate(format: "label == %@", "Permissions")).allElementsBoundByIndex
        XCTAssertEqual(backButtons.count, 1, "The loaded native submenu has exactly one back control")
        XCTAssertEqual(firstRows.count, 1, "The loaded native submenu has exactly one first permission action")
        guard backButtons.count == 1, firstRows.count == 1,
              let title = expectedPermissionTitle(sectionFrames: sections.map(\.frame),
                  back: backButtons[0].frame, firstRow: firstRows[0].frame, pane: nativePane(app)) else {
            XCTFail("The native submenu's loaded top must distinguish an absent section from an ambiguous or clipped one: \(app.debugDescription)")
            return app
        }
        assertFullText(firstRows[0], expected: levels[0].fullLabel)
        XCTAssertTrue(firstRows[0].isHittable)
        expectedBackTitle = title
        XCTAssertEqual(entryTitle, title, "The captured entry and presented permission section must agree")
        XCTAssertEqual(backButtons[0].label, title, "The native back title must match the independently classified section")
        print("PERMISSION_MENU_LAYOUT sectionCount=\(sections.count) expectedBackTitle=\(title) keyboard=\(String(describing: visibleKeyboardFrame(app)))")
        if title == "Permissions" {
            XCTAssertEqual(entryTitle, "Permissions", "The section-free compact menu names the permission context")
            // Native title-only layout trades the entry's current-level subtitle
            // for room. The circle above names it; the checked row below shows it.
        } else {
            // Roomy native menus keep their original current-level title and shield;
            // their expanded Permissions heading supplies the section context.
            XCTAssertEqual(entryTitle, "Auto-accept edits")
            // UIKit omits all decorative native menu images at AX XXXL.
            if !flags.contains("UICTContentSizeCategoryAccessibilityXXXL") {
                XCTAssertTrue(entryHasShield)
            }
        }
        let initialBack = backHeader(app)
        XCTAssertTrue(initialBack.exists, "The native back header matches the independently expected layout")
        XCTAssertLessThanOrEqual(initialBack.frame.maxY, app.buttons["companion-level-plan"].frame.minY + 1,
                                 "Before scrolling, the matched header is above the first level, not another button")
        XCTAssertEqual(composer.value as? String, "Permission menu draft", "Opening a native menu preserves the draft")
        if visibleKeyboardFrame(app) == nil {
            XCTAssertTrue(app.keyboards.allElementsBoundByIndex.allSatisfy { keyboard in
                let visible = keyboard.frame.intersection(app.frame)
                return visible.isNull || visible.height < 1 || visible.width < 1
            }, "Native dismissal must leave the keyboard wholly offscreen")
            print("PERMISSION_KEYBOARD during-menu=native-dismissed landscape=\(landscape) flags=\(flags)")
        } else {
            print("PERMISSION_KEYBOARD during-menu=\(String(describing: visibleKeyboardFrame(app)))")
        }
        return app
    }

    private func visibleKeyboardFrame(_ app: XCUIApplication) -> CGRect? {
        app.keyboards.allElementsBoundByIndex.map(\.frame).first { frame in
            let visible = frame.intersection(app.frame)
            return !visible.isNull && visible.height >= 100 && visible.width >= app.frame.width / 2
        }
    }

    // Classify the loaded section, never a keyboard notification or either title.
    // A missing heading only proves compact layout when no heading-sized gap is hidden above the first row.
    private func expectedPermissionTitle(sectionFrames: [CGRect], back: CGRect, firstRow: CGRect, pane: CGRect) -> String? {
        guard ([pane, back, firstRow] + sectionFrames).allSatisfy({ frame in
            frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }), pixelContains(pane, back), firstRow.minY >= back.maxY - 1,
            firstRow.intersection(pane).width >= firstRow.width - 1,
            firstRow.intersection(pane).height >= min(firstRow.height, 42) else { return nil }
        if sectionFrames.count == 1 {
            let section = sectionFrames[0]
            guard pixelContains(pane, section), section.minY >= back.maxY - 1,
                  section.maxY <= firstRow.minY + 1 else { return nil }
            return "Auto-accept edits"
        }
        guard sectionFrames.isEmpty, firstRow.minY - back.maxY <= 20 else { return nil }
        return "Permissions"
    }

    func testNativePermissionContextRejectsUnloadedClippedAndCrossedLayouts() {
        let pane = CGRect(x: 0, y: 0, width: 250, height: 400)
        let back = CGRect(x: 0, y: 10, width: 250, height: 42)
        let compactRow = CGRect(x: 0, y: 62, width: 250, height: 42)
        let roomyRow = CGRect(x: 0, y: 103, width: 250, height: 58)
        let section = CGRect(x: 28, y: 76, width: 194, height: 16)
        let compactTitle = expectedPermissionTitle(sectionFrames: [], back: back, firstRow: compactRow, pane: pane)
        let roomyTitle = expectedPermissionTitle(sectionFrames: [section], back: back, firstRow: roomyRow, pane: pane)
        XCTAssertEqual(compactTitle, "Permissions")
        XCTAssertEqual(roomyTitle, "Auto-accept edits")
        XCTAssertNotEqual(compactTitle, "Auto-accept edits", "The original hosted compact capture rejects the roomy title")
        XCTAssertNotEqual(roomyTitle, "Permissions", "The observed roomy capture rejects the prospective compact title")
        XCTAssertNil(expectedPermissionTitle(sectionFrames: [], back: back, firstRow: .zero, pane: pane))
        XCTAssertNil(expectedPermissionTitle(sectionFrames: [], back: .zero, firstRow: compactRow, pane: pane))
        XCTAssertNil(expectedPermissionTitle(sectionFrames: [], back: back, firstRow: roomyRow, pane: pane),
                     "An unloaded section with its space still present is not compact")
        XCTAssertNil(expectedPermissionTitle(sectionFrames: [section, section], back: back, firstRow: roomyRow, pane: pane))
        XCTAssertNil(expectedPermissionTitle(sectionFrames: [section.offsetBy(dx: -40, dy: 0)],
                                             back: back, firstRow: roomyRow, pane: pane),
                     "A clipped section is not an absent section")

        let scrollingPane = CGRect(x: 22, y: 304, width: 370, height: 508)
        for initialRow in [
            CGRect(x: 22, y: 293.6666666667, width: 370, height: 277.3333333333),
            CGRect(x: 22, y: 545, width: 370, height: 277.3333333333),
            CGRect(x: 22, y: 1004, width: 370, height: 277.3333333333),
            CGRect(x: 22, y: 303, width: 370, height: 500),
            CGRect(x: 22, y: 313, width: 370, height: 500),
            CGRect(x: 22, y: 303, width: 370, height: 508),
            CGRect(x: 22, y: 305, width: 370, height: 508),
        ] {
            var row = initialRow
            for _ in 0..<8 {
                if pixelContains(scrollingPane, row) { break }
                guard let distance = permissionScrollDistance(row: row, pane: scrollingPane) else {
                    XCTFail("Loaded permission rows need a safe navigation displacement")
                    break
                }
                row = row.offsetBy(dx: 0, dy: -distance)
            }
            XCTAssertTrue(pixelContains(scrollingPane, row),
                          "Clipped rows must converge rather than oscillate across opposite pane edges")
        }
        XCTAssertNil(permissionScrollDistance(row: .zero, pane: scrollingPane))
        XCTAssertNil(permissionScrollDistance(row: compactRow, pane: .zero))
        XCTAssertNil(permissionScrollDistance(row: CGRect(x: 0, y: 900, width: 370, height: 100),
                                               pane: scrollingPane),
                     "Vertical pans cannot repair horizontally clipped rows")
    }

    /// UIKit exposes the menu's collection at its full content height. Its containing native pane clips it.
    /// Find that ancestor, excluding the larger shadow container, rather than treating offscreen cells as visible.
    private func nativePane(_ app: XCUIApplication, requiresKeyboard: Bool = false) -> CGRect {
        let menu = app.collectionViews.firstMatch
        XCTAssertTrue(menu.exists)
        let content = menu.frame
        // Native collections have no AX identifier; an empty identifier is not an absent filter.
        let ancestors = app.otherElements.containing(.collectionView, identifier: nil).allElementsBoundByIndex
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
        let keyboard = visibleKeyboardFrame(app)
        if requiresKeyboard && keyboard == nil {
            capture(app, "missing portrait keyboard")
            XCTFail("Standard portrait containment requires a visible software keyboard: \(app.debugDescription)")
        }
        // Native menus can dismiss the keyboard in landscape and at accessibility sizes.
        // Measure the real screen pane rather than an offscreen Keyboard left in AX.
        return pane.intersection(CGRect(x: app.frame.minX, y: app.frame.minY,
                                       width: app.frame.width, height: (keyboard?.minY ?? app.frame.maxY) - app.frame.minY))
    }

    private func visiblePane(_ app: XCUIApplication, requiresKeyboard: Bool = false) -> CGRect {
        var visible = nativePane(app, requiresKeyboard: requiresKeyboard)
        // Native submenu headers can remain above scrolled cells. A row behind one isn't readable.
        // Require the independently expected title, rather than accepting either.
        // Its sticky back button must exclude exactly the same covered area.
        let back = backHeader(app)
        let section = app.staticTexts["Permissions"]
        for header in [back, section] where header.exists && header.frame.intersects(visible) {
            let top = min(visible.maxY, max(visible.minY, header.frame.maxY))
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
        }
        return visible
    }

    private func backHeader(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", expectedBackTitle, "")).firstMatch
    }

    private func assertFullText(_ row: XCUIElement, expected: String) {
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.label, expected, "VoiceOver keeps the complete meaning and driver name")
    }

    private func assertSelectedLevel(_ app: XCUIApplication, in pane: CGRect) {
        let selected = app.buttons["companion-level-auto_edit"]
        assertFullText(selected, expected: levels[2].fullLabel)
        XCTAssertTrue(selected.isSelected && selected.images["checkmark"].exists,
                      "The current level retains its selected checkmark row")
        XCTAssertTrue(selected.isHittable && pixelContains(pane, selected.frame),
                      "The whole selected level stays visible inside the native pane")
    }

    private func capture(_ app: XCUIApplication, _ state: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
            let pane = visiblePane(app, requiresKeyboard: true)
            assertSelectedLevel(app, in: pane)
            for level in levels {
                let row = app.buttons["companion-level-\(level.id)"]
                assertFullText(row, expected: level.fullLabel)
                XCTAssertTrue(row.isHittable)
                XCTAssertTrue(pixelContains(pane, row.frame), "\(name) \(level.id) \(row.frame) must fit wholly in \(pane), without scrolling")
                print("PERMISSION_GEOMETRY state=portrait-\(name) level=\(level.id) pane=\(pane) row=\(row.frame)")
            }
            if app.frame.height < 800 { XCTAssertGreaterThanOrEqual(pane.maxY - full.frame.maxY, 8, "Default SE retains a real bottom margin") }
            capture(app, "portrait \(name)")
            confirmFullAccess(app)
            app.terminate()
        }
    }

    func testXLargePortraitEveryLevelFitsWithoutScrollingAcrossThemes() {
        for (name, theme) in [
            ("Light", ["--companion-header-light"]),
            ("Dark", []),
            ("Catppuccin Latte", ["--companion-header-latte", "--companion-header-light"]),
            ("Catppuccin Mocha", ["--companion-header-mocha"]),
        ] {
            let app = openMenu(theme + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"])
            let full = app.buttons["companion-level-full_access"]
            XCTAssertTrue(waitFor(full, NSPredicate(format: "hittable == true"), timeout: 5))
            let pane = visiblePane(app, requiresKeyboard: true)
            assertSelectedLevel(app, in: pane)
            for level in levels {
                let row = app.buttons["companion-level-\(level.id)"]
                assertFullText(row, expected: level.fullLabel)
                XCTAssertTrue(row.isHittable)
                XCTAssertTrue(pixelContains(pane, row.frame), "XLarge \(name) \(level.id) \(row.frame) must fit wholly in \(pane), without scrolling")
                print("PERMISSION_GEOMETRY state=XLarge-\(name) level=\(level.id) pane=\(pane) row=\(row.frame)")
            }
            if app.frame.height < 800 { XCTAssertGreaterThanOrEqual(pane.maxY - full.frame.maxY, 8, "XLarge SE retains a real bottom margin") }
            capture(app, "XLarge portrait \(name)")
            confirmFullAccess(app)
            app.terminate()
        }
    }

    func testFullAccessConfirmationExplainsUnpromptedEditsAndCommands() {
        let app = openMenu(["--companion-header-light"])
        let agentName = app.buttons["companion-chat-header"].label.components(separatedBy: ",")[0]
        XCTAssertFalse(agentName.isEmpty)
        let confirmation = app.buttons["Switch to Full access"]
        waitAndTap(app.buttons["companion-level-full_access"], until: confirmation, attempts: 1)
        XCTAssertTrue(app.staticTexts["\(agentName) will edit files and run commands without asking you first."].exists,
                      "The confirmation retains the safety meaning omitted from compact visual subtitles")
        XCTAssertTrue(confirmation.isHittable)
        capture(app, "Full access consequence confirmation")
        confirmation.tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertEqual(composer.value as? String, "Permission menu draft")
    }

    func testAutoConfirmationExplainsApprovalChoice() {
        let app = openMenu(["--companion-header-light"])
        let agentName = app.buttons["companion-chat-header"].label.components(separatedBy: ",")[0]
        XCTAssertFalse(agentName.isEmpty)
        let confirmation = app.buttons["Switch to Auto"]
        waitAndTap(app.buttons["companion-level-auto"], until: confirmation, attempts: 1)
        XCTAssertTrue(app.staticTexts["\(agentName) will decide for itself what needs your approval."].exists,
                      "Auto retains its approval consequence when compact visual subtitles are omitted")
        XCTAssertTrue(confirmation.isHittable)
        capture(app, "Auto consequence confirmation")
        confirmation.tap()
        XCTAssertTrue(app.staticTexts["Preview only. This action does not contact a desktop."].waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertEqual(composer.value as? String, "Permission menu draft")
    }

    func testPermissionDescriptionsUseEditingRoomAndRemainVisibleWithKeyboardDown() {
        let editing = openMenu(["--companion-header-light"])
        XCTAssertGreaterThan(editing.frame.height, editing.frame.width)
        // This matrix runs on SE3 (667pt) and Pro Max (956pt). Assert the native
        // row geometry independently of the app's available-height classification.
        let shortPhone = editing.frame.height < 800
        XCTAssertEqual(editing.staticTexts["Permissions"].exists, !shortPhone,
                       "Only the short editing pane omits the redundant section heading")
        for level in levels {
            let row = editing.buttons["companion-level-\(level.id)"]
            assertFullText(row, expected: level.fullLabel)
            if shortPhone {
                XCTAssertLessThanOrEqual(row.frame.height, 46, "Short editing uses a single native title line")
            } else {
                XCTAssertGreaterThanOrEqual(row.frame.height, 57, "Roomy editing retains the native subtitle line")
            }
        }
        capture(editing, "editing visual descriptions \(shortPhone ? "short" : "roomy")")
        editing.terminate()

        let reading = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-header-light"], attempts: 1)
        XCTAssertTrue(reading.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        XCTAssertNil(visibleKeyboardFrame(reading))
        waitAndTap(reading.buttons["companion-level-menu"], until: reading.buttons["companion-permissions-menu"], attempts: 1)
        waitAndTap(reading.buttons["companion-permissions-menu"], until: reading.buttons["companion-level-plan"], attempts: 1)
        XCTAssertTrue(reading.staticTexts["Permissions"].exists, "Keyboard-down presentation retains its section heading")
        for level in levels {
            let row = reading.buttons["companion-level-\(level.id)"]
            assertFullText(row, expected: level.fullLabel)
            XCTAssertGreaterThanOrEqual(row.frame.height, 57, "Keyboard-down presentation retains every native subtitle line")
        }
        capture(reading, "keyboard down visual descriptions")
    }

    private func permissionScrollDistance(row: CGRect?, pane: CGRect) -> CGFloat? {
        guard [pane.minX, pane.minY, pane.width, pane.height].allSatisfy({ $0.isFinite }),
              pane.width > 0, pane.height >= 48 else { return nil }
        let maximum = min(120, pane.height / 2)
        guard let row else { return maximum }
        guard [row.minX, row.minY, row.width, row.height].allSatisfy({ $0.isFinite }),
              row.width > 0, row.height > 0,
              row.minX >= pane.minX - 0.5, row.maxX <= pane.maxX + 0.5 else { return nil }
        var distance: CGFloat
        if row.minY < pane.minY {
            distance = -max(24, pane.minY - row.minY + 8)
        } else if row.maxY > pane.maxY {
            distance = max(24, row.maxY - pane.maxY + 8)
        } else {
            return nil
        }
        if row.height <= pane.height {
            distance = min(row.minY - pane.minY, max(row.maxY - pane.maxY, distance))
        }
        return min(maximum, max(-maximum, distance))
    }

    /// Swipes stay inside the clipped native pane; the collection's oversized frame extends over the keyboard.
    private func reveal(_ row: XCUIElement, in app: XCUIApplication, accessibility: Bool) {
        for step in 0...8 {
            checkTimeLeft("revealing a permission level")
            let pane = visiblePane(app)
            let frame = row.exists ? row.frame : nil
            if let frame {
                let fits = pixelContains(pane, frame)
                let oversized = accessibility && frame.height > pane.height
                    && frame.intersection(pane).height >= 44
                if row.isHittable && (fits || oversized) {
                    print("PERMISSION_GEOMETRY state=\(accessibility ? "XXXL" : "landscape") level=\(row.identifier) pane=\(pane) row=\(frame) scrolls=\(step) oversized=\(oversized)")
                    return
                }
            }
            guard step < 8 else { break }
            guard let distance = permissionScrollDistance(row: frame, pane: pane) else {
                capture(app, "non-navigable permission row")
                XCTFail("A permission row must expose safe geometry and be actionable when fully visible")
                return
            }
            let startY = distance < 0 ? pane.minY + 8 : pane.maxY - 8
            let endY = startY - distance
            let identifier = frame == nil ? "unloaded permission row" : row.identifier
            print("PERMISSION_NAVIGATION step=\(step) level=\(identifier) pane=\(pane) row=\(String(describing: frame)) distance=\(distance)")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: pane.midX, dy: startY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: pane.midX, dy: endY)),
                withVelocity: .slow, thenHoldForDuration: 0)
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

    func testLargestTextPortraitEveryLevelKeepsFullVoiceOverTextAndRemainsReachable() {
        // Combined XXXL + landscape starts with the composer control under the keyboard on plain main (#483).
        // This NEW matrix excludes only that combination; existing Chrome XXXL target assertions remain intact.
        let app = openMenu(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for level in levels {
            let row = app.buttons["companion-level-\(level.id)"]
            reveal(row, in: app, accessibility: true)
            assertFullText(row, expected: level.fullLabel)
            if level.id == "plan" || level.id == "full_access" {
                capture(app, "XXXL portrait \(level.id)")
            }
        }
        confirmFullAccess(app)
    }
}
