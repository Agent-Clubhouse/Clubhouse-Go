import XCTest

/// Bounded readiness checks for the isolated simulator fixtures. These add
/// preconditions; the tests still own every behavior and result assertion.
@MainActor extension XCTestCase {
    func launchReadyApplication(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Previous fixture must finish terminating")
        }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "Fixture must be in the foreground")
        // Requesting an orientation that is already active can leave XCTest
        // waiting for a change notification that will never arrive.
        if XCUIDevice.shared.orientation != .portrait {
            XCUIDevice.shared.orientation = .portrait
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Fixture window must exist")
        let portrait = NSPredicate { object, _ in
            guard let window = object as? XCUIElement else { return false }
            let frame = window.frame
            return frame.height > frame.width
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: window)], timeout: 10), .completed,
                       "Fixture window must finish rotating to portrait")
        return app
    }

    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let ready = NSPredicate(format: "exists == true AND hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: timeout), .completed,
                       "Control must be visible and hittable before interaction")
    }
}
