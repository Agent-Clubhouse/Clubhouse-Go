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

    /// Spins the run loop until `condition` holds, for at most `timeout` seconds; UIKit's presentation and dismissal
    /// bookkeeping lands on its own schedule (it varies by OS), so a fixed settle is not enough.
    private func wait(timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// One window for the whole test: a second window made in the same host is one more thing for a transition to
    /// wait on.
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

    /// What UIKit says about the stand-in page and the controller under it, for failures that must tell a harness that
    /// never finished a transition (UIKit really still has it up) from the product's own check being wrong.
    private func state(_ root: UIViewController, _ window: UIWindow, _ page: UIViewController?) -> Comment {
        Comment(rawValue: """
            page: presentingViewController=\(String(describing: page?.presentingViewController)) \
            isBeingPresented=\(String(describing: page?.isBeingPresented)) isBeingDismissed=\(String(describing: page?.isBeingDismissed)) \
            view.window=\(String(describing: page?.viewIfLoaded?.window)); \
            root.presentedViewController=\(String(describing: root.presentedViewController)); \
            window.isKeyWindow=\(window.isKeyWindow) isHidden=\(window.isHidden); \
            browser.isPresented=\(CompanionInAppBrowser.isPresented)
            """)
    }

    /// Opens the browser over `presenter` and, when it opened, waits for UIKit to finish presenting the stand-in, so a
    /// later outside dismissal is a dismissal of a presentation that completed. Returns the stand-in page, or nil when
    /// `present` refused.
    private func open(over presenter: UIViewController, in window: UIWindow, finished: @escaping () -> Void = {}) throws -> (shown: Bool, page: UIViewController?) {
        var page: UIViewController?
        let shown = CompanionInAppBrowser.present(link, over: presenter, animated: false, makeController: { _ in
            let made = UIViewController()
            page = made
            return made
        }, finished: finished)
        guard shown, let page else { settle(); return (shown, nil) }
        wait { page.presentingViewController != nil && !page.isBeingPresented }
        try #require(page.presentingViewController != nil && !page.isBeingPresented,
                     "Harness: the stand-in page's presentation never completed. \(state(presenter, window, page).rawValue)")
        settle()
        return (true, page)
    }

    /// Clears every presentation from outside, the way the Message Dispatcher App Intent does, and waits for UIKit to
    /// say it is done. A dismissal that never completes is the harness's failure, not the product's.
    private func dismissFromOutside(_ root: UIViewController, in window: UIWindow, page: UIViewController?) throws {
        var completed = false
        root.dismiss(animated: false) { completed = true }
        wait { completed && root.presentedViewController == nil }
        try #require(completed && root.presentedViewController == nil,
                     "Harness: the outside dismissal never completed (completed=\(completed)). \(state(root, window, page).rawValue)")
        wait { !CompanionInAppBrowser.isPresented }
    }

    /// One test, not two: both share the browser's static record, and spinning the run loop could interleave them.
    @Test func aStaleBrowserNeverBlocksOpenAndDoneReportsOnce() throws {
        // 1. Every presentation is cleared from outside (the Message Dispatcher App Intent): the page's own delegate
        // is never told, so its stale record must not make Open fail.
        let (window, root) = try window()
        defer { window.isHidden = true }
        let first = try open(over: root, in: window)
        #expect(first.shown)
        #expect(CompanionInAppBrowser.isPresented)
        #expect(!(try open(over: root, in: window).shown), "One browser at a time")
        try dismissFromOutside(root, in: window, page: first.page)
        #expect(!CompanionInAppBrowser.isPresented, "A completed outside dismissal must read as not presented. \(state(root, window, first.page).rawValue)")
        let second = try open(over: root, in: window)
        #expect(second.shown, "A stale browser must not make Open fail silently. \(state(root, window, first.page).rawValue)")
        #expect(CompanionInAppBrowser.isPresented)
        try dismissFromOutside(root, in: window, page: second.page)

        // 2. Done dismisses the page, then tells its delegate (twice here: it must still report once).
        var finished = 0
        let third = try open(over: root, in: window) { finished += 1 }
        #expect(third.shown, "\(state(root, window, third.page).rawValue)")
        let browser = try #require(CompanionInAppBrowser.current)
        try dismissFromOutside(root, in: window, page: third.page)
        let safari = SFSafariViewController(url: link.url)
        browser.safariViewControllerDidFinish(safari)
        browser.safariViewControllerDidFinish(safari)
        #expect(finished == 1)
        #expect(!CompanionInAppBrowser.isPresented)
        let fourth = try open(over: root, in: window)
        #expect(fourth.shown)
        try dismissFromOutside(root, in: window, page: fourth.page)
    }
}
