import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// While the desktop has no live connection (reconnecting, offline, failed), opening or refreshing a conversation
/// issues no history read: on a dead route it could only wait out the request timeout behind a spinner. The last-good
/// conversation stays, marked as needing a resync, and the reconnect reloads it once. Connecting and synchronizing still read.
@MainActor @Suite struct DeadConnectionHistoryDeferralTests {
    typealias H = LiveServiceHarness

    enum Dead: String, CaseIterable, CustomTestStringConvertible {
        case reconnecting, offline, failed, notPaired
        var testDescription: String { rawValue }
        var event: AnnexTransportEvent {
            switch self {
            case .reconnecting: .connection(.reconnecting(attempt: 1, delaySeconds: 0.5))
            case .offline: .connection(.disconnected)
            case .failed: .connection(.failed(.trustRequired))
            case .notPaired: .connection(.failed(.rejected(status: 401, code: "peer_not_paired", message: nil)))
            }
        }
        func matches(_ connection: CompanionConnection?) -> Bool {
            switch (self, connection) {
            case (.reconnecting, .reconnecting?), (.offline, .offline?), (.failed, .failed?), (.notPaired, .failed?): true
            default: false
            }
        }
    }

    static let approvalSnapshot = H.chatSnapshot(events: [H.chatEvent("s1", sequence: 2, type: "permission_request", data: [
        "requestId": .string("perm-1"), "toolName": .string("Bash"), "title": .string("Run ls"),
        "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")])]),
    ])], fields: ["state": .string("waiting_permission")])

    static func start(snapshot: AnnexJSON = H.chatSnapshot(), agents extra: [String] = []) async throws -> H {
        try await H.start { transport in
            await transport.setRead("chat", snapshot)
            await transport.setAgents(.array((["agent"] + extra).map { .object(["id": .string($0), "name": .string($0), "status": .string("idle")]) }))
        }
    }
    static func selectedAndLoaded(snapshot: AnnexJSON = H.chatSnapshot()) async throws -> H {
        let h = try await start(snapshot: snapshot)
        h.store.selection = h.target
        await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).isLoaded)
        return h
    }
    static func goDead(_ h: H, _ dead: Dead = .reconnecting) async throws {
        await h.transport.emit(dead.event)
        try await h.waitUntil { dead.matches(h.host?.connection) }
    }
    /// The transport's reconnect: a resync on the new socket, then the catalog refresh, which also reloads the selection.
    static func recover(_ h: H, settling target: CompanionTarget) async throws {
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil {
            let c = h.store.conversation(for: target)
            return h.host?.connection == .connected && !c.isLoading && !c.requiresResync
        }
        // Long enough for any duplicate reload to have been issued.
        try await Task.sleep(for: .milliseconds(150))
    }
    static func pendingApproval(_ h: H) -> CompanionApproval? {
        for case .approval(let approval) in h.store.conversation(for: h.target).items where approval.resolution == .pending { return approval }
        return nil
    }

    // MARK: T1: first load with no items

    @Test func aColdOpenWhileReconnectingIsDeferredAndLoadsOnceOnRecovery() async throws {
        let h = try await Self.start()
        defer { h.stop() }
        try await Self.goDead(h)
        h.store.selection = h.target
        let chats = await h.transport.chatReads.count
        await h.store.loadOnOpen(h.target)
        #expect(await h.transport.chatReads.count == chats, "a history read was issued with no live connection")
        let c = h.store.conversation(for: h.target)
        // Not an empty current transcript: not loaded, needing a resync, and no failure invented.
        #expect(!c.isLoading && !c.isLoaded && c.requiresResync && c.items.isEmpty && c.error == nil)
        let status = CompanionRecoveryStatus(connection: h.host!.connection, isLoading: c.isLoading, requiresResync: c.requiresResync, error: c.error)
        #expect(status.phase == .reconnecting && status.isVisible && status.requiresResync)

        try await Self.recover(h, settling: h.target)
        #expect(await h.transport.chatReads.count - chats == 1)
        #expect(h.store.conversation(for: h.target).isLoaded)
    }

    // MARK: T2: last-good items and a pending approval

    @Test func reopeningAfterAReadIsRetiredKeepsLastGoodContentAndIssuesNoRead() async throws {
        let h = try await Self.selectedAndLoaded(snapshot: Self.approvalSnapshot)
        defer { h.stop() }
        let lastGood = h.store.conversation(for: h.target).items
        #expect(Self.pendingApproval(h)?.id == "perm-1")
        // A read in flight when the socket drops; it answers, late, with a different session.
        await h.transport.holdNextRead("chat", returning: H.chatSnapshot(session: "late"))
        let first = Task { await h.store.load(h.target, force: true) }
        try await h.waitUntil { await h.transport.isReadPaused("chat") }
        try await Self.goDead(h)
        try await h.waitUntil { !h.store.conversation(for: h.target).isLoading }
        let chats = await h.transport.chatReads.count
        await h.store.loadOnOpen(h.target)
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count == chats, "a history read was issued with no live connection")
        var c = h.store.conversation(for: h.target)
        #expect(!c.isLoading && c.isLoaded && c.requiresResync && c.items == lastGood)
        #expect(Self.pendingApproval(h)?.id == "perm-1")
        // The retired read's late answer does not replace the last-good conversation.
        await h.transport.resumeRead("chat")
        await first.value
        c = h.store.conversation(for: h.target)
        #expect(c.items == lastGood && c.sessionID == "s1" && c.requiresResync)

        try await Self.recover(h, settling: h.target)
        #expect(await h.transport.chatReads.count - chats == 1)
        #expect(Self.pendingApproval(h)?.id == "perm-1")
    }

    // MARK: Forced Refresh

    @Test(arguments: Dead.allCases) func aForcedRefreshWhileDeadIsDeferred(_ dead: Dead) async throws {
        let h = try await Self.selectedAndLoaded(snapshot: Self.approvalSnapshot)
        defer { h.stop() }
        let lastGood = h.store.conversation(for: h.target).items
        try await Self.goDead(h, dead)
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count == chats, "Refresh read history while \(dead.rawValue)")
        let c = h.store.conversation(for: h.target)
        #expect(!c.isLoading && c.isLoaded && c.requiresResync && c.items == lastGood && c.error == nil)
        #expect(Self.pendingApproval(h)?.id == "perm-1")
        #expect(!h.store.canOperate(h.target))
    }

    @Test func aForcedRefreshWhileConnectingStillReads() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        await h.transport.emit(.connection(.connecting))
        try await h.waitUntil { h.host?.connection == .connecting }
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count - chats == 1)
        let c = h.store.conversation(for: h.target)
        #expect(c.isLoaded && !c.isLoading && !c.requiresResync)
    }

    @Test func aForcedRefreshWhileSynchronizingAndReadableStillReads() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        await h.transport.pauseNextRead("projects")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("projects") }
        try await h.waitUntil { h.host?.connection == .synchronizing && h.host?.canReadHistory == true && !h.store.conversation(for: h.target).isLoading }
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count - chats == 1)
        await h.transport.resumeRead("projects")
        try await h.waitUntil { h.host?.connection == .connected }
    }

    // MARK: A failed catalog refresh on a live connection

    /// A catalog read fails during the refresh, so the host shows `.failed` while its connection is still live.
    static func failCatalogRefresh(_ h: H) async throws -> CompanionConnection? {
        await h.transport.failProjects(.rejected(status: 500, code: "projects_failed", message: "The desktop couldn't list projects."))
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { if case .failed = h.host?.connection { true } else { false } }
        try await h.waitUntil { !h.store.conversation(for: h.target).isLoading }
        return h.host?.connection
    }

    @Test func aForcedRefreshAfterOnlyTheCatalogRefreshFailedStillReads() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        _ = try await Self.failCatalogRefresh(h)
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count - chats == 1, "a live connection's history read was deferred")
        let c = h.store.conversation(for: h.target)
        #expect(c.isLoaded && !c.isLoading && !c.requiresResync && c.error == nil)
        #expect(!h.store.canOperate(h.target), "Commands still wait for a connected desktop")
    }

    @Test(arguments: [Dead.failed, .notPaired]) func aTransportFailureAfterACatalogRefreshFailureIsStillDeferred(_ dead: Dead) async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let refreshFailed = try await Self.failCatalogRefresh(h)
        await h.transport.emit(dead.event)
        try await h.waitUntil { h.host?.connection != refreshFailed && dead.matches(h.host?.connection) }
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count == chats, "Refresh read history after the connection itself failed")
        #expect(h.store.conversation(for: h.target).requiresResync && !h.store.conversation(for: h.target).isLoading)
    }

    @Test func anEndedEventStreamAfterACatalogRefreshFailureIsStillDeferred() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let refreshFailed = try await Self.failCatalogRefresh(h)
        await h.transport.finishEvents(throwing: AnnexTransportError.disconnected)
        try await h.waitUntil {
            guard case .failed = h.host?.connection else { return false }
            return h.host?.connection != refreshFailed
        }
        let chats = await h.transport.chatReads.count
        await h.store.load(h.target, force: true)
        #expect(await h.transport.chatReads.count == chats, "Refresh read history after the event stream ended")
        #expect(h.store.conversation(for: h.target).requiresResync && !h.store.conversation(for: h.target).isLoading)
    }

    // MARK: Selection, cancellation, recovery

    @Test func retargetingTheSelectionDuringDeferralReloadsOnlyTheNewSelectionOnce() async throws {
        let other = CompanionTarget(hostID: H.hostID, projectID: "project", agentID: "agent2")
        let h = try await Self.start(agents: ["agent2"])
        defer { h.stop() }
        try await Self.goDead(h)
        let chats = await h.transport.chatReads.count
        h.store.selection = h.target
        await h.store.loadOnOpen(h.target)
        h.store.selection = other
        await h.store.loadOnOpen(other)
        #expect(await h.transport.chatReads.count == chats)
        try await Self.recover(h, settling: other)
        #expect(Array(await h.transport.chatReads.dropFirst(chats)) == ["agent2"])
        // The earlier one stays visibly stale until it is opened again.
        let first = h.store.conversation(for: h.target)
        #expect(!first.isLoaded && first.requiresResync && !first.isLoading)
    }

    @Test func cancelledOpensWhileDeadLeaveExactlyOneReadForRecovery() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        // A disconnect leaves every conversation stale, so each open would otherwise force a read.
        try await Self.goDead(h, .offline)
        #expect(h.store.conversation(for: h.target).requiresResync)
        let chats = await h.transport.chatReads.count
        for _ in 0..<2 {
            let open = Task { await h.store.loadOnOpen(h.target) }
            open.cancel()
            await open.value
        }
        #expect(await h.transport.chatReads.count == chats)
        try await Self.recover(h, settling: h.target)
        #expect(await h.transport.chatReads.count - chats == 1)
    }

    // MARK: Errors are not masked

    @Test func aFailureWhileOperableStillSurfacesAndADeferralKeepsIt() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        await h.transport.failRead("chat", .rejected(status: 500, code: "chat_failed", message: "The desktop couldn't read this chat."))
        await h.store.load(h.target, force: true)
        let failed = h.store.conversation(for: h.target)
        let error = try #require(failed.error)
        #expect(error.contains("couldn't read this chat") && failed.requiresResync && !failed.isLoading)
        #expect(CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: true, error: error).phase == .refreshFailed)

        // Going dead and refreshing neither reads nor clears that error.
        try await Self.goDead(h)
        let chats = await h.transport.chatReads.count
        await h.transport.holdNextRead("chat", returning: H.chatSnapshot())
        let refresh = Task { await h.store.load(h.target, force: true) }
        try await Task.sleep(for: .milliseconds(100))
        let deferred = h.store.conversation(for: h.target)
        #expect(await h.transport.chatReads.count == chats)
        #expect(deferred.error == error && deferred.requiresResync && !deferred.isLoading)
        if await h.transport.isReadPaused("chat") { await h.transport.resumeRead("chat") }
        await refresh.value
    }
}
