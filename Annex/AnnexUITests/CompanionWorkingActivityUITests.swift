import XCTest

/// Explicit tool-completion events through the real conversation and footer, with a stationary draft/keyboard.
@MainActor final class CompanionWorkingActivityUITests: ReliableUITestCase {
    func testToolBoundariesKeepWorkingFooterAtStandardText() throws {
        try checkToolBoundaries(accessibility: false)
    }

    func testToolBoundariesKeepWorkingFooterAtLargestText() throws {
        try checkToolBoundaries(accessibility: true)
    }

    private struct Geometry {
        var frames: [String: CGRect] = [:]
        var keyboardTop: CGFloat?
        var activityLabel = ""
    }

    private func geometry(_ app: XCUIApplication) throws -> Geometry {
        let root = try app.snapshot()
        var result = Geometry()
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .keyboard || node.identifier == "SystemInputAssistantView",
               node.frame.intersects(root.frame) {
                result.keyboardTop = min(result.keyboardTop ?? .infinity, node.frame.minY)
            }
            if !node.identifier.isEmpty, result.frames[node.identifier] == nil || node.elementType == .button {
                result.frames[node.identifier] = node.frame
                if node.identifier == "companion-chat-activity" { result.activityLabel = node.label }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return result
    }

    /// Readiness only: two matching atomic snapshots, without repeating a tool event.
    private func settledGeometry(_ app: XCUIApplication) throws -> Geometry {
        let ids = ["companion-chat-activity", "companion-grant-footer-scroll", "companion-pinned-decision",
                   "companion-composer-region", "companion-send"]
        let deadline = Date().addingTimeInterval(5)
        var previous = try geometry(app)
        repeat {
            let current = try geometry(app)
            if current.keyboardTop == previous.keyboardTop && ids.allSatisfy({ current.frames[$0] == previous.frames[$0] }) {
                return current
            }
            previous = current
        } while Date() < deadline
        XCTFail("Activity/footer geometry did not settle")
        return previous
    }

    private func capture(_ app: XCUIApplication, geometry: Geometry, state: String) {
        let frames = geometry.frames.keys.sorted().map { "\($0)=\(geometry.frames[$0]!)" }.joined(separator: "\n")
        let description = "ACTIVITY_GEOMETRY \(state) keyboardTop=\(String(describing: geometry.keyboardTop)) activity=\(geometry.activityLabel)\n\(frames)"
        print(description)
        let text = XCTAttachment(string: description); text.name = "555 geometry \(state)"; text.lifetime = .keepAlways; add(text)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "555 footer \(state)"; image.lifetime = .keepAlways; add(image)
    }

    private func checkToolBoundaries(accessibility: Bool) throws {
        for appearance in ["light", "dark"] {
            var arguments = ["--companion-preview", "--companion-preview-header-fixture",
                             "--companion-header-activity-transitions", "--companion-header-\(appearance)"]
            if accessibility { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            let app = launchApp(arguments, attempts: 1)
            let editor = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            focus(editor, in: app)
            editor.typeText("Keep this draft")
            let next = app.buttons["activity-fixture-next"]
            XCTAssertEqual(next.value as? String, "0")
            let baseline = try settledGeometry(app)
            capture(app, geometry: baseline, state: "\(appearance) AX=\(accessibility) step=0")
            XCTAssertTrue(baseline.activityLabel.contains("Read file"))
            let footer = try XCTUnwrap(baseline.frames["companion-grant-footer-scroll"])
            let activity = try XCTUnwrap(baseline.frames["companion-chat-activity"])
            let tray = try XCTUnwrap(baseline.frames["companion-pinned-decision"])
            let keyboard = try XCTUnwrap(baseline.keyboardTop)
            for step in 1...6 {
                next.tap()
                XCTAssertTrue(NSPredicate(format: "value == %@", String(step)).evaluate(with: next)
                    || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(step)), object: next)], timeout: 5) == .completed)
                let current = try settledGeometry(app)
                let state = "\(appearance) AX=\(accessibility) step=\(step)"
                capture(app, geometry: current, state: state)
                let currentFooter = try XCTUnwrap(current.frames["companion-grant-footer-scroll"])
                print("ACTIVITY_DELTA \(state) footerTop=\(currentFooter.minY-footer.minY) footerHeight=\(currentFooter.height-footer.height) activityHeight=\(String(describing: current.frames["companion-chat-activity"]?.height))")
                XCTAssertEqual(try XCTUnwrap(current.keyboardTop), keyboard, accuracy: 1, "The keyboard stays up across tool events")
                XCTAssertEqual(editor.value as? String, "Keep this draft")
                if step == 6 {
                    XCTAssertNil(current.frames["companion-chat-activity"], "Idle chats reserve no activity line")
                    continue
                }
                let currentActivity = try XCTUnwrap(current.frames["companion-chat-activity"], "Working always keeps an activity line")
                if step == 4 {
                    XCTAssertTrue(current.activityLabel.contains("mcp__clubhouse__message_parent"))
                    // Measure existing multiline tool wrapping separately; do not claim it has a fixed height.
                    print("ACTIVITY_LONG_TOOL \(state) extraHeight=\(currentActivity.height-activity.height) send=\(String(describing: current.frames["companion-send"])) keyboardTop=\(keyboard)")
                    continue
                }
                XCTAssertTrue(current.activityLabel.contains(step == 2 ? "Edit file" : "Working"), current.activityLabel)
                XCTAssertEqual(currentActivity.height, activity.height, accuracy: 1, "Short tool names and gaps use one stable line")
                XCTAssertEqual(currentFooter.minY, footer.minY, accuracy: 1, "Tool completion must not move the footer")
                XCTAssertEqual(currentFooter.height, footer.height, accuracy: 1)
                let currentTray = try XCTUnwrap(current.frames["companion-pinned-decision"])
                XCTAssertEqual(currentTray.minY, tray.minY, accuracy: 1, "The pending tray stays stationary")
                let send = try XCTUnwrap(current.frames["companion-send"])
                XCTAssertLessThan(send.maxY, keyboard, "Actions stay above the keyboard")
            }
            app.terminate()
        }
    }
}
