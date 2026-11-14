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

    func testPermissionsAndEffortOrderingDoNotChangeWhenModelsDiffer() {
        var plain: [[String]] = []
        for differs in [false, true] {
            var actual: [[String]] = []
            for menu in ["companion-permissions-menu", "companion-effort-menu"] {
                let app = launchApp(["--companion-preview"] + (differs ? ["--companion-preview-model-difference"] : []))
                let row = element(app, "agent-preview-studio-river")
                XCTAssertTrue(scrollTo(row, in: app))
                let composer = element(app, "companion-composer")
                waitAndTap(row, until: composer)
                composer.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                waitAndTap(app.buttons["companion-level-menu"], until: app.buttons[menu])
                let labels: [String]
                if menu == "companion-permissions-menu" {
                    labels = ["companion-level-plan", "companion-level-ask", "companion-level-auto_edit", "companion-level-auto", "companion-level-full_access"]
                    waitAndTap(app.buttons[menu], until: app.buttons[labels[0]])
                } else {
                    labels = ["Default", "Low", "Medium", "High", "Extra high"]
                    waitAndTap(app.buttons[menu], until: app.buttons["Low"])
                }
                let buttons = labels.map { label in
                    menu == "companion-permissions-menu" ? app.buttons[label] :
                        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
                }
                XCTAssertTrue(buttons.allSatisfy(\.exists))
                actual.append(buttons.sorted { $0.frame.midY < $1.frame.midY }.map(\.label))
                capture(app, "Menu ordering \(menu), models \(differs ? "different" : "equal")")
                app.terminate()
            }
            if differs { XCTAssertEqual(actual, plain, "Session/Saved rows must not reorder sibling menus") }
            else { plain = actual }
        }
    }

    func testSessionAndSavedAppearOnlyForProvenDifference() {
        var plainComposerHeight: CGFloat?
        for (arguments, differs, savedLabel): ([String], Bool, String) in [
            ([], false, "Opus"),
            (["--companion-preview-model-difference"], true, "Sonnet"),
            (["--companion-preview-start-model"], true, "claude-sonnet-5-5"),
            (["--companion-preview-model-alias"], false, "claude-opus-5-5")
        ] {
            let app = launchApp(["--companion-preview"] + arguments)
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
            XCTAssertFalse(text(app, "Saved: \(savedLabel) (next start)").exists)
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

            let model = app.buttons["companion-model-menu"]
            waitAndTap(app.buttons["companion-level-menu"], until: model)
            XCTAssertEqual(model.label, "Opus")
            let sonnet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sonnet")).firstMatch
            waitAndTap(model, until: sonnet)
            capture(app, differs ? "Session and Saved - Model submenu (preview)" : "Plain Model submenu - equal models (preview)")
            let status = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", "Session: Opus", "Saved: \(savedLabel) (next start)"
            )).firstMatch
            XCTAssertEqual(status.exists, differs, app.debugDescription)
            if differs {
                let frame = status.frame
                XCTAssertFalse(frame.isEmpty)
                XCTAssertTrue(app.frame.contains(frame))
                XCTAssertLessThanOrEqual(frame.maxY, app.keyboards.firstMatch.frame.minY, "Both model status lines are visible above the keyboard")
            } else {
                XCTAssertTrue(text(app, "Model").exists)
            }
            XCTAssertTrue(sonnet.exists, "The existing model choices remain available")

            // The menu makes toolbar elements non-hittable; dismiss outside it before using the toolbar.
            let ring = app.buttons["companion-context-usage"]
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: ring.frame.midX, dy: ring.frame.midY)).tap()
            XCTAssertTrue(sonnet.waitForNonExistence(timeout: 5))
            let picker = app.buttons["agent-settings-model"]
            waitAndTap(ring, until: element(app, "companion-context-reading-note"))
            XCTAssertTrue(scrollTo(picker, in: app))
            if differs {
                XCTAssertTrue(picker.label.contains("Saved") && picker.label.contains(savedLabel) && picker.label.contains("(next start)"), picker.label)
                XCTAssertTrue(element(app, "agent-settings-model-session").exists)
            } else {
                XCTAssertTrue(picker.label.contains("Model") && picker.label.contains(savedLabel), picker.label)
                XCTAssertFalse(element(app, "agent-settings-model-session").exists)
            }
            XCTAssertFalse(picker.isEnabled, "Saved model changes remain locked while running")
            capture(app, differs ? "Session and Saved - Agent settings (preview)" : "Plain Model - Agent settings (preview)")
            app.terminate()
        }
    }
}
