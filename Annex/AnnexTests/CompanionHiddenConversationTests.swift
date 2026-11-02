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

    @Test(arguments: Hidden.allCases) func hiddenStreamsDoNoTimelineWork(hidden: Hidden) async throws {
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

        // A visible control proves the counter observes actual timeline construction after each event.
        counts.reset()
        let visibleEvents = 5
        for _ in 0..<visibleEvents {
            store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " visible", sequence: nil))
            try await settle(window)
        }
        let visibleBodies = counts.bodies[target, default: 0]
        let visibleTimelines = counts.timelines[target, default: 0]
        #expect(visibleTimelines >= visibleEvents)

        // Move through the top first, which stops follow-latest just like the status-bar gesture. Then preserve an
        // arbitrary reading offset, not just a latest/top flag, through hidden events and a newly mounted scroll view.
        let before = try #require(transcript(in: window))
        before.setContentOffset(CGPoint(x: 0, y: -before.adjustedContentInset.top), animated: false)
        try await settle(window)
        before.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        try await settle(window)
        let readingOffset = before.contentOffset.y + before.adjustedContentInset.top

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
        #expect(hiddenTimelines == 0, "Hidden conversations must do zero timeline builds for 20 streamed events")
        #expect(store.drafts[target] == "Draft for this desktop")

        navigation.tab = 0; navigation.desktop = 0
        try await settle(window)
        try await settle(window)
        let restored = try #require(transcript(in: window))
        let restoredOffset = restored.contentOffset.y + restored.adjustedContentInset.top
        print("HIDDEN_SCROLL_MEASUREMENT case=\(hidden.rawValue) before=\(readingOffset) restored=\(restoredOffset)")
        #expect(abs(restoredOffset - readingOffset) <= 2, "The reading offset survives unmounting within two points")
        counts.reset()
        store.apply(.textDelta(target, messageID: "dispatcher-long-reply", text: " resumed", sequence: nil))
        try await settle(window)
        #expect(counts.timelines[target, default: 0] >= 1, "Visibility resumes current history rendering")
        #expect(store.conversation(for: target).items.contains { item in
            if case .message(let message) = item { message.text.hasSuffix(String(repeating: " hidden", count: streamedEvents) + " resumed") } else { false }
        })
    }
}
