import XCTest

@MainActor final class CompanionAccessoryUITests: ReliableUITestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testReviewAndSortShareReadableTextAcrossAppearances() {
        let variants: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("Latte", ["--companion-preview-light", "--companion-preview-theme-latte"]),
            ("Mocha", ["--companion-preview-dark", "--companion-preview-theme-mocha"]),
            ("XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in variants {
            let app = launchApp(["--companion-preview", "--companion-preview-start-home"] + flags, allowance: 360, attempts: 1)
            let review = app.buttons.matching(identifier: "companion-open-review").firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 15))
            XCTAssertEqual(review.label, "Review")
            XCTAssertTrue(scrollTo(review, in: app))
            capture(app, "Accessory Home Review \(name)")
            review.tap()
            let close = app.buttons["review-done"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            close.tap()
            let sort = app.buttons["project-sort-menu"]
            XCTAssertTrue(scrollUntilExists(sort, in: app) && scrollTo(sort, in: app))
            XCTAssertEqual(sort.label, "Sort projects, Recent")
            capture(app, "Accessory Project sort \(name)")
            sort.tap()
            let alphabetical = app.buttons["A–Z"]
            XCTAssertTrue(alphabetical.waitForExistence(timeout: 5))
            alphabetical.tap()
            XCTAssertTrue(waitFor(sort, NSPredicate(format: "label == %@", "Sort projects, A–Z"), timeout: 5))
            let needsTab = app.tabBars.buttons["Needs you"]
            if !needsTab.exists || !needsTab.isHittable {
                // Scrolling to Sort can minimize the native bar, especially at XXXL.
                // Tapping its selected Home control expands it just as a user would.
                let collapsedHome = app.tabBars.buttons["Home"]
                XCTAssertTrue(collapsedHome.exists && collapsedHome.isHittable)
                collapsedHome.tap()
            }
            XCTAssertTrue(waitFor(needsTab, NSPredicate { _, _ in needsTab.exists && needsTab.isHittable }, timeout: 5),
                          "Expand the native bar before selecting Needs you")
            needsTab.tap()
            let needsReview = app.buttons["companion-open-review"]
            XCTAssertTrue(needsReview.waitForExistence(timeout: 5))
            XCTAssertEqual(needsReview.label, "Review")
            XCTAssertTrue(needsReview.isHittable)
            capture(app, "Accessory Needs you Review \(name)")
            app.terminate()
        }
    }
}
