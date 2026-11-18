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
    private struct Fixture {
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

    @Test func pausedFirstBodyUsesItsEntryInsideAnExpandedWindowAndReleasesTheIDAfterScrolling() async throws {
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
        #expect(first.requestedEntryID == "message:reading-90" && !first.requestedBottom && first.pointY == nil)
        #expect(first.windowFirstID != first.requestedEntryID, "Earlier loaded messages must not become the first-paint target")
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
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.agents[0].id)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        let first = try #require(samples.first { $0.phase == .body })
        let saved = bookmark.position
        for _ in 0..<5 { f.navigation.revision += 1; try await f.settle() }
        await f.store.load(f.agents[0].id, force: true)
        try await f.wait { bookmark.viewport.historyRevision == f.store.conversation(for: f.agents[0].id).historyRevision
            && bookmark.viewport.restoration?.outcome == .arrived }
        #expect(Set(samples.map(\.mountID)) == [first.mountID], "A reload is not a mount boundary")
        #expect(samples.filter { $0.phase == .body }.allSatisfy { $0.shownEntries >= 300 && !$0.followsLatest })
        let frame = try #require(saved.entryID.flatMap { bookmark.viewport.frames[$0] })
        #expect(abs((bookmark.viewport.metrics?.normalizedOffset ?? -.infinity) - frame.lowerBound - saved.distanceFromEntry) <= 6)
    }

    @Test func hiddenReloadReseedsOnceAndTargetSwitchesCannotBorrowAnotherChatsState() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause()
        f.store.drafts[f.agents[0].id] = "First chat draft"
        f.store.drafts[f.agents[1].id] = "Second chat draft"
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
        f.navigation.visible = true
        try await f.wait { samples.contains { $0.phase == .body && $0.mountID != originalID } }
        let secondID = try #require(samples.last?.mountID)
        #expect(Set(samples.map(\.mountID)) == [originalID, secondID])
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        f.navigation.selected = 1
        try await f.wait { samples.contains { $0.target == f.agents[1].id && $0.phase == .body } }
        let other = try #require(samples.first { $0.target == f.agents[1].id && $0.phase == .body })
        #expect(other.followsLatest && other.requestedBottom && other.requestedEntryID == nil)
        #expect(other.mountID != secondID)
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
        #expect(opening.requestedEntryID == "question:first" && !opening.requestedBottom)
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


    @Test func exactInitialLandingReleasesTheIdentityEvenWithoutANumericCorrection() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 0)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        f.mount()
        let viewport = f.store.readingBookmark(for: f.agents[0].id).viewport
        try await f.wait { viewport.restoration?.outcome == .arrived }
        #expect(viewport.restoration?.attempts == 0, "This fixture must exercise an exact initial ID landing")
        let arrival = try #require(samples.first { $0.phase == .arrived })
        #expect(arrival.requestedEntryID == nil)
        if let handoff = samples.first(where: { $0.phase == .handoff }) { #expect(handoff.pointY != nil) }
        #expect(samples.filter { $0.phase == .scroll }.isEmpty)
    }

    @Test func realOpeningTouchDropsTheInitialIdentityWithoutIssuingAnotherTarget() async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.pause(distance: 40)
        var samples: [CompanionReadingOpeningProbe.Sample] = []
        CompanionReadingOpeningProbe.record = { samples.append($0) }
        var deliveryCount = 0
        var priorPoint: Double?
        var priorOffset: Double?
        func touchAnchor(_ view: UIView) -> CompanionReadingTouchObserver.Anchor? {
            if let anchor = view as? CompanionReadingTouchObserver.Anchor { return anchor }
            return view.subviews.lazy.compactMap { touchAnchor($0) }.first
        }
        CompanionReadingRestoreProbe.deliver = { _, _, _, _ in
            deliveryCount += 1
            priorPoint = samples.last?.pointY
            priorOffset = f.store.readingBookmark(for: f.agents[0].id).viewport.metrics?.normalizedOffset
            let anchor = touchAnchor(f.window)
            #expect(anchor != nil)
            anchor?.touchBegan(at: CGPoint(x: 10, y: 10))
            return false
        }
        f.mount()
        let viewport = f.store.readingBookmark(for: f.agents[0].id).viewport
        try await f.wait { viewport.restoration?.outcome == .touch }
        let cancellation = try #require(samples.first { $0.phase == .cancelled })
        #expect(cancellation.requestedEntryID == nil)
        #expect(cancellation.pointY == nil || cancellation.pointY == priorPoint,
                "User authority clears the ID without requesting any new numeric target")
        try await f.settle()
        #expect(deliveryCount == 1 && samples.filter { $0.phase == .scroll }.isEmpty)
        #expect(viewport.restoration?.outcome == .touch)
        let before = try #require(priorOffset)
        #expect(abs((viewport.metrics?.normalizedOffset ?? -.infinity) - before) <= 6)
    }

}
