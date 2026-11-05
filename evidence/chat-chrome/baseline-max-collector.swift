import XCTest

/// Temporary evidence-only baseline collector; never included in the source PR.
@MainActor final class CompanionChatChromeBaselineUITests: ReliableUITestCase {
    func testLargestTextWithPreviewBanner() { measure(hideBanner: false) }
    func testLargestTextWithoutPreviewBanner() { measure(hideBanner: true) }

    private func measure(hideBanner: Bool) {
        let app = launchApp(["--companion-preview", "--companion-preview-dispatcher", "--companion-preview-context-window",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                            + (hideBanner ? ["--companion-preview-hide-banner"] : []))
        let any = app.descendants(matching: .any)
        let composer = any.matching(identifier: "companion-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["companion-transcript"].frame.intersection(app.frame)
        let header = any.matching(identifier: "companion-chat-header").firstMatch.frame
        let region = any.matching(identifier: "companion-composer-region").firstMatch.frame
        let readable = transcript.isNull ? 0 : max(0, min(transcript.maxY, region.minY) - max(transcript.minY, header.maxY))
        print("CHAT_CHROME baseline-largest-text hiddenPreviewBanner=\(hideBanner) transcript=\(transcript) header=\(header) composer=\(region) readableHeight=\(readable)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Baseline largest text \(hideBanner ? "without preview banner" : "with preview banner")"
        shot.lifetime = .keepAlways; add(shot)
    }
}
