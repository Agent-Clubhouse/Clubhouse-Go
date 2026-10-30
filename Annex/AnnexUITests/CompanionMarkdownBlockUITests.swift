import XCTest

/// Large Markdown blocks (#180): a wide, many-row table and a long code block each open on their own, full screen,
/// where the last row and the last line can be reached.
@MainActor
final class CompanionMarkdownBlockUITests: ReliableUITestCase {
    private func openRiver(_ app: XCUIApplication) {
        let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
        scrollUntilExists(agent, in: app)
        XCTAssertTrue(scrollTo(agent, in: app), "River's row must be on screen")
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        waitAndTap(agent, until: composer, timeout: 15, "Selecting an agent must open its conversation")
    }

    /// Brings a block's caption into the top third of the screen, clear of the pinned approval and the composer that
    /// float over the conversation's lower half. The conversation opens at its newest items, below the reply.
    private func caption(_ label: String, below: Bool = false, in app: XCUIApplication) -> XCUIElement {
        let caption = app.staticTexts[label]
        scrollUntilExists(caption, in: app, up: below, maxSwipes: 6, wait: 1)
        XCTAssertTrue(scrollTo(caption, in: app, up: below, maxSwipes: 6), "\(label) must be on screen")
        let window = app.windows.firstMatch.frame
        for _ in 0..<4 {
            checkTimeLeft("raising \(label)")
            let offset = caption.frame.midY - window.height / 3
            if abs(offset) < 60 { break }
            // Drag at most half a screen at a time, slowly enough that it doesn't fling.
            let distance = max(-window.height / 2, min(window.height / 2, offset))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)), withVelocity: .slow,
                        thenHoldForDuration: 0.3)
        }
        XCTAssertLessThan(caption.frame.midY, window.height / 2, "\(label) must be clear of the composer")
        return caption
    }

    /// Swipes the full-screen block until `element`'s far edge is inside it, in the direction given.
    private func reveal(_ element: XCUIElement, in sheet: XCUIElement, horizontally: Bool, _ message: String) {
        func inside() -> Bool {
            horizontally ? element.frame.maxX <= sheet.frame.maxX + 1 : element.frame.maxY <= sheet.frame.maxY + 1
        }
        for _ in 0..<12 {
            if inside() { break }
            checkTimeLeft(message)
            if horizontally { sheet.swipeLeft() } else { sheet.swipeUp() }
        }
        XCTAssertTrue(inside(), message)
        XCTAssertGreaterThanOrEqual(element.frame.maxY, sheet.frame.minY, "\(message): it must not scroll past")
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTableAndCodeOpenFullScreenToTheirLastRowAndLine() {
        let app = launchApp(["--companion-preview", "--companion-preview-long-blocks"])
        openRiver(app)
        let sheet = app.scrollViews["companion-markdown-block-sheet"]
        let done = app.buttons["companion-markdown-block-done"]

        // Inline, the wrapped first row is whole: the table grows to fit it rather than clipping it.
        let tableCaption = caption("Table · 14 rows", in: app)
        let firstRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Row 1. Area: Desktop'")).firstMatch
        XCTAssertTrue(firstRow.exists, "VoiceOver reads the table by row")
        XCTAssertGreaterThan(firstRow.frame.height, 30, "A wrapped row must be as tall as its text")
        XCTAssertTrue(app.buttons["Show all 14 rows"].exists, "A long table shows its first rows, then Show all")
        attachScreenshot(app, "Inline long table")

        // Tap the table: it opens alone, and its last row and column can be reached.
        waitAndTap(tableCaption, until: done, timeout: 10, "Tapping a table must open it full screen")
        XCTAssertTrue(app.navigationBars["Table"].waitForExistence(timeout: 5))
        let copy = app.buttons["companion-markdown-block-copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Full screen offers Copy\n\(app.debugDescription)")
        XCTAssertEqual(copy.label, "Copy table")
        XCTAssertTrue(app.buttons["companion-markdown-block-share"].exists, "Full screen offers Share")
        let lastRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Row 14. Area: Wrap-up'")).firstMatch
        XCTAssertTrue(lastRow.waitForExistence(timeout: 5), "The last row must be in the full-screen table")
        reveal(lastRow, in: sheet, horizontally: false, "The last row must scroll into view")
        reveal(lastRow, in: sheet, horizontally: true, "The last column must scroll into view")
        let width = lastRow.frame.width
        sheet.pinch(withScale: 2, velocity: 2)
        XCTAssertGreaterThan(lastRow.frame.width, width * 1.2, "Pinching must zoom the table")
        attachScreenshot(app, "Full-screen table")
        waitAndTap(done, untilGone: done, "Done must close the table")

        // Long-press the code block, further down: its menu opens it on its own, where the last line can be reached.
        let codeCaption = caption("typescript", below: true, in: app)
        XCTAssertTrue(app.buttons["Show all 64 lines"].exists, "Long code shows its first lines, then Show all")
        // The inline header's buttons say "Open code" and "Copy code"; the menu's own items are "Open" and "Copy code".
        let menuOpen = app.buttons["Open"]
        XCTAssertTrue(longPressUntilMenu(codeCaption, shows: menuOpen), "Long-press offers Open")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "Copy code").count, 2, "Long-press offers Copy code")
        waitAndTap(menuOpen, until: done, timeout: 10, "Open must show the code full screen")
        XCTAssertTrue(app.navigationBars["typescript"].waitForExistence(timeout: 5))
        XCTAssertEqual(copy.label, "Copy code", "Full screen offers Copy code")
        let code = app.staticTexts["companion-markdown-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertTrue(code.label.hasSuffix("// End of the release checks"), "The whole block opens, through its last line")
        reveal(code, in: sheet, horizontally: false, "The last line must scroll into view")
        reveal(code, in: sheet, horizontally: true, "The longest line must scroll into view")
        attachScreenshot(app, "Full-screen code")
        waitAndTap(done, untilGone: done, "Done must close the code")
    }
}
