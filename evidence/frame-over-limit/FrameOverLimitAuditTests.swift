import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Scratch evidence only: production transport, service, projector and observable store.
// CH frames are captured by its real server test harness at ba560869.
private func capture(_ name: String) throws -> AnnexJSON {
    let root = try #require(ProcessInfo.processInfo.environment["GO2732_CAPTURE_ROOT"])
    return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name + ".json")))
}
private func frames(_ name: String) throws -> [AnnexEnvelope] {
    guard case .array(let values) = try capture(name) else { throw AnnexTransportError.malformedResponse }
    return try values.map { try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode($0)) }
}
private func event(_ type: String, _ seq: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
    .object(["sessionId": .string("s1"), "seq": .integer(seq), "type": .string(type), "data": .object(data)])
}
private let baseEvents: [AnnexJSON] = [
    event("session_started", 1, ["capabilities": .object(["chat": .bool(true), "questions": .bool(true)])]),
    event("user_message", 2, ["messageId": .string("q"), "delivery": .string("queued"), "content": .array([.object(["type": .string("text"), "text": .string("Queued")])])]),
    event("turn_started", 3, [:]),
    event("agent_message_chunk", 4, ["messageId": .string("answer"), "text": .string("prefix")]),
    event("queue_state", 5, ["queuedMessageIds": .array([.string("q")])]),
    event("question", 6, ["requestId": .string("question"), "questions": .array([.object(["question": .string("Exact question?"), "header": .string("H"), "options": .array([])])])]),
    event("permission_request", 7, ["requestId": .string("p"), "title": .string("Approval"), "options": .array([])])
]
private var initialHistory: AnnexJSON {
    .object(["sessionId": .string("s1"), "state": .string("waiting_permission"), "events": .array(baseEvents), "pendingPermissions": .array([baseEvents[6]]), "pendingQuestions": .array([baseEvents[5]]), "capabilities": .object(["chat": .bool(true)]), "queuedMessageIds": .array([.string("q")]), "queueStateSeq": .integer(5)])
}
private actor LimitSocket: AnnexWebSocket {
    private var packets: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private(set) var requests: [Int64] = []
    private(set) var gaps = 0
    private var gapBelow: Int64?
    func configureGap(below: Int64) { gapBelow = below }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !packets.isEmpty { return packets.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ values: [AnnexEnvelope]) throws {
        for value in values {
            let data = try JSONEncoder().encode(value)
            if let pending { self.pending = nil; pending.resume(returning: data) } else { packets.append(data) }
        }
    }
    func send(_ data: Data) throws {
        let value = try JSONDecoder().decode(AnnexJSON.self, from: data)
        guard value["type"]?.string == "mobile:replay", let since = value["since"]?.integer else { return }
        requests.append(since)
        if let gapBelow, since < gapBelow { gaps += 1; try push(frames("critical-gap")) }
        else { try push(frames("critical-clean")) }
    }
    func oversizedReceiveFailure() {
        // Reuse the earlier pinned URLSession cap proof: Darwin emits EMSGSIZE;
        // current PinnedAnnexIO normalizes it, whereas 147 passes it through.
        #if AUDIT147
        let error: any Error = NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE))
        #else
        let error: any Error = AnnexTransportError.responseTooLarge
        #endif
        pending?.resume(throwing: error); pending = nil
    }
    func ping() throws { if closed { throw AnnexTransportError.disconnected } }
    func close() { closed = true; pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil }
}
private actor LimitIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let epoch: String
    private(set) var sockets: [LimitSocket] = []
    private(set) var reads: [String: Int] = [:]
    private var checkpoints: [Int64] = []
    private var gapBelow: Int64?
    private var history = initialHistory
    init(epoch: String) { self.epoch = epoch }
    func setCheckpoints(_ values: [Int64], gapBelow: Int64?) { checkpoints = values; self.gapBelow = gapBelow }
    func setHistory(_ value: AnnexJSON) { history = value }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        reads[path, default: 0] += 1
        let body: AnnexJSON
        if path.hasSuffix("/identity") {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if path.hasSuffix("/capabilities") {
            body = .object(["version": .integer(1), "epoch": .string(epoch), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]), "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])])
        } else if path.hasSuffix("/projects") { body = .array([.object(["id": .string("project"), "name": .string("Project")])]) }
        else if path.hasSuffix("/agents") { body = .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running")])]) }
        else if path.hasSuffix("/chat") { body = history }
        else { body = .object([:]) }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket {
        let socket = LimitSocket(); sockets.append(socket)
        if let gapBelow { await socket.configureGap(below: gapBelow) }
        if !checkpoints.isEmpty { try await socket.push([checkpoint(checkpoints.removeFirst())]) }
        return socket
    }
}
private func checkpoint(_ sequence: Int64) throws -> AnnexEnvelope {
    let snapshot = try #require(frames("critical-reconnect").first)
    // A held first snapshot uses its connection-start cursor, not build-finish seq.
    // The production-captured catalog is otherwise unchanged.
    if case .object(var payload) = snapshot.payload {
        payload["lastSeq"] = .integer(sequence)
        return .init(type: "snapshot", payload: .object(payload), epoch: snapshot.epoch)
    }
    throw AnnexTransportError.malformedResponse
}
@MainActor private final class LimitHarness {
    let io: LimitIO
    let clock = AnnexManualClock()
    let transport: AnnexTransport
    let credentials = MemoryAnnexCredentialStore()
    let service = CompanionLiveService()
    let store: CompanionStore
    let target: CompanionTarget
    var trace: [AnnexTransportEvent] = []
    var monitor: Task<Void, Never>?
    var host: CompanionHost? { store.hosts.first }
    init() throws {
        io = try LimitIO(epoch: #require(capture("epoch").string))
        let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id, verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        transport = AnnexTransport(host: host, credentials: credentials, io: io, eventCapacity: 2048, telemetry: AnnexTelemetry(), clock: clock.clock)
        store = CompanionStore(service: service)
        target = .init(hostID: id, projectID: "project", agentID: "agent")
    }
    func start(checkpoint sequence: Int64 = 0) async throws {
        // Credentials are normally loaded from Keychain; only the leaf is fake.
        await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: target.hostID)
        let events = await transport.events()
        monitor = Task { [weak self] in do { for try await value in events { self?.trace.append(value) } } catch {} }
        store.start()
        await service.register(.init(host: transport.host, alias: "Fixture", transport: transport))
        try await wait { await self.io.sockets.count == 1 }
        let socket = try #require(await io.sockets.first)
        try await socket.push([checkpoint(sequence)])
        try await wait { self.host?.connection == .connected }
        await store.load(target)
        #expect(store.conversation(for: target).lastSequence == 7)
    }
    func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("2732 condition timed out"); throw AnnexTransportError.disconnected
    }
    func reconnect(to count: Int) async throws {
        try await wait { self.trace.filter { value in
            if case .connection(.reconnecting) = value { return true }
            #if !AUDIT147
            if case .connection(.retrying) = value { return true }
            #endif
            return false
        }.count >= count - 1 && self.clock.sleeperCount > 0 }
        clock.advance(by: .seconds(46))
        try await wait { await self.io.sockets.count == count }
    }
    func assertCritical() {
        let items = store.conversation(for: target).items
        #expect(items.contains { $0.id == "approval:p" })
        #expect(items.contains { $0.id == "question:question" })
        #expect(items.contains { if case .message(let m) = $0 { m.id == "q" && m.queueState == .queued } else { false } })
    }
    func message(_ id: String) -> CompanionMessage? {
        store.conversation(for: target).items.compactMap { if case .message(let m) = $0, m.id == id { m } else { nil } }.first
    }
    func stop() async { await transport.disconnect(); monitor?.cancel(); store.stop(); service.remove(hostID: target.hostID) }
}

