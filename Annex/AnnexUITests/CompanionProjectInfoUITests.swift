import XCTest

@MainActor final class CompanionProjectInfoUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openInfo(linked: Bool) -> XCUIApplication {
        var arguments = ["--companion-preview", "--companion-preview-start-home"]
        if linked { arguments.append("--companion-preview-linked-projects") }
        let app = launchApp(arguments, attempts: 1)
        let project = element(app, "open-project-preview-studio-clubhouse")
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        waitAndTap(project, until: app.buttons["project-page-options"], attempts: 1)
        waitAndTap(app.buttons["project-page-options"], until: app.buttons["Project info"], attempts: 1)
        waitAndTap(app.buttons["Project info"], until: app.navigationBars["Project info"], attempts: 1)
        return app
    }

    func testSingleProjectInfoShowsDefaultsWithoutEditors() {
        let app = openInfo(linked: false)
        let access = element(app, "project-info-access-preview-studio-clubhouse")
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertTrue(access.label.contains("Ask first"), access.label)
        let mcp = element(app, "project-info-mcp-preview-studio-clubhouse")
        XCTAssertTrue(mcp.label.contains("GitHub"), mcp.label)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.switches.count, 0)
        XCTAssertFalse(app.buttons["Save"].exists)
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Change these project settings on your desktop."], in: app))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Single project info — read only"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.navigationBars["Project info"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 5))
    }

    func testLinkedProjectInfoKeepsEachDesktopAndDoesNotInventUnsupportedDefaults() {
        let app = openInfo(linked: true)
        XCTAssertTrue(app.staticTexts["2 linked desktops"].waitForExistence(timeout: 5))
        let access = element(app, "project-info-access-preview-studio-clubhouse")
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertTrue(access.label.contains("Ask first"), access.label)
        let laptop = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Travel MacBook")).firstMatch
        XCTAssertTrue(scrollUntilExists(laptop, in: app) && scrollTo(laptop, in: app))
        XCTAssertFalse(element(app, "project-info-access-preview-laptop-notes").exists)
        XCTAssertFalse(element(app, "project-info-mcp-preview-laptop-notes").exists)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.switches.count, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Linked project info — separate desktops"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
