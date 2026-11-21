import Testing
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Exercise the real paused transcript boundary; availability samples are the actual row constructor inputs,
/// not native button activation. Native archive activation and Show-in-chat are proved separately.
@MainActor @Suite(.serialized) struct CompanionTranscriptEqualityTests {
    private struct CatalogHost: View {
        let store: CompanionStore
        let target: CompanionTarget
        var body: some View {
            NavigationStack {
                if let agent = store.agent(for: target) {
                    CompanionConversationView(store: store, agent: agent, isVisible: true)
                }
            }
        }
    }

    @MainActor private struct Fixture {
        let store: CompanionStore
        let target: CompanionTarget
        let window: UIWindow
        init() async throws {
            let service = CompanionPreviewService(showsReadingScenario: true)
            store = CompanionStore(service: service)
            var events = service.events().makeAsyncIterator()
            store.apply(try #require(await events.next()))
            target = CompanionPreviewService.target
            _ = try #require(store.agent(for: target))
            await store.load(target)
            #expect(store.conversation(for: target).isLoaded)
            let bookmark = store.readingBookmark(for: target)
            bookmark.hasMounted = true
            bookmark.position = .init(followsLatest: false, entryID: "message:reading-90", distanceFromEntry: 0,
                                      shownEntries: 300)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        }
        func mount() {
            window.rootViewController = UIHostingController(rootView: CatalogHost(store: store, target: target))
            window.makeKeyAndVisible()
        }
        func close() {
            CompanionTranscriptActionProbe.record = nil
            CompanionConversationBuildProbe.record = nil
            CompanionReadingOpeningProbe.didComputeSeed = nil
            window.isHidden = true
            window.rootViewController = nil
            store.shutdown()
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(condition(), "A bounded product-state wait must fail, never manufacture success")
        }
        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
        }
        func capability(_ capability: CompanionCapabilities, allowed: Bool) throws {
            var hosts = store.hosts
            let h = try #require(hosts.firstIndex { $0.id == target.hostID })
            let p = try #require(hosts[h].projects.firstIndex { $0.id == target.projectID })
            let a = try #require(hosts[h].projects[p].agents.firstIndex { $0.id == target })
            if allowed { hosts[h].projects[p].agents[a].capabilities.formUnion(capability) }
            else { hosts[h].projects[p].agents[a].capabilities.subtract(capability) }
            store.apply(.hosts(hosts))
            #expect(store.agent(for: target)?.capabilities.contains(capability) == allowed)
        }
    }

    @Test func pausedApprovalRowAvailabilityTracksCatalogCapabilityWithoutRemount() async throws {
        try await capabilityChanges(.approve, itemID: "equality-approval", initialItem:
            .approval(.init(id: "equality-approval", toolName: "Edit", summary: "Real transcript availability proof"))) {
                .approval(canRespond: $0)
            }
    }

    @Test func pausedQueuedRowAvailabilityTracksCatalogCapabilityWithoutRemount() async throws {
        try await capabilityChanges(.removeQueued, itemID: "equality-queued", initialItem:
            .message(.init(id: "equality-queued", role: .user, text: "Queued availability proof", queueState: .queued))) {
                .queued(canRemove: $0, hasAction: $0)
            }
    }

    private func capabilityChanges(_ capability: CompanionCapabilities, itemID: String, initialItem: CompanionTimelineItem,
                                   expected: (Bool) -> CompanionTranscriptActionProbe.Availability) async throws {
        let f = try await Fixture()
        defer { f.close() }
        f.store.apply(.upsert(f.target, initialItem, sequence: nil))
        try f.capability(capability, allowed: false)
        #expect(f.store.canOperate(f.target) && !f.store.pendingCommands.contains(f.target))
        var availability: CompanionTranscriptActionProbe.Availability?
        var timeline = 0, seeds = 0
        CompanionTranscriptActionProbe.record = { target, observedID, value in
            if target == f.target && observedID == itemID { availability = value }
        }
        CompanionConversationBuildProbe.record = { kind, target in
            if target == f.target, case .timeline = kind { timeline += 1 }
        }
        CompanionReadingOpeningProbe.didComputeSeed = { if $0 == f.target { seeds += 1 } }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.target)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived && availability == expected(false) }
        try await f.settle()
        #expect(!bookmark.position.followsLatest && seeds == 1)
        for allowed in [true, false] {
            let before = timeline
            try f.capability(capability, allowed: allowed)
            try await f.wait { availability == expected(allowed) }
            try await f.settle()
            #expect(availability == expected(allowed), "Actual row inputs must follow both grant and revocation")
            #expect(timeline - before == 1, "One catalog change must not duplicate the paused transcript projection")
            #expect(seeds == 1 && !bookmark.position.followsLatest, "Capability changes are not a mount or a Latest action")
        }
    }

    @Test func pausedStreamingProjectsTheTranscriptExactlyOncePerRenderedBatch() async throws {
        let f = try await Fixture()
        defer { f.close() }
        var timeline = 0
        CompanionConversationBuildProbe.record = { kind, target in
            if target == f.target, case .timeline = kind { timeline += 1 }
        }
        f.mount()
        let bookmark = f.store.readingBookmark(for: f.target)
        try await f.wait { bookmark.viewport.restoration?.outcome == .arrived }
        try await f.settle()
        for batch in 0..<10 {
            let before = timeline
            for _ in 0..<10 { f.store.apply(.textDelta(f.target, messageID: "reading-helper", text: " streamed", sequence: nil)) }
            f.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            f.window.layoutIfNeeded()
            #expect(timeline - before == 1, "Exactly one real observed projection for streamed batch \(batch)")
            #expect(!bookmark.position.followsLatest)
        }
    }
}
