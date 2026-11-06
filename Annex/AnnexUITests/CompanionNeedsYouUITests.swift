import XCTest

@MainActor final class CompanionNeedsYouUITests: ReliableUITestCase {
    private func open(_ scenario: String, largeText: Bool = false) -> XCUIApplication {
        var arguments = ["--companion-preview", "--companion-preview-needs-you"]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        let app = launchApp(arguments,
                            environment: ["COMPANION_NEEDS_YOU_SCENARIO": scenario])
        waitAndTap(app.tabBars.buttons["Needs you"], until: app.navigationBars["Needs you"], timeout: 15)
        return app
    }

    func testOfflineNoticeKeepsReachableRequestAndScopedRetry() {
        let app = open("one-offline")
        let request = app.staticTexts["Needs permission to use Bash"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "Reachable requests appear before availability notices")
        let retry = app.buttons["needs-you-retry-preview-laptop"]
        XCTAssertTrue(scrollUntilExists(retry, in: app))
        XCTAssertEqual(retry.label, "Retry Travel MacBook")
        XCTAssertTrue(app.staticTexts["Travel MacBook is offline"].exists)
        XCTAssertTrue(app.staticTexts["Pending items are unknown until this desktop is ready."].exists)
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        scrollUntilExists(request, in: app, up: false)
        XCTAssertTrue(request.exists, "The reachable desktop's request remains in the flat list")
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you with one offline desktop")
    }

    func testNoReachableDesktopsQualifiesEmptyStateAndKeepsBothRetries() {
        let app = open("all-unavailable", largeText: true)
        let empty = app.staticTexts["No requests to show"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(empty.label, "No requests to show")
        XCTAssertGreaterThan(empty.frame.height, 60, "The full AccessibilityL title must wrap, rather than truncate or shrink to one line on the narrow iPhone")
        attach(app, "Needs you unavailable empty state — AccessibilityL")
        let studioTitle = app.staticTexts["Studio Mac is offline"]
        XCTAssertTrue(revealNoticeElement(studioTitle, in: app))
        XCTAssertEqual(studioTitle.label, "Studio Mac is offline")
        XCTAssertGreaterThan(studioTitle.frame.width, app.frame.width * 0.65, "Accessibility text must use the card width, not a narrow column beside Retry")
        attach(app, "Needs you first unavailable title — AccessibilityL")
        let studio = app.buttons["needs-you-retry-preview-studio"]
        XCTAssertTrue(revealNoticeElement(studio, in: app))
        XCTAssertEqual(studio.label, "Retry Studio Mac")
        attach(app, "Needs you first unavailable desktop — AccessibilityL")
        let laptopTitle = app.staticTexts["Travel MacBook has a connection issue"]
        XCTAssertTrue(revealNoticeElement(laptopTitle, in: app))
        XCTAssertEqual(laptopTitle.label, "Travel MacBook has a connection issue")
        XCTAssertGreaterThan(laptopTitle.frame.width, app.frame.width * 0.65)
        attach(app, "Needs you second unavailable title — AccessibilityL")
        let laptop = app.buttons["needs-you-retry-preview-laptop"]
        XCTAssertTrue(revealNoticeElement(laptop, in: app))
        XCTAssertEqual(laptop.label, "Retry Travel MacBook")
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you second unavailable desktop — AccessibilityL")
    }

    func testConnectionInProgressShowsUnknownWithoutDuplicateRetry() {
        let app = open("progress")
        XCTAssertTrue(app.staticTexts["Looking for Studio Mac…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connecting to Travel MacBook…"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Retry")).count, 0,
                       "No Retry is offered while either desktop is already connecting, regardless of inherited identifiers")
        XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
        XCTAssertFalse(app.staticTexts["All caught up"].exists)
        attach(app, "Needs you while desktops reconnect")
    }

    func testBothOnlineCanShowKnownEmptyState() {
        let app = open("online-empty")
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Nothing is waiting on you."].exists)
        XCTAssertFalse(app.staticTexts["Pending items are unknown until this desktop is ready."].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Retry")).count, 0)
    }

    /// A whole-app fling passed Studio and then kept moving away from it in the retained 375pt recording.
    /// Recheck the current bars and target after each short drag, allowing recovery in either direction.
    private func revealNoticeElement(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = app.collectionViews.firstMatch
        let navigation = app.navigationBars["Needs you"]
        let tabs = app.tabBars.firstMatch
        for gesture in 0...6 {
            checkTimeLeft("revealing a Needs you notice")
            let listFrame = list.frame
            let top = max(listFrame.minY, navigation.frame.maxY) + 12
            let bottom = min(listFrame.maxY, tabs.frame.minY) - 12
            let usable = CGRect(x: listFrame.minX + 8, y: top, width: listFrame.width - 16, height: bottom - top)
            guard usable.width > 0, usable.height > 0 else { break }
            let frame = target.exists ? target.frame : nil
            if let frame, usable.contains(frame) {
                if target.isHittable { return true }
                // A fully visible but inaccessible element needs investigation, not more scrolling.
                break
            }
            guard gesture < 6 else { break }
            let above = frame.map { $0.minY < usable.minY } ?? false
            let distance = min(140, usable.height * 0.35)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: usable.midX, dy: usable.midY + (above ? -distance / 2 : distance / 2)))
            let end = start.withOffset(CGVector(dx: 0, dy: above ? distance : -distance))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: 200), thenHoldForDuration: 0.15)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Needs you reveal failure — accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        attach(app, "Needs you reveal failure")
        return false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