@Suite(.serialized) @MainActor struct FrameOverLimitAuditTests {
    @Test(arguments: [false, true])
    func criticalOversizeReconnectAndGapAdoptFreshCheckpoint(heldOldCheckpoint: Bool) async throws {
        let h = try LimitHarness(); try await h.start(checkpoint: 8)
        let first = try #require(await h.io.sockets.first)
        await h.io.setCheckpoints(heldOldCheckpoint ? [8, 9] : [9], gapBelow: 9)
        await first.oversizedReceiveFailure()
        try await h.reconnect(to: 2)
        if heldOldCheckpoint {
            try await h.wait { await h.io.sockets.last?.gaps == 1 }
            try await h.reconnect(to: 3)
        }
        try await h.wait { h.host?.connection == .connected }
        let last = try #require(await h.io.sockets.last)
        try await h.wait { await last.requests == [9] }
        // Repeated equal checkpoints request the new cursor, never the old one.
        try await last.push([checkpoint(9), checkpoint(9)])
        try await h.wait { await last.requests == [9, 9, 9] }
        try await last.push(frames("critical-next"))
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 17 }
        await h.store.load(h.target, force: true)
        h.assertCritical()
        #expect(h.store.conversation(for: h.target).requiresResync == false)
        let sockets = await h.io.sockets
        var requests: [[Int64]] = [], gaps = 0
        for socket in sockets { requests.append(await socket.requests); gaps += await socket.gaps }
        #expect(gaps == (heldOldCheckpoint ? 1 : 0))
        #expect(sockets.count == (heldOldCheckpoint ? 3 : 2))
        print("2732 CRITICAL held=\(heldOldCheckpoint) sockets=\(sockets.count) replay=\(requests) gaps=\(gaps) reads=\(await h.io.reads) pending/queue=kept refreshed=true")
        await h.stop()
    }

    @Test func olderCursorBeforeCheckpointGapNeedsOneFreshSnapshot() async throws {
        let h = try LimitHarness(); try await h.start(checkpoint: 8)
        let first = try #require(await h.io.sockets.first)
        await first.configureGap(below: 9)
        await h.io.setCheckpoints([9], gapBelow: 9)
        try await first.push([checkpoint(8)])
        try await h.wait { await first.gaps == 1 }
        try await h.reconnect(to: 2)
        try await h.wait { h.host?.connection == .connected }
        let last = try #require(await h.io.sockets.last)
        try await h.wait { await last.requests == [9] }
        #expect(await h.io.sockets.count == 2)
        h.assertCritical()
        print("2732 OLD CURSOR gap.lastSeq=9 ignored; closes once; fresh snapshot9 -> replay9 clean; sockets=2 gaps=1 reads=\(await h.io.reads)")
        await h.stop()
    }

    @Test func repeatedStaleSnapshotsRepeatGapsUntilCheckpointAdvances() async throws {
        let h = try LimitHarness(); try await h.start(checkpoint: 8)
        let first = try #require(await h.io.sockets.first)
        await first.configureGap(below: 9)
        await h.io.setCheckpoints([8, 8, 9], gapBelow: 9)
        try await first.push([checkpoint(8)])
        for count in 2...4 { try await h.reconnect(to: count) }
        let last = try #require(await h.io.sockets.last)
        try await h.wait { await last.requests == [9] && h.host?.connection == .connected }
        var gaps = 0
        for socket in await h.io.sockets { gaps += await socket.gaps }
        #expect(gaps == 3)
        print("2732 NEGATIVE CONTROL three stale snapshot8s -> three gaps9; fresh snapshot9 stops it; gap.lastSeq is NOT adopted")
        await h.stop()
    }

    @Test(arguments: [false, true])
    func omittedTextFitsFinalOrEndsPrefixThenHistoryReplacesOnce(stub: Bool) async throws {
        let h = try LimitHarness(); try await h.start()
        let socket = try #require(await h.io.sockets.first)
        try await socket.push(frames("fitting"))
        let full = try #require(frames("fitting")[1].payload?["event"]?["data"]?["text"]?.string)
        try await h.wait { h.message("answer")?.text == full && h.message("answer")?.isStreaming == false }
        #expect(h.store.conversation(for: h.target).items.filter { $0.id == "message:answer" }.count == 1)
        try await socket.push(frames("omitted-final"))
        try await h.wait { h.store.conversation(for: h.target).lastSequence == 15 }
        #expect(h.message("omittedAnswer")?.text == "Visible prefix")
        #expect(h.message("omittedAnswer")?.isStreaming == false)
        #expect(h.host?.agent(for: h.target)?.status == .idle)
        h.assertCritical()
        let history = try capture(stub ? "history-stub" : "history-preview")
        let body = try #require(history["body"]?.string)
        let page = try JSONDecoder().decode(AnnexJSON.self, from: Data(body.utf8))
        await h.io.setHistory(page)
        await h.store.load(h.target, force: true)
        let afterFirst = h.store.conversation(for: h.target).items
        if stub {
            #expect(h.message("omittedAnswer") == nil)
            #expect(afterFirst.contains { if case .notice(_, let text) = $0 { text == "Something here is too large to show. It's on the desktop." } else { false } })
        } else {
            let preview = try #require(h.message("omittedAnswer"))
            #expect(preview.text.utf8.count <= 256 * 1024 + 256)
            #expect(preview.text.contains("omitted"))
            #expect(preview.isStreaming == false)
            #expect(afterFirst.filter { $0.id == "message:omittedAnswer" }.count == 1)
        }
        await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).items == afterFirst)
        #expect(await h.io.sockets.count == 1)
        print("2732 TEXT finalFits=full3MiBonce omittedFinal=Visible prefix/nonStreaming/idle historyStub=\(stub) replacedOnce sockets=1")
        await h.stop()
    }

    @Test func canvasMarkersAreIgnoredWithoutTouchingState() async throws {
        let h = try LimitHarness(); try await h.start()
        let before = h.store.conversation(for: h.target)
        let socket = try #require(await h.io.sockets.first)
        try await socket.push(frames("canvas"))
        let marker = AnnexEnvelope(type: "fixture:done", payload: .object([:]))
        try await socket.push([marker])
        try await h.wait { h.trace.contains { if case .message(let e) = $0 { e.type == "fixture:done" } else { false } } }
        #expect(h.store.conversation(for: h.target).items == before.items)
        #expect(h.store.conversation(for: h.target).lastSequence == before.lastSequence)
        #expect(h.host?.connection == .connected)
        #expect(await socket.closed == false)
        h.assertCritical()
        print("2732 CANVAS project/global markers ignored; pending/queue/chat/cursor kept; sockets=1")
        await h.stop()
    }
}
