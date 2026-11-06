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

    /// One optional content drag on a freshly verified description; never a full-viewport claim.
    private func navigateContextDescriptionOnce(_ app: XCUIApplication) -> Bool {
        let description = "How much conversation the CLI keeps before it compacts. This doesn't change the model's own context window."
        let pickerID = "agent-settings-context-window", resetID = "agent-settings-context-window-reset"
        let noteID = "companion-context-reading-note", limitsID = "companion-context-plan-limits"
        func log(_ value: String) {
            XCTContext.runActivity(named: "Context description anchor: \(value); uptime=\(ProcessInfo.processInfo.systemUptime)") { _ in }
        }
        func reject(_ reason: String) -> Bool { log(reason); XCTFail(reason); return false }
        func finite(_ r: CGRect) -> Bool {
            !r.isNull && !r.isInfinite && r.width > 0 && r.height > 0
                && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { $0.isFinite }
        }
        func one(_ query: XCUIElementQuery, _ name: String) -> XCUIElement? {
            let count = query.count; log("\(name) count=\(count)")
            guard count == 1 else { return nil }
            let value = query.element(boundBy: 0)
            return value.exists ? value : nil
        }
        func reportPresent() -> Bool? {
            let any = app.descendants(matching: .any).matching(identifier: "companion-context-report")
            let text = app.staticTexts.matching(identifier: "companion-context-report")
            let counts = [any.count, text.count]; log("report Any/StaticText=\(counts)")
            if counts == [0, 0] { return false }
            guard counts == [1, 1], text.element(boundBy: 0).exists else { return nil }
            return true
        }
        func capture(_ phase: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Context description anchor — \(phase)"; shot.lifetime = .keepAlways; add(shot)
        }
        checkTimeLeft("before the context description anchor")
        guard let present = reportPresent() else { return reject("Ambiguous report export") }
        if present { return true }
        capture("before fresh anchor queries")
        let exact = NSPredicate(format: "label == %@", description)
        guard let anchor = one(app.staticTexts.matching(exact), "description StaticText"),
              app.descendants(matching: .any).matching(exact).count == 1,
              let picker = one(app.buttons.matching(identifier: pickerID), "picker"),
              let reset = one(app.buttons.matching(identifier: resetID), "Reset"),
              let note = one(app.staticTexts.matching(identifier: noteID), "reading note"),
              let limits = one(app.buttons.matching(identifier: limitsID), "Plan limits"),
              let collection = one(app.collectionViews.containing(.button, identifier: pickerID), "picker CollectionView"),
              let cell = one(collection.cells.containing(.button, identifier: pickerID).containing(.button, identifier: resetID)
                .containing(.staticText, identifier: description), "picker/Reset/description Cell"),
              let window = one(app.windows.containing(.button, identifier: pickerID).containing(.button, identifier: resetID)
                .containing(.staticText, identifier: noteID).containing(.button, identifier: limitsID), "content Window"),
              let nav = one(app.navigationBars.matching(identifier: "River").containing(.button, identifier: "Done"), "presented River navigation"),
              let done = one(nav.buttons.matching(identifier: "Done"), "presented Done") else {
            return reject("Missing or ambiguous anchor/owner/presented surface")
        }
        let localCounts = [collection.staticTexts.matching(exact).count, cell.staticTexts.matching(exact).count,
            collection.buttons.matching(identifier: resetID).count, collection.buttons.matching(identifier: pickerID).count,
            window.collectionViews.containing(.button, identifier: pickerID).count, window.staticTexts.matching(exact).count,
            window.navigationBars.matching(identifier: "River").containing(.button, identifier: "Done").count,
            window.staticTexts.matching(identifier: noteID).count, window.buttons.matching(identifier: limitsID).count]
        let roleCounts = [pickerID, resetID, noteID, limitsID].map { app.descendants(matching: .any).matching(identifier: $0).count }
        log("local ownership counts=\(localCounts), any-role surface counts=\(roleCounts)")
        guard (localCounts + roleCounts).allSatisfy({ $0 == 1 }) else { return reject("Ownership or role agreement changed") }
        let appFrame = app.frame, windowFrame = window.frame, collectionFrame = collection.frame, cellFrame = cell.frame
        let anchorFrame = anchor.frame
        let ownerFrames = [appFrame, windowFrame, collectionFrame, cellFrame]
        let start = CGPoint(x: anchorFrame.midX, y: anchorFrame.minY + anchorFrame.height * 0.75)
        let end = CGPoint(x: anchorFrame.midX, y: anchorFrame.minY + anchorFrame.height * 0.25)
        log("owner frames=\(ownerFrames), description=\(anchorFrame), start=\(start), end=\(end)")
        guard finite(anchorFrame), ownerFrames.allSatisfy(finite),
              ownerFrames.allSatisfy({ $0.contains(anchorFrame) && $0.contains(start) && $0.contains(end) }),
              start.y > end.y, anchor.isHittable else { return reject("Unsupported or non-hittable description segment") }
        func clear(_ element: XCUIElement, _ name: String) -> Bool {
            guard element.exists else { log("\(name) disappeared"); return false }
            let r = element.frame
            let intersects = r.minX <= start.x && start.x <= r.maxX && r.minY <= start.y && end.y <= r.maxY
            log("surface \(name) frame=\(r), intersects segment=\(intersects)")
            return finite(r) && !intersects
        }
        for (name, surface) in [("navigation", nav), ("Done", done), ("note", note), ("limits", limits), ("picker", picker), ("Reset", reset)] {
            guard clear(surface, name) else { return reject("Required presented surface obstructs or is unavailable: \(name)") }
        }
        // Inspect controls only in the owned collection; underlying chat shares its Window.
        let controlRoles: [XCUIElement.ElementType] = [.button, .link, .switch, .slider, .stepper, .picker, .pickerWheel,
            .textField, .secureTextField, .textView, .searchField, .segmentedControl]
        for role in controlRoles {
            let controls = collection.descendants(matching: role), count = controls.count
            log("collection control role=\(role.rawValue) count=\(count)")
            guard count <= 32 else { return reject("Unsupported collection control cardinality") }
            for index in 0..<count {
                guard clear(controls.element(boundBy: index), "collection role \(role.rawValue) index \(index)") else {
                    return reject("Exported collection control obstructs or changed")
                }
            }
        }
        let overlays = collection.images.matching(identifier: "AdditionalDimmingOverlay"), overlayCount = overlays.count
        log("known collection dimming overlays=\(overlayCount)")
        guard overlayCount == 2 else { return reject("Unsupported known decoration export shape") }
        for index in 0..<overlayCount {
            guard clear(overlays.element(boundBy: index), "dimming overlay \(index)") else { return reject("Known decoration overlaps or changed") }
        }
        let inputs = [app.keyboards, app.otherElements.matching(identifier: "inputView"), app.otherElements.matching(identifier: "SystemInputAssistantView")]
        let inputCounts = inputs.map { $0.count }
        let inputAnyCounts = ["inputView", "SystemInputAssistantView"].map { app.descendants(matching: .any).matching(identifier: $0).count }
        let alertCount = app.alerts.count
        log("global keyboard/inputView/assistant counts=\(inputCounts), input any-role counts=\(inputAnyCounts), alerts=\(alertCount)")
        guard inputAnyCounts == Array(inputCounts.dropFirst()), alertCount == 0 else { return reject("Unsupported input role or alert presentation") }
        guard inputCounts == [0, 0, 0] || inputCounts == [1, 1, 0] || inputCounts == [1, 1, 1] else {
            return reject("Unsupported full-input export shape")
        }
        for index in inputs.indices where inputCounts[index] == 1 {
            guard clear(inputs[index].element(boundBy: 0), "global input \(index)") else { return reject("Input surface overlaps or changed") }
        }
        checkTimeLeft("before the single context description drag")
        guard let nowPresent = reportPresent() else { return reject("Report export became ambiguous") }
        if nowPresent { return true }
        // No intervening screenshot; reject changed anchor geometry rather than choosing another segment.
        guard anchor.exists, anchor.label == description, anchor.frame == anchorFrame, anchor.isHittable,
              app.frame == appFrame, window.frame == windowFrame, collection.frame == collectionFrame, cell.frame == cellFrame else {
            return reject("Description changed before the one allowed gesture")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: start.x - appFrame.minX, dy: start.y - appFrame.minY))
        let to = origin.withOffset(CGVector(dx: end.x - appFrame.minX, dy: end.y - appFrame.minY))
        log("one upward drag, distance=\(start.y - end.y); public checks are sequential, not a native recipient proof")
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: start.y - end.y), thenHoldForDuration: 0.2)
        capture("after single drag, before unchanged report assertion")
        return true
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
        guard navigateContextDescriptionOnce(app) else { return }
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
