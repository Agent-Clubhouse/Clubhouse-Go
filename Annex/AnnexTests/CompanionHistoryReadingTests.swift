import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

@MainActor private final class HistoryReadingService: CompanionService {
    // Test fixture owns only the ARC-only preview and scalar gate state.
    nonisolated deinit {}
    let preview = CompanionPreviewService(showsReadingScenario: true)
    var historyRequested = false
    var releaseHistory = false
    var hasEarlierMessages = false
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        historyRequested = true
        while !releaseHistory { try await Task.sleep(for: .milliseconds(10)) }
        var history = try await preview.history(for: target)
        history.hasEarlierMessages = hasEarlierMessages
        return history
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
}

@MainActor final class CompanionHistoryReadingTests: XCTestCase {
    private final class NativeTopDelegate: NSObject, UIScrollViewDelegate {
        var allowsTop = true
        var topRequests = 0
        var scrolls = 0
        var scrolled: (@MainActor (UIScrollView) -> Void)?
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { topRequests += 1; return allowsTop }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrolls += 1; scrolled?(scrollView) }
    }

    private func transcript(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.width > 300, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap(transcript).first
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The hosted reading fixture must settle")
    }

    func testNativeTopAdapterPreservesTheEnclosingScrollDelegate() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: window.bounds.width, height: window.bounds.height * 3)
        let original = NativeTopDelegate()
        scroll.delegate = original
        let anchor = CompanionNativeScrollTopObserver.Anchor()
        var requests = 0
        var nativeMetrics: CompanionScrollMetrics?
        anchor.geometryChanged = { nativeMetrics = $0 }
        anchor.requested = { requests += 1 }
        scroll.addSubview(anchor)
        controller.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer { anchor.disconnect(); window.isHidden = true; window.rootViewController = nil }
        scroll.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 100, right: 0)
        scroll.bounds.size.height -= 50
        scroll.contentOffset.y = 500
        XCTAssertTrue(scroll.delegate === anchor)
        nativeMetrics = nil
        original.scrolled = { scroll in
            XCTAssertEqual(nativeMetrics, CompanionScrollMetrics(offset: scroll.contentOffset.y, contentHeight: scroll.contentSize.height,
                containerHeight: scroll.bounds.height, topInset: scroll.adjustedContentInset.top, bottomInset: scroll.adjustedContentInset.bottom),
                "The native viewport must be available before SwiftUI processes its forwarded scroll callback")
        }
        let before = original.scrolls
        scroll.delegate?.scrollViewDidScroll?(scroll)
        XCTAssertEqual(original.scrolls, before + 1, "Unintercepted SwiftUI delegate callbacks must still be delivered")
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == true)
        XCTAssertEqual(requests, 1)
        original.allowsTop = false
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == false)
        XCTAssertEqual(original.topRequests, 2)
        XCTAssertEqual(requests, 1, "A veto must not pause following")

        let replacement = NativeTopDelegate()
        scroll.delegate = replacement
        anchor.connect()
        XCTAssertTrue(scroll.delegate === anchor)
        anchor.disconnect()
        XCTAssertTrue(scroll.delegate === replacement, "Dismantling must restore the latest delegate")
    }

    func testNativeTopAdapterSurvivesItsOriginalDelegate() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: window.bounds.width, height: window.bounds.height * 3)
        var original: NativeTopDelegate? = NativeTopDelegate()
        weak var weakOriginal = original
        scroll.delegate = original
        let anchor = CompanionNativeScrollTopObserver.Anchor()
        scroll.addSubview(anchor)
        controller.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer { anchor.disconnect(); window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset.y = 500
        XCTAssertTrue(scroll.delegate === anchor)
        XCTAssertGreaterThan(original?.scrolls ?? 0, 0)
        original = nil
        XCTAssertNil(weakOriginal)
        scroll.contentOffset.y = 600
        XCTAssertTrue(scroll.delegate === anchor)
    }

    func testNativeTopAdapterPreservesUIKitDefaultsWithoutAnOriginalDelegate() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: window.bounds.width, height: window.bounds.height * 3)
        scroll.maximumZoomScale = 3
        let zoomRect = CGRect(origin: .zero, size: CGSize(width: window.bounds.width / 2, height: window.bounds.height / 2))
        scroll.zoom(to: zoomRect, animated: false)
        let unadaptedZoom = scroll.zoomScale
        let anchor = CompanionNativeScrollTopObserver.Anchor()
        var requests = 0
        anchor.requested = { requests += 1 }
        scroll.addSubview(anchor)
        controller.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer { anchor.disconnect(); window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset.y = 500
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == true)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(scroll.delegate?.viewForZooming?(in: scroll))
        scroll.zoom(to: zoomRect, animated: false)
        XCTAssertEqual(scroll.zoomScale, unadaptedZoom, "An absent zoom view must retain UIKit's disabled-zoom behavior")
        var target = CGPoint(x: 7, y: 11)
        scroll.delegate?.scrollViewWillEndDragging?(scroll, withVelocity: CGPoint(x: 1, y: 2), targetContentOffset: &target)
        XCTAssertEqual(target, CGPoint(x: 7, y: 11), "An absent drag callback must not change UIKit's target")
    }

    func testNativeTopBookmarkSurvivesYieldedHistoryRestore() async throws {
        let service = HistoryReadingService()
        service.releaseHistory = true
        let store = CompanionStore(service: service), target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        func mount() {
            window.rootViewController = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
            window.makeKeyAndVisible()
        }
        mount()
        defer { window.isHidden = true; window.rootViewController = nil }
        let bookmark = store.readingBookmark(for: target)
        try await waitUntil { bookmark.viewport.hasInitialized && bookmark.viewport.metrics?.isAtTrueBottom == true }
        let entry = "message:reading-100"
        let frame = try XCTUnwrap(bookmark.viewport.frames[entry])
        let seed = CompanionReadingPosition(followsLatest: false, entryID: entry,
            distanceFromEntry: 8, offset: frame.lowerBound + 8, shownEntries: bookmark.position.shownEntries)
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(50))
        bookmark.position = seed
        mount()
        try await waitUntil {
            bookmark.viewport.hasInitialized && !bookmark.viewport.isRestoring
                && abs((bookmark.viewport.metrics?.normalizedOffset ?? -1) - seed.offset) <= 1
        }
        var interceptedYield = false
        let monitor = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if !bookmark.viewport.hasInitialized, let restore = bookmark.viewport.restoration, restore.outcome == nil {
                    let scroll = try XCTUnwrap(self.transcript(window))
                    XCTAssertGreaterThan(scroll.contentOffset.y + scroll.adjustedContentInset.top, 500)
                    XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) ?? false)
                    XCTAssertTrue(bookmark.viewport.isScrollingToTop)
                    XCTAssertEqual(bookmark.position.offset, 0, accuracy: 1)
                    interceptedYield = true
                    let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !bookmark.viewport.hasInitialized, !Task.isCancelled, ContinuousClock.now < restoreDeadline {
                        await Task.yield()
                    }
                    XCTAssertTrue(bookmark.viewport.hasInitialized)
                    XCTAssertTrue(bookmark.viewport.isScrollingToTop)
                    XCTAssertEqual(bookmark.position.offset, 0, accuracy: 1, "The yielded history task must not save its pre-native offset over the top bookmark")
                    return
                }
                await Task.yield()
            }
            XCTFail("Did not intercept the yielded history task")
        }
        defer { monitor.cancel() }
        await store.load(target, force: true)
        try await monitor.value
        XCTAssertTrue(interceptedYield)
    }

    func testNewHistoryRestorationCannotReclaimPendingNativeTop() async throws {
        let service = HistoryReadingService()
        service.releaseHistory = true
        let store = CompanionStore(service: service), target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        window.rootViewController = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let bookmark = store.readingBookmark(for: target)
        try await waitUntil { bookmark.viewport.hasInitialized && bookmark.viewport.metrics?.isAtTrueBottom == true }
        let scroll = try XCTUnwrap(transcript(window))
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) ?? false)
        XCTAssertTrue(bookmark.viewport.isScrollingToTop)
        XCTAssertEqual(bookmark.position.offset, 0, accuracy: 1)
        service.hasEarlierMessages = true
        await store.load(target, force: true)
        let revision = store.conversation(for: target).historyRevision
        try await waitUntil {
            bookmark.viewport.historyRevision == revision && bookmark.viewport.hasInitialized
                && !bookmark.viewport.isRestoring && bookmark.viewport.restoration?.outcome != nil
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1,
                       "A new history restore must not reclaim a pending native-top request")
        XCTAssertEqual(bookmark.position.offset, 0, accuracy: 1)
    }

    func testNativeTopRepairIsOneShotAndNewUserIntentDisarmsIt() async throws {
        for intent in ["stalled", "ended", "drag", "navigation"] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
            let controller = UIViewController()
            window.rootViewController = controller
            let scroll = UIScrollView(frame: window.bounds)
            scroll.contentSize = CGSize(width: window.bounds.width, height: window.bounds.height * 3)
            let anchor = CompanionNativeScrollTopObserver.Anchor()
            var pending = false, repairs = 0
            anchor.requested = { pending = true }
            anchor.pending = { pending }
            anchor.repaired = { repairs += 1 }
            scroll.addSubview(anchor)
            controller.view.addSubview(scroll)
            window.makeKeyAndVisible()
            defer { anchor.disconnect(); window.isHidden = true; window.rootViewController = nil }
            scroll.contentOffset.y = 500
            XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == true)
            if intent == "drag" { scroll.delegate?.scrollViewWillBeginDragging?(scroll) }
            if intent == "navigation" { pending = false }
            if intent == "ended" {
                scroll.contentOffset.y = 250
                scroll.delegate?.scrollViewDidEndScrollingAnimation?(scroll)
            }
            if intent == "stalled" || intent == "ended" {
                try await waitUntil { repairs == 1 }
                XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
            }
            scroll.contentOffset.y = 600
            let intentOffset = scroll.contentOffset.y + scroll.adjustedContentInset.top
            scroll.delegate?.scrollViewDidEndScrollingAnimation?(scroll)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(repairs, intent == "stalled" || intent == "ended" ? 1 : 0, intent)
            XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, intentOffset, accuracy: 1,
                           "A repair must never override newer intent: \(intent)")
        }
    }

    func testNativeTopOwnsTheViewportBeforeTheFirstAnimationSample() async throws {
        let service = HistoryReadingService()
        service.releaseHistory = true
        let store = CompanionStore(service: service), target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        window.rootViewController = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let bookmark = store.readingBookmark(for: target)
        try await waitUntil { bookmark.viewport.hasInitialized && bookmark.viewport.metrics?.isAtTrueBottom == true }
        let scroll = try XCTUnwrap(transcript(window))
        XCTAssertGreaterThan(scroll.contentOffset.y + scroll.adjustedContentInset.top, 500)

        // UIKit asks before moving. Deliver a chunk in that same turn, before
        // SwiftUI can publish the native animation's first upward geometry.
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) ?? true)
        XCTAssertFalse(bookmark.position.followsLatest, "The explicit request must pause before any offset changes")
        let before = scroll.contentSize.height
        store.apply(.upsert(target, .message(.init(id: "reading-helper", role: .assistant,
            text: String(repeating: "A chunk arriving as the native jump starts. ", count: 100),
            isStreaming: true, subagentID: "preview-helper")), sequence: nil))
        try await waitUntil { scroll.contentSize.height > before }
        XCTAssertFalse(bookmark.position.followsLatest, "A pending bottom sample cannot take ownership back")
        XCTAssertEqual(bookmark.position.offset, 0, accuracy: 1, "Pending geometry cannot replace the requested top bookmark")
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
        try await waitUntil { abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) <= 1 }
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1,
                       "A same-turn follow command must not cancel native top")
        XCTAssertFalse(bookmark.position.followsLatest)
        store.apply(.upsert(target, .message(.init(id: "reading-helper", role: .assistant,
            text: String(repeating: "The next chunk must leave the top alone. ", count: 120),
            isStreaming: true, subagentID: "preview-helper")), sequence: nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
        XCTAssertFalse(bookmark.position.followsLatest)
        XCTAssertFalse(bookmark.viewport.isScrollingToTop)
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await waitUntil { bookmark.position.followsLatest && bookmark.viewport.metrics?.isAtTrueBottom == true }
    }

    func testFiveLiveItemsThenHistoryCannotSaveAnOffsetResetAsReadingIntent() async throws {
        let service = HistoryReadingService()
        let loading = CompanionStore(service: service), target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        loading.apply(.hosts(hosts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        // Explicit paragraphs keep five items taller than the viewport even when iPad wraps less text.
        let paragraphs = Int(ceil((window.bounds.height + 600) / (5 * UIFont.preferredFont(forTextStyle: .body).lineHeight)))
        let liveText = String(repeating: "Live preview update.\n\n", count: paragraphs)
        for id in 0..<5 {
            loading.apply(.upsert(target, .message(.init(id: "live-\(id)", role: .assistant,
                text: liveText)), sequence: nil))
        }
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        window.rootViewController = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: loading, agent: agent) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(service.historyRequested)
        XCTAssertEqual(loading.conversation(for: target).items.count, 5)
        let scroll = try XCTUnwrap(transcript(window)), bookmark = loading.readingBookmark(for: target)
        let before = scroll.contentOffset.y + scroll.adjustedContentInset.top
        XCTAssertGreaterThan(before, 500)
        // Force the history-load offset reset seen on 26.5. No gesture or status-bar tap occurs.
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        service.releaseHistory = true
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        XCTAssertEqual(loading.conversation(for: target).items.count, 182)
        let followedAfterHistory = bookmark.position.followsLatest
        let reachedBottom = bookmark.viewport.metrics?.isAtTrueBottom == true
        XCTAssertTrue(followedAfterHistory, "The reset must not persist a false reading choice")
        XCTAssertTrue(reachedBottom, "Loaded history re-anchors the follower")
        // UIKit's raw offset assignment did not establish a paused SwiftUI state on 26.5;
        // why it differs is unknown. Real drags/native taps are covered by the reading UI suite.
        // Here, explicitly restore a saved reading bookmark before testing a full refresh.
        let rawScroll = scroll
        rawScroll.setContentOffset(CGPoint(x: 0, y: 200 - rawScroll.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        let activeScroll = try XCTUnwrap(transcript(window))
        print("HISTORY_RAW targetAttached=\(rawScroll.window === window ? 1 : 0) sameTarget=\(rawScroll === activeScroll ? 1 : 0) rawOffset=\(rawScroll.contentOffset.y) activeOffset=\(activeScroll.contentOffset.y) following=\(bookmark.position.followsLatest ? 1 : 0)")
        let entry = "message:reading-100"
        let frame = try XCTUnwrap(bookmark.viewport.frames[entry])
        let seed = CompanionReadingPosition(followsLatest: false, entryID: entry,
            distanceFromEntry: 8, offset: frame.lowerBound + 8, shownEntries: bookmark.position.shownEntries)
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(50))
        bookmark.position = seed
        window.rootViewController = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: loading, agent: agent) })
        window.makeKeyAndVisible()
        try await waitUntil {
            !bookmark.viewport.isRestoring && bookmark.position.entryID == entry
                && abs((bookmark.viewport.metrics?.normalizedOffset ?? -1) - seed.offset) <= 1
        }
        let saved = bookmark.position
        XCTAssertFalse(saved.followsLatest)
        XCTAssertEqual(saved.entryID, seed.entryID)
        XCTAssertEqual(saved.distanceFromEntry, seed.distanceFromEntry, accuracy: 1)

        // Force another offset reset at the new history's first body pass, before its anchoring task.
        // Without the revision gate this overwrites the real reading bookmark and fails below.
        let previousRevision = loading.conversation(for: target).historyRevision
        var resetDuringRefresh = false
        CompanionConversationBuildProbe.record = { kind, incoming in
            guard kind == .body, incoming == target, !resetDuringRefresh,
                  loading.conversation(for: target).historyRevision != previousRevision else { return }
            resetDuringRefresh = true
            if let current = self.transcript(window) {
                current.setContentOffset(CGPoint(x: 0, y: -current.adjustedContentInset.top), animated: false)
            }
        }
        defer { CompanionConversationBuildProbe.record = nil }
        await loading.load(target, force: true)
        try await waitUntil {
            resetDuringRefresh && !bookmark.viewport.isRestoring && bookmark.position.entryID == saved.entryID
                && abs((bookmark.viewport.metrics?.normalizedOffset ?? -1) - saved.offset) <= 1
        }
        XCTAssertTrue(resetDuringRefresh)
        XCTAssertFalse(bookmark.position.followsLatest)
        XCTAssertEqual(bookmark.position.entryID, saved.entryID)
        XCTAssertEqual(bookmark.position.distanceFromEntry, saved.distanceFromEntry, accuracy: 1)
        XCTAssertEqual(bookmark.viewport.metrics?.normalizedOffset ?? -1, saved.offset, accuracy: 1)
        let retained = saved.entryID != nil && bookmark.position.entryID == saved.entryID
            && abs(bookmark.position.distanceFromEntry - saved.distanceFromEntry) <= 1
        print("HISTORY_READING partialCount=5 fullCount=182 oldOffset=\(before) forcedOffset=0 followsAfterHistory=\(followedAfterHistory ? 1 : 0) reachedBottom=\(reachedBottom ? 1 : 0) readingRefreshRetained=\(retained ? 1 : 0)")
    }
}
