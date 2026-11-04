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
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        historyRequested = true
        while !releaseHistory { try await Task.sleep(for: .milliseconds(10)) }
        return try await preview.history(for: target)
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
    private func transcript(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.width > 300, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap(transcript).first
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The hosted reading fixture must settle")
    }
    func testFiveLiveItemsThenHistoryCannotSaveAnOffsetResetAsReadingIntent() async throws {
        let service = HistoryReadingService()
        let loading = CompanionStore(service: service), target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        loading.apply(.hosts(hosts))
        for id in 0..<5 {
            loading.apply(.upsert(target, .message(.init(id: "live-\(id)", role: .assistant,
                text: String(repeating: "Live preview update. ", count: 40))), sequence: nil))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
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
