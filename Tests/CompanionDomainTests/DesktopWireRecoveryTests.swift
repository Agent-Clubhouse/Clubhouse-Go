import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Wire consequences of desktop #2665 head 2ed9286b34c734b3ba2bb01176729b6a2401e0bc.
// Uses the production AnnexTransport/cursor, CompanionLiveService and CompanionStore.
private actor RecoverySocket: AnnexWebSocket {
    private var queue: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    var gap = false
    var replay: [AnnexEnvelope] = []
    func setReplay(_ frames: [AnnexEnvelope], gap: Bool = false) { replay = frames; self.gap = gap }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ frames: [AnnexEnvelope]) throws {
        guard !closed else { throw AnnexTransportError.disconnected }
        for frame in frames {
            let bytes = try JSONEncoder().encode(frame)
            if let pending { self.pending = nil; pending.resume(returning: bytes) }
            else { queue.append(bytes) }
        }
    }
    func send(_ bytes: Data) throws {
        let frame = try JSONDecoder().decode(AnnexJSON.self, from: bytes)
        guard frame["type"]?.string == "mobile:replay" else { return }
        if gap { try push([.init(type: "replay:gap", epoch: "epoch")]); return }
        let since = frame["since"]?.integer ?? 0
        try push([.init(type: "replay:start", epoch: "epoch")])
        try push(replay.filter { ($0.seq ?? 0) > since }.map {
            AnnexEnvelope(type: $0.type, payload: $0.payload, seq: $0.seq, replayed: true, epoch: "epoch")
        })
        try push([.init(type: "replay:end", epoch: "epoch")])
    }
    func ping() throws { if closed { throw AnnexTransportError.disconnected } }
    func close() { closed = true; pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil }
}
private actor RecoveryIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let rest: ScriptedAnnexTransport
    init(rest: ScriptedAnnexTransport) { self.rest = rest }
    private(set) var sockets: [RecoverySocket] = []
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        let body: AnnexJSON
        if path.hasSuffix("/identity") {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if path.hasSuffix("/capabilities") { body = try await rest.read(.capabilities) }
        else if path.hasSuffix("/projects") { body = try await rest.read(.projects) }
        else if path.hasSuffix("/agents") { body = try await rest.read(.agents(projectID: "project")) }
        else if path.hasSuffix("/chat") {
            if request.url?.query != nil { body = try await rest.read(.chatHistory(agentID: "agent", sessionID: nil, beforeSeq: nil, limit: 1)) }
            else { body = try await rest.read(.chat(agentID: "agent")) }
        } else { body = .object([:]) }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = RecoverySocket(); sockets.append(socket); return socket
    }
}
private func recoveryEvent(_ type: String, _ seq: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
    .object(["sessionId": .string("s1"), "seq": .integer(seq), "type": .string(type), "data": .object(data)])
}
private let recoveryBaseEvents = [
    recoveryEvent("session_started", 1, ["capabilities": .object(["chat": .bool(true)])]),
    recoveryEvent("user_message", 2, ["messageId": .string("q"), "delivery": .string("queued"), "content": .array([])]),
    recoveryEvent("tool_call", 3, ["toolCallId": .string("t"), "status": .string("in_progress"), "rawOutput": .string("partial")]),
    recoveryEvent("turn_started", 4, [:]),
    recoveryEvent("agent_message_chunk", 5, ["messageId": .string("answer"), "text": .string("part")]),
    recoveryEvent("queue_state", 6, ["queuedMessageIds": .array([.string("q")])]),
    recoveryEvent("permission_request", 7, ["requestId": .string("p"), "options": .array([])]),
]
private let recoveryFinalEvents = [
    recoveryEvent("agent_message", 8, ["messageId": .string("answer"), "text": .string("Final answer")]),
    recoveryEvent("tool_call_update", 9, ["toolCallId": .string("t"), "status": .string("completed"), "rawOutput": .string("done")]),
    recoveryEvent("queue_state", 10, ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string("q")]), "status": .string("delivered")])]),
    recoveryEvent("permission_resolved", 11, ["requestId": .string("p"), "decision": .string("allow")]),
    recoveryEvent("session_state", 12, ["state": .string("idle")]),
]
private func recoveryHistory(final: Bool) -> AnnexJSON {
    .object(["sessionId": .string("s1"), "state": .string(final ? "idle" : "waiting_permission"),
             "events": .array(recoveryBaseEvents + (final ? recoveryFinalEvents : [])), "capabilities": .object(["chat": .bool(true)]),
             "queuedMessageIds": .array(final ? [] : [.string("q")]), "queueStateSeq": .integer(final ? 10 : 6), "queueRemovalSupported": .bool(true)])
}
private func recoveryFrames() -> [AnnexEnvelope] {
    recoveryFinalEvents.enumerated().map { index, event in
        .init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]), seq: 101 + Int64(index), epoch: "epoch")
    }
}
private func recoverySnapshot(_ seq: Int64, fresh: Bool = true, name: String = "Project") -> AnnexEnvelope {
    let quick: AnnexJSON = .object(["id": .string("q5"), "name": .string("New helper"), "kind": .string("quick"), "status": .string("running")])
    let helper: AnnexJSON = .object(["requestId": .string("hstart_1"), "kind": .string("start"), "projectId": .string("project"), "requester": .object(["agentId": .string("agent")])])
    return .init(type: "snapshot", payload: .object([
        "projects": .array([.object(["id": .string("project"), "name": .string(name)])]),
        "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running")])])]),
        "quickAgents": .object(["project": .array(fresh ? [quick] : [])]), "helperRequests": .array(fresh ? [] : [helper])]), lastSeq: seq, epoch: "epoch")
}
@MainActor private struct RecoveryHarness {
    let io: RecoveryIO
    let transport: AnnexTransport
    let service: CompanionLiveService
    let store: CompanionStore
    let target: CompanionTarget
    let clock: AnnexManualClock
    let monitor: AsyncThrowingStream<AnnexTransportEvent, Error>
    var host: CompanionHost? { store.hosts.first }
    static func start() async throws -> Self {
        let io = RecoveryIO(rest: ScriptedAnnexTransport()), clock = AnnexManualClock()
        await io.rest.setRead("chat", recoveryHistory(final: false))
        await io.rest.setRead("chatHistory", recoveryHistory(final: false))
        let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id,
            verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: id)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, eventCapacity: 2048, telemetry: AnnexTelemetry(), clock: clock.clock)
        let monitor = await transport.events()
        let service = CompanionLiveService(), store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        let result = Self(io: io, transport: transport, service: service, store: store, target: .init(hostID: id, projectID: "project", agentID: "agent"), clock: clock, monitor: monitor)
        try await result.wait { await io.sockets.count == 1 }
        await store.load(result.target)
        #expect(store.conversation(for: result.target).lastSequence == 7)
        return result
    }
    func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Recovery condition timed out"); throw AnnexTransportError.disconnected
    }
    func makeHistoryFresh() async {
        await io.rest.setRead("chat", recoveryHistory(final: true))
        await io.rest.setRead("chatHistory", recoveryHistory(final: true))
    }
    func reconnectAfterGap() async throws -> [AnnexResyncReason] {
        var reasons: [AnnexResyncReason] = []
        var delay = 0.0
        for try await event in monitor {
            if case .resyncRequired(let reason) = event { reasons.append(reason) }
            if case .connection(.reconnecting(_, let seconds)) = event { delay = seconds; break }
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(delay + 0.001))
        try await wait { await io.sockets.count == 2 }
        let next = try #require(await io.sockets.last)
        try await next.push([recoverySnapshot(105)])
        try await wait { host?.connection == .connected && store.conversation(for: target).requiresResync }
        // This is the full-history load the store requests from its resync flag, as the conversation UI does.
        await store.load(target, force: true)
        return reasons
    }
    func assertFinal() {
        let items = store.conversation(for: target).items
        #expect(items.contains { if case .message(let m) = $0 { m.id == "answer" && m.text == "Final answer" } else { false } })
        #expect(items.contains { if case .tool(let t) = $0 { t.id == "t" && t.state == .completed && t.output == "done" } else { false } })
        #expect(items.contains { if case .message(let m) = $0 { m.id == "q" && m.queueState == .delivered } else { false } })
        #expect(items.contains { if case .approval(let p) = $0 { p.id == "p" && p.resolution == .allowed } else { false } })
        #expect(host?.agent(for: target)?.status == .idle)
        #expect(host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count == 1)
        #expect(host?.helperRequests.isEmpty == true)
    }
    func stop() async { await transport.disconnect(); store.stop(); service.remove(hostID: target.hostID) }
}

