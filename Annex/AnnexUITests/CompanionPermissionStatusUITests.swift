import XCTest

@MainActor final class CompanionPermissionStatusUITests: ReliableUITestCase {
    func testPendingPermissionHasOneStateAndFullToolNameAtNarrowWidth() {
        checkPendingPermission(accessibility: false)
    }

    func testPendingPermissionKeepsFullAccessibilityText() {
        checkPendingPermission(accessibility: true)
    }

    private func checkPendingPermission(accessibility: Bool) {
        var arguments = ["--companion-preview", "--companion-preview-start-home"]
        if accessibility {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        let app = launchApp(arguments, attempts: 1)
        let row = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        row.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // Loading River supplies its real pending Bash approval; the catalog has no tool.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-review-approval").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        XCTAssertTrue(row.label.contains("Needs permission · Bash"), row.label)
        XCTAssertEqual(row.label.components(separatedBy: "Needs permission").count - 1, 1, row.label)
        XCTAssertTrue(row.isHittable)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "573 Home permission row \(accessibility ? "XXXL" : "standard")"; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "573 Home permission row AX \(accessibility ? "XXXL" : "standard")"; tree.lifetime = .keepAlways; add(tree)
    }
}
