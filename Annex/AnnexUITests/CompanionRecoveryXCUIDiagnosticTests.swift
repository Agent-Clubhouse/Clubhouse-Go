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

    /// One geometry-directed content drag for an exported control below the medium sheet's visible content.
    private func revealDetailsRetry(_ retry: XCUIElement, in app: XCUIApplication) -> Bool {
        let scrolls = app.scrollViews.containing(.button, identifier: "companion-recovery-detail-retry")
        let bars = app.navigationBars.matching(identifier: "Connection and recovery")
        guard scrolls.count == 1, bars.count == 1 else {
            XCTFail("Recovery Details must have one containing scroll view and one sheet navigation bar")
            return false
        }
        let scroll = scrolls.firstMatch, bar = bars.firstMatch
        func viewport() -> CGRect? {
            let visible = scroll.frame.intersection(app.windows.firstMatch.frame)
            let navigation = bar.frame
            let top = max(visible.minY, navigation.maxY)
            guard !visible.isNull, !visible.isInfinite, visible.width > 24,
                  top.isFinite, visible.maxY.isFinite, visible.maxY - top > 24 else {
                XCTFail("Recovery sheet must expose a finite content viewport below its navigation bar")
                return nil
            }
            return CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
                .insetBy(dx: 12, dy: 12)
        }
        guard let before = viewport() else { return false }
        let target = retry.frame
        guard target.minX.isFinite, target.minY.isFinite, target.maxX.isFinite, target.maxY.isFinite,
              target.width > 0, target.height > 0 else {
            XCTFail("The exported retry must have a finite nonempty frame")
            return false
        }
        if !before.contains(target) {
            let displacement = target.midY - before.midY
            let start = CGPoint(x: before.midX, y: before.maxY - 1)
            let end = CGPoint(x: start.x, y: start.y - displacement)
            let appFrame = app.frame
            guard target.minX >= before.minX, target.maxX <= before.maxX,
                  target.minY >= before.minY, target.maxY > before.maxY,
                  displacement > 0, displacement <= before.height,
                  before.contains(start), before.contains(end),
                  appFrame.contains(start), appFrame.contains(end) else {
                XCTFail("Only a below-viewport retry reachable by one bounded upward content drag may be navigated to")
                return false
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: start.x - appFrame.minX, dy: start.y - appFrame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - appFrame.minX, dy: end.y - appFrame.minY))
            XCTContext.runActivity(named: "Recovery Details content drag: viewport \(before), retry \(target), \(start) → \(end)") { _ in
                from.press(forDuration: 0.05, thenDragTo: to)
            }
        }
        // The gesture may change the sheet detent. Re-read both the viewport/nav and the target, without a wait/loop.
        guard let after = viewport() else { return false }
        let revealed = retry.frame
        let contained = after.contains(revealed)
        XCTAssertTrue(contained, "The whole retry must be inside the current sheet content viewport: \(revealed), viewport \(after)")
        return contained
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
        guard revealDetailsRetry(retry, in: app) else { return }
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        waitAndTap(retry, untilGone: explanation, timeout: 5, attempts: 1)
        XCTAssertTrue(details.waitForNonExistence(timeout: 5), "Clean connected history success removes recovery")
        XCTAssertTrue(app.buttons["Read earlier messages in archive"].exists)
        XCTAssertTrue(element(app, "companion-composer").isHittable)
    }
}
