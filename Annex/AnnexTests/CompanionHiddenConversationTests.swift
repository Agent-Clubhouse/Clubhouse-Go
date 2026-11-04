import Testing
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Real hosted views, long preview histories, and separately rendered store events. Bounds count work, not time.
@MainActor @Suite(.serialized) struct CompanionHiddenConversationTests {
    enum Hidden: String, CaseIterable { case tab, desktop }
    @Observable final class Navigation {
        var tab = 0
        var desktop = 0
    }
    private struct Fixture: View {
        let store: CompanionStore
        let agents: [CompanionAgent]
        @Bindable var navigation: Navigation
        var body: some View {
            TabView(selection: $navigation.tab) {
                Tab("Dispatcher", systemImage: "sparkles", value: 0) {
                    NavigationStack {
                        ZStack {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                                let visible = navigation.tab == 0 && navigation.desktop == index
                                CompanionConversationView(store: store, agent: agent, showsActions: visible, isVisible: visible)
                                    .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                            }
                        }
                    }
                }
                Tab("Home", systemImage: "house", value: 1) { Text("Home") }
            }
        }
    }
    @MainActor private final class Counts {
        var bodies: [CompanionTarget: Int] = [:]
        var timelines: [CompanionTarget: Int] = [:]
        func record(_ kind: CompanionConversationBuildProbe.Kind, _ target: CompanionTarget) {
            switch kind {
            case .body: bodies[target, default: 0] += 1
            case .timeline: timelines[target, default: 0] += 1
            }
        }
        func reset() { bodies = [:]; timelines = [:] }
    }
    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    private func transcript(in view: UIView) -> UIScrollView? {
        if view.isHidden || view.alpha == 0 { return nil }
        if let scroll = view as? UIScrollView, scroll.bounds.width > 300,
           scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }

    private func touchObserver(in view: UIView) -> CompanionReadingTouchObserver.Anchor? {
        if let anchor = view as? CompanionReadingTouchObserver.Anchor { return anchor }
        return view.subviews.lazy.compactMap { touchObserver(in: $0) }.first
    }

    @Test(arguments: Hidden.allCases) func hiddenStreamsDoNoTimelineWork(hidden: Hidden) async throws {
        try await exercise(hidden: hidden, dropFirstRestore: false)
    }
    @Test func lostRestoreCommandRecoversWhileStreaming() async throws {
        try await exercise(hidden: .tab, dropFirstRestore: true)
    }
    @Test func touchDuringRetryWindowKeepsTheUsersPosition() async throws {
        try await exercise(hidden: .tab, dropFirstRestore: true, touchDuringRestore: true)
    }
    @Test func timeoutPreservesBookmarkAndTheNextMountRetriesIt() async throws {
        try await exercise(hidden: .tab, dropFirstRestore: true, timeoutRestore: true)
    }
    private func exercise(hidden: Hidden, dropFirstRestore: Bool, touchDuringRestore: Bool = false, timeoutRestore: Bool = false) async throws {
        let service = CompanionPreviewService(showsLongReply: true, showsDispatcher: true, showsMultipleDispatchers: true)
        let store = CompanionStore(service: service)
        var events = service.events().makeAsyncIterator()
        store.apply(try #require(await events.next()))
        let agents = store.hosts.compactMap(\.dispatcher?.liveAgent)
        #expect(agents.count == 2)
        for agent in agents { await store.load(agent.id) }
        let target = agents[0].id
        #expect(store.conversation(for: target).items.reduce(0) { count, item in
            if case .message(let message) = item { count + message.text.count } else { count }
        } > 50_000)
        store.drafts[target] = "Draft for this desktop"
        let navigation = Navigation()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        window.rootViewController = UIHostingController(rootView: Fixture(store: store, agents: agents, navigation: navigation))
        window.makeKeyAndVisible()
        let counts = Counts()
        CompanionConversationBuildProbe.record = { counts.record($0, $1) }
        defer { CompanionConversationBuildProbe.record = nil; window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        try await settle(window)

        // Prove the counter sees real rendering, but do not require a full visible rebuild per chunk: the active
        // chat may legitimately update just a row as its separate streaming optimizations evolve.
        #expect(counts.timelines[target, default: 0] > 0)
        counts.reset()
        let visibleEvents = 5
        for _ in 0..<visibleEvents {
            store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " visible", sequence: nil))
            try await settle(window)
        }
        let visibleBodies = counts.bodies[target, default: 0]
        let visibleTimelines = counts.timelines[target, default: 0]

        // Move through the top first, which stops follow-latest just like the status-bar gesture. Then preserve an
        // arbitrary reading offset, not just a latest/top flag, through hidden events and a newly mounted scroll view.
        weak var originalObserver = try #require(touchObserver(in: window))
        let recognizer = try #require(window.gestureRecognizers?.first { String(describing: type(of: $0)).contains("ReadingOpeningTouch") })
        #expect(!recognizer.cancelsTouchesInView)
        #expect(!recognizer.delaysTouchesBegan)
        #expect(!recognizer.delaysTouchesEnded)
        let before = try #require(transcript(in: window))
        before.setContentOffset(CGPoint(x: 0, y: -before.adjustedContentInset.top), animated: false)
        try await settle(window)
        before.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        try await settle(window)
        let readingOffset = before.contentOffset.y + before.adjustedContentInset.top
        let bookmark = store.readingBookmark(for: target)
        let entryID = try #require(bookmark.position.entryID, "The shared reading bookmark captures an entry")
        #expect(!bookmark.position.followsLatest)

        switch hidden { case .tab: navigation.tab = 1; case .desktop: navigation.desktop = 1 }
        try await settle(window)
        counts.reset()
        let streamedEvents = 20
        for _ in 0..<streamedEvents {
            store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " hidden", sequence: nil))
            try await settle(window)
        }
        let hiddenBodies = counts.bodies[target, default: 0]
        let hiddenTimelines = counts.timelines[target, default: 0]
        print("HIDDEN_STREAM_MEASUREMENT case=\(hidden.rawValue) visibleEvents=\(visibleEvents) visibleBody=\(visibleBodies) visibleTimeline=\(visibleTimelines) hiddenEvents=\(streamedEvents) hiddenBody=\(hiddenBodies) hiddenTimeline=\(hiddenTimelines)")
        #expect(bookmark.position.entryID == entryID, "Unmounting retains the shared entry bookmark")
        #expect(bookmark.viewport.metrics == nil, "Unmounting clears mounted geometry, not the bookmark")
        #expect(originalObserver?.window == nil, "The touch observer detaches on unmount")
        #expect(hiddenTimelines == 0, "Hidden conversations must do zero timeline builds for 20 streamed events")
        #expect(store.drafts[target] == "Draft for this desktop")

        func diagnostic(_ stage: String) {
            let view = bookmark.viewport
            let offset = view.metrics?.normalizedOffset ?? -1
            print("HIDDEN_RESTORE_DIAGNOSTIC case=\(hidden.rawValue) stage=\(stage) geometryOffset=\(offset) saved=\(bookmark.position.offset) follows=\(bookmark.position.followsLatest) entryPresent=\(bookmark.position.entryID.map { view.frames[$0] != nil } ?? false) frames=\(view.frames.count) initialized=\(view.hasInitialized) restoring=\(view.isRestoring) ready=\(view.acceptsGeometry(historyRevision: store.conversation(for: target).historyRevision, isLoaded: store.conversation(for: target).isLoaded)) restoreOffset=\(view.restoreOffset ?? -1)")
        }
        diagnostic("hidden")
        let clock = ContinuousClock()
        let started = clock.now
        var requests: [Double] = []
        if dropFirstRestore {
            CompanionReadingRestoreProbe.deliver = { _, attempt, offset, phaseChanged in
                requests.append(offset)
                if attempt == 1 {
                    phaseChanged(.animating)
                    phaseChanged(.idle)
                    #expect(bookmark.viewport.restoration?.outcome == nil, "Non-user phases cannot cancel initial delivery")
                    #expect(bookmark.viewport.isRestoring)
                    #expect(abs(bookmark.position.offset - readingOffset) <= 2, "Non-user phases cannot save the bottom before arrival")
                    if touchDuringRestore {
                        // Invoke the installed passive recognizer's public touch-down path,
                        // then model the drag's offset. No private UIKit touch construction.
                        let anchor = self.touchObserver(in: window)
                        #expect(anchor != nil)
                        anchor?.touchBegan(at: CGPoint(x: -10, y: -10))
                        #expect(bookmark.viewport.restoration?.outcome == nil, "A touch outside the transcript must not cancel")
                        anchor?.touchBegan(at: CGPoint(x: 10, y: 10))
                        let scroll = self.transcript(in: window)
                        #expect(scroll != nil)
                        scroll?.setContentOffset(CGPoint(x: 0, y: 2_400 - (scroll?.adjustedContentInset.top ?? 0)), animated: false)
                    }
                    store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " during restore", sequence: nil))
                    return false
                }
                return !timeoutRestore
            }
        }
        defer { CompanionReadingRestoreProbe.deliver = nil }
        navigation.tab = 0; navigation.desktop = 0
        var firstReadyMs: Double?
        var loggedEarlyState = false
        func restorationReady() -> Bool {
            let viewport = bookmark.viewport
            return viewport.acceptsGeometry(historyRevision: store.conversation(for: target).historyRevision,
                                            isLoaded: store.conversation(for: target).isLoaded)
                && !viewport.isRestoring
        }
        func elapsedMs() -> Double {
            let duration = started.duration(to: clock.now).components
            return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        }
        // Wait for completion, never for the expected offset: a completed restore to the
        // wrong place must still fail the original two-point assertion below. The old
        // two 100ms sleeps could sample the mounted scroll view before its restore task ran.
        while elapsedMs() < 3_000 {
            window.layoutIfNeeded()
            if restorationReady(), firstReadyMs == nil { firstReadyMs = elapsedMs() }
            if elapsedMs() >= 200 {
                if !loggedEarlyState { diagnostic("200ms"); loggedEarlyState = true }
                if restorationReady() { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = restorationReady()
        print("HIDDEN_RESTORE_TIMING case=\(hidden.rawValue) firstObservedReadyMs=\(firstReadyMs ?? -1) observedCompletionMs=\(elapsedMs()) ready=\(ready)")
        diagnostic(ready ? "completed" : "timeout")
        #expect(ready, "Restoration must complete within three seconds; see HIDDEN_RESTORE_DIAGNOSTIC and HIDDEN_RESTORE_TIMING")
        if timeoutRestore {
            #expect(bookmark.viewport.restoration?.outcome == .exhausted)
            #expect(!bookmark.viewport.isRestoring)
            #expect(bookmark.viewport.preserveBookmarkUntilUserAction)
            #expect(abs(bookmark.position.offset - readingOffset) <= 2, "Timeout must preserve the reading bookmark, never the bottom")
            #expect(!bookmark.position.followsLatest)
            navigation.tab = 1
            try await settle(window)
            CompanionReadingRestoreProbe.deliver = nil
            navigation.tab = 0
            let retryStarted = clock.now
            while !restorationReady(), retryStarted.duration(to: clock.now) < .seconds(3) {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(restorationReady(), "A later mount retries the preserved bookmark")
        }
        let restored = try #require(transcript(in: window))
        let restoredOffset = restored.contentOffset.y + restored.adjustedContentInset.top
        print("HIDDEN_SCROLL_MEASUREMENT case=\(hidden.rawValue) before=\(readingOffset) restored=\(restoredOffset)")
        if touchDuringRestore {
            #expect(abs(restoredOffset - 2_400) <= 2, "Touch-down cancels restoration before the user's drag offset")
            #expect(requests.count == 1, "No late retry may overwrite the user")
            #expect(bookmark.viewport.restoration?.outcome == .touch)
        } else {
            #expect(abs(restoredOffset - readingOffset) <= 2, "The reading offset survives unmounting within two points")
        }
        if dropFirstRestore && !touchDuringRestore && !timeoutRestore {
            #expect(requests.count >= 2, "Dropping the first command requires another delivery")
            #expect(requests.count <= CompanionReadingRestoration.maximumAttempts)
            #expect(requests.allSatisfy { $0 == requests.first }, "Streaming must not move the frozen restore target")
        }
        #expect(counts.timelines[target, default: 0] >= 1, "Becoming visible remounts current history")
        counts.reset()
        store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " resumed", sequence: nil))
        try await settle(window)
        #expect(store.conversation(for: target).items.contains { item in
            if case .message(let message) = item { message.text.hasSuffix(String(repeating: " hidden", count: streamedEvents) + (dropFirstRestore ? " during restore" : "") + " resumed") } else { false }
        })
    }
}
