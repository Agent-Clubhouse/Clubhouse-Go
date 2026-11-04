import XCTest

/// Primitives for hosted macOS runners, where an element lookup can take 15–20 s, a launch 90 s, and a tap or
/// long-press is sometimes lost. They retry the gesture, never the assertion, and every wait is bounded.
///
/// Avoid `for _ in 0..<n where !condition { swipe }`: `where` filters iterations rather than ending the loop, so the
/// condition (one or two slow lookups) still runs on every remaining iteration after it holds. Use these loops instead.
@MainActor
class ReliableUITestCase: XCTestCase {
    /// Steps fail with a message once a test runs this close to its execution time allowance. A test killed by the
    /// allowance restarts the runner and is not retried, so it should fail first.
    private static let allowanceMargin: TimeInterval = 30
    private var deadline = Date.distantFuture

    /// Launches the app in portrait with `--ui-testing-fast`, relaunching if the runner times out launching or
    /// terminating it.
    func launchApp(_ arguments: [String], environment: [String: String] = [:], allowance: TimeInterval = 240, attempts: Int = 3,
                   file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = allowance
        deadline = Date().addingTimeInterval(allowance - Self.allowanceMargin)
        // The launch-configuration matrix can leave the shared device in landscape. Requesting the
        // orientation that is already active can leave XCTest waiting for a change that never comes (#122).
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        // A previous test's fixture may still be shutting down; launching over it can time out (#122).
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 15)
        }
        app.launchArguments = arguments + ["--ui-testing-fast"]
        app.launchEnvironment.merge(environment) { _, new in new }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            ["Failed to launch", "Failed to terminate", "Timed out while launching"].contains { issue.compactDescription.contains($0) }
        }
        for attempt in 1..<max(attempts, 1) {
            continueAfterFailure = true
            XCTExpectFailure("Attempt \(attempt): hosted runners sometimes time out launching the app", options: options) {
                app.launch()
            }
            continueAfterFailure = false
            if app.wait(for: .runningForeground, timeout: 30) { return app }
        }
        // The last attempt reports any failure as it is.
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "The app must launch", file: file, line: line)
        return app
    }

    /// Fails the test, rather than letting the allowance kill it, once it is close to running out of time.
    func checkTimeLeft(_ step: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        guard Date() > deadline else { return }
        XCTFail("Ran out of time before \(step()); the test is within \(Int(Self.allowanceMargin)) s of its allowance", file: file, line: line)
    }

    /// Taps `element` until `expected` appears, tapping again only while `element` is still there and hittable.
    /// Each attempt waits the whole `timeout`, so a slow lookup is not mistaken for a lost tap.
    @discardableResult
    func waitAndTap(_ element: XCUIElement, until expected: XCUIElement, timeout: TimeInterval = 10, attempts: Int = 3,
                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<attempts {
            checkTimeLeft("tapping \(element)", file: file, line: line)
            if expected.exists { return true }
            guard element.exists && element.isHittable else { break }
            element.tap()
            if expected.waitForExistence(timeout: timeout) { return true }
        }
        let appeared = expected.waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, failureMessage(message(), default: "\(expected) must appear after tapping \(element)"), file: file, line: line)
        return appeared
    }

    /// Taps `element` until `gone` disappears, such as Done closing a sheet.
    @discardableResult
    func waitAndTap(_ element: XCUIElement, untilGone gone: XCUIElement, timeout: TimeInterval = 5, attempts: Int = 3,
                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<attempts {
            checkTimeLeft("tapping \(element)", file: file, line: line)
            if !gone.exists { return true }
            guard element.exists && element.isHittable else { break }
            element.tap()
            if gone.waitForNonExistence(timeout: timeout) { return true }
        }
        let closed = gone.waitForNonExistence(timeout: 2)
        XCTAssertTrue(closed, failureMessage(message(), default: "\(gone) must go after tapping \(element)"), file: file, line: line)
        return closed
    }

    /// iPad's top tabs are buttons outside a UITabBar; the content then extends
    /// to the bottom of the window. Keep the same margin for checked row targets.
    func rowContentBottom(in app: XCUIApplication) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        return (tabBar.exists ? tabBar.frame.minY : app.frame.maxY) - 12
    }

    /// These pushed fixture chats hide their tab bar. The navigation bar starts
    /// immediately below the status bar; a fraction of the whole screen can land
    /// in navigation instead on iPad's shorter status bar.
    func tapChatStatusBar(in app: XCUIApplication) {
        let window = app.frame
        let navigation = app.navigationBars.firstMatch.frame
        let status = CGRect(x: window.minX, y: window.minY, width: window.width, height: navigation.minY - window.minY)
        XCTAssertGreaterThan(status.height, 0)
        let point = CGPoint(x: status.minX + status.width * 0.1, y: status.midY)
        XCTAssertTrue(status.contains(point))
        XCTAssertFalse(navigation.contains(point))
        XCTContext.runActivity(named: "Tap chat status bar at \(point), status band \(status), navigation \(navigation)") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
    }

    /// Hittability alone can include a row clipped by the navigation bar. Move the
    /// whole row into the content area, then tap its checked center explicitly.
    func tapVisibleRow(_ row: XCUIElement, in app: XCUIApplication, until expected: XCUIElement) {
        for _ in 0..<3 {
            if expected.exists { return }
            for _ in 0..<6 {
                checkTimeLeft("moving the agent row clear of the navigation bar")
                let top = app.navigationBars.firstMatch.frame.maxY + 12
                let bottom = rowContentBottom(in: app)
                if row.exists && row.isHittable && row.frame.minY >= top && row.frame.maxY <= bottom { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let dy: CGFloat = row.frame.minY < top ? 120 : -120
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
            }
            XCTAssertTrue(row.exists && row.isHittable)
            let frame = row.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY + 12)
            XCTAssertLessThanOrEqual(frame.maxY, rowContentBottom(in: app))
            XCTAssertTrue(frame.contains(point))
            XCTAssertFalse(app.navigationBars.firstMatch.frame.contains(point))
            XCTContext.runActivity(named: "Tap visible agent row at \(point), row \(frame), navigation bar \(app.navigationBars.firstMatch.frame)") { _ in
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if expected.waitForExistence(timeout: 10) { return }
        }
        XCTAssertTrue(expected.waitForExistence(timeout: 2), "The visible agent row must open its conversation")
    }

    /// Long-presses `element` until its context menu shows `item`. A press that a slow runner drops opens nothing,
    /// so it presses again, but never while the menu is already open.
    @discardableResult
    func longPressUntilMenu(_ element: XCUIElement, shows item: XCUIElement, duration: TimeInterval = 1.2, attempts: Int = 3,
                            _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<attempts {
            checkTimeLeft("long-pressing \(element)", file: file, line: line)
            if item.exists { return true }
            guard element.exists && element.isHittable else { break }
            element.press(forDuration: duration)
            if item.waitForExistence(timeout: 5) { return true }
        }
        let shown = item.waitForExistence(timeout: 2)
        XCTAssertTrue(shown, failureMessage(message(), default: "Long-pressing \(element) must offer \(item)"), file: file, line: line)
        return shown
    }

    /// Swipes until `target` is on screen and hittable, stopping as soon as it is. The caller asserts.
    @discardableResult
    func scrollTo(_ target: XCUIElement, in app: XCUIApplication, up: Bool = true, maxSwipes: Int = 6,
                  velocity: XCUIGestureVelocity = .default, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<maxSwipes {
            checkTimeLeft("scrolling to \(target)", file: file, line: line)
            if target.exists && target.isHittable { return true }
            if up { app.swipeUp(velocity: velocity) } else { app.swipeDown(velocity: velocity) }
        }
        return target.exists && target.isHittable
    }

    /// Waits briefly for `target`, swiping between waits, and stops as soon as it exists. The caller asserts.
    @discardableResult
    func scrollUntilExists(_ target: XCUIElement, in app: XCUIApplication, up: Bool = true, maxSwipes: Int = 4, wait: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<maxSwipes {
            checkTimeLeft("looking for \(target)", file: file, line: line)
            if target.waitForExistence(timeout: wait) { return true }
            if up { app.swipeUp() } else { app.swipeDown() }
        }
        return target.exists
    }

    /// Scrolls to a Home fold such as "1 sleeping", opens it if it is collapsed, and scrolls until `target` inside it is on screen.
    @discardableResult
    func expandFold(_ fold: XCUIElement, revealing target: XCUIElement, in app: XCUIApplication,
                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if target.exists { return scrollTo(target, in: app, file: file, line: line) }
        XCTAssertTrue(scrollTo(fold, in: app, file: file, line: line), "\(fold) must be on screen", file: file, line: line)
        tapToExpand(fold, file: file, line: line)
        // A row can exist below the fold before it can be tapped or long-pressed, so bring it on screen too.
        return scrollUntilExists(target, in: app, file: file, line: line) && scrollTo(target, in: app, file: file, line: line)
    }

    /// Taps a fold until it reports Expanded. The fold says whether it is open, so a retried tap never closes it.
    func tapToExpand(_ fold: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expanded = NSPredicate(format: "value == %@", "Expanded")
        for _ in 0..<3 {
            checkTimeLeft("opening \(fold)", file: file, line: line)
            if fold.value as? String == "Expanded" { return }
            fold.tap()
            if waitFor(fold, expanded, timeout: 3) { return }
        }
        XCTAssertEqual(fold.value as? String, "Expanded", "\(fold) must open", file: file, line: line)
    }

    /// The plain timeline exposes off-screen frames. Choose direction from geometry instead of assuming it opens
    /// at a particular edge, and keep gestures between the header and composer.
    func bringTranscriptRowIntoView(_ row: XCUIElement, in app: XCUIApplication, maxGestures: Int = 40) -> Bool {
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<maxGestures {
            checkTimeLeft("bringing transcript content into view")
            if row.exists && row.frame.minY > height * 0.23 && row.frame.maxY < height * 0.72 && row.isHittable { return true }
            let above = row.exists && row.frame.minY < height * 0.23
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.35 : 0.65))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.65 : 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        return row.exists && row.isHittable
    }

    /// A compact activity fold can be tappable at the end of a short transcript without its entire AX frame
    /// fitting above a fixed screen fraction. Keep this acceptance separate from images/links whose callers
    /// require their whole frame visible (including with approval cards and a keyboard open).
    private func bringActivityFoldIntoView(_ row: XCUIElement, in app: XCUIApplication, maxGestures: Int = 40) -> Bool {
        let height = app.windows.firstMatch.frame.height
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        let top = max(app.navigationBars.firstMatch.frame.maxY, height * 0.15)
        let bottom = composer.exists ? composer.frame.minY : height * 0.72
        let viewport = CGRect(x: 0, y: top, width: app.windows.firstMatch.frame.width, height: max(0, bottom - top))
        for _ in 0..<maxGestures {
            checkTimeLeft("bringing transcript content into view")
            let before = row.exists ? row.frame : nil
            if let before, before.minY >= top && before.maxY <= bottom && row.isHittable { return true }
            let above = before.map { $0.minY < top } ?? false
            let high = (top + viewport.height * 0.25) / height
            let low = (top + viewport.height * 0.75) / height
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? high : low))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? low : high))
            from.press(forDuration: 0.05, thenDragTo: to)
            if let before, row.exists {
                let after = row.frame
                if abs(after.minY - before.minY) < 1 && abs(after.maxY - before.maxY) < 1 {
                    // A short transcript cannot move its last fold further up. Do not burn forty drags:
                    // require a visible, hittable target, and let the caller prove its tap actually acts.
                    print("[transcript-target] stoppedAtBoundary=true minY=\(after.minY) maxY=\(after.maxY) viewportTop=\(top) viewportBottom=\(bottom)")
                    return viewport.intersects(after) && row.isHittable
                }
            }
        }
        return row.exists && viewport.intersects(row.frame) && row.isHittable
    }

    /// Routine traffic now starts compact. Expand enclosing activity rows without changing inner routed folds.
    func revealActivityContent(_ target: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 20) {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if target.exists { return }
            let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'companion-activity-' AND value == 'Collapsed'"))
            if let candidate = groups.allElementsBoundByIndex.last {
                let group = app.buttons[candidate.identifier]
                XCTAssertTrue(bringActivityFoldIntoView(group, in: app))
                tapToExpand(group)
            } else { _ = target.waitForExistence(timeout: 1) }
        } while Date() < end
        XCTAssertTrue(target.exists, "Activity must expose its content")
    }

    /// Waits for `predicate` to hold for `element`, for at most `timeout` seconds.
    func waitFor(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func failureMessage(_ message: String, default fallback: String) -> String { message.isEmpty ? fallback : message }
}
