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
    private var attachAck: AnnexEnvelope?
    private(set) var attachRequests = 0
    func configureAttach(bytes: Int) {
        attachAck = .init(type: "pty:attach:ack", payload: .object(["agentId": .string("agent"), "buffer": .string(String(repeating: "x", count: bytes)), "cols": .integer(120), "rows": .integer(40)]))
    }
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
        if frame["type"]?.string == "pty:attach" {
            attachRequests += 1
            if let attachAck { try push([attachAck]) }
            return
        }
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
    private var reads: [String: AnnexJSON] = [:]
    private var extraCapabilities: [String: AnnexJSON] = [:]
    func setRead(_ name: String, _ value: AnnexJSON) { reads[name] = value }
    func setCapability(_ name: String, _ value: AnnexJSON) { extraCapabilities[name] = value }
    private var capabilities: AnnexJSON {
        var fields: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]), "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])]
        fields.merge(extraCapabilities) { _, new in new }
        return .object(fields)
    }
    private(set) var sockets: [RecoverySocket] = []
    private var oversizeUntil: Date?
    private var recoverAfterWindow = false
    private var terminalAckBytes: Int?
    func configureTerminal(bytes: Int) { terminalAckBytes = bytes }
    private var recoveryTask: Task<Void, Never>?
    func simulateOversizeWindow(seconds: TimeInterval) {
        oversizeUntil = Date().addingTimeInterval(seconds)
        recoverAfterWindow = true
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.finishOversizeWindow()
        }
    }
    private func finishOversizeWindow() async {
        oversizeUntil = nil
        for socket in sockets where await !socket.closed {
            try? await socket.push([recoverySnapshot(105)])
        }
    }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        let body: AnnexJSON
        if path.hasSuffix("/identity") {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if path.hasSuffix("/capabilities") { body = capabilities }
        else if path.hasSuffix("/projects") { body = .array([.object(["id": .string("project"), "name": .string("Project")])]) }
        else if path.hasSuffix("/agents") { body = .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])]) }
        else if path.hasSuffix("/chat") {
            if request.url?.query != nil { body = reads["chatHistory"] ?? .null }
            else { body = reads["chat"] ?? .null }
        } else { body = .object([:]) }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket {
        let socket = RecoverySocket(); sockets.append(socket)
        if let terminalAckBytes {
            await socket.configureAttach(bytes: terminalAckBytes)
            try await socket.push([recoverySnapshot(0)])
        }
        if let oversizeUntil, Date() < oversizeUntil {
            try await socket.push([.init(type: "error", payload: .object(["message": .string("snapshot_failed")]))])
        } else if recoverAfterWindow {
            try await socket.push([recoverySnapshot(105)])
        }
        return socket
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
    static func start(liveClock: Bool = false, oversizeWindow: TimeInterval? = nil, terminalAckBytes: Int? = nil) async throws -> Self {
        let io = RecoveryIO(), clock = AnnexManualClock()
        if let oversizeWindow { await io.simulateOversizeWindow(seconds: oversizeWindow) }
        if let terminalAckBytes {
            await io.configureTerminal(bytes: terminalAckBytes)
            await io.setCapability("terminal", .object(["version": .integer(1), "agentAttach": .bool(true), "projectShell": .bool(true), "agentShell": .bool(true)]))
        }
        await io.setRead("chat", recoveryHistory(final: false))
        await io.setRead("chatHistory", recoveryHistory(final: false))
        let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id,
            verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: id)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, eventCapacity: 2048, telemetry: AnnexTelemetry(), clock: liveClock ? .live : clock.clock)
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
        await io.setRead("chat", recoveryHistory(final: true))
        await io.setRead("chatHistory", recoveryHistory(final: true))
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

