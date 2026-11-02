import Foundation
import Testing
@testable import ClubhouseTransport

// Regression tests for the independently reproduced first-snapshot sequencing races.
// No real desktop, phone, simulator or native UI is involved.
private struct SnapshotRaceSession: Sendable {
    var initial: [AnnexEnvelope]
    var replay: [AnnexEnvelope] = []
    var afterReplay: [AnnexEnvelope] = []
    var replayGap = false
    var receiveFailure: NSError?
    var omitReplayStart = false
    var omitReplayEnd = false
    var epoch = "race"
    var capabilitiesMissing = false
}

private actor SnapshotRaceSocket: AnnexWebSocket {
    private var queue: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private let session: SnapshotRaceSession
    private(set) var replaySince: [Int64] = []
    private(set) var replayRequests: [AnnexJSON] = []
    init(_ session: SnapshotRaceSession) throws {
        self.session = session
        queue = try session.initial.map { try JSONEncoder().encode($0) }
    }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !queue.isEmpty { return queue.removeFirst() }
        if let failure = session.receiveFailure { throw failure }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) throws {
        let request = try JSONDecoder().decode(AnnexJSON.self, from: data)
        guard ["mobile:replay", "replay"].contains(request["type"]?.string ?? "") else { return }
        replayRequests.append(request)
        replaySince.append(request["since"]?.integer ?? -1)
        let frames: [AnnexEnvelope]
        if session.replayGap { frames = [AnnexEnvelope(type: "replay:gap", epoch: session.epoch)] }
        else {
            let since = request["since"]?.integer ?? 0
            var response = session.omitReplayStart ? [] : [AnnexEnvelope(type: "replay:start", epoch: session.epoch)]
            response.append(contentsOf: session.replay.filter { ($0.seq ?? 0) > since })
            if !session.omitReplayEnd { response.append(AnnexEnvelope(type: "replay:end", epoch: session.epoch)) }
            response.append(contentsOf: session.afterReplay)
            response.append(AnnexEnvelope(type: "fixture:end"))
            frames = response
        }
        for frame in frames {
            let bytes = try JSONEncoder().encode(frame)
            if let pending { self.pending = nil; pending.resume(returning: bytes) }
            else { queue.append(bytes) }
        }
    }
    func push(_ frames: [AnnexEnvelope]) throws {
        guard !closed else { throw AnnexTransportError.disconnected }
        for frame in frames {
            let bytes = try JSONEncoder().encode(frame)
            if let pending { self.pending = nil; pending.resume(returning: bytes) }
            else { queue.append(bytes) }
        }
    }
    func ping() throws { if closed { throw AnnexTransportError.disconnected } }
    func close() {
        closed = true
        pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil
    }
}

