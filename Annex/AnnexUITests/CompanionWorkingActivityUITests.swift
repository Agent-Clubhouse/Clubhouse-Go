import XCTest

/// Explicit tool-completion events through the real conversation and footer, with a stationary draft/keyboard.
@MainActor final class CompanionWorkingActivityUITests: ReliableUITestCase {
    func testToolBoundariesKeepWorkingFooterAtStandardText() throws {
        try checkToolBoundaries(accessibility: false)
    }

    func testToolBoundariesKeepWorkingFooterAtLargestText() throws {
        try checkToolBoundaries(accessibility: true)
        try checkMinimumFloorBoundaries()
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
            editor.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(editor.debugDescription.contains("Keyboard Focused"), "One tap focuses the draft")
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
                    XCTAssertEqual(currentActivity.height, activity.height, accuracy: 1, "Long tool names truncate to the same one-line height")
                    XCTAssertEqual(currentFooter.minY, footer.minY, accuracy: 1)
                    XCTAssertEqual(currentFooter.height, footer.height, accuracy: 1)
                    // Full tool text remains in accessibility despite visual tail truncation.
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

    /// Image + one native editor line + fixed actions expose the SE AX floor. Requests add only
    /// their minimum Review target; without requests that height is zero and the line can fit.
    private func checkMinimumFloorBoundaries() throws {
        for hasRequests in [true, false] {
            for appearance in ["light", "dark"] {
                var arguments = ["--companion-preview", "--companion-preview-header-fixture",
                                 "--companion-header-activity-transitions", "--companion-header-\(appearance)",
                                 "--companion-sample-images", "-UIPreferredContentSizeCategoryName",
                                 "UICTContentSizeCategoryAccessibilityXXXL"]
                if !hasRequests { arguments += ["--companion-header-activity-no-requests"] }
                let app = launchApp(arguments, attempts: 1)
                let editor = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 10))
                let image = app.descendants(matching: .any).matching(identifier: "companion-attachment-thumbnail").firstMatch
                waitAndTap(app.buttons["companion-attach"], until: image, attempts: 1)
                editor.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                editor.typeText("Keep direction")
                let baseline = try settledGeometry(app)
                let state = "floor \(appearance) requests=\(hasRequests)"
                capture(app, geometry: baseline, state: "\(state) step=0")
                let region = try XCTUnwrap(baseline.frames["companion-composer-region"])
                let send = try XCTUnwrap(baseline.frames["companion-send"])
                let keyboard = try XCTUnwrap(baseline.keyboardTop)
                let review = app.buttons["companion-review-approval"]
                let reviewFrame = hasRequests ? try XCTUnwrap(baseline.frames["companion-review-approval"]) : nil
                let omitsLine = app.frame.width <= 375 && app.frame.height <= 667 && hasRequests
                print("ACTIVITY_FLOOR_BRANCH \(state) omitted=\(omitsLine) window=\(app.frame) composer=\(region) keyboard=\(keyboard)")
                if omitsLine { XCTAssertNil(baseline.frames["companion-chat-activity"]) }
                else { XCTAssertTrue(baseline.activityLabel.contains("Read file")) }
                if hasRequests { XCTAssertTrue(review.exists && review.isHittable) }
                else { XCTAssertNil(baseline.frames["companion-pinned-decision"]) }
                XCTAssertLessThan(region.maxY, keyboard)
                let next = app.buttons["activity-fixture-next"]
                for step in 1...6 {
                    next.tap()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", String(step)), object: next)], timeout: 5), .completed)
                    let current = try settledGeometry(app)
                    capture(app, geometry: current, state: "\(state) step=\(step)")
                    XCTAssertEqual(editor.value as? String, "Keep direction")
                    XCTAssertEqual(try XCTUnwrap(current.keyboardTop), keyboard, accuracy: 1)
                    let currentRegion = try XCTUnwrap(current.frames["companion-composer-region"])
                    let currentSend = try XCTUnwrap(current.frames["companion-send"])
                    for pair in [(currentRegion, region), (currentSend, send)] {
                        XCTAssertEqual(pair.0.minY, pair.1.minY, accuracy: 1)
                        XCTAssertEqual(pair.0.height, pair.1.height, accuracy: 1)
                    }
                    XCTAssertLessThan(currentRegion.maxY, keyboard)
                    if step < 6 {
                        XCTAssertTrue(app.buttons["companion-chat-header"].label.contains("Working"), "The header retains working status")
                        if step == 4 {
                            XCTAssertTrue(app.buttons["companion-chat-header"].label.contains("mcp__clubhouse__message_parent"), "Header accessibility keeps the full tool name")
                        }
                    }
                    if omitsLine || step == 6 { XCTAssertNil(current.frames["companion-chat-activity"]) }
                    else { XCTAssertNotNil(current.frames["companion-chat-activity"]) }
                    if hasRequests && (omitsLine || step < 6) {
                        XCTAssertTrue(review.isEnabled && review.isHittable)
                        let frame = try XCTUnwrap(current.frames["companion-review-approval"])
                        XCTAssertEqual(frame.minY, try XCTUnwrap(reviewFrame).minY, accuracy: 1)
                        XCTAssertEqual(frame.height, try XCTUnwrap(reviewFrame).height, accuracy: 1)
                        XCTAssertLessThanOrEqual(frame.maxY, currentRegion.minY)
                    }
                }
                app.terminate()
            }
        }
    }

}
