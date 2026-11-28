import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// beta.8 answers a history read with `409 chat_read_changed` when the chat's display run changes while the read
/// waits, and builds no page. The phone keeps the last-good conversation, marked stale and with no error, and reads
/// once more under a new owner. A second refusal in a row shows the error, as any failed read does.
///
/// The re-read rule: it happens only while the refused load still owns the conversation, meaning it is still
/// loading and was neither retired (connection lost, resync) nor replaced by a newer load, and while the desktop can
/// serve history. Selection doesn't matter: a load for a conversation off screen re-reads under the same rule.
///
/// Runs on the real transport, service and store with the host's V2 beta.8 fixture (sha256 pinned in `CompatFixture`).
/// The fixture's Dispatcher is asleep and read-only, so these tests cover the display contract only.
@MainActor @Suite(.serialized) struct ChatReadChangedResyncTests {
    typealias H = CompatHarness
    static let refusal: AnnexJSON = .object(["error": .string("chat_read_changed")])
    static let refusalText = "Desktop request failed (409): chat_read_changed."

    /// Selected, and loaded with the page of an earlier display run. Later reads serve the fixture's current page.
    static func startOnEarlierRun() async throws -> (H, [CompanionTimelineItem]) {
        let h = try await H.start(.v2beta8)
        let earlier = h.page(reply: "Earlier run reply.", session: "sess_dispatch_earlier")
        await h.io.override(h.fixture.chatPath, status: 200, body: earlier)
        await h.select()
        try await h.wait("baseline") { h.usable && h.texts().contains("Earlier run reply.") }
        await h.io.clearOverride(h.fixture.chatPath)
        return (h, h.conversation.items)
    }

    @Test func aChatReadChangedRefusalRereadsOnceAndShowsTheCurrentReply() async throws {
        let (h, earlier) = try await Self.startOnEarlierRun()
        let reads0 = await h.chatReads()
        await h.io.hold(h.fixture.chatPath)
        let refresh = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        h.sampler.stalePage = earlier
        await h.io.release(h.fixture.chatPath, status: 409, body: Self.refusal)
        await refresh.value
        try await h.wait("current") { h.usable }
        await h.settle(150)
        h.sampler.stop()
        #expect(await h.chatReads() - reads0 == 2, "the refused read and exactly one re-read")
        #expect(h.sampler.staleShownAsCurrent == 0, "the earlier run's page is never presented as current")
        #expect(!h.sampler.phases.contains(.refreshFailed), "no error is shown for the first refusal")
        #expect(h.conversation.error == nil && !h.conversation.requiresResync && h.conversation.isLoaded)
        #expect(h.texts().contains(h.fixture.expectedReply) && !h.texts().contains("Earlier run reply."), "the current run's reply")
        #expect(h.projectsFixtureInOrder())
        #expect(await h.io.posts == 0)
        #expect(await h.io.unauthorized == 0)
        #expect(h.pendingApprovals() == 0)
        await h.stop()
    }

    @Test func aSecondRefusalInARowShowsTheErrorAfterTwoReads() async throws {
        let (h, earlier) = try await Self.startOnEarlierRun()
        let reads0 = await h.chatReads()
        await h.io.override(h.fixture.chatPath, status: 409, body: Self.refusal)
        h.sampler.stalePage = earlier
        await h.store.load(h.target, force: true)
        await h.settle(150)
        let c = h.conversation
        #expect(await h.chatReads() - reads0 == 2, "two reads, then no loop")
        #expect(c.error == Self.refusalText, "the error as shown before this change")
        #expect(c.requiresResync && !c.isLoading && c.items == earlier, "last-good items kept, marked stale")
        #expect(h.sampler.staleShownAsCurrent == 0)
        // A later manual Refresh is a new load, with its own single re-read.
        await h.io.clearOverride(h.fixture.chatPath)
        await h.store.load(h.target, force: true)
        #expect(h.usable && h.texts().contains(h.fixture.expectedReply))
        #expect(await h.chatReads() - reads0 == 3)
        await h.stop()
    }

    @Test func aRefusalAfterTheConnectionDropsIsNotReread() async throws {
        let (h, earlier) = try await Self.startOnEarlierRun()
        await h.io.hold(h.fixture.chatPath)
        let refresh = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        // The socket drops while the read waits. The transport sits in its backoff on the manual clock.
        await h.io.socket?.close()
        try await h.wait("reconnecting") { h.host?.connection == .reconnecting }
        try await h.wait("retired") { !h.conversation.isLoading }
        let reads = await h.chatReads()
        await h.io.release(h.fixture.chatPath, status: 409, body: Self.refusal)
        await refresh.value
        await h.settle(150)
        let c = h.conversation
        #expect(await h.chatReads() == reads, "no re-read for a retired owner")
        #expect(c.items == earlier && c.requiresResync && c.error == nil && !c.isLoading, "retirement unchanged: stale, no error")
        // Recovery reloads it once, as before.
        for _ in 0..<6 where !h.usable { await h.advance(1); try? await h.wait("recovered", steps: 300) { h.usable } }
        await h.settle(150)
        #expect(h.usable && h.texts().contains(h.fixture.expectedReply))
        #expect(await h.chatReads() - reads == 1, "exactly one recovery read")
        await h.stop()
    }

    @Test func aRefusalForAReplacedLoadIsNotReread() async throws {
        let (h, _) = try await Self.startOnEarlierRun()
        let reads0 = await h.chatReads()
        await h.io.hold(h.fixture.chatPath)
        let first = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        // A newer load (a forced refresh) takes ownership and finishes first.
        await h.store.load(h.target, force: true)
        #expect(h.usable && h.texts().contains(h.fixture.expectedReply))
        await h.io.release(h.fixture.chatPath, status: 409, body: Self.refusal)
        await first.value
        await h.settle(150)
        #expect(await h.chatReads() - reads0 == 2, "the replaced load's refusal starts no read")
        #expect(h.usable && h.conversation.error == nil && h.texts().contains(h.fixture.expectedReply))
        await h.stop()
    }

    @Test func aRefusalForAConversationOffScreenRereadsWhileItsLoadStillOwnsIt() async throws {
        let h = try await H.start(.v2beta8)
        // Nothing selected and no view mounted: a load started elsewhere, such as a Review page.
        #expect(h.store.selection == nil)
        await h.io.hold(h.fixture.chatPath)
        let load = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        await h.io.release(h.fixture.chatPath, status: 409, body: Self.refusal)
        await load.value
        await h.settle(150)
        #expect(await h.chatReads() == 2, "one re-read under the same rule")
        #expect(h.usable && h.texts().contains(h.fixture.expectedReply))
        await h.stop()
    }

    @Test func otherRefusalsAreUnchanged() async throws {
        let (h, earlier) = try await Self.startOnEarlierRun()
        let reads0 = await h.chatReads()
        await h.io.override(h.fixture.chatPath, status: 409, body: .object(["error": .string("not_chat")]))
        await h.store.load(h.target, force: true)
        await h.settle(100)
        var c = h.conversation
        #expect(await h.chatReads() - reads0 == 1)
        #expect(c.error != nil && c.requiresResync && c.items == earlier)
        await h.io.override(h.fixture.chatPath, status: 500, body: .object(["error": .string("chat_failed"), "message": .string("The desktop couldn't read this chat.")]))
        await h.store.load(h.target, force: true)
        await h.settle(100)
        c = h.conversation
        #expect(await h.chatReads() - reads0 == 2)
        #expect(c.error == "The desktop couldn't read this chat." && c.requiresResync)
        await h.stop()
    }
}
