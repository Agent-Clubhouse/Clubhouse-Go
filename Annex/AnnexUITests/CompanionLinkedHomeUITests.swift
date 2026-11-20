import XCTest

@MainActor final class CompanionLinkedHomeUITests: ReliableUITestCase {
    private let base = ["--companion-preview", "--companion-preview-linked-projects", "--companion-preview-linked-home-offline"]

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollUntilExists(element, in: app) && scrollTo(element, in: app))
        XCTAssertTrue(element.isHittable)
    }

    private func openHeaderMenu(_ app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        reveal(header, in: app)
        XCTAssertEqual(header.label, "Open Clubhouse")
        XCTAssertEqual(app.buttons.matching(identifier: "open-project-preview-studio-clubhouse").count, 1)
        longPressUntilMenu(header, shows: app.buttons["project-wake"], attempts: 1)
        XCTAssertFalse(app.buttons["project-menu-preview-studio-clubhouse"].exists, "The header has no overflow button")
    }

    func testHeaderLinkTapStillOpensProjectAndPlusKeepsItsMenu() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects"], attempts: 1)
        let link = app.buttons["open-project-preview-studio-clubhouse"]
        reveal(link, in: app)
        XCTAssertEqual(link.label, "Open Clubhouse")
        link.tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5), "An ordinary tap still opens the Project page")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        let plus = app.buttons["project-new-agent-preview-studio-clubhouse"]
        reveal(plus, in: app)
        XCTAssertEqual(plus.label, "New agent in Clubhouse")
        longPressUntilMenu(plus, shows: app.buttons["project-wake"], attempts: 1)
        XCTAssertEqual(app.buttons["project-wake"].label, "Wake with a message")
        XCTAssertTrue(app.buttons["Project info"].exists)
        XCTAssertTrue(app.buttons["Terminal"].exists)
        capture(app, "Home project plus exposes the same named actions without losing its label")
    }

    func testHeaderActionsChooseOneMachineForAllAndSelectedWakeIsDirect() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects"], attempts: 1)
        XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
        openHeaderMenu(app)
        XCTAssertTrue(app.buttons["Project info"].exists)
        app.buttons["project-wake"].tap()
        XCTAssertTrue(app.navigationBars["Choose a desktop"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch.exists)
        let studio = app.buttons["project-machine-choice-preview-studio-clubhouse"]
        let laptop = app.buttons["project-machine-choice-preview-laptop-notes"]
        XCTAssertTrue(studio.isEnabled)
        XCTAssertFalse(laptop.isEnabled, "A desktop with no sleeping agent cannot receive Wake")
        capture(app, "Home All Wake chooses an explicit available machine")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Choose a desktop"].waitForNonExistence(timeout: 5))
        let chip = app.buttons["desktop-chip-host-preview-studio"]
        reveal(chip, in: app)
        chip.tap()
        openHeaderMenu(app)
        app.buttons["project-wake"].tap()
        let message = app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Choose a desktop"].exists)
        XCTAssertTrue(app.buttons["wake-agent-picker"].label.contains("Juniper"))
        capture(app, "Home selected Studio Wake opens only Studio's sleeping agents")
        app.buttons["Cancel"].tap()
    }

    func testHeaderTerminalUsesOneConcreteShellAndInfoRemainsReadOnly() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects"], attempts: 1)
        XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
        openHeaderMenu(app)
        app.buttons["Terminal"].tap()
        XCTAssertTrue(app.navigationBars["Choose a desktop"].waitForExistence(timeout: 5))
        let output = app.descendants(matching: .any).matching(identifier: "terminal-output").firstMatch
        XCTAssertFalse(output.exists, "All never opens an arbitrary member's terminal")
        let studio = app.buttons["project-machine-choice-preview-studio-clubhouse"]
        XCTAssertTrue(studio.isEnabled)
        studio.tap()
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", "clubhouse %"), timeout: 10))
        app.buttons["terminal-done"].tap()
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
        openHeaderMenu(app)
        app.buttons["Project info"].tap()
        XCTAssertTrue(app.navigationBars["Project info"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.switches.count, 0)
        capture(app, "Home project info remains read-only")
    }

    func testOfflineDisclosureIsSessionOnlyAndCachedRowsCannotNavigate() {
        let app = launchApp(base, attempts: 1)
        XCTAssertTrue(app.staticTexts["home-summary"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["home-summary"].label.contains("1 working"), "Cached Laptop Working cannot inflate live counts")
        let offline = app.buttons["project-machine-preview-laptop-notes"]
        let cached = app.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch
        reveal(offline, in: app)
        XCTAssertTrue(offline.label.contains("Travel MacBook not connected · 1 agent"))
        XCTAssertFalse(cached.exists, "Unavailable machines start collapsed regardless of desktop count")
        offline.tap()
        XCTAssertTrue(cached.waitForExistence(timeout: 5))
        XCTAssertTrue(cached.label.contains("cached on Travel MacBook"))
        XCTAssertFalse(app.buttons.matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch.exists, "The cached row has no navigation or menu button")
        XCTAssertFalse(cached.isEnabled)
        XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists)
        capture(app, "Linked Home cached Laptop rows are dimmed and non-actionable")
        XCTAssertEqual(offline.value as? String, "Expanded")
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(waitFor(app.tabBars.buttons["Search"], NSPredicate(format: "selected == true"), timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitFor(app.tabBars.buttons["Home"], NSPredicate(format: "selected == true"), timeout: 5))
        XCTAssertTrue(app.navigationBars["Clubhouse"].waitForExistence(timeout: 5))
        // Home's foreground List is recreated on tab return. Reveal its existing fold without
        // tapping it, so viewport virtualization cannot masquerade as a collapsed disclosure.
        reveal(offline, in: app)
        XCTAssertEqual(offline.value as? String, "Expanded", "The existing disclosure must survive tab changes; do not expand it again")
        XCTAssertTrue(scrollUntilExists(cached, in: app), "Materialize the disabled cached row without requiring a hit target")
        XCTAssertTrue(cached.exists, "Expansion survives tab changes for this session")
        XCTAssertFalse(cached.isEnabled)
        XCTAssertFalse(app.buttons.matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch.exists)
        capture(app, "Linked Home returned session retains the expanded read-only cached row")
        app.terminate()
        let relaunched = launchApp(base, attempts: 1)
        let collapsed = relaunched.buttons["project-machine-preview-laptop-notes"]
        reveal(collapsed, in: relaunched)
        XCTAssertEqual(collapsed.value as? String, "Collapsed", "A new app session must reset the native disclosure state")
        XCTAssertFalse(relaunched.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch.exists,
                       "Expansion is never persisted across launches")
        capture(relaunched, "Linked Home offline machine starts collapsed after relaunch")
    }

    func testCachedRowsScrollClearOfFloatingTabBarAtStandardAndXXXL() {
        for accessibility in [false, true] {
            for desktops in [2, 5] {
                let extra = desktops == 5 ? ["--companion-preview-home-five-desktops"] : []
                let size = accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
                let app = launchApp(base + ["--companion-preview-light"] + extra + size, allowance: 180, attempts: 1)
                let offline = app.buttons["project-machine-preview-laptop-notes"]
                reveal(offline, in: app)
                offline.tap()
                let cached = app.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch
                XCTAssertTrue(cached.waitForExistence(timeout: 5))
                XCTAssertFalse(cached.isEnabled)
                for _ in 0..<8 {
                    if cached.frame.maxY <= app.tabBars.firstMatch.frame.minY { break }
                    app.swipeUp(velocity: .slow)
                }
                XCTAssertLessThanOrEqual(cached.frame.maxY, app.tabBars.firstMatch.frame.minY,
                                         "The last cached row must scroll fully above the native floating tab bar")
                capture(app, "Cached River clears floating tab bar \(desktops) desktops \(accessibility ? "XXXL" : "standard")")
                app.terminate()
            }
        }
    }

    func testLinkedCardFiveAppearancesWithTwoAndFiveDesktops() {
        let variants: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("accessibility XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in variants {
            for desktops in [2, 5] {
                let extra = desktops == 5 ? ["--companion-preview-home-five-desktops"] : []
                let app = launchApp(base + ["--companion-preview-linked-home-seen"] + extra + flags, allowance: 360, attempts: 1)
                XCTAssertTrue(app.buttons["desktop-chip-all"].waitForExistence(timeout: 15))
                if name == "accessibility XXXL" {
                    let sort = app.buttons["project-sort-menu"]
                    reveal(sort, in: app)
                    XCTAssertEqual(sort.label, "Sort projects, Recent")
                    XCTAssertTrue(app.staticTexts["Projects"].isHittable)
                    capture(app, "Linked Home \(desktops) desktops readable Projects and sort XXXL")
                }
                let offline = app.buttons["project-machine-preview-laptop-notes"]
                reveal(offline, in: app)
                XCTAssertTrue(offline.label.contains("Travel MacBook offline, seen"))
                XCTAssertTrue(offline.label.contains("· 1 agent"))
                assertMinimumTarget(offline, "Offline machine disclosure")
                XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch.exists)
                capture(app, "Linked Home \(desktops) desktops collapsed \(name)")
                offline.tap()
                let cached = app.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch
                XCTAssertTrue(cached.waitForExistence(timeout: 5))
                XCTAssertFalse(cached.isEnabled)
                XCTAssertFalse(app.buttons.matching(identifier: "agent-preview-laptop-river").firstMatch.exists)
                XCTAssertTrue(scrollTo(cached, in: app))
                capture(app, "Linked Home \(desktops) desktops expanded \(name)")
                app.terminate()
            }
        }
    }
}
