import Testing
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Actual SwiftUI State identity and first-body inputs, independently of final pixel restoration.
@MainActor @Suite(.serialized) struct CompanionReadingOpeningTests {
    @Observable final class Navigation {
        nonisolated deinit {}
        var visible = true
        var selected = 0
        var revision = 0
        var jump: CompanionDecisionChatJump?
    }
    private struct Host: View {
        let store: CompanionStore
        let agents: [CompanionAgent]
        @Bindable var navigation: Navigation
        private var chat: CompanionConversationView {
            var view = CompanionConversationView(store: store, agent: agents[navigation.selected], isVisible: navigation.visible)
            view.debugReadingJump = navigation.jump
            return view
        }
        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    // Deliberately reuse this parent identity when selected changes; the transcript must key itself.
                    chat
                    Text("Parent revision \(navigation.revision)").font(.caption)
                }
            }
        }
    }
    @MainActor private struct Fixture {
        let store: CompanionStore
        let agents: [CompanionAgent]
        let navigation: Navigation
        let window: UIWindow
        init() async throws {
            let service = CompanionPreviewService(showsReadingScenario: true)
            store = CompanionStore(service: service)
            var events = service.events().makeAsyncIterator()
            store.apply(try #require(await events.next()))
            agents = Array(store.hosts.flatMap(\.allAgents).filter { !$0.isDispatcher }.prefix(2))
            #expect(agents.count == 2)
            for agent in agents { await store.load(agent.id) }
            navigation = Navigation()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        }
        func mount() {
            window.rootViewController = UIHostingController(rootView: Host(store: store, agents: agents, navigation: navigation))
            window.makeKeyAndVisible()
        }
        func close() {
            CompanionReadingOpeningProbe.record = nil
            CompanionReadingOpeningProbe.didComputeSeed = nil
            CompanionConversationBuildProbe.record = nil
            CompanionReadingRestoreProbe.deliver = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        func pause(_ index: Int = 0, distance: Double = 0) {
            let bookmark = store.readingBookmark(for: agents[index].id)
            bookmark.position = .init(followsLatest: false, entryID: "message:reading-90", distanceFromEntry: distance,
                                      offset: 0, shownEntries: 300)
            bookmark.hasMounted = true
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(condition(), "A bounded mount/restore wait must fail if the product does not reach its state")
        }
        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
        }
    }

    @Test func pausedFirstBodyStartsAtItsCanonicalBookmarkWithoutAnIdentityRequest() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.agents[0].id)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        let first = try #require(samples.first { $0.phase == .body })
        #expect(!first.followsLatest && first.shownEntries == 300)
        #expect(first.requestedEntryID == nil && first.requestedTop && !first.requestedBottom && first.pointY == nil)
        #expect(first.windowStartID == "message:reading-90" && first.windowFirstID == first.windowStartID,
                "User-approved #582 UX replaces the old expanded-prefix inequality")
        #expect(first.latestVisible, "Latest must be available from the paused semantic state before geometry")
        let scrolled = try #require(samples.first { $0.phase == .scroll })
        #expect(scrolled.requestedEntryID == nil && scrolled.pointY != nil,
                "The initial ID must not retain a competing implicit anchor after numeric restoration starts")
        let saved = bookmark.position
        let lower = try #require(saved.entryID.flatMap { bookmark.viewport.frames[$0]?.lowerBound })
        let offset = try #require(bookmark.viewport.metrics?.normalizedOffset)
        #expect(abs(offset - (lower + saved.distanceFromEntry)) <= 6)
    }

    @Test func parentRecreationAndOpenReloadDoNotReseedOrShrinkTheReadersWindow() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause()
        let target = f.agents[0].id
        var seedCounts: [CompanionTarget: Int] = [:]
        var parentBodies = 0
        CompanionReadingOpeningProbe.didComputeSeed = { seedCounts[$0, default: 0] += 1 }
        CompanionConversationBuildProbe.record = { kind, observed in
            if observed == target, case .body = kind { parentBodies += 1 }
        }
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.agents[0].id)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        let first = try #require(samples.first { $0.phase == .body })
        let saved = bookmark.position
        #expect(seedCounts[target] == 1)
        for _ in 0..<5 { f.navigation.revision += 1; try await f.settle() }
        let beforeChunks = seedCounts[target, default: 0]
        let parentBefore = parentBodies
        for _ in 0..<20 {
            f.store.apply(.textDelta(target, messageID: "reading-helper", text: " streamed", sequence: nil))
            try await f.settle()
        }
        #expect(parentBodies > parentBefore, "This must observe real parent re-evaluation while paused")
        #expect(seedCounts[target] == beforeChunks && beforeChunks == 1,
                "No opening seed or its candidate slicing may run per chunk or discarded initializer")
        print("READING_OPENING_SEED chunks=20 before=\(beforeChunks) after=\(seedCounts[target, default: 0]) parentBodyDelta=\(parentBodies - parentBefore)")
        await f.store.load(f.agents[0].id, force: true)
        try await f.wait { bookmark.viewport.historyRevision == f.store.conversation(for: f.agents[0].id).historyRevision
            && bookmark.viewport.restoration?.outcome == .arrived }
        #expect(Set(samples.map(\.mountID)) == [first.mountID], "A reload is not a mount boundary")
        #expect(seedCounts[target] == 1, "Reload/resync keeps the immutable opening seed")
        #expect(samples.filter { $0.phase == .body }.allSatisfy { $0.shownEntries >= 300 && !$0.followsLatest })
        let frame = try #require(saved.entryID.flatMap { bookmark.viewport.frames[$0] })
        #expect(abs((bookmark.viewport.metrics?.normalizedOffset ?? -.infinity) - frame.lowerBound - saved.distanceFromEntry) <= 6)
    }

    @Test func followingStreamAndParentRecreationComputeOnlyOneOpeningSeed() async throws {
        let f = try await Fixture()
        defer { f.close() }
        let target = f.agents[0].id
        var seeds = 0
        CompanionReadingOpeningProbe.didComputeSeed = { if $0 == target { seeds += 1 } }
        f.mount()
        try await f.wait { seeds == 1 && f.store.readingBookmark(for: target).viewport.metrics != nil }
        for _ in 0..<20 {
            f.navigation.revision += 1
            f.store.apply(.textDelta(target, messageID: "reading-helper", text: " streamed", sequence: nil))
            try await f.settle()
        }
        #expect(seeds == 1, "Following streaming and discarded parent initializers cannot recompute or slice the opening seed")
        #expect(f.store.readingBookmark(for: target).position.followsLatest)
        print("READING_OPENING_SEED followingChunks=20 seeds=\(seeds)")
    }

    @Test func hiddenReloadReseedsOnceAndTargetSwitchesCannotBorrowAnotherChatsState() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause()
        f.store.drafts[f.agents[0].id] = "First chat draft"
        f.store.drafts[f.agents[1].id] = "Second chat draft"
        var seedCounts: [CompanionTarget: Int] = [:]
        CompanionReadingOpeningProbe.didComputeSeed = { seedCounts[$0, default: 0] += 1 }
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let target = f.agents[0].id
        let bookmark = f.store.readingBookmark(for: target)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        let originalID = try #require(samples.first?.mountID)
        f.navigation.visible = false
        try await f.settle()
        #expect(bookmark.viewport.metrics == nil)
        let hiddenCount = samples.count
        await f.store.load(target, force: true)
        try await f.settle()
        #expect(samples.count == hiddenCount, "A hidden transcript must not build a seed or body")
        #expect(seedCounts[target] == 1)
        f.navigation.visible = true
        try await f.wait { samples.contains { $0.phase == .body && $0.mountID != originalID } }
        let secondID = try #require(samples.last?.mountID)
        #expect(Set(samples.map(\.mountID)) == [originalID, secondID])
        #expect(seedCounts[target] == 2, "Exactly one seed is computed on re-show after hidden reload")
        let reopened = try #require(samples.first { $0.phase == .body && $0.mountID == secondID })
        #expect(reopened.windowFirstID == reopened.windowStartID && reopened.requestedTop && reopened.requestedEntryID == nil)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        f.navigation.selected = 1
        try await f.wait { samples.contains { $0.target == f.agents[1].id && $0.phase == .body } }
        let other = try #require(samples.first { $0.target == f.agents[1].id && $0.phase == .body })
        #expect(other.followsLatest && other.requestedBottom && other.requestedEntryID == nil)
        #expect(other.mountID != secondID)
        #expect(seedCounts[f.agents[1].id] == 1 && seedCounts[target] == 2)
        #expect(!bookmark.position.followsLatest && f.store.readingBookmark(for: f.agents[1].id).position.followsLatest)
        #expect(f.store.drafts[target] == "First chat draft" && f.store.drafts[f.agents[1].id] == "Second chat draft")
    }

    @Test func groupedQuestionAliasUsesTheVisibleGroupOnTheFirstBody() async throws {
        let f = try await Fixture()
        defer { f.close() }
        let target = f.agents[0].id
        let first = CompanionQuestion(id: "first", prompts: [])
        let later = CompanionQuestion(id: "later", prompts: [], hasUnreadablePrompts: true)
        f.store.apply(.timeline(target, items: [.question(first), .question(later)], sequence: 1, reset: true))
        let bookmark = f.store.readingBookmark(for: target)
        bookmark.hasMounted = true
        bookmark.position = .init(followsLatest: false, entryID: "question:later")
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        try await f.wait { samples.contains { $0.phase == .body } }
        let opening = try #require(samples.first { $0.phase == .body })
        #expect(opening.requestedEntryID == nil && opening.requestedTop && !opening.requestedBottom)
        #expect(opening.windowStartID == "question:first" && opening.windowFirstID == "question:first")
    }

    @Test func removedEntryAndReplacementSessionDoNotInstallAStaleInitialPixelTarget() async throws {
        let f = try await Fixture()
        defer { f.close() }
        let target = f.agents[0].id
        f.store.apply(.timeline(target, items: [.message(.init(id: "new-session", role: .assistant, text: "New history"))],
                                sequence: 1, reset: true, sessionID: "new-session"))
        let bookmark = f.store.readingBookmark(for: target)
        bookmark.hasMounted = true
        bookmark.position = .init(followsLatest: false, entryID: "message:old-session", offset: 900)
        var first: CompanionReadingOpeningProbe.Sample?
        CompanionReadingOpeningProbe.record = { if first == nil && $0.phase == .body { first = $0 } }
        f.mount()
        try await f.wait { first != nil }
        let opening = try #require(first)
        #expect(!opening.followsLatest && opening.requestedBottom && opening.requestedEntryID == nil && opening.pointY == nil)
        #expect(bookmark.viewport.historyRevision == nil || bookmark.viewport.historyRevision == f.store.conversation(for: target).historyRevision,
                "Prior-generation geometry cannot be accepted")
    }

    /// Main retains the request after use: it runs once again on a later opening. This test preserves that policy.
    @Test func aHiddenShowInChatRequestRunsOncePerRevealAndOncePerNewRequest() async throws {
        let f = try await Fixture()
        defer { f.navigation.jump = nil; f.close() }
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.navigation.visible = false
        f.mount()
        let first = CompanionDecisionChatJump(itemID: "message:reading-90")
        f.navigation.jump = first
        try await f.settle()
        #expect(samples.filter { $0.phase == .jump }.isEmpty)
        f.navigation.visible = true
        try await f.wait { samples.filter { $0.phase == .jump }.count == 1 }
        #expect(samples.filter { $0.phase == .jump }.map(\.requestID) == [first.id])
        for _ in 0..<3 { f.navigation.revision += 1; try await f.settle() }
        #expect(samples.filter { $0.phase == .jump }.count == 1)
        let second = CompanionDecisionChatJump(itemID: "message:reading-100")
        f.navigation.jump = second
        try await f.wait { samples.filter { $0.phase == .jump }.count == 2 }
        #expect(samples.filter { $0.phase == .jump }.map(\.requestID) == [first.id, second.id])
        f.navigation.visible = false
        try await f.settle()
        #expect(samples.filter { $0.phase == .jump }.count == 2)
        f.navigation.visible = true
        try await f.wait { samples.filter { $0.phase == .jump }.count == 3 }
        #expect(samples.filter { $0.phase == .jump }.map(\.requestID) == [first.id, second.id, second.id])
    }


    @Test func exactTopOpeningArrivesWithoutANumericCorrection() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.agents[0].id)
        let viewport = bookmark.viewport
        try await f.wait { viewport.restoration?.outcome == .arrived }
        let entryID = try #require(samples.first { $0.phase == .body }?.windowFirstID)
        let measuredLower = try #require(viewport.frames[entryID]?.lowerBound)
        f.navigation.visible = false
        try await f.wait { samples.contains { $0.phase == .unmounted } && viewport.metrics == nil }
        // A real top-position capture has a negative entry-relative distance when header/padding precedes it.
        // Derive it from the identical mounted window, never from a guessed height or an assumed ID landing.
        bookmark.position = .init(followsLatest: false, entryID: entryID,
            distanceFromEntry: 0.5 - measuredLower, offset: 0.5, shownEntries: 300)
        samples.removeAll()
        f.navigation.visible = true
        try await f.wait { viewport.restoration?.outcome == .arrived }
        #expect(abs((viewport.frames[entryID]?.lowerBound ?? -.infinity) - measuredLower) <= 0.01,
                "The zero-arrival setup requires the same real window geometry")
        #expect(viewport.restoration?.attempts == 0, "The nonzero 0.5pt saved distance exercises A's unchanged 1pt arrival threshold")
        let arrival = try #require(samples.first { $0.phase == .arrived })
        #expect(arrival.requestedEntryID == nil)
        #expect(samples.filter { $0.phase == .handoff }.isEmpty)
        #expect(samples.filter { $0.phase == .scroll }.isEmpty)
        let offset = try #require(viewport.metrics?.normalizedOffset)
        let phaseCount = samples.filter { $0.phase == .phaseChanged }.count
        try await f.settle()
        #expect(abs((viewport.metrics?.normalizedOffset ?? -.infinity) - offset) <= 1)
        #expect(samples.filter { $0.phase == .phaseChanged }.count == phaseCount)
        #expect(samples.filter { $0.phase == .saved }.count == 1,
                "Only the original arrival save is allowed; the marker handoff adds none")
        #expect(viewport.restoration?.attempts == 0)
    }

    /// #569 can still trim on an open reload; bookmark-first remounts themselves must retain their boundary.
    @Test func reopenedPausedWindowKeepsItsFirstEntryWhenATailArrivesDuringRestore() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        let target = f.agents[0].id
        let bookmark = f.store.readingBookmark(for: target)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        var injected = false
        var exercised = false
        var firstLower: Double?
        CompanionReadingRestoreProbe.deliver = { _, attempt, pinnedOffset, _ in
            if !injected {
                injected = true
                firstLower = bookmark.viewport.frames["message:reading-90"]?.lowerBound
                #expect(bookmark.viewport.restoration?.offset == pinnedOffset)
                f.store.apply(.upsert(target, .message(.init(id: "opening-tail", role: .assistant,
                    text: "A normal tail arrival during bookmark-first restoration.")), sequence: nil))
                return false
            }
            let viewport = bookmark.viewport
            if viewport.frames["message:opening-tail"] != nil,
               let metrics = viewport.metrics, abs(metrics.contentHeight - (viewport.frameContentHeight ?? -1)) < 1 {
                exercised = true
                return true
            }
            #expect(attempt < 10, "The real tail geometry must be exercised, not passed on a timeout")
            return attempt >= 10
        }
        f.mount()
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        #expect(injected && exercised)
        #expect(samples.filter { $0.phase == .body }.allSatisfy {
            $0.windowFirstID == "message:reading-90" && $0.windowStartID == "message:reading-90" && $0.requestedEntryID == nil
        })
        let lower = try #require(bookmark.viewport.frames["message:reading-90"]?.lowerBound)
        #expect(abs(lower - (firstLower ?? -.infinity)) <= 1,
                "Tail growth cannot trim the bookmark-first prefix")
        let offset = try #require(bookmark.viewport.metrics?.normalizedOffset)
        #expect(abs(offset - lower - 40) <= 6)
    }

    private func touchAnchor(_ view: UIView) -> CompanionReadingTouchObserver.Anchor? {
        if let anchor = view as? CompanionReadingTouchObserver.Anchor { return anchor }
        return view.subviews.lazy.compactMap { touchAnchor($0) }.first
    }
    private func transcript(_ view: UIView) -> UIScrollView? {
        if view.isHidden || view.alpha == 0 { return nil }
        if let scroll = view as? UIScrollView, scroll.bounds.width > 300,
           scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
        return view.subviews.lazy.compactMap { transcript($0) }.first
    }

    /// Native hosted scroll view, with phases injected through the existing DEBUG hook, not a finger gesture.
    @Test func activeOpeningDragNeverWritesAnIdentityHandoff() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        var drivePhase: ((ScrollPhase) -> Void)?
        var deliveries = 0
        CompanionReadingRestoreProbe.deliver = { _, _, _, phaseChanged in
            deliveries += 1
            drivePhase = phaseChanged
            // The installed passive observer takes the same path as a touch in the transcript.
            let anchor = touchAnchor(f.window)
            #expect(anchor != nil)
            anchor?.touchBegan(at: CGPoint(x: 10, y: 10))
            phaseChanged(.tracking)
            phaseChanged(.interacting)
            return false
        }
        f.mount()
        let viewport = f.store.readingBookmark(for: f.agents[0].id).viewport
        try await f.wait { drivePhase != nil && viewport.restoration?.outcome == .touch }
        let scroll = try #require(transcript(f.window))
        let phase = try #require(drivePhase)
        let attempts = viewport.restoration?.attempts
        let writesBefore = samples.filter { $0.phase == .handoff || $0.phase == .scroll }.count
        #expect(writesBefore == 0)
        let activeOffset = scroll.contentOffset.y
        try await f.settle()
        #expect(abs(scroll.contentOffset.y - activeOffset) <= 1)
        #expect(samples.filter { $0.phase == .handoff || $0.phase == .scroll }.isEmpty,
                "No binding write is allowed while tracking, interacting or decelerating")
        phase(.decelerating)
        try await f.settle()
        #expect(abs(scroll.contentOffset.y - activeOffset) <= 1)
        #expect(samples.filter { $0.phase == .handoff || $0.phase == .scroll }.isEmpty)
        let savesBeforeIdle = samples.filter { $0.phase == .saved }.count
        let idleOffset = scroll.contentOffset.y
        phase(.idle)
        try await f.settle()
        #expect(abs(scroll.contentOffset.y - idleOffset) <= 1)
        let handoffs = samples.filter { $0.phase == .handoff }
        #expect(handoffs.isEmpty, "Edge-seeded openings have no held identity, including at idle")
        #expect(samples.filter { $0.phase == .saved }.count == savesBeforeIdle + 1,
                "Only the unchanged gesture-idle save is allowed; the handoff adds no save")
        #expect(samples.filter { $0.phase == .scroll }.isEmpty && deliveries == 1)
        #expect(viewport.restoration?.attempts == attempts && viewport.restoration?.outcome == .touch)
        drivePhase = nil
    }

    @Test func lightOpeningTouchNeverInstallsAnIdentityHandoff() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        var drivePhase: ((ScrollPhase) -> Void)?
        CompanionReadingRestoreProbe.deliver = { _, _, _, phaseChanged in
            drivePhase = phaseChanged
            let anchor = touchAnchor(f.window)
            #expect(anchor != nil)
            anchor?.touchBegan(at: CGPoint(x: 10, y: 10))
            return false
        }
        f.mount()
        let viewport = f.store.readingBookmark(for: f.agents[0].id).viewport
        try await f.wait { drivePhase != nil && viewport.restoration?.outcome == .touch }
        let scroll = try #require(transcript(f.window))
        let before = scroll.contentOffset.y
        let saves = samples.filter { $0.phase == .saved }.count
        try await f.settle()
        #expect(samples.filter { $0.phase == .handoff || $0.phase == .scroll }.isEmpty)
        #expect(abs(scroll.contentOffset.y - before) <= 1)
        let phase = try #require(drivePhase)
        phase(.idle)
        try await f.settle()
        #expect(samples.filter { $0.phase == .handoff }.isEmpty)
        #expect(samples.filter { $0.phase == .saved }.count == saves,
                "A light-touch idle is not a gesture and cannot add a save")
        #expect(abs(scroll.contentOffset.y - before) <= 1)
        drivePhase = nil
    }

    @Test func navigationAwayDuringTheOpeningHoldWritesNoIdentityHandoff() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        var deliveries = 0
        CompanionReadingRestoreProbe.deliver = { _, _, _, _ in deliveries += 1; return false }
        f.mount()
        try await f.wait { deliveries > 0 }
        #expect(samples.filter { $0.phase == .scroll || $0.phase == .handoff }.isEmpty)
        f.navigation.visible = false
        try await f.wait { samples.contains { $0.phase == .unmounted } }
        try await f.settle()
        #expect(samples.filter { $0.phase == .scroll || $0.phase == .handoff }.isEmpty,
                "An unmounted transcript must not write any late target")
        #expect(f.store.readingBookmark(for: f.agents[0].id).viewport.metrics == nil)
    }

}