private actor SnapshotRaceIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let clock: AnnexManualClock
    let sessions: [SnapshotRaceSession]
    private(set) var sockets: [SnapshotRaceSocket] = []
    private(set) var accepts: [Date] = []
    init(_ sessions: [SnapshotRaceSession], clock: AnnexManualClock) { self.sessions = sessions; self.clock = clock }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let body: AnnexJSON
        if request.url?.path.hasSuffix("identity") == true {
            body = try .object(["publicKey": .string(identity.publicKeyBase64),
                                "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else {
            let session = sessions[min(sockets.count, sessions.count - 1)]
            if session.capabilitiesMissing { return AnnexHTTPResponse(status: 404, data: Data()) }
            body = .object(["version": .integer(1), "epoch": .string(session.epoch), "controlAuth": .string("mtls-pinned-client"),
                "controlAvailable": .bool(true), "commands": .array([]),
                "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])])
        }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        let socket = try SnapshotRaceSocket(sessions[min(sockets.count, sessions.count - 1)])
        sockets.append(socket); accepts.append(clock.now)
        clock.advance(by: .milliseconds(170)) // modeled busy socket lifetime, no wall-clock wait
        return socket
    }
}

private struct SnapshotRaceObservation {
    var attempts: [Int] = []
    var delays: [Double] = []
    var messages: [AnnexEnvelope] = []
    var resyncs: [AnnexResyncReason] = []
}
private func snapshot(_ sequence: Int64) -> AnnexEnvelope { AnnexEnvelope(type: "snapshot", lastSeq: sequence, epoch: "race") }
private func event(_ sequence: Int64, replayed: Bool = false) -> AnnexEnvelope {
    AnnexEnvelope(type: "chat:event", payload: .object(["agentId": .string("busy")]), seq: sequence, replayed: replayed, epoch: "race")
}
private func raceTransport(_ io: SnapshotRaceIO) async throws -> AnnexTransport {
    let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id,
                                  verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: id)
    return AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry(), clock: io.clock.clock)
}
private func observe(_ io: SnapshotRaceIO, intentionallyCloseFirst: Bool = false) async throws -> SnapshotRaceObservation {
    let transport = try await raceTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    var result = SnapshotRaceObservation()
    for try await frame in stream {
        switch frame {
        case .message(let envelope):
            result.messages.append(envelope)
            if envelope.type == "fixture:end" {
                if intentionallyCloseFirst, await io.sockets.count == 1 { await io.sockets.first?.close() }
                else { await transport.disconnect(); return result }
            }
        case .resyncRequired(let reason): result.resyncs.append(reason)
        case .connection(.reconnecting(let attempt, let delay)):
            result.attempts.append(attempt); result.delays.append(delay)
            if result.attempts.count == 4 { await transport.disconnect(); return result }
            await io.clock.waitForSleepers(1)
            io.clock.advance(by: .seconds(delay))
        default: break
        }
    }
    await transport.disconnect()
    return result
}
private func report(_ label: String, _ result: SnapshotRaceObservation, io: SnapshotRaceIO) async {
    let accepts = await io.accepts
    let cadence: [Double] = zip(accepts, accepts.dropFirst()).map { pair in pair.1.timeIntervalSince(pair.0) }
    let delivered = result.messages.compactMap(\.seq)
    print("\(label): accepts=\(accepts.count), attempts=\(result.attempts), delays=\(result.delays)")
    print("accept intervals=\(cadence), delivered seq=\(delivered), resyncs=\(result.resyncs)")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func reconnectBusyFramesBeforeTheFirstSnapshotMustNotCauseRepeatedGaps(snapshotFailedFirst: Bool) async throws {
    let busy = (105...108).map { event(Int64($0)) }
    let replay = (105...108).map { event(Int64($0), replayed: true) }
    let failure = AnnexEnvelope(type: "error", payload: .object(["message": .string("snapshot_failed")]))
    let prefix = snapshotFailedFirst ? [failure] : []
    let io = SnapshotRaceIO([.init(initial: [snapshot(100)]), .init(initial: prefix + busy + [snapshot(104)], replay: replay)], clock: AnnexManualClock())
    let result = try await observe(io, intentionallyCloseFirst: true)
    await report("A reconnect snapshot_failed first=\(snapshotFailedFirst)", result, io: io)
    #expect(result.attempts == [1], "Only the intentional first disconnect should reconnect")
    #expect(result.messages.filter { $0.type == "snapshot" }.compactMap(\.snapshotSequence) == [100, 104])
    #expect(result.messages.compactMap(\.seq) == [105, 106, 107, 108])
    #expect(!result.resyncs.contains(.sequenceGap))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func firstSnapshotMustNotRewindAndRedeliverBusyFrames(replayBeforeNextLive: Bool) async throws {
    let before = [event(101), event(102), snapshot(100)]
    let session = SnapshotRaceSession(initial: before + (replayBeforeNextLive ? [] : [event(103)]),
        replay: (101...(replayBeforeNextLive ? 102 : 103)).map { event(Int64($0), replayed: true) },
        afterReplay: replayBeforeNextLive ? [event(103)] : [])
    let io = SnapshotRaceIO([session], clock: AnnexManualClock())
    let result = try await observe(io)
    await report("B rewind replayFirst=\(replayBeforeNextLive)", result, io: io)
    #expect(result.attempts.isEmpty)
    #expect(result.messages.compactMap(\.seq) == [101, 102, 103], "Replay order must not lose or deliver an event twice")
    #expect(result.messages.first?.type == "snapshot", "The first snapshot is authoritative")
    #expect(!result.resyncs.contains(.serverRestart))
}

@Test(.timeLimit(.minutes(1))) func anInteriorReplayHoleIsRecoveredByAFreshSnapshotUnlessCleanupKeepsRacing() async throws {
    let clock = AnnexManualClock()
    let io = SnapshotRaceIO([.init(initial: [snapshot(100)], replayGap: true), .init(initial: [snapshot(103)])], clock: clock)
    let once = try await observe(io)
    await report("Interior hole once", once, io: io)
    #expect(once.attempts == [1])
    #expect(once.resyncs.filter { $0 == .replayGap }.count == 1)
    let racingSessions: [SnapshotRaceSession] = (0..<4).map { index in
        SnapshotRaceSession(initial: [snapshot(100 + Int64(index) * 3)], replayGap: true)
    }
    let racing = SnapshotRaceIO(racingSessions, clock: AnnexManualClock())
    let repeated = try await observe(racing)
    await report("Interior hole repeated in each new snapshot/replay window", repeated, io: racing)
    #expect(repeated.attempts == [1, 2, 3, 4])
}

// Desktop #2665: initial checkpoint at connect, then held live frames before replay replies.
@Test(.timeLimit(.minutes(1))) func snapshotFirstServerDeduplicatesHeldLiveAndReplayFrames() async throws {
    let held = [event(101), event(102)]
    let replay = [event(101, replayed: true), event(102, replayed: true)]
    let io = SnapshotRaceIO([.init(initial: [snapshot(100)] + held, replay: replay, afterReplay: [event(103)])], clock: AnnexManualClock())
    let result = try await observe(io)
    await report("Desktop2665 snapshot-first held/replay duplicate", result, io: io)
    #expect(result.attempts.isEmpty)
    #expect(result.resyncs.isEmpty)
    #expect(result.messages.compactMap(\.seq) == [101, 102, 103])
}

@Test(.timeLimit(.minutes(1))) func anAheadRefreshRetainsTheAppliedCursorAndReplaysMissingEvents() async throws {
    // The refresh advertises 103 while only 101 was applied. Its catalog cannot stand in for deltas 102/103.
    let io = SnapshotRaceIO([.init(initial: [snapshot(100), event(101), snapshot(103)],
        replay: [event(101, replayed: true), event(102, replayed: true), event(103, replayed: true)],
        afterReplay: [event(104)])], clock: AnnexManualClock())
    let result = try await observe(io)
    await report("Desktop2665 ahead refresh", result, io: io)
    #expect(result.attempts.isEmpty, "An ahead snapshot itself does not close the socket")
    #expect(result.resyncs == [.sequenceGap])
    #expect(result.messages.compactMap(\.seq) == [101, 102, 103, 104])
    let socket = try #require(await io.sockets.first)
    #expect(await socket.replaySince == [100, 101], "Refresh replay uses the applied cursor, not snapshot.lastSeq")
}

@Test(.timeLimit(.minutes(1))) func aRefreshMatchingHeldEventsDoesNotRewindOrDoubleApplyReplay() async throws {
    let io = SnapshotRaceIO([.init(initial: [snapshot(100), event(101), event(102), snapshot(102), event(103)],
        replay: [event(101, replayed: true), event(102, replayed: true), event(103, replayed: true)], afterReplay: [event(104)])], clock: AnnexManualClock())
    let result = try await observe(io)
    await report("Desktop2665 caught-up refresh", result, io: io)
    #expect(result.attempts.isEmpty)
    #expect(result.resyncs.isEmpty)
    #expect(result.messages.compactMap(\.seq) == [101, 102, 103, 104])
}

@Test(.timeLimit(.minutes(1))) func serverOverrun1013ErrorBacksOffNormallyAndRecovers() async throws {
    let overrun = SnapshotRaceSession(initial: [], receiveFailure: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN)))
    let io = SnapshotRaceIO([overrun, overrun, overrun, .init(initial: [snapshot(100)])], clock: AnnexManualClock())
    let result = try await observe(io)
    await report("Desktop2665 close1013/ENOTCONN", result, io: io)
    #expect(result.attempts == [1, 2, 3])
    #expect((0.25...0.5).contains(result.delays[0]))
    #expect((0.5...1).contains(result.delays[1]))
    #expect((1...2).contains(result.delays[2]))
    #expect(await io.sockets.count == 4)
}

