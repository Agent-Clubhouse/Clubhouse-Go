import XCTest

/// Preview presentation only; no provider CLI or real desktop is contacted.
@MainActor final class CompanionSessionModelUITests: ReliableUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testSessionAndSavedAppearOnlyForProvenDifference() {
        var plainComposerHeight: CGFloat?
        for differs in [false, true] {
            let app = launchApp(["--companion-preview"] + (differs ? ["--companion-preview-model-difference"] : []))
            let row = element(app, "agent-preview-studio-river")
            XCTAssertTrue(scrollTo(row, in: app))
            let composer = element(app, "companion-composer")
            waitAndTap(row, until: composer)
            let region = element(app, "companion-composer-region")
            if let plainComposerHeight {
                XCTAssertEqual(region.frame.height, plainComposerHeight, accuracy: 1, "Model clarity adds no persistent composer height")
            } else {
                plainComposerHeight = region.frame.height
            }
            XCTAssertFalse(text(app, "Session: Opus").exists)
            XCTAssertFalse(text(app, "Saved: Sonnet (next start)").exists)
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

            let model = app.buttons["companion-model-menu"]
            waitAndTap(app.buttons["companion-level-menu"], until: model)
            XCTAssertEqual(model.label, "Model: Opus")
            let sonnet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sonnet,")).firstMatch
            waitAndTap(model, until: sonnet)
            XCTAssertEqual(text(app, "Session: Opus").exists, differs)
            XCTAssertEqual(text(app, "Saved: Sonnet (next start)").exists, differs)
            XCTAssertTrue(text(app, "Model").exists, "The existing model choices remain available")
            capture(app, differs ? "Session and Saved - Model submenu (preview)" : "Plain Model submenu - equal models (preview)")

            // The first tap dismisses the menu; a subsequent tap opens the existing settings route.
            let picker = app.buttons["agent-settings-model"]
            waitAndTap(app.buttons["companion-context-usage"], until: element(app, "agent-settings-summary"))
            XCTAssertTrue(scrollTo(picker, in: app))
            if differs {
                XCTAssertTrue(picker.label.contains("Saved") && picker.label.contains("Sonnet") && picker.label.contains("(next start)"), picker.label)
                XCTAssertTrue(element(app, "agent-settings-model-session").exists)
            } else {
                XCTAssertTrue(picker.label.contains("Model") && picker.label.contains("Opus"), picker.label)
                XCTAssertFalse(element(app, "agent-settings-model-session").exists)
            }
            XCTAssertFalse(picker.isEnabled, "Saved model changes remain locked while running")
            capture(app, differs ? "Session and Saved - Agent settings (preview)" : "Plain Model - Agent settings (preview)")
            app.terminate()
        }
    }
}
