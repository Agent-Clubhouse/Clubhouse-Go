import XCTest

@MainActor final class CompanionMarkdownFileUITests: ReliableUITestCase {
    private let raw = "# Phone notes\r\n\r\n**Keep** trailing spaces  \r\nCaf\u{00e9} \u{1f680}\r\n\r\n- [x] Native preview\r\n\r\n![Blocked local image](./private.png)\r\n"
    private func open(_ path: String, app: XCUIApplication) {
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        if !composer.exists {
            let agent = app.descendants(matching: .any).matching(identifier: "agent-preview-studio-river").firstMatch
            XCTAssertTrue(agent.waitForExistence(timeout: 15))
            XCTAssertTrue(scrollTo(agent, in: app))
            waitAndTap(agent, until: composer)
        }
        let link = app.buttons.matching(identifier: "companion-content-link").matching(NSPredicate(format: "label == %@", path)).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(scrollTo(link, in: app, maxSwipes: 3))
        waitAndTap(link, until: app.segmentedControls["companion-markdown-file-mode"])
    }
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPreviewSourceAndCopyRawMarkdown() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance", "--companion-preview-markdown-files"], attempts: 1)
        open("phone-notes.md", app: app)
        let picker = app.segmentedControls["companion-markdown-file-mode"]
        XCTAssertTrue(picker.buttons["Preview"].isSelected)
        XCTAssertTrue(app.staticTexts["Phone notes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textViews["companion-markdown-file-source"].exists)
        XCTAssertTrue(app.staticTexts["companion-markdown-file-truncated"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "companion-markdown-file-image-placeholder").firstMatch.exists)
        screenshot(app, name: "Markdown Preview")
        waitAndTap(picker.buttons["Source"], until: app.textViews["companion-markdown-file-source"])
        let source = app.textViews["companion-markdown-file-source"]
        XCTAssertEqual(source.value as? String, raw)
        XCTAssertTrue(app.staticTexts["companion-markdown-file-truncated"].exists)
        screenshot(app, name: "Exact Markdown Source")
        app.buttons["companion-markdown-file-copy"].tap()
        app.buttons["companion-preview-done"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let paste = app.menuItems["Paste"]
        _ = paste.waitForExistence(timeout: 1)
        waitAndTap(composer, until: paste, timeout: 3, "The composer offers the system Paste action")
        paste.tap()
        XCTAssertTrue(waitFor(composer, NSPredicate(format: "value == %@", raw), timeout: 5),
                      "Copy must paste the raw source, not rendered Markdown")
    }

    func testLineTargetStartsInSource() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance", "--companion-preview-markdown-files"], attempts: 1)
        open("phone-notes.md:4", app: app)
        XCTAssertTrue(app.segmentedControls["companion-markdown-file-mode"].buttons["Source"].isSelected)
        XCTAssertTrue(app.staticTexts["Source line 4"].exists)
        XCTAssertEqual(app.textViews["companion-markdown-file-source"].value as? String, raw)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "companion-markdown-file-loading").firstMatch.exists)
    }

    func testDefaultPreviewLoaderAfterSourceSwitchAndSheetReopen() {
        let app = launchApp(["--companion-preview", "--companion-preview-content-acceptance", "--companion-preview-markdown-files"], attempts: 1)
        for _ in 0..<2 {
            open("phone-notes.md:4", app: app)
            let picker = app.segmentedControls["companion-markdown-file-mode"]
            XCTAssertTrue(picker.buttons["Source"].isSelected)
            XCTAssertEqual(app.textViews["companion-markdown-file-source"].value as? String, raw)
            waitAndTap(picker.buttons["Preview"], until: app.staticTexts["Phone notes"])
            XCTAssertTrue(app.staticTexts["Phone notes"].exists, "The production default loader renders on the first Preview switch")
            XCTAssertEqual(app.state, .runningForeground)
            waitAndTap(app.buttons["companion-preview-done"], untilGone: picker)
        }
    }
}
