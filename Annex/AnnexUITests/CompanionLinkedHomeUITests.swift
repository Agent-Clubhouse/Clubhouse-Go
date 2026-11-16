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
        app.tabBars.buttons["Search"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(cached.exists, "Expansion survives tab changes for this session")
        app.terminate()
        let relaunched = launchApp(base, attempts: 1)
        let collapsed = relaunched.buttons["project-machine-preview-laptop-notes"]
        reveal(collapsed, in: relaunched)
        XCTAssertFalse(relaunched.descendants(matching: .any).matching(identifier: "cached-agent-preview-laptop-notes-river").firstMatch.exists,
                       "Expansion is never persisted across launches")
        capture(relaunched, "Linked Home offline machine starts collapsed after relaunch")
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
