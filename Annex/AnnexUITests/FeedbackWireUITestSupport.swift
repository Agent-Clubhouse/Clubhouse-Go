import XCTest
import UIKit

/// Wire-fixture helpers shared by the Feedback UI test classes. Each class still inherits
/// ReliableUITestCase directly, so UI class discovery and lane routing see it. No tests here.
protocol FeedbackWireUITesting {}

extension FeedbackWireUITesting where Self: ReliableUITestCase {
    @MainActor func launch(image: Bool = false) -> XCUIApplication {
        let app = launchApp(["--framebriar-shake-ui-testing", "--framebriar-wire-ui-testing"] + (image ? ["--framebriar-wire-image"] : []))
        XCTAssertTrue(app.buttons["fixture-shake"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor func wire(_ app: XCUIApplication) throws -> [String: Any] {
        let text = app.staticTexts["fixture-wire-summary"]
        XCTAssertTrue(scrollUntilExists(text, in: app, maxSwipes: 8, wait: 0.3))
        return try JSONSerialization.jsonObject(with: Data(text.label.utf8)) as! [String: Any]
    }
    @MainActor func menu(_ app: XCUIApplication, captureMenu: ((CGRect, Data) -> Void)? = nil) {
        let menu = app.buttons["fixture-feedback-menu"]
        XCTAssertTrue(scrollTo(menu, in: app, up: false, maxSwipes: 6))
        menu.tap()
        let send = app.buttons["Send feedback"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        if let captureMenu { captureMenu(send.frame, app.screenshot().pngRepresentation) }
        send.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 5))
    }
    /// Keep taps between the SDK's pinned summary and navigation bars, including at accessibility sizes.
    @MainActor func revealComposerElement(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        // Observation only (#620 L2 stall): the form's first row is read before each drag, so
        // consecutive entries show whether each drag moved the form. The search is unchanged.
        var movement: [String] = []
        var reference: XCUIElement?
        for attempt in 0..<16 {
            var top = app.navigationBars["Send feedback"].frame.maxY
            for id in ["framebriar-error", "framebriar-send-reason"] where app.staticTexts[id].exists {
                top = max(top, app.staticTexts[id].frame.maxY)
            }
            let explanation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Start your note with ‘Diagnostics test’")).firstMatch
            if explanation.exists { top = max(top, explanation.frame.maxY) }
            let bottom = app.staticTexts["framebriar-included"].frame.minY
            if element.exists, element.frame.midY > top + 10, element.frame.midY < bottom - 10 { break }
            let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.maxX - 12, dy: (top + bottom) / 2))
            let delta: CGFloat = element.exists ? (element.frame.midY < top + 10 ? 110 : -110) : (attempt < 8 ? -110 : 110)
            let row = form.cells.firstMatch
            reference = row
            movement.append("before drag \(attempt + 1) delta=\(delta) band=\(top)...\(bottom) reference=\(probedFrame(row)) target=\(probedFrame(element))")
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
        let hittable = element.isHittable
        if !hittable {
            movement.append("final reference=\(reference.map(probedFrame) ?? "none") target=\(probedFrame(element))")
            attachMovement(movement, named: "Feedback composer reveal drag movement")
        }
        XCTAssertTrue(hittable)
        return element
    }
    @MainActor func probedFrame(_ element: XCUIElement) -> String {
        element.exists ? NSCoder.string(for: element.frame) : "absent"
    }
    @MainActor func attachMovement(_ movement: [String], named name: String) {
        print("GESTURE_MOVEMENT \(name)\n" + movement.joined(separator: "\n"))
        let attachment = XCTAttachment(string: movement.joined(separator: "\n"))
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func editor(_ app: XCUIApplication) -> XCUIElement {
        revealComposerElement(app.images["framebriar-attachment"], in: app).tap()
        let canvas = app.descendants(matching: .any)["framebriar-editor-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        return canvas
    }
}
