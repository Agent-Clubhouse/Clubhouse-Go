import XCTest

@MainActor final class CompanionLargeCatalogUITests: ReliableUITestCase {
    func testHomeAndRealContextMenuRenderLargeGeneratedCatalog() {
        let app = launchApp(["--companion-preview", "--companion-preview-large-catalog"], attempts: 1)
        let header = app.descendants(matching: .any).matching(identifier: "project-synthetic-host-0-project-0").firstMatch
        XCTAssertTrue(scrollUntilExists(header, in: app) && scrollTo(header, in: app))
        longPressUntilMenu(header, shows: app.buttons["Pin project"])
        XCTAssertTrue(app.buttons["Pin project"].isEnabled && app.buttons["Pin project"].isHittable)
        XCTAssertTrue(app.buttons["Mark inactive"].exists)
        XCTAssertTrue(app.buttons["Project info"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "524 generated large catalog real Home context menu"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