private func raceCollect(_ stream: AsyncThrowingStream<AnnexTransportEvent, Error>, until stop: (AnnexTransportEvent) -> Bool) async throws -> [AnnexTransportEvent] {
    var frames: [AnnexTransportEvent] = []
    for try await frame in stream { frames.append(frame); if stop(frame) { break } }
    return frames
}
private func isRaceMessage(_ frame: AnnexTransportEvent, _ type: String) -> Bool {
    if case .message(let envelope) = frame { envelope.type == type } else { false }
}

@Test(.timeLimit(.minutes(1)), arguments: [2, 8])
func heldEventsAfterSnapshotFailureRecoverOnTheProposedRetrySchedule(recoveredAt: Int) async throws {
    let failure = AnnexEnvelope(type: "error", payload: .object(["message": .string("snapshot_failed")]))
    let clock = AnnexManualClock()
    let io = SnapshotRaceIO([.init(initial: [failure], replay: [event(101, replayed: true)])], clock: clock)
    let transport = try await raceTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    _ = try await raceCollect(stream) { isRaceMessage($0, "error") }
    let socket = try #require(await io.sockets.first)
    await clock.waitForSleepers(2) // existing ping + #207's 30-second explicit-failure grace
    clock.advance(by: .seconds(2))
    #expect(await socket.closed == false)
    try await socket.push([AnnexEnvelope(type: "fixture:command-reply")])
    _ = try await raceCollect(stream) { isRaceMessage($0, "fixture:command-reply") }
    if recoveredAt == 8 { clock.advance(by: .seconds(6)) }
    // The server holds every sequenced event until a successful snapshot, then releases them in order.
    try await socket.push([snapshot(100), event(101)])
    let frames = try await raceCollect(stream) { isRaceMessage($0, "fixture:end") }
    #expect(frames.contains(.connection(.connected)))
    let delivered: [Int64] = frames.compactMap { frame -> Int64? in if case .message(let e) = frame { e.seq } else { nil } }
    #expect(delivered == [101])
    #expect(!frames.contains { if case .connection(.reconnecting) = $0 { true } else { false } })
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(31))
    try await socket.push([AnnexEnvelope(type: "fixture:after-grace")])
    _ = try await raceCollect(stream) { isRaceMessage($0, "fixture:after-grace") }
    #expect(await io.sockets.count == 1)
    #expect(await socket.closed == false)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func failedRetriesAtTwoAndEightSecondsThen1013RecoverThroughNormalBackoff() async throws {
    let failure = AnnexEnvelope(type: "error", payload: .object(["message": .string("snapshot_failed")]))
    let clock = AnnexManualClock()
    let io = SnapshotRaceIO([.init(initial: [failure]), .init(initial: [snapshot(102)])], clock: clock)
    let transport = try await raceTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    let first = try await raceCollect(stream) { isRaceMessage($0, "error") }
    #expect(first.filter { isRaceMessage($0, "error") }.count == 1)
    let socket = try #require(await io.sockets.first)
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(2))
    #expect(await socket.closed == false, "A failed server retry sends no second error and keeps holding events")
    clock.advance(by: .seconds(6))
    await socket.close() // The separately measured real 1013 is ENOTCONN; both use the normal retry path.
    let waiting = try await raceCollect(stream) { if case .connection(.reconnecting) = $0 { true } else { false } }
    guard case .connection(.reconnecting(let attempt, let delay)) = waiting.last else { Issue.record("Missing backoff"); return }
    #expect(attempt == 1)
    #expect((0.25...0.5).contains(delay))
    #expect(await io.sockets.count == 1)
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(delay))
    let recovered = try await raceCollect(stream) { isRaceMessage($0, "fixture:end") }
    #expect(recovered.contains(.resyncRequired(.reconnected)))
    #expect(await io.sockets.count == 2)
    let current = try #require(await io.sockets.last)
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(31))
    try await current.push([AnnexEnvelope(type: "fixture:after-grace")])
    _ = try await raceCollect(stream) { isRaceMessage($0, "fixture:after-grace") }
    #expect(await current.closed == false, "The old grace timer cannot close the replacement connection")
    await transport.disconnect()
}

