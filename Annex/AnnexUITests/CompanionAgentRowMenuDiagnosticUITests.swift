import XCTest

/// Opt-in investigation of #247. Uses the real preview rows and native context menus.
/// Each case makes exactly one 1.2-second press; navigation and unknown outcomes fail.
@MainActor
final class CompanionAgentRowMenuDiagnosticUITests: ReliableUITestCase {
    private enum Position: String { case center, name }

    func testJuniperCenterAfterDetailsAndSettings() throws {
        try juniperAfterDetailsAndSettings(.center)
    }

    func testJuniperNameAfterDetailsAndSettings() throws {
        try juniperAfterDetailsAndSettings(.name)
    }

    func testDispatcherCenter() throws {
        try dispatcher(.center)
    }

    func testDispatcherName() throws {
        try dispatcher(.name)
    }

    private func launchDiagnostic(dispatcher: Bool = false) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLUBHOUSE_RUN_AGENT_ROW_MENU_DIAGNOSTIC"] == "1",
                          "Run explicitly in a coordinated simulator slot; see docs/agent-row-menu-investigation.md")
        return launchApp(["--companion-preview"] + (dispatcher ? ["--companion-preview-dispatcher"] : []), attempts: 1)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapOnce(_ source: XCUIElement, until expected: XCUIElement) {
        XCTAssertTrue(source.exists && source.isHittable, "Setup target must be visible before its single tap")
        source.tap()
        XCTAssertTrue(expected.waitForExistence(timeout: 10), "Setup must complete without a gesture retry")
    }

    private func checkedFrame(_ row: XCUIElement, in app: XCUIApplication) -> CGRect {
        XCTAssertTrue(scrollUntilExists(row, in: app) && scrollTo(row, in: app))
        XCTAssertTrue(row.exists && row.isHittable)
        let frame = row.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, rowContentBottom(in: app))
        return frame
    }

    private func juniperAfterDetailsAndSettings(_ position: Position) throws {
        let app = try launchDiagnostic()
        let river = element(app, "agent-preview-studio-river")
        _ = checkedFrame(river, in: app)
        let actions = app.buttons["Conversation actions"]
        tapOnce(river.staticTexts["River"].firstMatch, until: actions)
        tapOnce(actions, until: app.buttons["Agent details"])
        let sheet = element(app, "agent-details-sheet")
        tapOnce(app.buttons["Agent details"], until: sheet)
        let settings = element(app, "agent-details-open-settings")
        XCTAssertTrue(scrollTo(settings, in: app))
        tapOnce(settings, until: element(app, "agent-settings-summary"))
        tapOnce(sheet.navigationBars.buttons.element(boundBy: 0), until: settings)
        let done = sheet.buttons["Done"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "companion-composer").exists)
        let back = app.navigationBars["River"].buttons.element(boundBy: 0)
        let fold = element(app, "fold-sleeping-preview-studio-clubhouse")
        tapOnce(back, until: fold)
        _ = checkedFrame(fold, in: app)
        let juniper = element(app, "agent-preview-studio-juniper")
        XCTAssertFalse(juniper.exists, "Fresh preview keeps Juniper folded until the single disclosure tap")
        tapOnce(fold, until: juniper)
        assertMenu(app, row: juniper, name: "Juniper", position: position, history: "River details/settings/back/Done/Home")
    }

    private func dispatcher(_ position: Position) throws {
        let app = try launchDiagnostic(dispatcher: true)
        assertMenu(app, row: element(app, "dispatcher-row-preview-studio"), name: "Dispatcher",
                   position: position, history: "fresh Home")
    }

    private func assertMenu(_ app: XCUIApplication, row: XCUIElement, name: String, position: Position, history: String) {
        let frame = checkedFrame(row, in: app)
        let label = row.staticTexts[name].firstMatch
        XCTAssertTrue(label.exists && label.isHittable)
        let labelFrame = label.frame
        let point = position == .center ? CGPoint(x: frame.midX, y: frame.midY) : CGPoint(x: labelFrame.midX, y: labelFrame.midY)
        XCTAssertTrue(frame.contains(point))
        XCTAssertFalse(app.navigationBars.firstMatch.frame.contains(point))
        let details = app.buttons["Agent details"]
        let settings = app.buttons["Agent settings"]
        let composer = element(app, "companion-composer")
        XCTAssertFalse(details.exists || settings.exists || composer.exists, "Start on Home with no menu or conversation")
        attach(app.debugDescription, name: "Before single row press")
        XCTContext.runActivity(named: "#247 \(name) \(position.rawValue); history=\(history); point=\(point); row=\(frame); name=\(labelFrame); duration=1.2s") { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).press(forDuration: 1.2)
        }
        let hasDetails = details.waitForExistence(timeout: 5)
        let hasSettings = settings.exists
        let hasComposer = composer.exists
        let hasChatTitle = app.navigationBars[name].exists
        let outcome = hasDetails && hasSettings ? "menu" : hasComposer || hasChatTitle ? "navigation" : "unknown"
        let evidence = "AGENT_ROW_MENU name=\(name) position=\(position.rawValue) history=\(history) duration=1.2 point=\(point) row=\(frame) label=\(labelFrame) outcome=\(outcome) details=\(hasDetails) settings=\(hasSettings) composer=\(hasComposer) chatTitle=\(hasChatTitle)"
        print(evidence)
        attach(evidence + "\n" + app.debugDescription, name: "After single row press: \(outcome)")
        XCTAssertFalse(hasComposer || hasChatTitle, "A long-press must not navigate: \(evidence)")
        XCTAssertTrue(hasDetails && hasSettings, "The actual context menu must offer details and settings: \(evidence)")
        // Exercise the actual menu action as well as checking its labels.
        let sheet = element(app, "agent-details-sheet")
        tapOnce(details, until: sheet)
        XCTAssertTrue(sheet.navigationBars[name].exists, "The menu must open details for the pressed agent")
        XCTAssertFalse(composer.exists, "Selecting details from Home must not open a chat underneath")
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
