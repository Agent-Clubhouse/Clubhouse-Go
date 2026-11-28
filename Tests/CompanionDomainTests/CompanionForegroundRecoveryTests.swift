import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Background and foreground through the app's lifecycle, as the app wires it to the live service: the open
/// conversation keeps its last-good items while backgrounded and while the desktop is coming back, no history
/// read goes to a dead connection (#647), and the reconnect reloads it exactly once (#646).
@MainActor @Suite struct CompanionForegroundRecoveryTests {
    typealias H = LiveServiceHarness

    static func lifecycle(_ h: H) -> CompanionLifecycle {
        CompanionLifecycle { [service = h.service] active in
            if active { await service.resume() } else { await service.suspend() }
        }
    }

    @Test func backgroundKeepsLastGoodDefersReadsAndForegroundReloadsOnce() async throws {
        let h = try await H.start { await $0.setRead("chat", H.chatSnapshot()) }
        defer { h.stop() }
        let lifecycle = Self.lifecycle(h)
        h.store.selection = h.target
        await h.store.load(h.target, force: true)
        let lastGood = h.store.conversation(for: h.target).items
        #expect(!lastGood.isEmpty)
        let chats = await h.transport.chatReads.count
        let connects = await h.transport.connectCount

        lifecycle.update(.inactive)
        lifecycle.update(.background)
        await lifecycle.settle()
        try await h.waitUntil { h.host?.connection == .offline }
        var c = h.store.conversation(for: h.target)
        #expect(c.items == lastGood && c.isLoaded && c.requiresResync && !c.isLoading && c.error == nil)
        #expect(await h.transport.disconnectCount >= 1)

        // Opening or refreshing it while backgrounded and dead reads nothing.
        await h.store.loadOnOpen(h.target)
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count == chats, "a history read was issued with no live connection")
        c = h.store.conversation(for: h.target)
        #expect(c.items == lastGood && c.requiresResync)

        // Hold the reconnect's catalog refresh so the first instant after foreground is observable.
        await h.transport.pauseNextRead("projects")
        lifecycle.update(.inactive)
        lifecycle.update(.active)
        await lifecycle.settle()
        #expect(await h.transport.connectCount == connects + 1, "Foreground reconnects at once")
        #expect(h.store.conversation(for: h.target).items == lastGood, "Last-good content is still shown")
        try await h.waitUntil { await h.transport.isReadPaused("projects") }
        await h.transport.resumeRead("projects")
        try await h.waitUntil {
            let c = h.store.conversation(for: h.target)
            return h.host?.connection == .connected && !c.isLoading && !c.requiresResync
        }
        // Long enough for any duplicate reload to have been issued.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - chats == 1, "Exactly one reload once readable")
        #expect(h.store.conversation(for: h.target).isLoaded)
    }

    @Test func rapidFlipsEndConnectedWithOneReload() async throws {
        let h = try await H.start { await $0.setRead("chat", H.chatSnapshot()) }
        defer { h.stop() }
        let lifecycle = Self.lifecycle(h)
        h.store.selection = h.target
        await h.store.load(h.target, force: true)
        let chats = await h.transport.chatReads.count
        for phase in [CompanionLifecycle.Phase.background, .active, .background, .inactive, .active, .background, .active] {
            lifecycle.update(phase)
        }
        await lifecycle.settle()
        try await h.waitUntil {
            let c = h.store.conversation(for: h.target)
            return h.host?.connection == .connected && !c.isLoading && !c.requiresResync
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - chats == 1)
    }
}