@Test func sequencedFramesCannotChangeTheCursorBeforeAnAuthoritativeSnapshot() {
    var cursor = AnnexReplayCursor()
    #expect(cursor.accept(event(999)) == .awaitSnapshot)
    #expect(cursor.lastSequence == nil)
    #expect(cursor.accept(snapshot(100)) == .deliver)
    cursor.beginConnection()
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: -1, epoch: "different")) == .awaitSnapshot)
    #expect(cursor.accept(event(105)) == .awaitSnapshot)
    #expect(cursor.lastSequence == 100)
    #expect(cursor.epoch == "race")
    #expect(cursor.accept(AnnexEnvelope(type: "pty:data")) == .deliver)
    #expect(cursor.accept(snapshot(104)) == .deliver)
    #expect(cursor.accept(event(105)) == .deliver)
    #expect(cursor.accept(event(107)) == .resync(.sequenceGap))
}

@Test(.timeLimit(.minutes(1))) func sequencedTerminalFramesReplayOnceAndUnsequencedRepliesStayImmediate() async throws {
    let terminal = ["pty:data", "pty:exit", "pty:spawned"].enumerated().map {
        AnnexEnvelope(type: $0.element, payload: .object(["data": .string("terminal")]), seq: 101 + Int64($0.offset), epoch: "race")
    }
    let unsequenced = AnnexEnvelope(type: "pty:data", payload: .object(["data": .string("immediate")]))
    let terminalError = AnnexEnvelope(type: "error", payload: .object(["op": .string("pty:spawn"), "message": .string("session_not_found")]))
    let initial = [unsequenced, terminalError] + terminal + [snapshot(100), event(104)]
    let io = SnapshotRaceIO([.init(initial: initial, replay: terminal + [event(104)])], clock: AnnexManualClock())
    let transport = try await raceTransport(io)
    let events = await transport.events(), terminals = await transport.terminalEvents()
    try await transport.connect()
    let frames = try await raceCollect(events) { isRaceMessage($0, "fixture:end") }
    #expect(frames.compactMap { frame -> Int64? in if case .message(let e) = frame { e.seq } else { nil } } == [104])
    #expect(!frames.contains { if case .resyncRequired = $0 { true } else { false } })
    await transport.disconnect()
    var received: [AnnexEnvelope] = []
    for await frame in terminals {
        if case .frame(let e) = frame { received.append(e) }
        if received.count == 5 { break }
    }
    #expect(received.map(\.type) == ["pty:data", "error", "pty:data", "pty:exit", "pty:spawned"])
    #expect(received.compactMap(\.seq) == [101, 102, 103])
}