// Opt-in wall-clock experiment: run uses ContinuousClock to reset attempts, so a
// test clock alone cannot establish its long-period cadence. This scripts the
// audited server's wire promises; it does NOT execute or approve that server.
@Suite @MainActor struct DesktopOversizeCooldownCadenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANNEX_REAL_CADENCE_TESTS"] == "1"), .timeLimit(.minutes(7)))
    func fiveMinuteWindowOn147RecoversThroughResync() async throws {
        let started = ContinuousClock.now
        let h = try await RecoveryHarness.start(liveClock: true, oversizeWindow: 300)
        await h.makeHistoryFresh()
        var attempts: [Int] = [], delays: [Double] = [], elapsed: [Duration] = []
        var failures = 0, reconnectResyncs = 0
        for try await event in h.monitor {
            if case .message(let frame) = event {
                if frame.type == "error", frame.payload?["message"]?.string == "snapshot_failed" { failures += 1 }
                if frame.type == "snapshot" { break }
            }
            if case .resyncRequired(.reconnected) = event { reconnectResyncs += 1 }
            if case .connection(.reconnecting(let attempt, let delay)) = event {
                attempts.append(attempt); delays.append(delay); elapsed.append(ContinuousClock.now - started)
                print("147 cooldown reconnect \(attempts.count): attempt=\(attempt) delay=\(delay) elapsed=\(elapsed.last!)")
            }
            if case .connection(.retrying) = event { Issue.record("Withheld oversize must not be labeled responseTooLarge") }
        }
        #expect(ContinuousClock.now - started >= .seconds(300))
        #expect((9...10).contains(attempts.count))
        #expect(attempts.allSatisfy { $0 == 1 })
        #expect(delays.allSatisfy { (0.25...0.5).contains($0) })
        #expect(failures == attempts.count + 1)
        #expect(reconnectResyncs == attempts.count)
        try await h.wait { h.host?.connection == .connected && h.store.conversation(for: h.target).requiresResync }
        await h.store.load(h.target, force: true)
        h.assertFinal()
        print("69c626b7e scripted wire, live 147 clock: failures=\(failures), attempts=\(attempts), delays=\(delays), elapsed=\(elapsed), resyncs=\(reconnectResyncs); first good snapshot restores final state with full history load")
        await h.stop()
    }
}

// Opt-in wall-clock experiment: run uses ContinuousClock to reset attempts, so a
// test clock alone cannot establish its long-period cadence. This scripts the
// audited server's wire promises; it does NOT execute or approve that server.
@Suite @MainActor struct DesktopFailureCooldownCadenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANNEX_REAL_CADENCE_TESTS"] == "1"), .timeLimit(.minutes(7)))
    func failedBuildBackoffOn147RecoversThroughResync() async throws {
        let started = ContinuousClock.now
        let h = try await RecoveryHarness.start(liveClock: true, oversizeWindow: 160)
        await h.makeHistoryFresh()
        var attempts: [Int] = [], delays: [Double] = [], elapsed: [Duration] = []
        var failures = 0, reconnectResyncs = 0
        for try await event in h.monitor {
            if case .message(let frame) = event {
                if frame.type == "error", frame.payload?["message"]?.string == "snapshot_failed" { failures += 1 }
                if frame.type == "snapshot" { break }
            }
            if case .resyncRequired(.reconnected) = event { reconnectResyncs += 1 }
            if case .connection(.reconnecting(let attempt, let delay)) = event {
                attempts.append(attempt); delays.append(delay); elapsed.append(ContinuousClock.now - started)
                print("147 cooldown reconnect \(attempts.count): attempt=\(attempt) delay=\(delay) elapsed=\(elapsed.last!)")
            }
            if case .connection(.retrying) = event { Issue.record("Withheld oversize must not be labeled responseTooLarge") }
        }
        #expect(ContinuousClock.now - started >= .seconds(160))
        #expect((4...5).contains(attempts.count))
        #expect(attempts.allSatisfy { $0 == 1 })
        #expect(delays.allSatisfy { (0.25...0.5).contains($0) })
        #expect((attempts.count...(attempts.count + 1)).contains(failures))
        #expect(reconnectResyncs == attempts.count)
        try await h.wait { h.host?.connection == .connected && h.store.conversation(for: h.target).requiresResync }
        await h.store.load(h.target, force: true)
        h.assertFinal()
        print("5cdd0c62 failed-build scripted wire, live 147 clock: failures=\(failures), attempts=\(attempts), delays=\(delays), elapsed=\(elapsed), resyncs=\(reconnectResyncs); first good snapshot restores final state with full history load")
        await h.stop()
    }
}

