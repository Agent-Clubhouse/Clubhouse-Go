import Foundation
import Testing
@testable import ClubhouseTransport

// Recv-loop audit (mini-go/recvloop-audit): can the PRODUCTION AnnexTransport receive loop
// (AnnexTransport.swift:598-605) delay observing a pong past the 10 s ping deadline?
//
// The fake socket models one URLSession property as an ASSUMED model: control frames (pongs) are read
// only while a receive() is outstanding, in wire order behind any data frames ahead of them. Apple's
// URLSessionWebSocketTask documentation doesn't state this; it's observed on macOS loopback
// (PinnedWebSocketTests.swift:148, the urlsession-pool probe), not verified on iOS. Its ping()
// mirrors URLSessionAnnexWebSocket.ping (AnnexIO.swift:255-280): production AnnexPingCompletion,
// a 10 s deadline on the injected clock, then close(). Everything above the socket is production code.

private let pongCapabilities = #"{"version":1,"epoch":"EPOCH","controlAuth":"mtls-pinned-client","controlAvailable":false,"commands":["chat.send"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var current: Int { lock.withLock { generation } }
    func fire() {
        let ready = lock.withLock { generation += 1; defer { waiters.removeAll() }; return waiters }
        ready.forEach { $0.resume() }
    }
    func wait(past seen: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { if generation != seen { return true }; waiters.append(c); return false }
            if ready { c.resume() }
        }
    }
}

private func settle(_ signal: Signal, _ condition: () async -> Bool) async {
    while true {
        let seen = signal.current
        if await condition() { return }
        await signal.wait(past: seen)
    }
}

/// Like `settle`, but gives up after `seconds` of wall time, so a condition that never holds fails rather than hangs.
private func settle(_ signal: Signal, within seconds: Double, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await settle(signal) { await condition() || Task.isCancelled }; return await condition() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); signal.fire(); return false }
        let first = await group.next() ?? false
        group.cancelAll(); signal.fire()
        return first
    }
}

private enum WireItem { case frame(Data), pong }
private enum PingOutcome: Equatable { case answered, timedOut, failed }

private final class PongGatedSocket: AnnexWebSocket, @unchecked Sendable {
    let signal: Signal
    let clock: AnnexClock
    private let lock = NSLock()
    private var wire: [WireItem]
    private var pendingReceive: CheckedContinuation<Data, Error>?
    private var pongHandlers: [@Sendable (Error?) -> Void] = []
    private var heldSend: CheckedContinuation<Void, Error>?
    private let holdReplaySend: Bool
    private(set) var closed = false
    private(set) var receiveCalls = 0
    private(set) var pingsSent = 0
    private(set) var outcomes: [PingOutcome] = []
    private(set) var pongsOnWireUnread = 0
    private(set) var sentTypes: [String] = []
    /// A send that started while another send was still held (processing would have overlapped the replay).
    private(set) var overlappingSends = 0
    deinit { signal.fire() }
    /// Wall time from the last enqueue to each pong being observed (ms).
    private(set) var pongObservedAfterMs: [Double] = []
    private var lastEnqueue = ContinuousClock.now

    init(initial: [String], holdReplaySend: Bool, signal: Signal, clock: AnnexClock) {
        wire = initial.map { .frame(Data($0.utf8)) }
        self.holdReplaySend = holdReplaySend; self.signal = signal; self.clock = clock
    }
    var isReceiveOutstanding: Bool { lock.withLock { pendingReceive != nil } }
    var isSendHeld: Bool { lock.withLock { heldSend != nil } }

