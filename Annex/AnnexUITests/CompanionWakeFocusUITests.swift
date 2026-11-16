import XCTest

/// Diagnostic scenarios for #246, not evidence that the intermittent hosted failure is fixed.
@MainActor final class CompanionWakeFocusUITests: ReliableUITestCase {
    private var app: XCUIApplication?
    private var started = ContinuousClock.now
    private var phases: [String] = []

    override func setUp() {
        super.setUp()
        started = .now
        phases = []
        app = nil
    }

    override func tearDown() {
        if let app {
            let timeline = XCTAttachment(string: phases.joined(separator: "\n"))
            timeline.name = "Wake focus phases"
            timeline.lifetime = .keepAlways
            add(timeline)
            if (testRun?.failureCount ?? 0) > 0 {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Wake focus failure hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Wake focus failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        super.tearDown()
    }

    private func phase(_ name: String) {
        let line = "WAKE_FOCUS_UI elapsed=\(started.duration(to: .now)) phase=\(name)"
        phases.append(line)
        print(line)
    }

    private func openProject(diagnostics: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = 240
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["--companion-preview"]
        if diagnostics { app.launchArguments.append("--companion-preview-wake-focus-diagnostics") }
        phase("animated-launch")
        app.launch()
        let project = app.descendants(matching: .any).matching(identifier: "open-project-preview-studio-clubhouse").firstMatch
        XCTAssertTrue(scrollUntilExists(project, in: app) && scrollTo(project, in: app))
        project.tap()
        XCTAssertTrue(app.buttons["project-page-options"].waitForExistence(timeout: 10))
        return app
    }

    private func presentAndType(_ text: String, in app: XCUIApplication) -> XCUIElement {
        phase("present-\(text)")
        let options = app.buttons["project-page-options"]
        XCTAssertTrue(options.isHittable)
        options.tap()
        XCTAssertTrue(app.buttons["project-wake"].waitForExistence(timeout: 5))
        let wake = app.buttons["project-wake"]
        XCTAssertTrue(wake.isHittable && wake.isEnabled)
        let frame = wake.frame
        // Wake is a native toolbar-menu item, which can overlay the large navigation title.
        // Its entire target must stay inside the screen and accept the checked center tap.
        assertMinimumTarget(wake, "Wake menu action")
        XCTAssertTrue(app.frame.contains(frame))
        // After reactivation, XCTest once synthesized the AX activation point inside Terminal instead.
        // Use one checked on-screen point, never a repeated tap or a message-field focus rescue.
        let point = CGPoint(x: frame.midX, y: frame.midY)
        phase("wake-tap-\(point)-frame-\(frame)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        let message = app.descendants(matching: .any).matching(identifier: "wake-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        phase("no-tap-type-\(text)")
        app.typeText(text)
        XCTAssertEqual(message.value as? String, text)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wake-send"].isEnabled)
        phase("exact-value-and-keyboard-\(text)")
        return message
    }

    private func cancel(_ message: XCUIElement, in app: XCUIApplication) {
        app.buttons["Cancel"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        phase("cancelled")
    }

    func testAnimatedPresentationAndRepeatedPresentationAcceptNoTapTyping() {
        let app = openProject()
        for index in 1...3 {
            let message = presentAndType("Presentation \(index)", in: app)
            cancel(message, in: app)
        }
    }

    func testAnimatedPresentationAfterForegroundAndRotationAcceptsNoTapTyping() {
        let app = openProject()
        phase("background-before-presentation")
        XCUIDevice.shared.press(.home)
        app.activate()
        let message = presentAndType("After foreground", in: app)
        phase("rotate-presented-sheet")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.typeText(" rotated")
        XCTAssertEqual(message.value as? String, "After foreground rotated")
        cancel(message, in: app)
        let landscapeMessage = presentAndType("Landscape presentation", in: app)
        cancel(landscapeMessage, in: app)
        XCUIDevice.shared.orientation = .portrait
        let portraitMessage = presentAndType("Portrait again", in: app)
        cancel(portraitMessage, in: app)
    }

    func testAnimatedPresentationRecordsNativeFocusDiagnostics() {
        let app = openProject(diagnostics: true)
        let message = presentAndType("Native focus diagnostics", in: app)
        cancel(message, in: app)
    }
}
