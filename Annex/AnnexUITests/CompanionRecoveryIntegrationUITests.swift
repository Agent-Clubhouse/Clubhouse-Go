import XCTest

/// Actual row/Details interaction and deduplication; service call counts live in hosted integration tests.
@MainActor final class CompanionRecoveryIntegrationUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func fixture(_ app: XCUIApplication, _ action: String) {
        let button = app.buttons["recovery-fixture-\(action)"]
        waitAndTap(app.buttons["recovery-fixture-menu"], until: button, attempts: 1)
        guard revealFixtureItem("recovery-fixture-\(action)", in: app) else { return }
        waitAndTap(button, untilGone: button, attempts: 1)
    }
    private func finiteRect(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite && frame.width > 0 && frame.height > 0
    }

    /// Public menu ancestry supplies the clip; the collection's exported content frame can exceed it.
    private func fixtureMenuGeometry(_ id: String, in app: XCUIApplication) -> (item: XCUIElement, menu: XCUIElement, clip: CGRect)? {
        let items = app.buttons.matching(identifier: id)
        let menus = app.collectionViews.containing(.button, identifier: id)
        let mainWindow = app.windows.firstMatch.frame
        let window = mainWindow.intersection(app.frame)
        guard items.count == 1, menus.count == 1, app.collectionViews.count == 1,
              finiteRect(mainWindow), finiteRect(app.frame), finiteRect(window) else {
            XCTFail("A fixture action must have one item, one native menu and a finite main window")
            return nil
        }
        let menu = menus.firstMatch
        let menuFrame = menu.frame
        guard finiteRect(menuFrame) else { XCTFail("The native menu must have finite geometry"); return nil }
        // There is exactly one collection globally, so containing that type and this exact item identifies its ancestors.
        let ancestors = app.otherElements.containing(.collectionView, identifier: nil).containing(.button, identifier: id)
        let frames = ancestors.allElementsBoundByIndex.map(\.frame)
        guard !frames.isEmpty, frames.allSatisfy({ finiteRect($0) && window.contains($0) }) else {
            XCTFail("Every exported enclosing menu frame must be finite and inside the actual window")
            return nil
        }
        let smallest = frames.filter { candidate in frames.allSatisfy { $0.contains(candidate) } }
        guard let clip = smallest.first, smallest.allSatisfy({ $0 == clip }), clip != window,
              clip.minX <= menuFrame.minX, clip.maxX >= menuFrame.maxX else {
            XCTFail("Menu clipping ancestry must have one smallest frame; only equal duplicates are accepted")
            return nil
        }
        return (items.firstMatch, menu, clip)
    }

    /// Scrollbar duplicates in the native AX tree may agree; divergent or missing tracks are never guessed.
    private func fixtureMenuTrack(_ menu: XCUIElement, clip: CGRect, in app: XCUIApplication) -> CGRect? {
        let bars = menu.descendants(matching: .other).matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar,"))
        let frames = bars.allElementsBoundByIndex.map(\.frame)
        guard let track = frames.first, finiteRect(track), clip.contains(track), frames.allSatisfy({ finiteRect($0) && $0 == track }) else {
            XCTFail("Native menu navigation requires one finite consensus vertical track")
            return nil
        }
        let interval = CGRect(x: clip.minX, y: track.minY, width: clip.width, height: track.height)
        let viewport = interval.intersection(clip).intersection(app.windows.firstMatch.frame).intersection(app.frame)
        guard finiteRect(viewport), viewport.width > 24, viewport.height > 26 else {
            XCTFail("Native menu navigation requires a nonempty conservative track viewport")
            return nil
        }
        return viewport
    }

    /// Zero to two content drags, followed by exactly the existing single checked item tap.
    private func revealFixtureItem(_ id: String, in app: XCUIApplication) -> Bool {
        for navigation in 0...2 {
            guard let current = fixtureMenuGeometry(id, in: app) else { return false }
            let target = current.item.frame
            guard finiteRect(target) else { XCTFail("Fixture item must have a finite nonempty frame"); return false }
            // The first visible row starts above the scrollbar track. Its actual clipping ancestor is authoritative.
            if navigation == 0, current.clip.contains(target), current.item.isHittable { return true }
            guard let viewport = fixtureMenuTrack(current.menu, clip: current.clip, in: app) else { return false }
            if navigation > 0, current.clip.contains(target), viewport.contains(target), current.item.isHittable { return true }
            guard navigation < 2, target.minX >= viewport.minX, target.maxX <= viewport.maxX,
                  target.height <= viewport.height, !viewport.contains(target) else {
                XCTFail("Fixture item must become wholly visible and hittable within two bounded content drags")
                return false
            }
            let interior = viewport.insetBy(dx: 12, dy: 12)
            let displacement = target.midY - viewport.midY
            let distance = min(abs(displacement), interior.height - 2)
            guard finiteRect(interior), distance.isFinite, distance > 0 else {
                XCTFail("Fixture menu displacement must be finite and nonzero"); return false
            }
            let start = CGPoint(x: interior.midX, y: displacement > 0 ? interior.maxY - 1 : interior.minY + 1)
            let end = CGPoint(x: start.x, y: start.y + (displacement > 0 ? -distance : distance))
            let window = app.windows.firstMatch.frame.intersection(app.frame)
            guard interior.contains(start), interior.contains(end), window.contains(start), window.contains(end) else {
                XCTFail("Both menu-content gesture endpoints must remain inside the actual viewport")
                return false
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY))
            XCTContext.runActivity(named: "Fixture menu content drag \(navigation + 1)/2: clip \(current.clip), track \(viewport), item \(target), \(start) → \(end)") { _ in
                from.press(forDuration: 0.05, thenDragTo: to)
            }
            // Re-query ancestry, track, item frame and hittability on the next bounded iteration; no wait or tap retry.
        }
        XCTFail("Fixture item was not resolved by bounded native menu navigation")
        return false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        launchApp(["--companion-preview", "--companion-preview-recovery-fixture"] + extra, attempts: 1)
    }
    private func assertNoLargeRecovery(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["Loading conversation…"].exists)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].exists)
        XCTAssertFalse(element(app, "companion-empty-conversation").exists)
    }
    private func capture(_ app: XCUIApplication, _ state: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recovery synthetic \(Int(app.frame.width))pt — \(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One geometry-directed content drag for an exported control below the medium sheet's visible content.
    private func revealDetailsRetry(_ retry: XCUIElement, in app: XCUIApplication) -> Bool {
        let scrolls = app.scrollViews.containing(.button, identifier: "companion-recovery-detail-retry")
        let bars = app.navigationBars.matching(identifier: "Connection and recovery")
        guard scrolls.count == 1, bars.count == 1 else {
            XCTFail("Recovery Details must have one containing scroll view and one sheet navigation bar")
            return false
        }
        let scroll = scrolls.firstMatch, bar = bars.firstMatch
        func viewport() -> CGRect? {
            let visible = scroll.frame.intersection(app.windows.firstMatch.frame)
            let navigation = bar.frame
            let top = max(visible.minY, navigation.maxY)
            guard !visible.isNull, !visible.isInfinite, visible.width > 24,
                  top.isFinite, visible.maxY.isFinite, visible.maxY - top > 24 else {
                XCTFail("Recovery sheet must expose a finite content viewport below its navigation bar")
                return nil
            }
            return CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
                .insetBy(dx: 12, dy: 12)
        }
        guard let before = viewport() else { return false }
        let target = retry.frame
        guard target.minX.isFinite, target.minY.isFinite, target.maxX.isFinite, target.maxY.isFinite,
              target.width > 0, target.height > 0 else {
            XCTFail("The exported retry must have a finite nonempty frame")
            return false
        }
        if !before.contains(target) {
            let displacement = target.midY - before.midY
            let start = CGPoint(x: before.midX, y: before.maxY - 1)
            let end = CGPoint(x: start.x, y: start.y - displacement)
            let appFrame = app.frame
            guard target.minX >= before.minX, target.maxX <= before.maxX,
                  target.minY >= before.minY, target.maxY > before.maxY,
                  displacement > 0, displacement <= before.height,
                  before.contains(start), before.contains(end),
                  appFrame.contains(start), appFrame.contains(end) else {
                XCTFail("Only a below-viewport retry reachable by one bounded upward content drag may be navigated to")
                return false
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: start.x - appFrame.minX, dy: start.y - appFrame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - appFrame.minX, dy: end.y - appFrame.minY))
            XCTContext.runActivity(named: "Recovery Details content drag: viewport \(before), retry \(target), \(start) → \(end)") { _ in
                from.press(forDuration: 0.05, thenDragTo: to)
            }
        }
        // The gesture may change the sheet detent. Re-read both the viewport/nav and the target, without a wait/loop.
        guard let after = viewport() else { return false }
        let revealed = retry.frame
        let contained = after.contains(revealed)
        XCTAssertTrue(contained, "The whole retry must be inside the current sheet content viewport: \(revealed), viewport \(after)")
        return contained
    }


    func testFirstLoadProgressFailureDetailsRetryAndRecovery() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Refreshing conversation…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Refreshing conversation…")).count, 1)
        XCTAssertFalse(app.buttons["companion-recovery-retry"].exists)
        assertNoLargeRecovery(app)
        capture(app, "compact first-load progress")
        fixture(app, "fail")
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        assertNoLargeRecovery(app)
        capture(app, "history failure")
        fixture(app, "next-success")
        let details = app.buttons["companion-recovery-details"]
        XCTAssertGreaterThanOrEqual(details.frame.width, 44)
        XCTAssertGreaterThanOrEqual(details.frame.height, 44)
        waitAndTap(details, until: element(app, "companion-recovery-explanation"), attempts: 1)
        let explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic history failure.\nThe response was incomplete.\nNo real desktop was contacted."))
        XCTAssertTrue(explanation.label.contains("Target: alpha on recovery-one."))
        capture(app, "full failure Details")
        let retry = app.buttons["companion-recovery-detail-retry"]
        guard revealDetailsRetry(retry, in: app) else { return }
        capture(app, "full failure Details after content navigation")
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        waitAndTap(retry, untilGone: explanation, attempts: 1)
        XCTAssertTrue(details.waitForNonExistence(timeout: 5), "Clean connected history success removes recovery")
        XCTAssertTrue(app.buttons["Read earlier messages in archive"].exists)
        XCTAssertTrue(element(app, "companion-composer").isHittable)
        capture(app, "recovered transcript")
    }

    func testLargeTextKeepsFullErrorsSeparateWarningAndTargetDetailsReachable() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons["companion-recovery-details"].waitForExistence(timeout: 10))
        fixture(app, "fail")
        fixture(app, "operation")
        fixture(app, "connection-failure")
        XCTAssertTrue(app.staticTexts["Connection issue"].waitForExistence(timeout: 5))
        let warning = app.staticTexts["Synthetic operation warning stays separate."]
        XCTAssertTrue(warning.exists)
        let retry = app.buttons["companion-recovery-retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        capture(app, "AX warning and connection retry")
        retry.tap() // Synthetic reconnect records intent; no invented connection success follows.
        XCTAssertTrue(app.staticTexts["Connection issue"].exists)
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"), attempts: 1)
        var explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic connection failure."))
        XCTAssertTrue(explanation.label.contains("Synthetic history failure."))
        capture(app, "AX full connection and history Details")
        waitAndTap(app.navigationBars.buttons["Done"], untilGone: explanation, attempts: 1)
        fixture(app, "progress")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(warning.exists, "Operation warnings remain separate during automatic recovery")
        assertNoLargeRecovery(app)
        fixture(app, "select-gamma")
        XCTAssertTrue(app.navigationBars["Gamma"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        waitAndTap(app.buttons["companion-recovery-details"], until: element(app, "companion-recovery-explanation"), attempts: 1)
        explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Target: gamma on recovery-two."))
        XCTAssertFalse(explanation.label.contains("Target: alpha"))
    }
}
