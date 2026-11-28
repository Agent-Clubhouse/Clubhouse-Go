import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Host-fixture replay through the real transport, service and store, with the selection set as RootView sets it.
/// Every test prints one `COMPAT_ROW` line with its counts, then states its properties as expectations. Each
/// expectation's comment names its property, so a failure identifies the property.
///
/// Two contracts are kept apart. DISPLAY (read-only): the selected reply is shown after recovery and a stale result is
/// never presented as current. LIVE ACTION (composer, send, approve): the fixture's Dispatcher is sleeping and
/// read-only, so these tests prove only that no command is sent and nothing is offered while the host is not live.
@MainActor @Suite(.serialized) struct CompatHarnessReplayTests {
    typealias H = CompatHarness

    // MARK: (1) Static replay

    @Test(arguments: CompatFixture.acceptance + CompatFixture.negativeControl)
    func staticReplayShowsTheSelectedReply(_ fixture: CompatFixture) async throws {
        let h = try await H.start(fixture)
        await h.select()
        let steps = try? await h.wait("history") { h.conversation.isLoaded && !h.conversation.isLoading }
        for frame in h.fixture.chatFrames { try await h.io.sendChatFrame(frame) }
        await h.settle()
        let reads = await h.chatReads(), posts = await h.io.posts, unauth = await h.io.unauthorized
        h.row("static", [("steps", steps ?? -1), ("chatReads", reads), ("catalogPasses", await h.catalogPasses()), ("usable", h.usable),
                         ("inOrder", h.projectsFixtureInOrder()), ("dispatcherLive", h.host?.dispatcher?.liveAgent?.id.agentID ?? "nil"),
                         ("canOperate", h.store.canOperate(h.target)), ("error", h.conversation.error ?? "nil"), ("posts", posts), ("unauthorized", unauth),
                         ("texts", h.texts().count), ("notFound", Set(await h.io.notFound).sorted().joined(separator: ","))])
        if CompatFixture.acceptance.contains(fixture) {
            #expect(h.usable, "DISPLAY: selected chat usable")
            #expect(h.projectsFixtureInOrder(), "DISPLAY: 7 frames projected in order, reply exactly once")
            #expect(reads == 1, "exactly one history read")
            #expect(h.host?.dispatcher?.liveAgent?.id == h.target, "selected Dispatcher present (enabled)")
        }
        #expect(posts == 0, "LIVE: no command sent")
        #expect(unauth == 0, "auth: every request carries the bearer")
        #expect(h.pendingApprovals() == 0, "pending: none invented for the selected chat")
        await h.stop()
    }

    /// The frames arrive while the history read is in flight; the page and the buffered frames merge once.
    @Test(arguments: CompatFixture.acceptance)
    func staticReplayWithFramesDuringTheRead(_ fixture: CompatFixture) async throws {
        let h = try await H.start(fixture)
        await h.io.hold(h.fixture.chatPath)
        let open = Task { await h.select() }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        for frame in h.fixture.chatFrames { try await h.io.sendChatFrame(frame) }
        await h.settle()
        await h.io.release(h.fixture.chatPath, status: 200, body: h.fixture.chatBody)
        await open.value
        let steps = try? await h.wait("history") { h.conversation.isLoaded && !h.conversation.isLoading }
        h.row("static-during-read", [("steps", steps ?? -1), ("chatReads", await h.chatReads()), ("usable", h.usable), ("inOrder", h.projectsFixtureInOrder())])
        #expect(h.usable, "DISPLAY: selected chat usable")
        #expect(h.projectsFixtureInOrder(), "DISPLAY: frames projected once, in order")
        #expect(await h.chatReads() == 1, "exactly one history read")
        #expect(await h.io.posts == 0, "LIVE: no command sent")
        await h.stop()
    }

    // MARK: Part 2: the observed reconnect pattern

    /// connect, 14-project catalog, ping timeout → reconnecting, a held history retired, a 30 s reconnect attempt,
    /// a second history while dead, then recovery.
    @Test(arguments: CompatFixture.acceptance)
    func reconnectPattern(_ fixture: CompatFixture) async throws {
        let h = try await H.start(fixture)
        await h.select()
        try await h.wait("baseline") { h.usable }
        for frame in h.fixture.chatFrames { try await h.io.sendChatFrame(frame) }
        await h.settle()
        let lastGood = h.conversation.items
        let baselineCanOperate = h.store.canOperate(h.target)

        // An in-flight history read (pull to refresh) that the dead route never answers.
        await h.io.hold(h.fixture.chatPath)
        let refresh = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }

        // The route dies; the next ping goes unanswered and times out after 10 s.
        await h.io.setDead(true)
        await h.io.socket?.setAnswersPings(false)
        await h.advance(20)
        await h.advance(10)
        try await h.wait("reconnecting") { h.host?.connection == .reconnecting }
        try? await h.wait("retired", steps: 200) { !h.conversation.isLoading }
        let retired = !h.conversation.isLoading && h.conversation.requiresResync
        let lastGoodVisible = h.conversation.items == lastGood