    /// Drains the wire while a receive is outstanding: pongs are consumed inline, the first data frame is returned.
    /// Caller holds the lock. Returns handlers to fire and the frame, if any.
    private func drainLocked() -> ([@Sendable (Error?) -> Void], Data?) {
        var fire: [@Sendable (Error?) -> Void] = []
        while let item = wire.first {
            wire.removeFirst()
            switch item {
            case .pong:
                pongsOnWireUnread -= 1
                if !pongHandlers.isEmpty { fire.append(pongHandlers.removeFirst()) }
                pongObservedAfterMs.append(Self.ms(ContinuousClock.now - lastEnqueue))
            case .frame(let data): return (fire, data)
            }
        }
        return (fire, nil)
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let (fire, frame, isClosed): ([@Sendable (Error?) -> Void], Data?, Bool) = lock.withLock {
                receiveCalls += 1
                if closed { return ([], nil, true) }
                let (fire, frame) = drainLocked()
                if frame == nil { pendingReceive = c }
                return (fire, frame, false)
            }
            fire.forEach { $0(nil) }
            if isClosed { c.resume(throwing: AnnexTransportError.disconnected) } else if let frame { c.resume(returning: frame) }
            signal.fire()
        }
    }
    /// Puts items on the wire. They're read only if (or once) a receive is outstanding.
    func enqueue(_ items: [WireItem]) {
        let (fire, frame, waiting): ([@Sendable (Error?) -> Void], Data?, CheckedContinuation<Data, Error>?) = lock.withLock {
            lastEnqueue = ContinuousClock.now
            pongsOnWireUnread += items.filter { if case .pong = $0 { true } else { false } }.count
            wire.append(contentsOf: items)
            guard let waiting = pendingReceive else { return ([], nil, nil) }
            let (fire, frame) = drainLocked()
            if frame != nil { pendingReceive = nil; return (fire, frame, waiting) }
            return (fire, nil, nil)
        }
        fire.forEach { $0(nil) }
        if let frame, let waiting { waiting.resume(returning: frame) }
        signal.fire()
    }
    func send(_ data: Data) async throws {
        let type = (try? JSONDecoder().decode(AnnexJSON.self, from: data))?["type"]?.string ?? "?"
        lock.withLock { sentTypes.append(type) }
        signal.fire()
        lock.withLock { if heldSend != nil { overlappingSends += 1 } }
        guard holdReplaySend, type.hasSuffix("replay") else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let isClosed = lock.withLock { if closed || !holdingSends { return true }; heldSend = c; return false }
            if isClosed { lock.withLock { closed } ? c.resume(throwing: AnnexTransportError.disconnected) : c.resume() }
            signal.fire()
        }
    }
    private var holdingSends = true
    /// Lets the held send (and any later one) complete.
    func releaseSends() {
        let held = lock.withLock { holdingSends = false; defer { heldSend = nil }; return heldSend }
        held?.resume()
        signal.fire()
    }
    /// Same structure as URLSessionAnnexWebSocket.ping (AnnexIO.swift:255-280).
    func ping() async throws {
        do { try await productionShapedPing(); record(.answered) }
        catch let error as URLError where error.code == .timedOut { record(.timedOut); throw error }
        catch { record(.failed); throw error }
    }
    /// Same structure as URLSessionAnnexWebSocket.ping (AnnexIO.swift:255-280); the outcome is recorded after its defer.
    private func productionShapedPing() async throws {
        let completion = AnnexPingCompletion()
        let deadline = Task { [clock] in
            do {
                try await clock.sleep(.seconds(10))
                completion.resolve(.failure(URLError(.timedOut)))
                close()
            } catch { }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation)
                // sendPing: the handler runs when the pong is READ, i.e. only under an outstanding receive.
                lock.withLock { pingsSent += 1; pongHandlers.append { error in completion.resolve(error.map { .failure($0) } ?? .success(())) } }
                signal.fire()
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
            close()
        }
    }
    private func record(_ outcome: PingOutcome) { lock.withLock { outcomes.append(outcome) }; signal.fire() }
    func close() {
        let (receive, send) = lock.withLock {
            closed = true
            defer { pendingReceive = nil; heldSend = nil }
            return (pendingReceive, heldSend)
        }
        receive?.resume(throwing: AnnexTransportError.disconnected)
        send?.resume(throwing: AnnexTransportError.disconnected)
        signal.fire()
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
}

private final class WeakSocket: @unchecked Sendable { weak var socket: PongGatedSocket?; init(_ s: PongGatedSocket) { socket = s } }

private actor PongSessionIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    nonisolated let signal = Signal()
    let clock: AnnexClock
    let holdReplaySend: Bool
    var epoch = "epoch1"
    /// Weak, so a test can prove the transport's tasks released every socket.
    private var opened: [WeakSocket] = []
    var sockets: [PongGatedSocket] { opened.compactMap(\.socket) }
    var openCount: Int { opened.count }
    init(clock: AnnexClock, holdReplaySend: Bool) { self.clock = clock; self.holdReplaySend = holdReplaySend }
    func setEpoch(_ value: String) { epoch = value }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        if request.url?.path.hasSuffix("/identity") == true {
            let body: AnnexJSON = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
            return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
        }
        return AnnexHTTPResponse(status: 200, data: Data(pongCapabilities.replacingOccurrences(of: "EPOCH", with: epoch).utf8))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        let socket = PongGatedSocket(initial: [#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#],
                                     holdReplaySend: holdReplaySend && opened.isEmpty, signal: signal, clock: clock)
        opened.append(WeakSocket(socket))
        signal.fire()
        return socket
    }
}

