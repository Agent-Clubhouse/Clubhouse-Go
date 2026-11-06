import XCTest

@MainActor final class CompanionChatHeaderUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openRiver(_ app: XCUIApplication) {
        let row = element(app, "agent-preview-studio-river")
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        waitAndTap(row, until: element(app, "companion-composer"))
    }

    /// Evidence only at the existing query phase; no assertion, wait, retry or action selection.
    private func captureContextBoundary(_ app: XCUIApplication, _ context: XCUIElement, _ phase: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Context boundary — \(phase)"
        shot.lifetime = .keepAlways
        add(shot)
        let exists = context.exists
        guard exists else {
            XCTContext.runActivity(named: "Context boundary \(phase): target exists=false; no frame available") { _ in }
            return
        }
        let frame = context.frame
        let label = context.label
        let value = context.value
        let enabled = context.isEnabled
        let hittable = context.isHittable
        let appFrame = app.frame
        let navCount = app.navigationBars.count
        let navFrame = navCount == 1 ? String(describing: app.navigationBars.element(boundBy: 0).frame) : "unavailable"
        XCTContext.runActivity(named: "Context boundary \(phase): actual Button frame=\(frame), label=\(label), value=\(String(describing: value)), enabled=\(enabled), hittable=\(hittable), app=\(appFrame), navCount=\(navCount), navFrame=\(navFrame)") { _ in }
    }

    /// Passive post-entry evidence. Counts and frames are sequential, not a native snapshot transaction.
    private func captureContextReport(_ app: XCUIApplication, _ phase: String) {
        let started = ProcessInfo.processInfo.systemUptime
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Context report — \(phase)"
        shot.lifetime = .keepAlways
        add(shot)
        func log(_ message: String) {
            XCTContext.runActivity(named: "Context report \(phase): \(message); uptime=\(ProcessInfo.processInfo.systemUptime)") { _ in }
        }
        func observe(_ name: String, _ query: XCUIElementQuery) {
            let queryStarted = ProcessInfo.processInfo.systemUptime
            let count = query.count
            log("\(name) count=\(count), queryStarted=\(queryStarted)")
            guard count == 1 else {
                log("\(name) attributes unavailable: cardinality is not one")
                return
            }
            let target = query.element(boundBy: 0)
            let exists = target.exists
            guard exists else {
                log("\(name) attributes unavailable: target disappeared after count")
                return
            }
            let frame = target.frame
            let label = target.label
            let finitePositive = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
                && frame.width > 0 && frame.height > 0
            log("\(name) exists=\(exists), frame=\(frame), finitePositive=\(finitePositive), label=\(label); attributes are sequential")
        }
        log("started=\(started), screenshotFinished=\(ProcessInfo.processInfo.systemUptime), appFrame=\(app.frame)")
        observe("report Any", app.descendants(matching: .any).matching(identifier: "companion-context-report"))
        observe("report StaticText", app.staticTexts.matching(identifier: "companion-context-report"))
        observe("settings picker Button", app.buttons.matching(identifier: "agent-settings-context-window"))
        observe("navigation bars", app.navigationBars)
        observe("windows", app.windows)
        observe("reading note Any", app.descendants(matching: .any).matching(identifier: "companion-context-reading-note"))
        observe("plan limits Any", app.descendants(matching: .any).matching(identifier: "companion-context-plan-limits"))
        let collections = app.collectionViews.containing(.button, identifier: "agent-settings-context-window")
        let collectionCount = collections.count
        log("picker-containing CollectionView count=\(collectionCount)")
        if collectionCount == 1 {
            let collection = collections.element(boundBy: 0)
            if collection.exists {
                let frame = collection.frame
                let finitePositive = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
                    && frame.width > 0 && frame.height > 0
                log("picker-containing CollectionView frame=\(frame), finitePositive=\(finitePositive); raw frame is not a proven usable clip")
                observe("collection picker Button", collection.buttons.matching(identifier: "agent-settings-context-window"))
                observe("collection report Any", collection.descendants(matching: .any).matching(identifier: "companion-context-report"))
                observe("collection report StaticText", collection.staticTexts.matching(identifier: "companion-context-report"))
            } else {
                log("picker-containing CollectionView attributes unavailable: disappeared after count")
            }
        } else {
            log("picker-containing CollectionView attributes unavailable: cardinality is not one")
        }
        let hierarchyStarted = ProcessInfo.processInfo.systemUptime
        let hierarchy = Data(app.debugDescription.utf8)
        let retained = Data(hierarchy.prefix(65_536))
        let tree = XCTAttachment(data: retained, uniformTypeIdentifier: "public.plain-text")
        tree.name = "Context report hierarchy — \(phase)"
        tree.lifetime = .keepAlways
        add(tree)
        log("hierarchyStarted=\(hierarchyStarted), fullUTF8Bytes=\(hierarchy.count), retainedUTF8Bytes=\(retained.count), truncated=\(hierarchy.count > retained.count); started=\(started), finished=\(ProcessInfo.processInfo.systemUptime)")
    }

    func testIdentityDisclosesDetailsAndUsageOpensContextAndDesktopPlanLimits() {
        let app = launchApp(["--companion-preview", "--companion-preview-context-window"])
        openRiver(app)
        let identity = app.buttons["companion-chat-header"]
        let details = element(app, "companion-chat-details")
        let activity = app.staticTexts["companion-chat-activity"]
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertEqual(activity.label, "Run xcodebuild")
        XCTAssertTrue(identity.label.contains("Permissions:"), identity.label)
        XCTAssertFalse(details.exists, "Status and permission details start collapsed")
        XCTAssertGreaterThanOrEqual(identity.frame.height, 44)
        XCTAssertGreaterThanOrEqual(identity.frame.width, 44)
        captureContextBoundary(app, context, "known ordinary before original size checks")
        XCTAssertTrue(context.isHittable)
        XCTAssertGreaterThanOrEqual(context.frame.width, 44)
        XCTAssertGreaterThanOrEqual(context.frame.height, 44)
        XCTAssertGreaterThan(activity.frame.minY, identity.frame.maxY, "Activity belongs in the footer")
        XCTAssertLessThanOrEqual(activity.frame.maxY, element(app, "companion-composer").frame.minY)
        waitAndTap(identity, until: details)
        XCTAssertTrue(details.isHittable)
        waitAndTap(identity, untilGone: details)

        let before = context.frame
        tapChatStatusBar(in: app)
        XCTAssertEqual(context.frame.minY, before.minY, accuracy: 1, "Reading older messages keeps the header pinned")
        XCTAssertTrue(context.isHittable)
        waitAndTap(context, until: app.buttons["agent-settings-context-window"])
        captureContextReport(app, "ordinary after original context target wait")
        XCTAssertTrue(element(app, "companion-context-report").exists, "Context still opens its reported details")
        XCTAssertEqual(element(app, "companion-context-reading-note").label, "Latest reported context usage")
        let limits = app.buttons["companion-context-plan-limits"]
        XCTAssertTrue(limits.isHittable)
        XCTAssertGreaterThanOrEqual(limits.frame.height, 44)
        waitAndTap(limits, until: app.navigationBars["Plan limits"])
        XCTAssertTrue(element(app, "plan-limits-unavailable-preview-studio").exists,
                      "Unsupported plan limits remain explicitly unavailable, independent of context settings")
    }

    func testAccessibilityKeyboardKeepsIdentityAndUsageActionReachable() {
        let app = launchApp(["--companion-preview", "--companion-preview-context-window",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openRiver(app)
        let status = element(app, "companion-chat-header")
        let context = app.buttons["companion-context-usage"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Permissions:"), status.label)
        captureContextBoundary(app, context, "AXL before editing")
        XCTAssertTrue(context.isHittable, "The large-text header keeps usage reachable before editing")
        XCTAssertFalse(element(app, "companion-chat-details").exists)

        let composer = element(app, "companion-composer")
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2), app.buttons["Keyboard"].exists {
            app.buttons["Keyboard"].tap()
            let show = app.buttons["Show Keyboard"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        composer.typeText("Header draft")
        captureContextBoundary(app, context, "AXL after original draft typing")
        XCTAssertTrue(context.isHittable, "Usage remains reachable while editing without an expanded status row")
        XCTAssertTrue(status.label.contains("Permissions:"), status.label)
        let actions = app.buttons["conversation-actions-menu"]
        waitAndTap(actions, until: app.buttons["companion-context-settings-menu"])
        waitAndTap(app.buttons["companion-context-settings-menu"], until: app.buttons["agent-settings-context-window"])
        captureContextReport(app, "AXL after original context target wait")
        XCTAssertTrue(element(app, "companion-context-report").exists, "Context stays available through conversation actions")
    }

    func testUnknownContextStillOffersDesktopPlanLimits() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        let usage = app.buttons["companion-context-settings"]
        captureContextBoundary(app, usage, "unknown Dispatcher before original action")
        XCTAssertTrue(usage.isHittable)
        XCTAssertEqual(usage.value as? String, "Context usage unknown")
        waitAndTap(usage, until: element(app, "companion-context-reading-note"))
        XCTAssertEqual(element(app, "companion-context-reading-note").label, "Context usage unknown")
        waitAndTap(app.buttons["companion-context-plan-limits"], until: app.navigationBars["Plan limits"])
    }

    func testReviewHasOneIdentityPrincipalWithPositionDisclosureAndUsage() {
        let app = launchApp(["--companion-preview"], attempts: 1)
        let open = app.buttons["companion-open-review"].firstMatch
        let title = app.buttons["review-title"]
        waitAndTap(open, until: title, attempts: 1)
        XCTAssertTrue(waitFor(title, NSPredicate(format: "label == %@", "Maple, 1 of 3"), timeout: 5))
        XCTAssertEqual(app.navigationBars.descendants(matching: .any).matching(identifier: "review-title").count, 1,
                       "The selected conversation alone owns Review's principal")
        XCTAssertFalse(app.navigationBars.descendants(matching: .any).matching(identifier: "companion-chat-header").firstMatch.exists)
        let details = element(app, "companion-chat-details")
        waitAndTap(title, until: details, attempts: 1)
        waitAndTap(title, untilGone: details, attempts: 1)

        // Match Review's existing gesture; usable-region changes need runtime evidence before adjustment.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.24))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitFor(title, NSPredicate(format: "label == %@", "Cedar, 2 of 3"), timeout: 5))
        XCTAssertEqual(app.navigationBars.descendants(matching: .any).matching(identifier: "review-title").count, 1)
        let usage = app.navigationBars.buttons["companion-context-settings"]
        captureContextBoundary(app, usage, "selected Review after original page gesture")
        waitAndTap(usage, until: element(app, "companion-context-reading-note"), attempts: 1)
        waitAndTap(app.buttons["companion-context-plan-limits"], until: app.navigationBars["Plan limits"], attempts: 1)
    }
}
