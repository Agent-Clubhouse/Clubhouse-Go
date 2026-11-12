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
            XCTAssertEqual(model.label, "Opus")
            let sonnet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sonnet")).firstMatch
            waitAndTap(model, until: sonnet)
            capture(app, differs ? "Session and Saved - Model submenu (preview)" : "Plain Model submenu - equal models (preview)")
            XCTAssertEqual(text(app, "Session: Opus").exists, differs)
            XCTAssertEqual(text(app, "Saved: Sonnet (next start)").exists, differs)
            if differs {
                for label in ["Session: Opus", "Saved: Sonnet (next start)"] {
                    let frame = text(app, label).frame
                    XCTAssertFalse(frame.isEmpty, label)
                    XCTAssertTrue(app.frame.contains(frame), label)
                    XCTAssertLessThanOrEqual(frame.maxY, app.keyboards.firstMatch.frame.minY, "\(label) is visible above the keyboard")
                }
            }
            XCTAssertTrue(text(app, "Model").exists, "The existing model choices remain available")

            // The menu makes toolbar elements non-hittable; dismiss outside it before using the toolbar.
            let ring = app.buttons["companion-context-usage"]
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: ring.frame.midX, dy: ring.frame.midY)).tap()
            XCTAssertTrue(sonnet.waitForNonExistence(timeout: 5))
            let picker = app.buttons["agent-settings-model"]
            waitAndTap(ring, until: element(app, "companion-context-reading-note"))
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
