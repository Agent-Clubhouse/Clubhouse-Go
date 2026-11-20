import XCTest

@MainActor final class CompanionAppUpdateUITests: ReliableUITestCase {
    private func openUpdate(state: String = "ready", dispatcherOff: Bool = false, supportsCheck: Bool = true, checkRunning: Bool = false) -> XCUIApplication {
        let app = launchApp(["--companion-preview", "--companion-preview-app-update"]
            + (dispatcherOff ? ["--companion-preview-app-update-dispatcher-off"] : [])
            + (supportsCheck ? [] : ["--companion-preview-app-update-no-check"])
            + (checkRunning ? ["--companion-preview-app-update-check-running"] : []),
            environment: ["COMPANION_PREVIEW_APP_UPDATE_STATE": state])
        waitAndTap(app.tabBars.buttons["Home"], until: app.navigationBars["Clubhouse"])
        if state == "none" || state == "unsupported" {
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["app-update-preview-studio"].exists, "Version information is not an update button")
            waitAndTap(app.buttons["settings-desktop-preview-studio"], until: app.buttons["desktop-connection-retry"])
            XCTAssertFalse(app.buttons["app-update-preview-studio"].exists, "Version information remains plain on the desktop detail page")
        } else {
            let indicator = app.buttons["app-update-preview-studio"]
            XCTAssertTrue(scrollTo(indicator, in: app))
            XCTAssertTrue(indicator.label.contains("1.0.0"))
            if state != "unsupported" { XCTAssertTrue(indicator.label.contains("1.1.0")) }
            if state == "ready" {
                XCTAssertTrue(indicator.label.contains("Restart to update"))
                attach(app, "Home - restart update entry point")
            }
            waitAndTap(indicator, until: app.navigationBars["Desktop update"])
        }
        XCTAssertTrue(scrollTo(app.staticTexts["app-update-status"], in: app, up: false))
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A different choice can be tappable while this one is clipped by the navigation bar.
    /// Reveal the action itself with bounded native pans, requiring its entire current frame.
    private func revealUpdateChoice(_ choice: XCUIElement, in app: XCUIApplication) -> Bool {
        for attempt in 0...6 {
            let window = app.frame
            let top = app.navigationBars["Desktop update"].frame.maxY + 12
            let bottom = rowContentBottom(in: app)
            let frame = choice.exists ? choice.frame : nil
            print("APP_UPDATE_CHOICE attempt=\(attempt) frame=\(String(describing: frame)) band=\(top)...\(bottom)")
            if let frame, frame.width > 0, frame.height > 0,
               frame.minX >= window.minX, frame.maxX <= window.maxX,
               frame.minY >= top, frame.maxY <= bottom, choice.isHittable { return true }
            guard attempt < 6, bottom - top > 260 else { return false }
            let origin = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.midX, dy: (top + bottom) / 2))
            let delta: CGFloat = frame.map { $0.minY < top ? 120 : -120 } ?? -120
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: delta)),
                         withVelocity: .slow, thenHoldForDuration: 0)
        }
        return false
    }

    func testReadyRequestPresentsOwnInterruptionReviewAndRestartWhenIdleWithoutLeavingTheScreen() {
        let app = openUpdate()
        let request = app.buttons["app-update-request"]
        XCTAssertEqual(request.label, "Restart to update to 1.1.0")
        attach(app, "Desktop update - ready")
        let review = app.staticTexts["app-update-working-agents"]
        waitAndTap(request, until: review)
        XCTAssertTrue(review.label.contains("River"))
        attach(app, "Desktop update - interruption review")
        let whenIdle = app.buttons["app-update-restart-when-idle"]
        XCTAssertTrue(scrollTo(app.buttons["app-update-decline"], in: app))
        XCTAssertTrue(app.buttons["app-update-restart-now"].exists)
        XCTAssertTrue(app.buttons["app-update-decline"].exists)
        XCTAssertFalse(app.buttons["grant-request-allow"].exists)
        XCTAssertTrue(app.navigationBars["Desktop update"].exists)
        attach(app, "Desktop update - approval choices")
        guard revealUpdateChoice(whenIdle, in: app) else {
            XCTFail("Restart when idle must be fully revealed before tapping"); return
        }
        attach(app, "Desktop update - Restart when idle fully revealed")
        guard whenIdle.exists else { XCTFail("The revealed choice must still exist"); return }
        let choiceFrame = whenIdle.frame, window = app.frame
        guard whenIdle.identifier == "app-update-restart-when-idle", whenIdle.isEnabled, whenIdle.isHittable,
              choiceFrame.width > 0, choiceFrame.height > 0,
              choiceFrame.minX >= window.minX, choiceFrame.maxX <= window.maxX,
              choiceFrame.minY >= app.navigationBars["Desktop update"].frame.maxY + 12,
              choiceFrame.maxY <= rowContentBottom(in: app) else {
            XCTFail("The exact current Restart when idle choice must remain fully visible and actionable"); return
        }
        waitAndTap(whenIdle, untilGone: whenIdle, attempts: 1)
        XCTAssertTrue(scrollTo(app.staticTexts["app-update-request-state"], in: app, up: false))
        XCTAssertTrue(app.staticTexts["app-update-request-state"].label.contains("Waiting for every agent"))
        attach(app, "Desktop update - waiting for idle")
        let cancel = app.buttons["app-update-cancel"]
        waitAndTap(cancel, untilGone: cancel)
        XCTAssertEqual(app.staticTexts["app-update-request-state"].label, "Update request cancelled.")
    }

    func testRestartNowAndCancelAreExplicitChoices() {
        for choice in ["app-update-restart-now", "app-update-decline"] {
            let app = openUpdate()
            waitAndTap(app.buttons["app-update-request"], until: app.staticTexts["app-update-working-agents"])
            let button = app.buttons[choice]
            XCTAssertTrue(scrollTo(button, in: app))
            waitAndTap(button, untilGone: button)
            let status = app.staticTexts["app-update-request-state"]
            XCTAssertTrue(scrollTo(status, in: app, up: false))
            XCTAssertTrue(status.label.contains(choice == "app-update-restart-now" ? "Restarting" : "cancelled"))
            if choice == "app-update-restart-now" { attach(app, "Desktop update - restarting") }
            XCTAssertFalse(app.buttons["app-update-cancel"].exists)
        }
    }

    func testDownloadingAvailableNoneAndUnsupportedHaveClearStatusWithoutDeadActions() {
        for state in ["downloading", "available", "none", "unsupported"] {
            let app = openUpdate(state: state)
            let status = app.staticTexts["app-update-status"]
            XCTAssertTrue(status.exists)
            XCTAssertFalse(app.buttons["app-update-request"].exists)
            XCTAssertEqual(app.buttons["app-update-check"].exists, state == "none" || state == "available")
            switch state {
            case "downloading":
                XCTAssertTrue(status.label.contains("47.5%"))
                XCTAssertTrue(app.progressIndicators["app-update-progress"].exists)
                XCTAssertTrue(app.staticTexts["Restart will be available when the download finishes."].exists)
            case "available":
                XCTAssertTrue(status.label.contains("1.1.0"))
                XCTAssertTrue(app.staticTexts["Restart will be available when the download finishes."].exists)
            case "none": XCTAssertEqual(status.label, "No update known (running 1.0.0)")
            default: XCTAssertTrue(app.staticTexts["This installation cannot self-update."].exists)
            }
            attach(app, "Desktop update - \(state)")
        }
    }

    func testDispatcherOffOffersExplicitEnableBeforeRequestingRestart() {
        let app = openUpdate(dispatcherOff: true)
        XCTAssertFalse(app.buttons["app-update-request"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "needs the Dispatcher on")).firstMatch.exists)
        attach(app, "Desktop update - Dispatcher off")
        waitAndTap(app.buttons["app-update-enable-dispatcher"], until: app.buttons["app-update-request"])
        XCTAssertFalse(app.buttons["app-update-restart-now"].exists, "Enabling is not a restart request or approval")
        waitAndTap(app.buttons["app-update-request"], until: app.staticTexts["app-update-working-agents"])
    }

    func testSettingsWithoutUpdateShowsPlainVersionAndDestructiveForgetKeepsItsConfirmation() {
        let app = openUpdate(state: "none")
        XCTAssertEqual(app.staticTexts["app-update-status"].label, "No update known (running 1.0.0)")
        XCTAssertFalse(app.images["arrow.down.circle"].exists)
        XCTAssertTrue(app.staticTexts["Verified desktop identity"].exists)
        XCTAssertTrue(app.buttons["desktop-connection-forget"].exists)
        XCTAssertTrue(app.buttons["desktop-connection-retry"].exists)
        attach(app, "Settings desktop - tinted Retry and red Forget - bf215c26")
        app.buttons["desktop-connection-forget"].tap()
        XCTAssertTrue(app.buttons["Forget desktop"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else {
            waitAndTap(app.otherElements["PopoverDismissRegion"], untilGone: app.buttons["Forget desktop"])
        }
        XCTAssertTrue(app.staticTexts["app-update-status"].exists, "Cancelling forget retains the desktop")
    }

    func testCheckFlowsThroughLiveDownloadToRestartAndOwnReview() throws {
        // Reach the update destination before Check starts the fixture's live download clock.
        // The no-update Settings/Home route is covered by the separate state-matrix test.
        let app = openUpdate(state: "available")
        waitAndTap(app.buttons["app-update-check"], until: app.buttons["Checking…"])
        XCTAssertFalse(app.buttons["app-update-check"].isEnabled)
        attach(app, "Desktop update - checking")
        XCTAssertTrue(app.progressIndicators["app-update-progress"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["app-update-check"].exists)
        attach(app, "Desktop update - live check download")
        let restart = app.buttons["app-update-request"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15))
        XCTAssertEqual(restart.label, "Restart to update to 1.1.0")
        waitAndTap(restart, until: app.staticTexts["app-update-working-agents"])
        XCTAssertTrue(scrollTo(app.buttons["app-update-decline"], in: app))
        XCTAssertTrue(app.buttons["app-update-restart-now"].exists)
        XCTAssertTrue(app.buttons["app-update-restart-when-idle"].exists)
        XCTAssertTrue(app.navigationBars["Desktop update"].exists)
    }

    func testOlderDesktopHidesCheckAndAlreadyCheckingIsDisabled() {
        for state in ["none", "available"] {
            let app = openUpdate(state: state, supportsCheck: false)
            XCTAssertFalse(app.buttons["app-update-check"].exists)
            attach(app, "Desktop update - older host \(state)")
        }
        let app = openUpdate(state: "none", checkRunning: true)
        waitAndTap(app.buttons["app-update-check"], until: app.buttons["Already checking"])
        XCTAssertFalse(app.buttons["app-update-check"].isEnabled)
        XCTAssertEqual(app.staticTexts["app-update-check-error"].label, "A desktop update check is already running.")
        attach(app, "Desktop update - already checking")
    }
}
