import XCTest

@MainActor final class CompanionCombinedLinkedHomeUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-combined-linked-home"]
    private let foldID = "fold-quiet-link:combined-home"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollUntilExists(element, in: app) && scrollTo(element, in: app))
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "536 \(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testCombinedActiveTreesAndQuietFoldLightDarkAndXXXL() {
        let appearances: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in appearances {
            let app = launchApp(arguments + flags, allowance: 360, attempts: 1)
            XCTAssertTrue(app.staticTexts["home-summary"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["home-summary"].label.contains("2 working"), "Offline cached Working cannot inflate the count")
            let river = element(app, "agent-combined-1-root")
            reveal(river, in: app)
            XCTAssertTrue(river.label.contains("River") && river.label.contains("Travel MacBook"))
            let willow = element(app, "agent-combined-1-helper")
            reveal(willow, in: app)
            XCTAssertTrue(willow.label.contains("Willow") && willow.label.contains("Travel MacBook"))
            XCTAssertTrue((willow.value as? String)?.contains("Helper of River") == true)
            XCTAssertLessThan(river.frame.minY, willow.frame.minY)
            capture(app, "combined active origin badges \(name)")
            let cedar = element(app, "agent-combined-0-root")
            reveal(cedar, in: app)
            XCTAssertTrue(cedar.label.contains("Cedar") && cedar.label.contains("Studio Mac"))
            let fern = element(app, "agent-combined-0-helper")
            reveal(fern, in: app)
            XCTAssertTrue((fern.value as? String)?.contains("Helper of Cedar") == true)
            XCTAssertFalse(element(app, "project-machine-combined-0-project").exists, "Live machine subheaders no longer split the active list")
            XCTAssertFalse(element(app, "project-machine-combined-2-project").exists, "A quiet-only machine contributes to the one quiet fold")
            let fold = app.buttons[foldID]
            reveal(fold, in: app)
            XCTAssertEqual(app.buttons.matching(identifier: foldID).count, 1)
            XCTAssertTrue(fold.label.contains("1 sleeping") && fold.label.contains("3 finished quick agents"))
            XCTAssertEqual(fold.value as? String, "Collapsed")
            assertMinimumTarget(fold, "Combined quiet fold")
            capture(app, "one collapsed quiet section \(name)")
            fold.tap()
            let juniper = element(app, "agent-combined-2-sleeper")
            reveal(juniper, in: app)
            XCTAssertTrue(juniper.label.contains("Juniper") && juniper.label.contains("Archive Mac"))
            let ash = element(app, "finished-combined-2-project-finished")
            reveal(ash, in: app)
            XCTAssertTrue(ash.label.contains("Ash") && ash.label.contains("Archive Mac"))
            XCTAssertTrue(scrollUntilExists(app.buttons["finished-clear-all"], in: app))
            capture(app, "expanded quiet origins \(name)")
            app.terminate()
        }
    }

    func testSingleDesktopScopeHidesOriginAndQuietOnlyScopeKeepsItsRows() {
        let app = launchApp(arguments, attempts: 1)
        let travel = app.buttons["desktop-chip-host-combined-1"]
        XCTAssertTrue(travel.waitForExistence(timeout: 15)); travel.tap()
        let river = element(app, "agent-combined-1-root")
        reveal(river, in: app)
        XCTAssertFalse(river.label.contains("Travel MacBook"))
        XCTAssertFalse(element(app, "agent-combined-0-root").exists)
        XCTAssertTrue(app.staticTexts["home-summary"].label.contains("1 working"))
        let quietChip = app.buttons["desktop-chip-host-combined-2"]
        let chips = app.scrollViews["desktop-chips"]
        for _ in 0..<4 { if quietChip.isHittable { break }; chips.swipeLeft() }
        XCTAssertTrue(quietChip.isHittable); quietChip.tap()
        let quiet = app.buttons["fold-quiet-combined-2-project"]
        reveal(quiet, in: app)
        XCTAssertTrue(quiet.label.contains("1 sleeping") && quiet.label.contains("1 finished quick agent"))
        XCTAssertFalse(element(app, "agent-combined-1-root").exists)
        quiet.tap()
        let juniper = element(app, "agent-combined-2-sleeper")
        reveal(juniper, in: app)
        XCTAssertTrue(juniper.label.contains("Juniper"))
        XCTAssertFalse(juniper.label.contains("Archive Mac"))
        capture(app, "quiet-only single desktop scope has no redundant badges")
    }

    func testOfflineDisclosureKeepsCachedRowsNonActionable() {
        let app = launchApp(arguments, attempts: 1)
        let offline = app.buttons["project-machine-combined-3-project"]
        reveal(offline, in: app)
        XCTAssertTrue(offline.label.contains("Offline Mac not connected · 1 agent"))
        let cached = element(app, "cached-agent-combined-3-project-root")
        XCTAssertFalse(cached.exists)
        offline.tap()
        XCTAssertTrue(scrollUntilExists(cached, in: app) && scrollTo(cached, in: app))
        XCTAssertTrue(cached.label.contains("cached on Offline Mac"))
        XCTAssertFalse(cached.isEnabled)
        XCTAssertFalse(app.buttons["agent-combined-3-root"].exists)
        capture(app, "offline cached disclosure remains separate and non-actionable")
    }

    func testDismissThenClearAffectOnlyRetainedRunsAcrossMachines() {
        let app = launchApp(arguments, attempts: 1)
        let fold = app.buttons[foldID]
        reveal(fold, in: app); fold.tap()
        let maple = element(app, "finished-combined-0-project-finished")
        reveal(maple, in: app)
        maple.swipeLeft()
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5)); dismiss.tap()
        XCTAssertTrue(maple.waitForNonExistence(timeout: 5))
        let birch = element(app, "finished-combined-1-project-finished")
        XCTAssertTrue(scrollUntilExists(birch, in: app))
        let clear = app.buttons["finished-clear-all"]
        reveal(clear, in: app); clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        XCTAssertFalse(birch.exists)
        XCTAssertFalse(element(app, "finished-combined-2-project-finished").exists)
        let juniper = element(app, "agent-combined-2-sleeper")
        reveal(juniper, in: app)
        XCTAssertTrue(juniper.label.contains("Archive Mac"), "Clearing finished history keeps the sleeping agent and its origin")
        capture(app, "one quiet fold keeps sleeping rows after Dismiss and Clear")
    }
}
