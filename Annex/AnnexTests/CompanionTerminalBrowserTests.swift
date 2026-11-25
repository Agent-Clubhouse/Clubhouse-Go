import SafariServices
import Testing
import UIKit
@testable import ClubhouseGo

/// The in-app browser for terminal links, presented over a window's root controller (standing in for the terminal).
/// Safari's remote view won't stay up in a unit-test host, so a plain controller stands in for it here; the UI test
/// presents the real one.
@MainActor struct CompanionTerminalBrowserTests {
    private let link = CompanionTerminalLink("https://claude.example.test/oauth/authorize?code=true&client_id=SYNTH")!

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    /// Spins the run loop until `condition` holds, for at most `timeout` seconds; UIKit's dismissal bookkeeping lands
    /// on its own schedule (it varies by OS), so a fixed settle is not enough.
    private func wait(timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func window() throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        settle()
        return (window, root)
    }

    private func open(over presenter: UIViewController, finished: @escaping () -> Void = {}) -> Bool {
        let shown = CompanionInAppBrowser.present(link, over: presenter, animated: false, makeController: { _ in UIViewController() }, finished: finished)
        settle()
        return shown
    }

    /// One test, not two: both share the browser's static record, and spinning the run loop could interleave them.
    @Test func aStaleBrowserNeverBlocksOpenAndDoneReportsOnce() throws {
        // 1. Every presentation is cleared from outside (the Message Dispatcher App Intent): the page's own delegate
        // is never told, so its stale record must not make Open fail.
        let (window, root) = try window()
        #expect(open(over: root))
        #expect(CompanionInAppBrowser.isPresented)
        #expect(!open(over: root), "One browser at a time")
        root.dismiss(animated: false)
        wait { !CompanionInAppBrowser.isPresented }
        #expect(!CompanionInAppBrowser.isPresented)
        #expect(open(over: root), "A stale browser must not make Open fail silently")
        #expect(CompanionInAppBrowser.isPresented)
        root.dismiss(animated: false)
        wait { !CompanionInAppBrowser.isPresented }
        window.isHidden = true

        // 2. Done dismisses the page, then tells its delegate (twice here: it must still report once).
        let (window2, root2) = try self.window()
        var finished = 0
        #expect(open(over: root2) { finished += 1 })
        let browser = try #require(CompanionInAppBrowser.current)
        root2.dismiss(animated: false)
        wait { !CompanionInAppBrowser.isPresented }
        let safari = SFSafariViewController(url: link.url)
        browser.safariViewControllerDidFinish(safari)
        browser.safariViewControllerDidFinish(safari)
        #expect(finished == 1)
        #expect(!CompanionInAppBrowser.isPresented)
        #expect(open(over: root2))
        root2.dismiss(animated: false)
        wait { !CompanionInAppBrowser.isPresented }
        window2.isHidden = true
    }
}