@Suite @MainActor struct DesktopWireRecoveryTests {
    @Test(arguments: [false, true])
    func firstSnapshotJumpAndLostReplayBufferRecoverAllState(lostReplay: Bool) async throws {
        let h = try await RecoveryHarness.start()
        let socket = try #require(await h.io.sockets.first)
        await h.makeHistoryFresh()
        await socket.setReplay(recoveryFrames(), gap: lostReplay)
        // The retained suffix is already queued ahead of the replay response; 147 closes on the jump.
        try await socket.push(lostReplay ? [recoverySnapshot(100)] : [recoverySnapshot(100), recoveryFrames().last!])
        let reasons = try await h.reconnectAfterGap()
        #expect(reasons.contains(lostReplay ? .replayGap : .sequenceGap))
        h.assertFinal()
        print("Head2ed9286 \(lostReplay ? "lost replay buffer" : "first snapshot + overflow seq jump"): real run reconnect + required full history restores chat/tool/queue/approval/catalog/helper state")
        await h.stop()
    }

    @Test func streamingAndRacedCatalogRefreshesPreserveFinalStateAndMakeProgress() async throws {
        let h = try await RecoveryHarness.start()
        let socket = try #require(await h.io.sockets.first)
        try await socket.push([recoverySnapshot(100, fresh: false)])
        try await h.wait { h.host?.connection == .connected }
        await h.makeHistoryFresh()
        try await socket.push(recoveryFrames())
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 12 }
        // Catalog change raced the disk reads. The old checkpoint is dropped; the 250 ms follow-up is fresh.
        try await socket.push([recoverySnapshot(100, fresh: false)])
        h.clock.advance(by: .milliseconds(250))
        try await socket.push([recoverySnapshot(105)])
        try await h.wait { h.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true }
        for round in 1...3 {
            let event = recoveryEvent("agent_message_chunk", 12 + Int64(round), ["messageId": .string("stream"), "text": .string("x")])
            try await socket.push([.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]), seq: 105 + Int64(round), epoch: "epoch"),
                recoverySnapshot(105 + Int64(round), name: "Round\(round)")])
        }
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 15 }
        // A REST refresh uses the canonical project name; transcript progress proves every wire refresh was accepted.
        #expect(await h.io.sockets.count == 1)
        #expect(await socket.closed == false)
        h.assertFinal()
        let stream = h.store.conversation(for: h.target).items.compactMap { if case .message(let m) = $0, m.id == "stream" { m.text } else { nil } }.first
        #expect(stream == "xxx")
        print("Head2ed9286 refresh: stale100 dropped at cursor105; follow-up105 accepted; three streaming refreshes make progress, no reconnect, final state intact")
        await h.stop()
    }
}
