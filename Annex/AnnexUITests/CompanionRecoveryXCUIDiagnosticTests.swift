import XCTest
import Foundation

/// One native route, with no helper relaunch or repeated gesture. Hosted discovery/count failures remain separate.
@MainActor final class CompanionRecoveryXCUIDiagnosticTests: ReliableUITestCase {
    private var failureApp: XCUIApplication?
    private var capturedFirstIssue = false

    // XCTest's recording entry point is nonisolated. Never dispatch or wait from a failure callback.
    override nonisolated func record(_ issue: XCTIssue) {
        // Keep the exact original issue, once, including when evidence is unavailable or capture recurses.
        defer { super.record(issue) }
        guard Thread.isMainThread else {
            print("RECOVERY_XCUI_EVIDENCE_UNAVAILABLE reason=non-main-XCTest-callback originalIssueRetained=true")
            return
        }
        // Runtime-checked actor entry for this synchronous main-thread callback; no unsafe isolation annotation.
        MainActor.assumeIsolated {
            guard !capturedFirstIssue else { return }
            capturedFirstIssue = true // Set before either SDK call, so a capture issue cannot capture recursively.
            guard let app = failureApp else {
                print("RECOVERY_XCUI_EVIDENCE_UNAVAILABLE reason=no-app-handle originalIssueRetained=true")
                return
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Recovery XCUI first issue — original synthetic app"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // Public SDK retrieval may itself take time. Only its retained output is byte-bounded.
            let hierarchy = XCTAttachment(string: boundedHierarchy(app.debugDescription))
            hierarchy.name = "Recovery XCUI first issue — public hierarchy (64 KiB maximum)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            print("RECOVERY_XCUI_FIRST_ISSUE maximumEvents=1 maximumAttachments=2 hierarchyMaxBytes=65536 postFailureOnly=true")
        }
    }

    private func boundedHierarchy(_ description: String) -> String {
        let limit = 65_536
        guard description.utf8.count > limit else { return description }
        let marker = "\n[TRUNCATED: public hierarchy exceeded 65536 UTF-8 bytes]\n"
        let payloadLimit = limit - marker.utf8.count
        var prefix = String(decoding: description.utf8.prefix(payloadLimit), as: UTF8.self)
        // A cut UTF-8 scalar can decode to a longer replacement character. Include the marker within the cap.
        while prefix.utf8.count > payloadLimit { prefix.removeLast() }
        return prefix + marker
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func fixture(_ app: XCUIApplication, _ action: String) {
        let button = app.buttons["recovery-fixture-\(action)"]
        waitAndTap(app.buttons["recovery-fixture-menu"], until: button, timeout: 10, attempts: 1)
        waitAndTap(button, untilGone: button, timeout: 5, attempts: 1)
    }
    private func assertNoLargeRecovery(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["Loading conversation…"].exists)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].exists)
        XCTAssertFalse(element(app, "companion-empty-conversation").exists)
    }

    func testSingleAttemptProgressFailureDetailsRetryAndRecovery() {
        continueAfterFailure = false
        // Same bundle/process handle is available even if launchApp reports its first issue before returning.
        failureApp = XCUIApplication()
        let app = launchApp(["--companion-preview", "--companion-preview-recovery-fixture"], allowance: 240, attempts: 1)
        failureApp = app
        XCTAssertTrue(app.staticTexts["Refreshing conversation…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Refreshing conversation…")).count, 1)
        XCTAssertFalse(app.buttons["companion-recovery-retry"].exists)
        assertNoLargeRecovery(app)
        fixture(app, "fail")
        XCTAssertTrue(app.staticTexts["Conversation refresh failed"].waitForExistence(timeout: 5))
        assertNoLargeRecovery(app)
        fixture(app, "next-success")
        let details = app.buttons["companion-recovery-details"]
        XCTAssertGreaterThanOrEqual(details.frame.width, 44)
        XCTAssertGreaterThanOrEqual(details.frame.height, 44)
        waitAndTap(details, until: element(app, "companion-recovery-explanation"), timeout: 10, attempts: 1)
        let explanation = element(app, "companion-recovery-explanation")
        XCTAssertTrue(explanation.label.contains("Synthetic history failure.\nThe response was incomplete.\nNo real desktop was contacted."))
        XCTAssertTrue(explanation.label.contains("Target: alpha on recovery-one."))
        let retry = app.buttons["companion-recovery-detail-retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        waitAndTap(retry, untilGone: explanation, timeout: 5, attempts: 1)
        XCTAssertTrue(details.waitForNonExistence(timeout: 5), "Clean connected history success removes recovery")
        XCTAssertTrue(app.buttons["Read earlier messages in archive"].exists)
        XCTAssertTrue(element(app, "companion-composer").isHittable)
    }
}
