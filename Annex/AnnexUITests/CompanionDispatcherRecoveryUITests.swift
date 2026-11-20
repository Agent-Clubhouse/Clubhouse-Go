import XCTest

/// Socket-free preview service only. No paired desktop or real Dispatcher is controlled.
@MainActor final class CompanionDispatcherRecoveryUITests: ReliableUITestCase {
    private func openRecovery() -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-start-dispatch",
                             "--companion-preview-dispatcher-recovery"], attempts: 1)
        XCTAssertTrue(app.navigationBars["Dispatcher"].waitForExistence(timeout: 10))
        app.buttons["conversation-actions-menu"].tap()
        let recovery = app.buttons["dispatcher-recovery-menu"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5)); recovery.tap()
        XCTAssertTrue(app.navigationBars["Dispatcher recovery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Studio Mac"].exists)
        return app
    }

    /// Reveal lazily materialized Form rows with real native pans; never tap through the toolbar.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for attempt in 0...8 {
            let top = (app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0) + 12
            let band = CGRect(x: app.frame.minX + 12, y: top, width: app.frame.width - 24,
                              height: app.frame.maxY - top - 24)
            if element.exists {
                let frame = element.frame
                print("DISPATCHER_RECOVERY_GEOMETRY id=\(element.identifier) attempt=\(attempt) band=\(band) row=\(frame)")
                if band.contains(frame), element.isHittable { return true }
                if frame.height > band.height || frame.width > band.width { return false }
            }
            if attempt == 8 || band.height < 160 { return false }
            let origin = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: band.midX, dy: band.midY))
            let delta: CGFloat = element.exists && element.frame.midY < band.midY ? 120 : -120
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: delta)),
                         withVelocity: .slow, thenHoldForDuration: 0)
        }
        return false
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testInterruptAndNewChatHaveSeparateConfirmedEffects() {
        let app = openRecovery()
        let interrupt = app.buttons["dispatcher-recovery-interrupt"]
        XCTAssertTrue(reveal(interrupt, in: app)); XCTAssertTrue(interrupt.isEnabled)
        capture("Visible chat target and interrupt")
        interrupt.tap()
        XCTAssertTrue(app.alerts["Interrupt this chat turn?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(interrupt.isEnabled)
        interrupt.tap(); app.alerts.buttons["Interrupt chat turn"].tap()
        XCTAssertTrue(interrupt.wait(for: \.isEnabled, toEqual: false, timeout: 5))

        let newChat = app.buttons["dispatcher-recovery-new-chat"]
        XCTAssertTrue(reveal(newChat, in: app)); newChat.tap()
        let alert = app.alerts["Start a new chat?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch.exists)
        capture("New chat host-bound confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(newChat.isEnabled)
        newChat.tap(); XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["Start new chat"].tap()
        let result = app.staticTexts["dispatcher-recovery-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "Its conversation started over.")
        XCTAssertTrue(reveal(result, in: app)); capture("Confirmed visible new chat result")
        let unsupported = app.staticTexts["dispatcher-recovery-host-required"]
        XCTAssertTrue(reveal(unsupported, in: app))
        XCTAssertTrue(unsupported.label.contains("doesn't offer controller history or Restart Dispatcher"))
        capture("Explicit unavailable controller operations")
        app.terminate()
    }

    func testStopChatIsConfirmedAndRequiresDesktopStateEvidence() {
        let app = openRecovery()
        let stop = app.buttons["dispatcher-recovery-stop"]
        XCTAssertTrue(reveal(stop, in: app)); XCTAssertTrue(stop.isEnabled)
        stop.tap()
        XCTAssertTrue(app.alerts["Stop this chat session?"].waitForExistence(timeout: 5))
        capture("Stop visible session confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(stop.isEnabled)
        stop.tap(); app.alerts.buttons["Stop chat session"].tap()
        let reported = app.staticTexts["dispatcher-recovery-stopped"]
        XCTAssertTrue(reported.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(reported, in: app))
        XCTAssertTrue(reported.label.contains("desktop reports this chat is sleeping"))
        XCTAssertFalse(stop.isEnabled)
        XCTAssertFalse(app.staticTexts["dispatcher-recovery-error"].exists)
        capture("Synthetic desktop reports visible chat sleeping")
        app.terminate()
    }
}
