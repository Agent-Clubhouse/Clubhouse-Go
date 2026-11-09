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

    private func focusComposer(_ app: XCUIApplication, typing text: String) {
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
        composer.typeText(text)
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
        XCTAssertTrue(identity.label.contains("Access: "), identity.label)
        XCTAssertFalse(details.exists, "Status and permission details start collapsed")
        assertMinimumTarget(identity, "identity")
        XCTAssertTrue(context.isHittable)
        assertMinimumTarget(context, "context usage")
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
        XCTAssertTrue(element(app, "companion-context-report").exists, "Context still opens its reported details")
        XCTAssertEqual(element(app, "companion-context-reading-note").label, "Latest reported context usage")
        let limits = app.buttons["companion-context-plan-limits"]
        XCTAssertTrue(limits.isHittable)
        assertMinimumTarget(limits, "plan limits", width: 0)
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
        XCTAssertTrue(status.label.contains("Access: "), status.label)
        XCTAssertTrue(context.isHittable, "The large-text header keeps usage reachable before editing")
        XCTAssertFalse(element(app, "companion-chat-details").exists)

        focusComposer(app, typing: "Header draft")
        XCTAssertTrue(context.isHittable, "Usage remains reachable while editing without an expanded status row")
        XCTAssertTrue(status.label.contains("Access: "), status.label)
        let actions = app.buttons["conversation-actions-menu"]
        waitAndTap(actions, until: app.buttons["companion-context-settings-menu"])
        waitAndTap(app.buttons["companion-context-settings-menu"], until: app.buttons["agent-settings-context-window"])
        // At accessibility sizes the report can sit below the context picker; the form scrolls to it.
        let report = element(app, "companion-context-report")
        XCTAssertTrue(scrollUntilExists(report, in: app, maxSwipes: 3, wait: 1), "Context stays available through conversation actions")
    }

    func testUnknownContextStillOffersDesktopPlanLimits() {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher"])
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 15))
        let usage = app.buttons["companion-context-settings"]
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
        waitAndTap(usage, until: element(app, "companion-context-reading-note"), attempts: 1)
        waitAndTap(app.buttons["companion-context-plan-limits"], until: app.navigationBars["Plan limits"], attempts: 1)
    }
}
