import XCTest

@MainActor final class CompanionNeedsYouActionCardUITests: ReliableUITestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testActionHeadlineAlignedMetadataAndVisibleReview() {
        let app = launchApp(["--companion-preview"], attempts: 1)
        waitAndTap(app.tabBars.buttons["Needs you"], until: app.staticTexts["Run xcodebuild"], timeout: 15, attempts: 1)
        let action = app.staticTexts["attention-action-agent:preview-studio:clubhouse:river"]
        XCTAssertEqual(action.label, "Run xcodebuild")
        XCTAssertFalse(app.staticTexts["Needs permission to use Bash"].exists)
        let tool = app.staticTexts["attention-tool-agent:preview-studio:clubhouse:river"]
        let countdown = app.descendants(matching: .any).matching(identifier: "companion-approval-countdown").firstMatch
        XCTAssertTrue(tool.exists && countdown.exists)
        XCTAssertLessThan(abs(tool.frame.midY - countdown.frame.midY), 6)
        XCTAssertLessThan(countdown.frame.minX - tool.frame.maxX, 40)
        XCTAssertTrue(app.buttons["Deny"].exists && app.buttons["Allow once"].exists)
        assertMinimumTarget(app.buttons["Deny"], "Deny")
        assertMinimumTarget(app.buttons["Allow once"], "Allow once")
        let review = app.navigationBars["Needs you"].buttons["companion-open-review"]
        XCTAssertEqual(review.label, "Review")
        XCTAssertTrue(review.isHittable)
        XCTAssertTrue(app.navigationBars["Needs you"].staticTexts.matching(NSPredicate(format: "label CONTAINS '1 request' AND label CONTAINS 'Travel MacBook offline'")).firstMatch.exists)
        capture(app, "Needs you action-first card and text Review")
    }

    func testSeveralRequestsAndDesktopsAppearanceMatrix() {
        // Light and XXXL every push; the dark and Catppuccin themes repeat Light's checks for their screenshots.
        let variants: [(String, [String])] = appearanceMatrix([
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Catppuccin Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Catppuccin Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ], everyPush: { ["light", "accessibility XXXL"].contains($0.0) })
        for (name, flags) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-home-five-desktops", "--companion-preview-needs-you-multiple-desktops"] + flags, allowance: 360, attempts: 1)
            waitAndTap(app.tabBars.buttons["Needs you"], until: app.navigationBars["Needs you"], timeout: 15, attempts: 1)
            if name == "accessibility XXXL" {
                XCTAssertTrue(app.navigationBars["Needs you"].staticTexts["2 requests"].waitForExistence(timeout: 10))
                let summary = app.staticTexts["needs-you-availability-summary"]
                XCTAssertTrue(summary.waitForExistence(timeout: 10))
                XCTAssertEqual(summary.label, "2 desktops not connected")
                XCTAssertTrue(summary.isHittable, "Availability is a visible scrolling row, not a clipped native subtitle line")
                XCTAssertTrue(app.frame.contains(summary.frame), "The entire wrapping summary fits on screen")
            } else {
                XCTAssertTrue(app.navigationBars["Needs you"].staticTexts.matching(NSPredicate(format: "label CONTAINS '2 requests' AND label CONTAINS '2 desktops not connected'")).firstMatch.waitForExistence(timeout: 10))
                XCTAssertFalse(app.staticTexts["needs-you-availability-summary"].exists)
            }
            capture(app, "Needs you several requests \(name)")
            let laptopAction = app.staticTexts["attention-action-agent:preview-laptop:notes:river"]
            XCTAssertTrue(scrollUntilExists(laptopAction, in: app) && scrollTo(laptopAction, in: app))
            XCTAssertTrue(waitFor(laptopAction, NSPredicate(format: "label == 'Run xcodebuild'"), timeout: 5))
            capture(app, "Needs you second desktop request \(name)")
            if name == "accessibility XXXL" {
                let deny = app.buttons["attention-deny-agent:preview-laptop:notes:river"]
                let allow = app.buttons["attention-allow-agent:preview-laptop:notes:river"]
                XCTAssertTrue(scrollUntilExists(allow, in: app) && scrollTo(allow, in: app))
                XCTAssertEqual(deny.label, "Deny")
                XCTAssertEqual(allow.label, "Allow once")
                XCTAssertGreaterThan(deny.frame.width, app.frame.width * 0.65, "Deny gets a full row so its word does not break")
                XCTAssertGreaterThan(allow.frame.width, app.frame.width * 0.65, "Allow once gets a full row at XXXL")
                XCTAssertGreaterThanOrEqual(allow.frame.minY, deny.frame.maxY)
                assertMinimumTarget(deny, "Deny")
                assertMinimumTarget(allow, "Allow once")
                capture(app, "Needs you readable XXXL decision buttons")
            }
            let reconnect = app.staticTexts["Their requests show up when they reconnect."]
            XCTAssertTrue(scrollUntilExists(reconnect, in: app) && scrollTo(reconnect, in: app))
            XCTAssertFalse(app.staticTexts["Cached offline request"].exists)
            capture(app, "Needs you offline section \(name)")
            app.terminate()
        }
    }
}
