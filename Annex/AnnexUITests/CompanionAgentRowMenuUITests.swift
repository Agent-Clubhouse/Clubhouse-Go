import XCTest

/// Native system-menu proof is deliberately live Home only. Frozen Home is behind a
/// pushed route. Hosted OCR proves its actual content; the unchanged callback tests
/// prove live guards. Hosted native button activation and telemetry are not claimed.
@MainActor final class CompanionAgentRowMenuUITests: ReliableUITestCase {
    // Each theme already launched/terminated its own app. Give those independent invocations
    // distinct test owners while retaining the complete Juniper -> Cedar route in each one.
    func testNativeHomeAgentMenuAtDefaultTypeLight() throws {
        try checkNativeMenu(accessibility: false, scheme: "light")
    }

    func testNativeHomeAgentMenuAtDefaultTypeDark() throws {
        try checkNativeMenu(accessibility: false, scheme: "dark")
    }

    func testNativeHomeAgentMenuAtAccessibilityXXXLLight() throws {
        try checkNativeMenu(accessibility: true, scheme: "light")
    }

    func testNativeHomeAgentMenuAtAccessibilityXXXLDark() throws {
        try checkNativeMenu(accessibility: true, scheme: "dark")
    }

    private func checkNativeMenu(accessibility: Bool, scheme: String) throws {
        let flags = ["--companion-preview", "--companion-preview-" + scheme]
            + (accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        let app = launchApp(flags, attempts: 1)
        let home = app.navigationBars["Clubhouse"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        let quiet = app.buttons["fold-quiet-preview-studio-clubhouse"]
        let sleeping = app.buttons["agent-preview-studio-juniper"]
        XCTAssertTrue(scrollUntilExists(quiet, in: app) && scrollTo(quiet, in: app))
        expandFold(quiet, revealing: sleeping, in: app)
        XCTAssertTrue(scrollTo(sleeping, in: app) && sleeping.isHittable)
        let details = app.buttons["Agent details"]
        let sleepingLabel = sleeping.label
        openMenuWithOneVisibleRowPress(sleeping, in: app, shows: details)
        let sleepingMenu = try nativeMenu(in: app, targetLabel: sleepingLabel, labels: ["Wake & Resume", "Start New Session", "Agent details", "Agent settings", "Terminal"])
        try assertItems(in: sleepingMenu, app: app, allowScroll: accessibility)
        capture(app, "Sleeping native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
        try reveal("Agent details", in: sleepingMenu, app: app, allowScroll: accessibility).tap()
        let sheet = element(app, "agent-details-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The native item invokes Root's inherited Details action")
        XCTAssertTrue(app.navigationBars["Juniper"].exists, "Details belongs to the long-pressed sleeping agent")
        app.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(home.exists)
        let running = app.buttons["agent-preview-studio-cedar"]
        XCTAssertTrue(scrollUntilExists(running, in: app, up: false) && scrollTo(running, in: app, up: false))
        let runningLabel = running.label
        openMenuWithOneVisibleRowPress(running, in: app, shows: details)
        let runningMenu = try nativeMenu(in: app, targetLabel: runningLabel, labels: ["Agent details", "Agent settings", "Terminal"])
        try assertItems(in: runningMenu, app: app, allowScroll: accessibility)
        XCTAssertFalse(app.buttons["Wake & Resume"].exists, "A running agent must not offer a stale Wake")
        XCTAssertFalse(app.buttons["Start New Session"].exists)
        capture(app, "Running native Home menu \(scheme) \(accessibility ? "AX5" : "standard")")
        try reveal("Agent details", in: runningMenu, app: app, allowScroll: accessibility).tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Cedar"].exists, "The action keeps the real running agent target")
        app.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    /// Hittability alone can describe a row clipped behind the navigation bar.
    /// Position first, then issue exactly ONE long-press at the checked row centre.
    private func openMenuWithOneVisibleRowPress(_ row: XCUIElement, in app: XCUIApplication, shows item: XCUIElement,
                                              file: StaticString = #filePath, line: UInt = #line) {
        for step in 0...8 {
            let top = app.navigationBars["Clubhouse"].frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
            let frame = row.frame
            let geometry = "step=\(step) row=\(frame) content=\(viewport) hittable=\(row.isHittable)"
            let record = XCTAttachment(string: geometry); record.name = "Home row before single long-press"; record.lifetime = .keepAlways
            add(record)
            capture(app, "Home row position \(step) — \(row.identifier)")
            XCTAssertLessThanOrEqual(frame.height, viewport.height, "The full row must fit before a long-press: " + geometry, file: file, line: line)
            if viewport.contains(frame) {
                XCTAssertTrue(row.exists && row.isHittable, file: file, line: line)
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                XCTAssertTrue(viewport.contains(centre) && frame.contains(centre), file: file, line: line)
                XCTAssertFalse(app.navigationBars["Clubhouse"].frame.contains(centre), file: file, line: line)
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
                XCTAssertTrue(item.waitForExistence(timeout: 5), "One visible-row long-press must reveal its actual native menu", file: file, line: line)
                return
            }
            guard step < 8 else { break }
            let upwards = frame.maxY > viewport.maxY
            let overflow = upwards ? frame.maxY - viewport.maxY : viewport.minY - frame.minY
            let distance = min(overflow + viewport.height * 0.08, viewport.height * 0.4)
            let startY = viewport.minY + viewport.height * (upwards ? 0.85 : 0.15)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: startY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: upwards ? -distance : distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("Home did not fully reveal the row within eight slow drags; no long-press was sent", file: file, line: line)
    }

    private struct NativeMenu {
        let panel: XCUIElement
        let preview: XCUIElement
        let targetLabel: String
        let labels: [String]

        func currentCollection(file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
            // Keep the original context and target while resolving its current child.
            // Never replace the original panel or preview with a global query.
            _ = try XCTUnwrap(panel.exists && preview.exists && preview.label == targetLabel ? true : nil,
                              "The original native panel and full agent preview must remain open and unchanged", file: file, line: line)
            let children = panel.collectionViews
            _ = try XCTUnwrap(children.count == 1 ? true : nil,
                              "Exactly one current native collection must belong to the original panel", file: file, line: line)
            let collection = children.element(boundBy: 0)
            _ = try XCTUnwrap(collection.exists ? true : nil,
                              "The original panel's current collection must exist", file: file, line: line)
            return collection
        }

        func viewport(in app: XCUIApplication, collection: XCUIElement) -> CGRect {
            panel.frame.intersection(collection.frame).intersection(app.frame)
        }
    }

    private func nativeMenu(in app: XCUIApplication, targetLabel: String, labels: [String],
                            file: StaticString = #filePath, line: UInt = #line) throws -> NativeMenu {
        capture(app, "Native menu before validation")
        // Bind the collection and its clipping ancestor to their actual AX elements.
        // A query containing the Details row stops matching when that row virtualizes.
        let owners = app.collectionViews.allElementsBoundByAccessibilityElement.filter {
            $0.buttons.matching(NSPredicate(format: "label == %@", "Agent details")).count == 1
        }
        let menu = try XCTUnwrap(owners.count == 1 ? owners.first : nil,
                                "Exactly one foreground native menu owns Agent details", file: file, line: line)
        // Native accessibility order is stable while on-screen positions change with scrolling.
        XCTAssertEqual(menu.buttons.allElementsBoundByIndex.map(\.label), labels,
                       "Every full menu label appears once in its original order", file: file, line: line)
        let tallest = menu.buttons.allElementsBoundByAccessibilityElement.map { $0.frame.height }.max() ?? 0
        let panels = app.otherElements.containing(.collectionView, identifier: nil)
            .containing(.button, identifier: "Agent details").allElementsBoundByAccessibilityElement
            .filter {
                let clip = $0.frame.intersection(menu.frame).intersection(app.frame)
                return !clip.isNull && !clip.isInfinite && clip.width > 0 && clip.height > tallest
            }
        let panel = try XCTUnwrap(panels.min {
            let left = $0.frame.intersection(menu.frame).intersection(app.frame)
            let right = $1.frame.intersection(menu.frame).intersection(app.frame)
            return left.width * left.height < right.width * right.height
        }, "A public ancestor of the native collection must provide its actual clip", file: file, line: line)
        let previews = app.otherElements.matching(NSPredicate(format: "label == %@", targetLabel))
            .allElementsBoundByAccessibilityElement
        let preview = try XCTUnwrap(previews.count == 1 ? previews.first : nil,
                                    "One native preview must name the full long-pressed agent and desktop", file: file, line: line)
        let bound = NativeMenu(panel: panel, preview: preview, targetLabel: targetLabel, labels: labels)
        let current = try bound.currentCollection(file: file, line: line)
        XCTAssertEqual(current.buttons.allElementsBoundByIndex.map(\.label), labels,
                       "The original panel owns the same ordered native actions", file: file, line: line)
        return bound
    }

    private func assertItems(in menu: NativeMenu, app: XCUIApplication, allowScroll: Bool,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        for label in menu.labels {
            let item = try reveal(label, in: menu, app: app, allowScroll: allowScroll, file: file, line: line)
            let collection = try menu.currentCollection(file: file, line: line)
            let matches = collection.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "The native menu has one \(label)", file: file, line: line)
            XCTAssertTrue(item.exists && item.isHittable && item.isEnabled, label, file: file, line: line)
            let frame = item.frame
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite && frame.width > 0 && frame.height > 0, label, file: file, line: line)
            XCTAssertTrue(app.frame.contains(frame), "Native item remains on screen at this text size: \(label)", file: file, line: line)
            XCTAssertTrue(menu.viewport(in: app, collection: collection).contains(frame), "Full item is inside the menu's actual clip: \(label)", file: file, line: line)
        }
    }

    private func reveal(_ label: String, in menu: NativeMenu, app: XCUIApplication, allowScroll: Bool,
                        file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let targetIndex = try XCTUnwrap(menu.labels.firstIndex(of: label), file: file, line: line)
        for step in 0...8 {
            let collection = try menu.currentCollection(file: file, line: line)
            let viewport = menu.viewport(in: app, collection: collection)
            _ = try XCTUnwrap(!viewport.isNull && !viewport.isEmpty ? viewport : nil,
                              "The original native menu still has a real clip", file: file, line: line)
            let item = collection.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            let frame = item.exists ? item.frame : nil
            let buttons = collection.buttons.allElementsBoundByAccessibilityElement
            _ = try XCTUnwrap(Set(buttons.map(\.label)).isSubset(of: Set(menu.labels)) ? true : nil,
                              "The bound native menu must retain only its original actions", file: file, line: line)
            let visible = buttons.compactMap { button -> (Int, CGRect)? in
                guard button.exists, let index = menu.labels.firstIndex(of: button.label) else { return nil }
                let rect = button.frame
                return !rect.isEmpty && rect.intersects(viewport) ? (index, rect) : nil
            }
            let tallestItem = visible.map { $0.1.height }.max() ?? 0
            let geometry = "tallestItem=\(tallestItem) step=\(step) label=\(label) item=\(String(describing: frame)) viewport=\(viewport) visibleIndices=\(visible.map { $0.0 })"
            print("NATIVE_MENU_REVEAL \(geometry)")
            let record = XCTAttachment(string: geometry); record.name = "Native menu reveal geometry"; record.lifetime = .keepAlways
            add(record)
            XCTAssertGreaterThan(viewport.height, tallestItem, "The clip must be the menu panel, not a single item's wrapper: " + geometry, file: file, line: line)
            if let frame {
                XCTAssertLessThanOrEqual(frame.height, viewport.height, "This item must fit without truncating its full label", file: file, line: line)
                if viewport.contains(frame) {
                    _ = try XCTUnwrap(item.isHittable && item.isEnabled ? true : nil, geometry, file: file, line: line)
                    capture(app, "Native menu revealed — \(label)")
                    return item
                }
            }
            XCTAssertTrue(allowScroll, "Standard-size native menus must need zero drags: " + geometry, file: file, line: line)
            guard allowScroll, step < 8 else { break }
            let upwards: Bool
            let overflow: CGFloat
            if let frame {
                upwards = frame.maxY > viewport.maxY
                overflow = upwards ? frame.maxY - viewport.maxY : viewport.minY - frame.minY
            } else {
                let first = try XCTUnwrap(visible.map { $0.0 }.min(), "Visible native menu anchors are required", file: file, line: line)
                let last = try XCTUnwrap(visible.map { $0.0 }.max(), file: file, line: line)
                _ = try XCTUnwrap(targetIndex < first || targetIndex > last ? true : nil,
                                  "A missing item inside the visible native range is not a scroll target: " + geometry, file: file, line: line)
                upwards = targetIndex > last
                overflow = viewport.height * 0.2
            }
            let distance = min(overflow + viewport.height * 0.08, viewport.height * 0.3)
            let startY = viewport.minY + viewport.height * (upwards ? 0.85 : 0.15)
            let endY = startY + (upwards ? -distance : distance)
            XCTAssertTrue(viewport.contains(CGPoint(x: viewport.midX, y: startY)) && viewport.contains(CGPoint(x: viewport.midX, y: endY)),
                          "Both drag endpoints belong to the native panel", file: file, line: line)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - app.frame.minX, dy: startY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - app.frame.minX, dy: endY - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture(app, "Native menu reveal failed — \(label)")
        return try XCTUnwrap(nil as XCUIElement?, "Native menu did not fully reveal \(label) within eight slow drags", file: file, line: line)
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
