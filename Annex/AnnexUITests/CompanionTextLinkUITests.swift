import XCTest

@MainActor final class CompanionTextLinkUITests: ReliableUITestCase {
    private let destination = "https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/123?check=a--b&mode=two#job-45"

    private func open(_ scenario: String) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--mobile-links-ui-testing"], environment: ["MOBILE_LINK_SCENARIO": scenario], attempts: 1)
        XCTAssertTrue(app.staticTexts["mobile-link-open-receipt"].waitForExistence(timeout: 10))
        if scenario.hasPrefix("archive-") {
            let saved = app.buttons["Saved links"]
            XCTAssertTrue(saved.waitForExistence(timeout: 10))
            saved.tap()
            XCTAssertTrue(app.staticTexts["Saved conversation · Read only"].waitForExistence(timeout: 10))
        }
        return app
    }

    private func tap(_ label: String, in app: XCUIApplication, opens: Int = 1) {
        let link = app.links[label].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Real native link must be accessible: \(label)\n\(app.debugDescription)")
        XCTAssertTrue(link.isHittable)
        XCTAssertTrue(app.frame.contains(link.frame))
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Before native link tap"; before.lifetime = .keepAlways; add(before)
        link.tap()
        let receipt = app.staticTexts["mobile-link-open-receipt"]
        XCTAssertTrue(waitFor(receipt, NSPredicate(format: "label == %@", "opens=\(opens);url=\(destination)"), timeout: 5),
                      "One real tap must deliver the exact original destination once")
        XCTAssertFalse(app.scrollViews["companion-markdown-block-sheet"].exists, "A table link must not also open its block")
    }

    func testSentAndRelayedLiteralRowsDeliverTheExactURLOnce() {
        for scenario in ["sent", "relayed", "clubhouse"] {
            let app = open(scenario)
            tap(destination, in: app)
            app.terminate()
        }
    }

    func testReceivedAndDispatcherRowsKeepLabeledAndBareDestinations() {
        for scenario in ["received", "dispatcher"] {
            let app = open(scenario)
            tap("Review PR", in: app)
            tap(destination, in: app, opens: 2)
            app.terminate()
        }
    }

    func testSavedSentAndReceivedRowsUseTheSameTapRoute() {
        for scenario in ["archive-sent", "archive-received"] {
            let app = open(scenario)
            tap(scenario == "archive-sent" ? destination : "Review PR", in: app)
            app.terminate()
        }
    }

    func testTableAndMarkdownFileExternalLinksDoNotSwallowOrDuplicateTaps() {
        let table = open("table")
        tap("Table PR", in: table)
        table.terminate()
        let file = open("markdown-file")
        tap("File PR", in: file)
        XCTAssertFalse(file.links["Blocked"].exists)
        XCTAssertFalse(file.links["Local"].exists)
        file.terminate()
    }

    func testCodeAndBlockedRoutesNeverReachTheSystemOpen() {
        let code = open("code")
        XCTAssertTrue(code.staticTexts["`\(destination)`"].waitForExistence(timeout: 10))
        XCTAssertFalse(code.links[destination].exists)
        code.staticTexts["`\(destination)`"].tap()
        XCTAssertEqual(code.staticTexts["mobile-link-open-receipt"].label, "opens=0;url=")
        code.terminate()
        let blocked = open("blocked")
        let link = blocked.links["Blocked route"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
        XCTAssertEqual(blocked.staticTexts["mobile-link-open-receipt"].label, "opens=0;url=")
        let outside = blocked.links["Outside file"]
        XCTAssertTrue(outside.exists); outside.tap()
        XCTAssertEqual(blocked.staticTexts["mobile-link-open-receipt"].label, "opens=0;url=")
        XCTAssertFalse(blocked.navigationBars["outside-secret.md"].exists)
        blocked.terminate()
    }

    func testApprovedLocalFileStillUsesTheDesktopPreviewRoute() {
        let app = open("local-file")
        let link = app.links["Local file"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.navigationBars["Conversation.swift"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Copy preview"].exists)
        XCTAssertEqual(app.staticTexts["mobile-link-open-receipt"].label, "opens=0;url=")
        app.buttons["companion-preview-done"].tap()
        XCTAssertTrue(app.buttons["companion-preview-done"].waitForNonExistence(timeout: 5))
        app.terminate()
    }
}