        // Backoff, then a reconnect attempt that waits out 30 s on the dead route; a second history meanwhile.
        let readsBeforeDead = await h.chatReads()
        await h.advance(1)
        let reopen = Task { await h.driver.open(); await h.store.load(h.target, force: true) }
        await h.settle()
        let deadReads = await h.chatReads() - readsBeforeDead
        await h.io.setDead(false)
        await h.advance(30)
        await reopen.value

        // Recovery: backoff, then a healthy attempt.
        let readsBeforeRecovery = await h.chatReads()
        var recoverySteps = -1
        for _ in 0..<6 where recoverySteps < 0 {
            await h.advance(2)
            recoverySteps = (try? await h.wait("recovered", steps: 500) { h.usable }) ?? -1
        }
        await h.settle(150)
        let recoveryReads = await h.chatReads() - readsBeforeRecovery
        // The retired read's late answer, from the dead socket's era, must not replace the recovered page.
        await h.io.release(h.fixture.chatPath, status: 200, body: h.page(reply: "STALE late reply"))
        await refresh.value
        await h.settle()

        h.row("reconnect", [("retired", retired), ("lastGoodVisibleWhileDead", lastGoodVisible), ("deadReads", deadReads),
                            ("recoverySteps", recoverySteps), ("recoveryReads", recoveryReads), ("usable", h.usable),
                            ("inOrder", h.projectsFixtureInOrder()), ("staleShown", h.texts().contains("STALE late reply")),
                            ("canOperate", h.store.canOperate(h.target)), ("baselineCanOperate", baselineCanOperate),
                            ("viewConnectionReloads", h.driver.connectionReloads), ("connects", await h.io.sockets.count),
                            ("phases", h.sampler.phases.map { "\($0)" }.joined(separator: ">"))])
        #expect(retired && lastGoodVisible, "(a) while dead: last-good contents visible, marked stale")
        #expect(recoverySteps >= 0 && h.usable, "(a) usable after recovery within bounded steps")
        #expect(h.store.canOperate(h.target) == baselineCanOperate, "(a) operability restored to its baseline")
        #expect(h.projectsFixtureInOrder(), "(b) arrived events projected")
        #expect(deadReads == 0, "(c) no history read issued while dead")
        #expect(!h.texts().contains("STALE late reply"), "(d) generation: retired read cannot replace recovered page")
        let (safePosts, safeUnauth) = (await h.io.posts, await h.io.unauthorized)
        #expect(safePosts == 0 && safeUnauth == 0, "(d) auth: no command, every request authorized")
        #expect(h.pendingApprovals() == 0, "(d) pending: none invented")
        #expect(recoveryReads == 1, "(e) exactly one recovery read")
        await h.stop()
    }

    // MARK: (2) beta.8 refresh churn

    enum Interleave: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case heldHistory, reconnectSync
        var testDescription: String { rawValue }
    }

    @Test(arguments: CompatFixture.acceptance, [1, 3, 10])
    func refreshChurnWithAHeldHistory(_ fixture: CompatFixture, _ pairs: Int) async throws {
        try await churn(fixture, pairs: pairs, interleave: .heldHistory)
    }
    @Test(arguments: CompatFixture.acceptance, [1, 3, 10])
    func refreshChurnDuringReconnectSync(_ fixture: CompatFixture, _ pairs: Int) async throws {
        try await churn(fixture, pairs: pairs, interleave: .reconnectSync)
    }

    private func churn(_ fixture: CompatFixture, pairs: Int, interleave: Interleave) async throws {
        let h = try await H.start(fixture)
        await h.select()
        try await h.wait("baseline") { h.usable }
        let reads0 = await h.chatReads(), passes0 = await h.catalogPasses()
        let starts0 = h.sampler.loadStarts, needResync0 = h.sampler.endsNeedingResync
        var pending: Task<Void, Never>?
        switch interleave {
        case .heldHistory:
            await h.io.hold(h.fixture.chatPath)
            pending = Task { await h.store.load(h.target, force: true) }
            try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        case .reconnectSync:
            // The socket drops; the reconnect's catalog pass is held while the churn arrives on the new socket.
            await h.io.hold("/api/v1/projects")
            await h.io.socket?.close()
            await h.settle(10)
            for _ in 0..<6 where !(await h.io.isHeld("/api/v1/projects")) { await h.advance(1) }
            try await h.wait("catalog held") { await h.io.isHeld("/api/v1/projects") }
        }
        let refreshes = fixture.refreshSnapshotsPerPair
        for index in 0..<pairs {
            try await h.io.permissionCreated(id: "perm-\(index)", refreshes: refreshes.created)
            await h.settle(3)
            try await h.io.permissionWithdrawn(refreshes: refreshes.withdrawn)
            await h.settle(3)
        }
        await h.settle()
        let retiredDuringChurn = h.sampler.endsNeedingResync - needResync0
        switch interleave {
        case .heldHistory: await h.io.release(h.fixture.chatPath, status: 200, body: h.fixture.chatBody)
        case .reconnectSync: await h.io.release("/api/v1/projects", status: 200, body: h.fixture.routes["/api/v1/projects"]!.body)
        }
        await pending?.value
        let steps = try? await h.wait("usable") { h.usable }
        await h.settle(150)
        let snapshots = pairs * (refreshes.created + refreshes.withdrawn)
        h.row("churn-\(interleave.rawValue)", [("pairs", pairs), ("refreshSnapshots", snapshots), ("steps", steps ?? -1),
            ("chatReads", await h.chatReads() - reads0), ("catalogPasses", await h.catalogPasses() - passes0),
            ("loadStarts", h.sampler.loadStarts - starts0), ("retiredDuringChurn", retiredDuringChurn),
            ("usable", h.usable), ("connection", "\(h.host?.connection ?? .offline)"), ("replyShown", h.texts().contains(h.fixture.expectedReply)),
            ("posts", await h.io.posts), ("phases", h.sampler.phases.map { "\($0)" }.joined(separator: ">"))])
        #expect(retiredDuringChurn == 0, "churn does not retire the selected chat's history read")
        #expect(steps != nil && h.usable, "DISPLAY: chat usable within bounded steps after churn")
        #expect(h.texts().contains(h.fixture.expectedReply), "DISPLAY: selected reply shown")
        #expect(await h.chatReads() - reads0 == 1, "one history read for the interleaved load")
        if interleave == .heldHistory { #expect(await h.catalogPasses() - passes0 == 0, "churn starts no catalog pass") }
        let (safePosts, safeUnauth) = (await h.io.posts, await h.io.unauthorized)
        #expect(safePosts == 0 && safeUnauth == 0, "auth: no command, every request authorized")
        #expect(h.pendingApprovals() == 0, "pending: none invented for the selected chat")
        await h.stop()
    }

    // MARK: (B) 409 chat_read_changed

    /// A held history read; the display run changes; beta.8 answers 409 chat_read_changed, beta.7 answers 200 with the
    /// current run's page. No WebSocket event accompanies the change, so this isolates the reply itself.
    @Test(arguments: CompatFixture.acceptance)
    func chatReadChangedDuringAHeldRead(_ fixture: CompatFixture) async throws {
        let h = try await H.start(fixture)
        await h.select()
        try await h.wait("baseline") { h.usable }
        let oldPage = h.conversation.items
        let current = h.page(reply: "Current run reply.", session: "sess_dispatch_run2")
        let reads0 = await h.chatReads()
        await h.io.hold(h.fixture.chatPath)
        let refresh = Task { await h.store.load(h.target, force: true) }
        try await h.wait("held") { await h.io.isHeld(h.fixture.chatPath) }
        // The display run changes while the read awaits; later reads serve the current run.
        await h.io.override(h.fixture.chatPath, status: 200, body: current)
        h.sampler.stalePage = oldPage
        if fixture.isBeta8 {
            await h.io.release(h.fixture.chatPath, status: 409, body: .object(["error": .string("chat_read_changed")]))
        } else {
            await h.io.release(h.fixture.chatPath, status: 200, body: current)
        }
        await refresh.value
        // Bounded observation with no user action.
        let auto = try? await h.wait("auto recovery", steps: 1000) { h.usable && h.texts().contains("Current run reply.") }
        let autoReads = await h.chatReads() - reads0
        let stuck = (error: h.conversation.error ?? "nil", requiresResync: h.conversation.requiresResync, isLoading: h.conversation.isLoading)
        let phaseAfter = CompanionRecoveryStatus(connection: h.host?.connection ?? .offline, isLoading: stuck.isLoading,
                                                 requiresResync: stuck.requiresResync, error: h.conversation.error).phase
        // One manual Refresh, as the recovery pill offers.
        var manualRecovered = auto != nil
        if auto == nil {
            await h.store.load(h.target, force: true)
            manualRecovered = (try? await h.wait("manual", steps: 500) { h.usable && h.texts().contains("Current run reply.") }) != nil
        }
        await h.settle()
        h.row("chat-read-changed", [("status", fixture.isBeta8 ? 409 : 200), ("autoRecoverySteps", auto ?? -1), ("readsWithoutUserAction", autoReads),
            ("errorAfter", "\"\(stuck.error)\""), ("requiresResyncAfter", stuck.requiresResync), ("isLoadingAfter", stuck.isLoading),
            ("phaseAfter", "\(phaseAfter)"), ("manualRefreshRecovered", manualRecovered), ("staleShownAsCurrent", h.sampler.staleShownAsCurrent),
            ("totalReads", await h.chatReads() - reads0)])
        #expect(h.sampler.staleShownAsCurrent == 0, "DISPLAY: old page never presented as current")
        #expect(autoReads <= 2, "no unbounded automatic retry")
        #expect(auto != nil, "DISPLAY: recovers to the current run's reply without user action, within bounded steps")
        #expect(manualRecovered, "DISPLAY: one manual Refresh recovers")
        let (safePosts, safeUnauth) = (await h.io.posts, await h.io.unauthorized)
        #expect(safePosts == 0 && safeUnauth == 0, "auth: no command, every request authorized")
        await h.stop()
    }
}
