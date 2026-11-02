import Foundation
import Testing
@testable import ClubhouseTransport

// Reproduction-only regression tests for the secondary sequencing hypothesis.
// These intentionally fail on the current client and belong on their own branch.
// No real desktop, phone, simulator or native UI is involved.
private struct SnapshotRaceSession: Sendable {
    var initial: [AnnexEnvelope]
    var replay: [AnnexEnvelope] = []
    var afterReplay: [AnnexEnvelope] = []
    var replayGap = false
}

private actor SnapshotRaceSocket: AnnexWebSocket {
    private var queue: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private let session: SnapshotRaceSession
    init(_ session: SnapshotRaceSession) throws {
        self.session = session
        queue = try session.initial.map { try JSONEncoder().encode($0) }
    }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) throws {
        let request = try JSONDecoder().decode(AnnexJSON.self, from: data)
        guard request["type"]?.string == "mobile:replay" else { return }
        let frames: [AnnexEnvelope]
        if session.replayGap { frames = [AnnexEnvelope(type: "replay:gap", epoch: "race")] }
        else {
            let since = request["since"]?.integer ?? 0
            var response = [AnnexEnvelope(type: "replay:start", epoch: "race")]
            response.append(contentsOf: session.replay.filter { ($0.seq ?? 0) > since })
            response.append(AnnexEnvelope(type: "replay:end", epoch: "race"))
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
            body = .object(["version": .integer(1), "epoch": .string("race"), "controlAuth": .string("mtls-pinned-client"),
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
private func observe(_ io: SnapshotRaceIO, intentionallyCloseFirst: Bool = false) async throws -> SnapshotRaceObservation {
    let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id,
                                  verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: id)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry(), clock: io.clock.clock)
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

@Test(.timeLimit(.minutes(1))) func reconnectBusyFramesBeforeTheFirstSnapshotMustNotCauseRepeatedGaps() async throws {
    let busy = (105...108).map { event(Int64($0)) }
    let replay = (105...108).map { event(Int64($0), replayed: true) }
    let io = SnapshotRaceIO([.init(initial: [snapshot(100)]), .init(initial: busy + [snapshot(104)], replay: replay)], clock: AnnexManualClock())
    let result = try await observe(io, intentionallyCloseFirst: true)
    await report("A reconnect", result, io: io)
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