@Suite @MainActor struct DesktopFanoutRefreshTests {
    @Test(arguments: [104, 105, 106])
    func connectedPhoneAcceptsEqualReplaysAheadAndDropsOlderSnapshot(checkpoint: Int64) async throws {
        let h = try await RecoveryHarness.start()
        let socket = try #require(await h.io.sockets.first)
        try await socket.push([recoverySnapshot(100, fresh: false)])
        try await h.wait { h.host?.connection == .connected }
        await h.makeHistoryFresh()
        try await socket.push(recoveryFrames())
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 12 }
        try await socket.push([recoverySnapshot(105)])
        try await h.wait { h.host?.helperRequests.isEmpty == true && h.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true }
        // Connected sockets receive the ordinary refresh checkpoint, not their
        // original connect seq. Only first-snapshot waiters use held.cursor.
        let extra = AnnexEnvelope(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": recoveryFinalEvents.last!]), seq: 106, epoch: "epoch")
        await socket.setReplay(checkpoint > 105 ? [extra] : [])
        try await socket.push([recoverySnapshot(checkpoint, fresh: checkpoint >= 105), .init(type: "fixture:fanout")])
        var gap = false, snapshotSeen = false, replayRecovered = false
        for try await frame in h.monitor {
            if frame == .resyncRequired(.sequenceGap) { gap = true }
            if case .message(let e) = frame, e.type == "snapshot", e.snapshotSequence == checkpoint { snapshotSeen = true }
            if case .message(let e) = frame, e.seq == 106, e.replayed == true { replayRecovered = true }
            if checkpoint > 105 {
                if replayRecovered { break }
            } else if case .message(let e) = frame, e.type == "fixture:fanout" { break }
        }
        #expect(gap == (checkpoint > 105))
        #expect(snapshotSeen == (checkpoint >= 105))
        #expect(replayRecovered == (checkpoint > 105))
        try await h.wait { h.host?.helperRequests.isEmpty == true }
        h.assertFinal()
        #expect(await socket.closed == false)
        #expect(await h.io.sockets.count == 1)
        print("5cdd0c62 connected cursor105 vs fanout\(checkpoint): gap=\(gap), deliveredSnapshot=\(snapshotSeen), no close; final chat/tool/queue/approval/catalog/helpers intact")
        await h.stop()
    }
}

@Suite @MainActor struct FirstSnapshotStateRecoveryTests {
    @Test func droppedBusyFramesRecoverOnceThroughReplayAndProduceFinalState() async throws {
        let h = try await RecoveryHarness.start()
        let socket = try #require(await h.io.sockets.first)
        await h.makeHistoryFresh()
        await socket.setReplay(recoveryFrames())
        try await socket.push(recoveryFrames() + [recoverySnapshot(100), recoveryFrames().last!])
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 12 && h.host?.helperRequests.isEmpty == true && h.host?.agent(for: h.target)?.status == .idle && h.host?.connection == .connected }
        h.assertFinal()
        try await socket.push([.init(type: "fixture:recovered")])
        var delivered: [Int64] = [], reasons: [AnnexResyncReason] = []
        for try await frame in h.monitor {
            if case .resyncRequired(let reason) = frame { reasons.append(reason) }
            if case .message(let e) = frame {
                if let seq = e.seq { delivered.append(seq) }
                if e.type == "fixture:recovered" { break }
            }
        }
        #expect(delivered == [101, 102, 103, 104, 105])
        #expect(reasons.isEmpty)
        #expect(await h.io.sockets.count == 1)
        await h.stop()
    }
}

@Suite(.serialized) @MainActor struct TerminalBudgetEndToEndTests {
    @Test(.timeLimit(.minutes(2)), arguments: [1_247_805, 26 * 1024 * 1024, 66 * 1024 * 1024])
    func attachedTerminalReopensAndRepeatsOversizedAck(bytes: Int) async throws {
        let h = try await RecoveryHarness.start(terminalAckBytes: bytes)
        try await h.wait { h.host?.connection == .connected }
        let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
        let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "PTY", channel: channel)
        session.start()
        if bytes < 16 * 1024 * 1024 {
            try await h.wait { session.state == .running }
            #expect(!session.screen.plainText().isEmpty)
            #expect(await h.io.sockets.count == 1)
        } else {
            var waits: [Double] = []
            for try await frame in h.monitor {
                if case .connection(.retrying(_, let delay, .responseTooLarge)) = frame {
                    waits.append(delay)
                    #expect((30...45).contains(delay))
                    try await h.wait { session.state == .reconnecting }
                    if waits.count == 2 { break }
                    await h.clock.waitForSleepers(1)
                    h.clock.advance(by: .seconds(delay))
                }
            }
            #expect(await h.io.sockets.count == 2)
            for socket in await h.io.sockets { #expect(await socket.attachRequests == 1) }
            print("Real transport+terminal session buffer\(bytes): auto-reattach twice -> oversized ack twice, waits=\(waits), terminal reconnecting")
        }
        session.close()
        await h.stop()
    }
}