private struct Harness {
    let clock: AnnexManualClock
    let io: PongSessionIO
    let transport: AnnexTransport
    let socket: PongGatedSocket
    var signal: Signal { io.signal }
}

/// Connects the production transport; returns once the first socket has delivered its snapshot and the
/// ping loop's 20 s sleeper is registered. With `holdReplaySend`, the loop is then parked in :739.
private func connectedHarness(holdReplaySend: Bool) async throws -> Harness {
    let clock = AnnexManualClock()
    let io = PongSessionIO(clock: clock.clock, holdReplaySend: holdReplaySend)
    let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: hostID,
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: hostID)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io,
                                   backoff: AnnexBackoff(initialSeconds: 3600, maximumSeconds: 3600), telemetry: AnnexTelemetry(), clock: clock.clock)
    try await transport.connect()
    await settle(io.signal) { await !io.sockets.isEmpty }
    let socket = try #require(await io.sockets.first)
    await settle(io.signal) { socket.sentTypes.contains { $0.hasSuffix("replay") } && (holdReplaySend ? socket.isSendHeld : socket.isReceiveOutstanding) }
    await clock.waitForSleepers(1) // the ping loop's 20 s interval (AnnexTransport.swift:595)
    return Harness(clock: clock, io: io, transport: transport, socket: socket)
}

/// Advances to the 20 s ping and returns once the fake has sent it and its 10 s deadline is waiting.
private func firePing(_ h: Harness) async {
    await h.clock.waitForSleepers(1)
    let sent = h.socket.pingsSent
    h.clock.advance(by: .seconds(20))
    await settle(h.signal) { h.socket.pingsSent == sent + 1 }
    await h.clock.waitForSleepers(1)
}