@Test(.timeLimit(.minutes(1))) func missingReplayStartIsBoundedAfterTheFirstSnapshot() async throws {
    let clock = AnnexManualClock()
    let io = SnapshotRaceIO([.init(initial: [event(105), snapshot(100)], omitReplayStart: true)], clock: clock)
    let transport = try await raceTransport(io), events = await transport.events()
    try await transport.connect()
    _ = try await raceCollect(events) { isRaceMessage($0, "fixture:end") }
    await clock.waitForSleepers(2) // ping and bounded replay-start wait
    clock.advance(by: .seconds(30))
    let frames = try await raceCollect(events) { if case .connection(.reconnecting) = $0 { true } else { false } }
    #expect(frames.contains { if case .connection(.reconnecting(let attempt, _)) = $0 { attempt == 1 } else { false } })
    #expect(await io.sockets.first?.closed == true)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func missingReplayEndNeverStallsLiveFramesOrLeavesADeadline() async throws {
    let clock = AnnexManualClock()
    let io = SnapshotRaceIO([.init(initial: [event(101), snapshot(100), event(103)], replay: [event(101), event(102)], afterReplay: [event(103)], omitReplayEnd: true)], clock: clock)
    let transport = try await raceTransport(io), events = await transport.events()
    try await transport.connect()
    let frames = try await raceCollect(events) { isRaceMessage($0, "fixture:end") }
    #expect(frames.compactMap { frame -> Int64? in if case .message(let e) = frame { e.seq } else { nil } } == [101, 102, 103])
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(31))
    try await io.sockets.first?.push([event(104), .init(type: "fixture:after-replay")])
    let live = try await raceCollect(events) { isRaceMessage($0, "fixture:after-replay") }
    #expect(!live.contains { if case .connection(.reconnecting) = $0 { true } else { false } })
    #expect(live.compactMap { frame -> Int64? in if case .message(let e) = frame { e.seq } else { nil } } == [104])
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func aNewEpochBeforeTheFirstSnapshotWaitsForTheSnapshotToDecideRestart() async throws {
    let busy = (1...2).map { AnnexEnvelope(type: "chat:event", seq: Int64($0), epoch: "restarted") }
    let replay = (1...2).map { AnnexEnvelope(type: "chat:event", seq: Int64($0), replayed: true, epoch: "restarted") }
    let io = SnapshotRaceIO([
        .init(initial: [snapshot(100)]),
        .init(initial: busy + [AnnexEnvelope(type: "snapshot", lastSeq: 0, epoch: "restarted")], replay: replay, epoch: "restarted")
    ], clock: AnnexManualClock())
    let result = try await observe(io, intentionallyCloseFirst: true)
    #expect(result.attempts == [1], "Only the deliberate first disconnect may reconnect")
    #expect(result.messages.filter { $0.type == "snapshot" }.compactMap(\.snapshotSequence) == [100, 0])
    #expect(result.messages.compactMap(\.seq) == [1, 2])
    #expect(result.resyncs.filter { $0 == .serverRestart }.count == 1, "The authoritative snapshot decides restart once")
    #expect(!result.resyncs.contains(.sequenceGap))
    #expect(await io.sockets.count == 2)
}

@Test(.timeLimit(.minutes(1))) func missingCapabilitiesRetainsLegacyReplayAndRecoversPreSnapshotFrames() async throws {
    let busy = (101...103).map { AnnexEnvelope(type: "chat:event", seq: Int64($0)) }
    let replay = (101...103).map { AnnexEnvelope(type: "chat:event", seq: Int64($0), replayed: true) }
    let io = SnapshotRaceIO([.init(initial: Array(busy.prefix(2)) + [AnnexEnvelope(type: "snapshot", lastSeq: 100), busy[2]], replay: replay, capabilitiesMissing: true)], clock: AnnexManualClock())
    let result = try await observe(io)
    #expect(result.attempts.isEmpty)
    #expect(result.messages.compactMap(\.seq) == [101, 102, 103])
    let socket = try #require(await io.sockets.first)
    #expect(await socket.replayRequests == [.object(["type": .string("replay"), "since": .integer(100)])])
}
