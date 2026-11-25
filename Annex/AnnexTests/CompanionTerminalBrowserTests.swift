import SafariServices
import Testing
import UIKit
@testable import ClubhouseGo

/// The in-app browser for terminal links, presented over a window's root controller (standing in for the terminal).
/// Safari's remote view won't stay up in a unit-test host, so a plain controller stands in for it here; the UI test
/// presents the real one. What a unit-test host cannot model is a presentation that completes and then an outside
/// dismissal (on iOS 26.5 the stand-in's `isBeingPresented` never clears here): that stale-browser case, where every
/// presentation is cleared from outside and Open must still work, is
/// `CompanionDispatcherLaunchUITests.testClearingPresentationsFromOutsideLeavesOpenWorkingAndClosesTheOldShell`,
/// in the real app.
@MainActor struct CompanionTerminalBrowserTests {
    private let link = CompanionTerminalLink("https://claude.example.test/oauth/authorize?code=true&client_id=SYNTH")!

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

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
    /// None of this needs UIKit to have finished a presentation or to complete a dismissal.
    @Test func oneBrowserAtATimeAndDoneReportsOnce() throws {
        let (window, root) = try window()
        defer { window.isHidden = true }

        // One browser at a time, and a refused Open never reports back.
        var refused = 0
        #expect(open(over: root))
        let first = try #require(CompanionInAppBrowser.current)
        #expect(CompanionInAppBrowser.isPresented)
        #expect(!open(over: root) { refused += 1 }, "One browser at a time")
        #expect(CompanionInAppBrowser.current === first, "The refused Open leaves the browser that is up alone")
        #expect(refused == 0)

        // Done tells its delegate (twice here: it must still report once) and forgets the browser, so Open works again.
        var finished = 0
        first.safariViewControllerDidFinish(SFSafariViewController(url: link.url))
        first.safariViewControllerDidFinish(SFSafariViewController(url: link.url))
        #expect(CompanionInAppBrowser.current == nil)
        #expect(!CompanionInAppBrowser.isPresented)
        #expect(open(over: root) { finished += 1 })
        let second = try #require(CompanionInAppBrowser.current)
        #expect(second !== first)
        second.safariViewControllerDidFinish(SFSafariViewController(url: link.url))
        second.safariViewControllerDidFinish(SFSafariViewController(url: link.url))
        #expect(finished == 1)
        #expect(CompanionInAppBrowser.current == nil)
    }
}
