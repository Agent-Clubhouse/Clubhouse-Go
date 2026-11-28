import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// A permission lifecycle on the SELECTED agent (the fixture's Dispatcher), with refresh snapshots behind, equal to
/// or ahead of the delivered stream, and overlapping a held history read (including 409 chat_read_changed).
///
/// Frames are host-schema pieces composed by this test:
/// - `permission_request` and `permission_resolved` chat events in the repo contract shapes (chat-events.json);
/// - withdrawal as `permission_resolved {decision: "cancelled", by: "agent"}`, as the beta.8 chat drivers emit it;
/// - beta.8's two refresh snapshots per separated create/withdraw (host permission-refresh.cjs). beta.7 sends neither.
/// Each case's `label` says whether the host producer or the field capture shows its ordering.
///
/// Phone-side approve and deny are NOT modelled. They are commands (`chat.permission`): this harness refuses every
/// command, the task forbids live permission changes, and the fixture session is asleep and read-only. Desktop-side
/// allow and deny are modelled, as the `permission_resolved` the phone would receive.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CompatSelectedLifecycleTests {
    typealias H = CompatHarness

    enum Interleave: String, Sendable, CaseIterable {
        case inSync, behind, aheadOutOfOrder, heldStaleBefore, heldPendingPage, held409, heldAhead, drainSettings
    }
    struct Case: Sendable, CustomTestStringConvertible {
        let fixture: CompatFixture
        let interleave: Interleave
        let decision: String
        var refreshes: Bool { fixture.isBeta8 }
        var label: String {
            switch interleave {
            case .inSync: refreshes ? "matches-producer(2 refreshes/pair, lastSeq=delivered; capture: REFRESH after cancellation)" : "matches-producer(beta.7: no refresh)"
            default: "synthetic"
            }
        }
        var testDescription: String { "\(fixture.rawValue)/\(interleave.rawValue)/\(decision)" }
    }
    nonisolated static let cases: [Case] = {
        var all: [Case] = []
        for fixture in CompatFixture.acceptance {
            for decision in ["cancelled", "allow", "deny"] { all.append(.init(fixture: fixture, interleave: .inSync, decision: decision)) }
            for interleave in [Interleave.heldStaleBefore, .heldPendingPage, .held409] { all.append(.init(fixture: fixture, interleave: interleave, decision: "cancelled")) }
        }
        // Refresh-snapshot orderings exist only on beta.8.
        for interleave in [Interleave.behind, .aheadOutOfOrder, .heldAhead, .drainSettings] { all.append(.init(fixture: .v2beta8, interleave: interleave, decision: "cancelled")) }
        // COMPAT_CASES=held409,drainSettings limits a run to those interleavings (older SHAs run only what differs).
        if let only = ProcessInfo.processInfo.environment["COMPAT_CASES"]?.split(separator: ",").map(String.init), !only.isEmpty {
            all = all.filter { only.contains($0.interleave.rawValue) }
        }
        return all
    }()

    static let requestID = "perm_sel_1"

    // MARK: Host-shaped events and pages

    static func request(_ agent: String) -> AnnexJSON {
        .object(["agentId": .string(agent), "sessionId": .string("sess_dispatch"), "seq": .integer(13), "ts": .integer(1_799_999_953_000),
                 "turnId": .string("turn_2"), "type": .string("permission_request"), "v": .integer(2),
                 "data": .object(["requestId": .string(requestID), "toolName": .string("Bash"), "title": .string("Run npm test"),
                                  "description": .string("npm test"), "toolCallId": .string("tool_sel_1"),
                                  "options": .array([.object(["kind": .string("allow_once"), "label": .string("Allow"), "optionId": .string("allow")]),
                                                     .object(["kind": .string("reject_once"), "label": .string("Deny"), "optionId": .string("deny")])])])])
    }
    static func resolved(_ agent: String, decision: String) -> AnnexJSON {
        var data: [String: AnnexJSON] = ["requestId": .string(requestID), "decision": .string(decision), "by": .string(decision == "cancelled" ? "agent" : "user")]
        if decision != "cancelled" { data["optionId"] = .string(decision == "allow" ? "allow" : "deny") }
        return .object(["agentId": .string(agent), "sessionId": .string("sess_dispatch"), "seq": .integer(14), "ts": .integer(1_799_999_954_000),
                        "turnId": .string("turn_2"), "type": .string("permission_resolved"), "v": .integer(2), "data": .object(data)])
    }
    enum Stage { case before, pending, after }
    /// The `/chat` page as the host would serve it at each stage: the fixture page plus the lifecycle's events.
    static func page(_ h: H, _ stage: Stage, decision: String) -> AnnexJSON {
        guard case .object(var body) = h.fixture.chatBody, stage != .before else { return h.fixture.chatBody }
        let agent = h.fixture.selectedAgent
        var events = body["events"].arrayValue + [request(agent)]
        if stage == .after { events.append(resolved(agent, decision: decision)) }
        body["events"] = .array(events)
        body["pendingPermissions"] = .array(stage == .pending ? [request(agent)] : [])
        body["lastSeq"] = .integer(stage == .pending ? 13 : 14)
        body["readOnly"] = .bool(false)
        body["state"] = .string(stage == .pending ? "waiting_permission" : "idle")
        return .object(body)
    }

    static func approvals(_ h: H) -> [CompanionApproval] {
        h.conversation.items.compactMap { if case .approval(let a) = $0, a.id == requestID { return a }; return nil }
    }
    static func pendingIDs(_ h: H) -> [String] {
        h.conversation.items.compactMap { if case .approval(let a) = $0, a.resolution == .pending { return a.id }; return nil }
    }
    static func expectedResolution(_ decision: String) -> CompanionApproval.Resolution {
        switch decision { case "allow": .allowed; case "cancelled": .cancelled; default: .denied }
    }

    // MARK: The case

    @Test(arguments: cases)
    func selectedPermissionLifecycle(_ c: Case) async throws {
        let h = try await H.start(c.fixture)
        let path = h.fixture.chatPath, agent = h.fixture.selectedAgent
        await h.select()
        try await h.wait("baseline") { h.usable }
        let reads0 = await h.chatReads(), passes0 = await h.catalogPasses()
        var resolvedDelivered = false
        h.sampler.staleCheck = { resolvedDelivered && Self.pendingIDs(h).contains(Self.requestID) }
        var held: Task<Void, Never>?
        var pendingSeen: [String] = []
        var drainBlocked: Bool?

        func holdRead() async throws {
            await h.io.hold(path)
            held = Task { await h.store.load(h.target, force: true) }
            try await h.wait("held") { await h.io.isHeld(path) }
        }
        func create() async throws {
            await h.io.override(path, status: 200, body: Self.page(h, .pending, decision: c.decision))
            switch c.interleave {
            case .behind:
                try await h.io.sendEvent(Self.request(agent))
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq - 1) }
            case .aheadOutOfOrder, .heldAhead:
                let seq = await h.io.reserveSeq()
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: seq) }
                await h.settle(10)
                try await h.io.sendEvent(Self.request(agent), seq: seq)
            default:
                try await h.io.sendEvent(Self.request(agent))
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq) }
            }
            await h.settle(20)
            pendingSeen = Self.pendingIDs(h)
        }
        func withdraw() async throws {
            await h.io.override(path, status: 200, body: Self.page(h, .after, decision: c.decision))
            switch c.interleave {
            case .behind:
                try await h.io.sendEvent(Self.resolved(agent, decision: c.decision))
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq - 1) }
            case .aheadOutOfOrder, .heldAhead:
                let seq = await h.io.reserveSeq()
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: seq) }
                await h.settle(10)
                try await h.io.sendEvent(Self.resolved(agent, decision: c.decision), seq: seq)
            case .drainSettings:
                // The settings were opened earlier, so a changed Dispatcher entry re-reads them inside the event drain.
                await h.io.hold("/api/v1/mobile/dispatcher/settings")
                try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq) { payload in
                    if case .object(var d)? = payload["dispatcher"] { d["requestsUnderWay"] = .integer(1); payload["dispatcher"] = .object(d) }
                }
                try await h.wait("settings held", steps: 500) { await h.io.isHeld("/api/v1/mobile/dispatcher/settings") }
                try await h.io.sendEvent(Self.resolved(agent, decision: c.decision))
                await h.settle(50)
                drainBlocked = Self.approvals(h).first?.resolution == .pending
                await h.io.release("/api/v1/mobile/dispatcher/settings", status: 200, body: try ContractFixtures.json("dispatcher-settings.json")["on"]?["response"]?["body"] ?? .null)
                try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq)
            default:
                try await h.io.sendEvent(Self.resolved(agent, decision: c.decision))
                if c.refreshes { try await h.io.pushSnapshot(lastSeq: await h.io.currentSeq) }
            }
            await h.settle(20)
            resolvedDelivered = true
        }

        if c.interleave == .drainSettings {
            await h.io.override("/api/v1/mobile/dispatcher/settings", status: 200, body: try ContractFixtures.json("dispatcher-settings.json")["on"]?["response"]?["body"] ?? .null)
            _ = try? await h.service.dispatcherSettings(hostID: h.target.hostID)
            await h.io.clearOverride("/api/v1/mobile/dispatcher/settings")
        }
        switch c.interleave {
        case .heldStaleBefore, .held409, .heldAhead:
            try await holdRead(); try await create(); try await withdraw()
        case .heldPendingPage:
            try await create(); try await holdRead(); try await withdraw()
        default:
            try await create(); try await withdraw()
        }
        // Release a held read: with the page from when it was issued, or with 409 after the display run moved on.
        if held != nil {
            switch c.interleave {
            case .held409: await h.io.release(path, status: 409, body: .object(["error": .string("chat_read_changed")]))
            case .heldPendingPage: await h.io.release(path, status: 200, body: Self.page(h, .pending, decision: c.decision))
            case .heldAhead: if await h.io.isHeld(path) { await h.io.release(path, status: 200, body: Self.page(h, .before, decision: c.decision)) }
            default: await h.io.release(path, status: 200, body: Self.page(h, .before, decision: c.decision))
            }
            await held?.value
        }
        // A replayed request (same chat seq, new global seq) after the resolution.
        try await h.io.sendEvent(Self.request(agent))
        await h.settle(20)

        let expected = Self.expectedResolution(c.decision)
        let steps = try? await h.wait("settled", steps: 2000) {
            h.usable && Self.approvals(h).first?.resolution == expected && Self.pendingIDs(h).isEmpty
        }
        await h.settle(150)
        h.sampler.stop()
        let reads = await h.chatReads() - reads0, passes = await h.catalogPasses() - passes0
        let approvals = Self.approvals(h)
        h.row("selected-lifecycle", [("case", c.testDescription), ("label", c.label), ("steps", steps ?? -1),
            ("pendingSeenAfterCreate", pendingSeen.joined(separator: ",")), ("finalPending", Self.pendingIDs(h).count),
            ("approvalItems", approvals.count), ("resolution", approvals.first.map { "\($0.resolution)" } ?? "nil"),
            ("chatReads", reads), ("catalogPasses", passes), ("loadStarts", h.sampler.loadStarts), ("staleShownAsCurrent", h.sampler.staleShownAsCurrent),
            ("drainBlockedBySettings", drainBlocked.map { "\($0)" } ?? "n/a"), ("error", h.conversation.error ?? "nil"),
            ("usable", h.usable), ("reply", h.texts().contains(h.fixture.expectedReply)), ("posts", await h.io.posts), ("unauthorized", await h.io.unauthorized),
            ("phases", h.sampler.phases.map { "\($0)" }.joined(separator: ">"))])

        // While a history read is in flight the service buffers live chat events (CompanionLiveService.history), so a
        // request created then is not shown until the read returns. That is recorded, not hidden.
        let createdDuringRead = [Interleave.heldStaleBefore, .held409, .heldAhead].contains(c.interleave)
        let createdDuringReadShown = c.interleave == .heldAhead   // the resync retires the read, which drains the buffer
        #expect(pendingSeen == (createdDuringRead && !createdDuringReadShown ? [] : [Self.requestID]),
                "pending identity: exactly the created request is pending after create (buffered while a read is in flight)")
        #expect(steps != nil, "settles within bounded steps")
        #expect(h.usable && h.projectsFixtureInOrder(), "DISPLAY: current generation's reply, usable")
        #expect(Self.pendingIDs(h).isEmpty, "the withdrawn/resolved request is no longer pending")
        #expect(approvals.count == 1 && approvals.first?.resolution == expected, "one approval item, resolved as delivered; no replayed or duplicated grant")
        #expect(h.sampler.staleShownAsCurrent == 0, "no stale pending shown as current")
        #expect(reads <= 3 && passes <= 2, "bounded reloads")
        #expect(await h.io.posts == 0, "LIVE: no command sent")
        #expect(await h.io.unauthorized == 0, "auth on every request")
        await h.stop()
    }
}