private func bigSnapshot(bytes: Int) -> String {
    // A same-sequence snapshot (lastSeq 0) is delivered, not resynced (AnnexReplay.swift:38-44).
    let filler = String(repeating: "x", count: 200)
    var projects: [String] = []
    var size = 0
    var i = 0
    while size < bytes { let p = #"{"id":"p\#(i)","name":"\#(filler)"}"#; projects.append(p); size += p.utf8.count + 1; i += 1 }
    return #"{"type":"snapshot","payload":{"lastSeq":0,"projects":[\#(projects.joined(separator: ","))],"agents":{}}}"#
}

// MARK: Control

@Test(.timeLimit(.minutes(1))) func recvAuditIdleLoopObservesAPongThatArrivesBeforeTheDeadline() async throws {
    let h = try await connectedHarness(holdReplaySend: false)
    await firePing(h)
    h.socket.enqueue([.pong])
    await settle(h.signal) { !h.socket.outcomes.isEmpty }
    #expect(h.socket.outcomes == [.answered])
    h.clock.advance(by: .seconds(10))
    #expect(h.socket.closed == false)
    print("RECVAUDIT control: outcome=\(h.socket.outcomes) closed=\(h.socket.closed)")
    await h.transport.disconnect()
}

// MARK: Candidate 1 - consumer back-pressure (events never drained)

@Test(.timeLimit(.minutes(1))) func recvAuditANonDrainingConsumerCannotDelayThePong() async throws {
    let h = try await connectedHarness(holdReplaySend: false)
    // A subscriber that never reads: emit() yields into .bufferingOldest(256) and never suspends (AnnexTransport.swift:48-74).
    let stalled = await h.transport.events()
    let draining = await h.transport.events()
    await firePing(h)
    let frames = (0..<400).map { WireItem.frame(Data(#"{"type":"agent:status","payload":{"i":\#($0)}}"#.utf8)) }
    h.socket.enqueue(frames + [.pong, .frame(Data(#"{"type":"marker","payload":{}}"#.utf8))])
    await settle(h.signal) { !h.socket.outcomes.isEmpty }
    #expect(h.socket.outcomes == [.answered])
    // Wait until all 400 frames were processed (a draining subscriber saw the marker after them).
    for try await event in draining { if case .message(let envelope) = event, envelope.type == "marker" { break } }
    var it = stalled.makeAsyncIterator()
    var delivered = 0
    var overflowed = false
    do { while try await it.next() != nil { delivered += 1 } } catch { overflowed = (error as? AnnexTransportError) == .queueOverflow }
    #expect(overflowed, "the stalled subscriber is finished with queueOverflow rather than back-pressuring the loop")
    print("RECVAUDIT nondraining: outcome=\(h.socket.outcomes) subscriberDelivered=\(delivered) overflow=\(overflowed) pongObservedAfterMs=\(h.socket.pongObservedAfterMs)")
    await h.transport.disconnect()
}

// MARK: Candidate 2 - large frame decode on the actor (wall time, not virtual)

@Test(.timeLimit(.minutes(1))) func recvAuditLargeSnapshotsAheadOfThePongDelayItOnlyByTheirProcessingTime() async throws {
    let h = try await connectedHarness(holdReplaySend: false)
    let stream = await h.transport.events()
    let reader = Task { var n = 0; do { for try await _ in stream { n += 1 } } catch {}; return n }
    await firePing(h)
    let one = Data(bigSnapshot(bytes: 684 * 1024).utf8)
    let started = ContinuousClock.now
    h.socket.enqueue([.frame(one), .pong])
    await settle(h.signal) { !h.socket.outcomes.isEmpty }
    let single = PongGatedSocket.ms(ContinuousClock.now - started)
    #expect(h.socket.outcomes == [.answered])
    // Ten in a row ahead of the next pong (head-of-line in the client's own consumption).
    await firePing(h)
    let started10 = ContinuousClock.now
    h.socket.enqueue(Array(repeating: WireItem.frame(one), count: 10) + [.pong])
    await settle(h.signal) { h.socket.outcomes.count == 2 }
    let ten = PongGatedSocket.ms(ContinuousClock.now - started10)
    #expect(h.socket.outcomes == [.answered, .answered])
    // The same decode the actor runs synchronously (AnnexTransport.swift:654), measured alone.
    let decodeStart = ContinuousClock.now
    _ = try JSONDecoder().decode(AnnexEnvelope.self, from: one)
    let decode = PongGatedSocket.ms(ContinuousClock.now - decodeStart)
    print(String(format: "RECVAUDIT largeframe: frameBytes=%d one=%.1fms ten=%.1fms envelopeDecodeAlone=%.1fms virtualSecondsElapsedDuringProcessing=0 outcomes=%@",
                 one.count, single, ten, decode, "\(h.socket.outcomes)"))
    await h.transport.disconnect()
    reader.cancel()
}

// MARK: Candidate 3 - a held await inside frame processing (the only one: send(replay) at :739)

/// Fails on 55c6fad7 (the ping timed out with the pong unread); passes once the reader re-arms independently.
@Test(.timeLimit(.minutes(1))) func recvAuditAHeldReplaySendNoLongerHidesAnArrivedPong() async throws {
    let h = try await connectedHarness(holdReplaySend: true)
    // The processor is parked in the replay send; the reader still has a receive() outstanding.
    #expect(h.socket.isSendHeld)
    let socket = h.socket
    #expect(await settle(h.signal, within: 2) { socket.isReceiveOutstanding }, "receive() re-armed while the send is held")
    await firePing(h)
    h.socket.enqueue([.pong]) // the pong is on the wire, well inside the deadline
    await settle(h.signal) { !h.socket.outcomes.isEmpty }
    #expect(h.socket.outcomes == [.answered])
    #expect(h.socket.pongsOnWireUnread == 0)
    h.clock.advance(by: .seconds(10))
    #expect(h.socket.closed == false)
    print("RECVAUDIT heldsend: outcome=\(h.socket.outcomes) pongUnread=\(h.socket.pongsOnWireUnread) receiveCalls=\(h.socket.receiveCalls) closed=\(h.socket.closed)")
    await h.transport.disconnect()
}

// MARK: Candidate 4 - actor occupied by a synchronous REST decode (the receive child's hop at :603)

@Test(.timeLimit(.minutes(1))) func recvAuditRestDecodeOnTheActorDelaysTheHopOnlyByItsCPUTime() async throws {
    // read(_:) decodes REST bodies synchronously on the actor (AnnexTransport.swift:290). Measure that decode alone at
    // the 16 MiB response cap (AnnexIO.swift:122) and a 684 KB body: the receive child's hop can wait at most this long.
    for bytes in [684 * 1024, 16 * 1024 * 1024 - 1024] {
        let body = Data(bigSnapshot(bytes: bytes).utf8)
        let start = ContinuousClock.now
        _ = try JSONDecoder().decode(AnnexJSON.self, from: body)
        print(String(format: "RECVAUDIT restdecode: bytes=%d decode=%.1fms", body.count, PongGatedSocket.ms(ContinuousClock.now - start)))
    }
}

// MARK: Ordering, lifecycle and overflow (mini-go/recvloop-rearm)
//
// Contract: frames are processed one at a time in receive order. A frame's processing, including the replay
// request a snapshot sends (AnnexTransport.swift receive(_:)), completes before the next frame is taken, so the
// snapshot, cursor and replay are established before any later frame. Only reading runs ahead, into a bounded buffer.

private func event(_ type: String, seq: Int) -> WireItem { .frame(Data(#"{"type":"\#(type)","seq":\#(seq),"payload":{}}"#.utf8)) }
private func snapshot(_ lastSeq: Int) -> WireItem { .frame(Data(#"{"type":"snapshot","payload":{"lastSeq":\#(lastSeq),"projects":[],"agents":{}}}"#.utf8)) }
private func label(_ envelope: AnnexEnvelope) -> String {
    envelope.type == "snapshot" ? "snapshot:\(envelope.snapshotSequence ?? -1)" : "\(envelope.type):\(envelope.seq ?? -1)"
}

@Test(.timeLimit(.minutes(1))) func recvAuditFramesBufferedBehindAHeldReplayAreProcessedStrictlyInOrderAfterIt() async throws {
    let h = try await connectedHarness(holdReplaySend: true)
    let stream = await h.transport.events()
    // Several snapshots with interleaved events. snapshot:2 and snapshot:4 match the cursor and are delivered;
    // snapshot:9 is a gap, so it resyncs and sends a second replay request.
    let wire = [event("agent:status", seq: 1), event("agent:status", seq: 2), snapshot(2), event("agent:status", seq: 3),
                event("agent:status", seq: 4), snapshot(4), event("agent:status", seq: 5), snapshot(9)]
    let before = h.socket.receiveCalls
    h.socket.enqueue(wire)
    let socket = h.socket
    // The reader buffers all eight and re-arms; the processor is still parked in the first replay send.
    #expect(await settle(h.signal, within: 2) { socket.receiveCalls == before + wire.count && socket.isReceiveOutstanding })
    #expect(h.socket.sentTypes.filter { $0.hasSuffix("replay") }.count == 1)
    h.socket.releaseSends()
    var seen: [String] = []
    var it = stream.makeAsyncIterator()
    while let next = try await it.next() {
        if case .message(let envelope) = next { seen.append(label(envelope)) }
        if seen.last == "snapshot:9" { break }
    }
    #expect(seen == ["agent:status:1", "agent:status:2", "snapshot:2", "agent:status:3", "agent:status:4", "snapshot:4", "agent:status:5", "snapshot:9"])
    await settle(h.signal) { socket.sentTypes.filter { $0.hasSuffix("replay") }.count == 2 }
    #expect(h.socket.overlappingSends == 0, "no later frame was processed (and sent) while the first replay was held")
    print("RECVAUDIT order: seen=\(seen) replays=\(h.socket.sentTypes) overlapping=\(h.socket.overlappingSends)")
    await h.transport.disconnect()
}

/// Opens one connection whose first replay send is held, buffers `frames` behind it, and returns weak handles.
private func stalledConnection(_ frames: [WireItem]) async throws -> (Harness, WeakSocket) {
    let h = try await connectedHarness(holdReplaySend: true)
    let socket = h.socket
    let before = socket.receiveCalls
    socket.enqueue(frames)
    #expect(await settle(h.signal, within: 2) { socket.receiveCalls == before + frames.count && socket.isReceiveOutstanding })
    return (h, WeakSocket(socket))
}

@Test(.timeLimit(.minutes(1))) func recvAuditCloseDuringAHeldReplayDropsTheBufferedFramesAndReleasesEveryTask() async throws {
    var weak: WeakSocket?
    var stream: AsyncThrowingStream<AnnexTransportEvent, Error>?
    var transport: AnnexTransport?
    var signal: Signal?
    do {
        let (h, w) = try await stalledConnection([event("agent:status", seq: 1), event("agent:status", seq: 2)])
        weak = w; transport = h.transport; signal = h.signal
        stream = await h.transport.events()
        await h.transport.disconnect()
    }
    var seen: [String] = []
    var it = stream!.makeAsyncIterator()
    while let next = try await it.next() {
        if case .message(let envelope) = next { seen.append(label(envelope)) }
        if next == .connection(.disconnected) { break }
    }
    #expect(seen.isEmpty, "frames buffered for the closed connection are never processed")
    // Every task that captured the socket (reader, processor, ping, fake deadline) has ended.
    let released = weak!
    #expect(await settle(signal!, within: 5) { released.socket == nil })
    #expect(await transport!.supportsShellReattach() == nil)
}

@Test(.timeLimit(.minutes(1))) func recvAuditResyncDuringAHeldReplayNeverProcessesTheOldGeneration() async throws {
    var weak: WeakSocket?
    let io: PongSessionIO
    let transport: AnnexTransport
    let stream: AsyncThrowingStream<AnnexTransportEvent, Error>
    do {
        let (h, w) = try await stalledConnection([event("agent:status", seq: 1), event("agent:status", seq: 2)])
        weak = w; io = h.io; transport = h.transport
        stream = await h.transport.events()
        // A capabilities refresh with a new epoch stops this connection and starts the next (AnnexTransport.swift:278-285).
        await io.setEpoch("epoch2")
        _ = try await transport.read(.capabilities)
    }
    var seen: [String] = []
    var it = stream.makeAsyncIterator()
    while let next = try await it.next() {
        if case .message(let envelope) = next { seen.append(label(envelope)) }
        if seen.last == "snapshot:0" { break }
    }
    // Only the new connection's snapshot: the old generation's buffered frames were dropped, not processed.
    #expect(seen == ["snapshot:0"])
    #expect(await io.openCount == 2)
    let released = weak!
    #expect(await settle(io.signal, within: 5) { released.socket == nil }, "the old connection's tasks all ended")
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1)), arguments: ["frames", "bytes"])
func recvAuditBufferOverflowFailsClosedAndTakesTheReconnectPath(limit: String) async throws {
    let h = try await connectedHarness(holdReplaySend: true)
    let stream = await h.transport.events()
    let big = Data(#"{"type":"agent:status","payload":{"pad":"\#(String(repeating: "x", count: 1024 * 1024))"}}"#.utf8)
    let frames: [WireItem] = limit == "frames"
        ? (0..<(AnnexReceivePipe.frameCapacity + 1)).map { event("agent:status", seq: $0 + 1) }
        : Array(repeating: .frame(big), count: AnnexReceivePipe.byteCapacity / big.count + 1)
    h.socket.enqueue(frames)
    var seen: [String] = []
    var it = stream.makeAsyncIterator()
    while let next = try await it.next() {
        if case .message(let envelope) = next { seen.append(label(envelope)) }
        if case .connection(.reconnecting) = next { break }
    }
    #expect(seen.isEmpty, "an overflowing buffer is dropped, never partially delivered")
    #expect(h.socket.closed)
    print("RECVAUDIT overflow(\(limit)): frames=\(frames.count) closed=\(h.socket.closed)")
    await h.transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func recvAuditRepeatedConnectCloseCyclesReleaseEverySocketAndTask() async throws {
    var weak: [WeakSocket] = []
    var signals: [Signal] = []
    for cycle in 0..<20 {
        let h = try await connectedHarness(holdReplaySend: cycle % 2 == 1)
        if cycle % 2 == 1 { h.socket.enqueue([event("agent:status", seq: 1)]) }
        weak.append(WeakSocket(h.socket)); signals.append(h.signal)
        await h.transport.disconnect()
    }
    for (w, signal) in zip(weak, signals) {
        #expect(await settle(signal, within: 5) { w.socket == nil })
    }
    print("RECVAUDIT cycles: live=\(weak.filter { $0.socket != nil }.count)/\(weak.count)")
}
