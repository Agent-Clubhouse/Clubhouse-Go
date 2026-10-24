//
//  AnnexUITestsLaunchTests.swift
//  AnnexUITests
//
//  Created by Mason Allen on 2/21/26.
//

import XCTest

final class AnnexUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // Hosted simulator configuration changes have taken up to 78 seconds.
        // Keep the launch matrix covered with a bounded allowance for that work.
        executionTimeAllowance = 120
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
