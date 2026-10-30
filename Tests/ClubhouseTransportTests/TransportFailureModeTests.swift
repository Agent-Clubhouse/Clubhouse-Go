import Foundation
import Testing
@testable import ClubhouseTransport

// Failure modes of AnnexTransport driven through fake IO: route validation, capability
// downgrades, malformed receipts and frames, replay gaps, TLS-class errors and the
// telemetry hello/ack negotiation. No real network, no fixed sleeps.

private let failureCapabilities = #"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":["chat.send","chat.interrupt"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#
private func failureHost(_ hostID: String = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef") throws -> TrustedAnnexHost {
    try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: hostID,
                         verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
}

/// Plays back HTTP responses in order and records every request it was asked to perform.
private actor QueueIO: AnnexIO {
    private var responses: [AnnexHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [AnnexHTTPResponse] = []) { self.responses = responses }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
        return responses.removeFirst()
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
    func lastQuery() -> [String: String] {
        guard let url = requests.last?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
private func ok(_ body: String, status: Int = 200) -> AnnexHTTPResponse { AnnexHTTPResponse(status: status, data: Data(body.utf8)) }
private func queueTransport(_ io: QueueIO, clock: AnnexClock = .live) async throws -> AnnexTransport {
    let host = try failureHost()
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry(), clock: clock)
}

// MARK: Subscribers

@Test func seventeenthEventSubscriberIsRefusedWithOverflow() async throws {
    let transport = try await queueTransport(QueueIO())
    var streams: [AsyncThrowingStream<AnnexTransportEvent, Error>] = []
    for _ in 0..<16 { streams.append(await transport.events()) }
    var refused = await transport.events().makeAsyncIterator()
    await #expect(throws: AnnexTransportError.queueOverflow) { _ = try await refused.next() }
    // Existing subscribers are unaffected and still receive the initial state.
    var first = streams[0].makeAsyncIterator()
    #expect(try await first.next() == .connection(.disconnected))
}

@Test func terminalSubscriberThatFallsBehindIsFinishedNotGapped() async throws {
    let transport = try await queueTransport(QueueIO())
    let terminal = await transport.terminalEvents() // one slot used by the initial state
    // Every disconnect emits a connection change; nobody reads, so the 4096-deep buffer overflows.
    for _ in 0..<4100 { await transport.disconnect() }
    var count = 0
    for await _ in terminal { count += 1 }
    #expect(count == 4096)
    // A fresh subscriber still works after the slow one was dropped.
    var fresh = await transport.terminalEvents().makeAsyncIterator()
    #expect(await fresh.next() == .connection(.disconnected))
}

// MARK: Read routes

@Test func chatContentNeedsExactlyOneOfReferenceOrFile() async throws {
    let io = QueueIO([ok("{}"), ok("{}")])
    let transport = try await queueTransport(io)
    await #expect(throws: AnnexTransportError.invalidEndpoint) {
        try await transport.read(.chatContent(agentID: "a", mediaRef: "m", filePath: "f"))
    }
    await #expect(throws: AnnexTransportError.invalidEndpoint) {
        try await transport.read(.chatContent(agentID: "a", mediaRef: nil, filePath: nil))
    }
    #expect(await io.requests.isEmpty)
    _ = try await transport.read(.chatContent(agentID: "a", mediaRef: "ref&1", filePath: nil))
    #expect(await io.lastQuery() == ["mediaRef": "ref&1"])
    #expect(await io.requests.last?.url?.path == "/api/v1/mobile/agents/a/content")
    _ = try await transport.read(.chatContent(agentID: "a", mediaRef: nil, filePath: "docs/a.png"))
    #expect(await io.lastQuery() == ["path": "docs/a.png"])
}

@Test func transcriptPaginationIsClampedToDesktopBounds() async throws {
    let io = QueueIO([ok("{}"), ok("{}")])
    let transport = try await queueTransport(io)
    _ = try await transport.read(.transcript(agentID: "a", sessionID: "s", offset: -10, limit: 10_000))
    #expect(await io.lastQuery() == ["offset": "0", "limit": "500"])
    #expect(await io.requests.last?.url?.path == "/api/v1/agents/a/sessions/s/transcript")
    _ = try await transport.read(.transcript(agentID: "a", sessionID: "s", offset: 40, limit: 0))
    #expect(await io.lastQuery() == ["offset": "40", "limit": "1"])
}

@Test func capabilityDowngradesAreRefusedAndNeverEnableCommands() async throws {
    let downgrades = [
        failureCapabilities.replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
        failureCapabilities.replacingOccurrences(of: #""epoch":"epoch1""#, with: #""epoch":"""#),
        failureCapabilities.replacingOccurrences(of: "mtls-pinned-client", with: "bearer"),
    ]
    for body in downgrades {
        let io = QueueIO([ok(body)])
        let transport = try await queueTransport(io)
        await #expect(throws: AnnexTransportError.unsupportedCapability("mobile-control-v1")) { try await transport.read(.capabilities) }
        await #expect(throws: AnnexTransportError.unsupportedCapability("chat.interrupt")) {
            try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
        }
        #expect(await io.requests.count == 1)
    }
}

/// A refused re-read withdraws authority the earlier document granted: no command may carry the old epoch.
@Test func aRefusedCapabilityReReadWithdrawsTheEarlierAuthority() async throws {
    let refusals: [(AnnexHTTPResponse, AnnexTransportError)] = [
        (ok(failureCapabilities.replacingOccurrences(of: "mtls-pinned-client", with: "bearer")), .unsupportedCapability("mobile-control-v1")),
        (ok(failureCapabilities.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)), .unsupportedCapability("mobile-control-v1")),
        (ok("<html>"), .malformedResponse),
        (ok("{}", status: 404), .rejected(status: 404, code: nil)),
    ]
    for (refusal, expected) in refusals {
        let io = QueueIO([ok(failureCapabilities), refusal])
        let transport = try await queueTransport(io)
        _ = try await transport.read(.capabilities)
        await #expect(throws: expected) { try await transport.read(.capabilities) }
        await #expect(throws: AnnexTransportError.unsupportedCapability("chat.interrupt")) {
            try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
        }
        #expect(await io.requests.count == 2, "The refused command never reaches the desktop")
    }
    // A document missing required fields fails decoding, and withdraws authority the same way.
    let io = QueueIO([ok(failureCapabilities), ok(#"{"version":1}"#)])
    let transport = try await queueTransport(io)
    _ = try await transport.read(.capabilities)
    await #expect(throws: DecodingError.self) { try await transport.read(.capabilities) }
    await #expect(throws: AnnexTransportError.unsupportedCapability("chat.interrupt")) {
        try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
}

/// A network failure before any reply proves nothing about the desktop, so the confirmed authority stays.
@Test func aCapabilityReadLostInTransitKeepsTheConfirmedAuthority() async throws {
    let io = QueueIO([ok(failureCapabilities)])
    let transport = try await queueTransport(io)
    _ = try await transport.read(.capabilities)
    await #expect(throws: URLError.self) { try await transport.read(.capabilities) }
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "c")) {
        try await transport.execute(AnnexCommand(commandID: "c", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
}

@Test func nonJSONReadBodyIsMalformed() async throws {
    let transport = try await queueTransport(QueueIO([ok("<html>")]))
    await #expect(throws: AnnexTransportError.malformedResponse) { try await transport.read(.status) }
}

// MARK: Commands

@Test func receiptsThatDoNotProveTheOutcomeAreUnknownAndNeverResent() async throws {
    let receipts: [AnnexHTTPResponse] = [
        ok("not json"),
        ok(#"{"version":2,"commandId":"c","epoch":"epoch1","status":"completed"}"#),
        ok(#"{"version":1,"commandId":"other","epoch":"epoch1","status":"completed"}"#),
        ok(#"{"version":1,"commandId":"c","epoch":"epoch2","status":"completed"}"#),
        ok(#"{"version":1,"commandId":"c","epoch":"epoch1","status":"completed"}"#, status: 500),
        ok(#"{"version":1,"commandId":"c","epoch":"epoch1","status":"failed"}"#, status: 200),
        ok(#"{"version":1,"commandId":"c","epoch":"epoch1","status":"rejected"}"#, status: 500),
    ]
    for receipt in receipts {
        let io = QueueIO([ok(failureCapabilities), receipt])
        let transport = try await queueTransport(io)
        _ = try await transport.read(.capabilities)
        let command = AnnexCommand(commandID: "c", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "hi"))
        await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "c")) { try await transport.execute(command) }
        // An idempotent retry of the same command must not hit the network again.
        await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "c")) { try await transport.execute(command) }
        #expect(await io.requests.count == 2)
    }
}

@Test func failedReceiptOn5xxIsDefinitive() async throws {
    let io = QueueIO([ok(failureCapabilities), ok(#"{"version":1,"commandId":"c","epoch":"epoch1","status":"failed","error":{"code":"internal","message":"x"}}"#, status: 503)])
    let transport = try await queueTransport(io)
    _ = try await transport.read(.capabilities)
    let receipt = try await transport.execute(AnnexCommand(commandID: "c", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    #expect(receipt.status == .failed)
    #expect(!receipt.isDispatchAcknowledged)
}

@Test func commandsWithoutCredentialFailBeforeDispatch() async throws {
    let io = QueueIO([ok(failureCapabilities)])
    let host = try failureHost()
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: host.hostID)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
    _ = try await transport.read(.capabilities)
    await credentials.remove(for: host.hostID)
    await #expect(throws: AnnexTransportError.credentialMissing) {
        try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
    await #expect(throws: AnnexTransportError.credentialMissing) { try await transport.connect() }
    #expect(await io.requests.count == 1)
}

// MARK: Live session fakes

private actor FailureSocket: AnnexWebSocket {
    enum Ack: Sendable { case none, badThenGood }
    private var messages: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private let sendFailure: Error?
    private let ack: Ack
    private(set) var sent: [AnnexJSON] = []
    init(extra: [String], sendFailure: Error?, ack: Ack) {
        messages = [Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)] + extra.map { Data($0.utf8) }
        self.sendFailure = sendFailure; self.ack = ack
    }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ json: String) {
        let data = Data(json.utf8)
        if let pending { self.pending = nil; pending.resume(returning: data) } else { messages.append(data) }
    }
    func send(_ data: Data) throws {
        if let sendFailure { throw sendFailure }
        let message = try JSONDecoder().decode(AnnexJSON.self, from: data)
        sent.append(message)
        guard message["type"]?.string == "telemetry:hello", let hello = message["payload"], ack == .badThenGood else { return }
        func ackFrame(_ payload: AnnexJSON) throws -> Data {
            try JSONEncoder().encode(AnnexJSON.object(["type": .string("telemetry:hello:ack"), "payload": payload]))
        }
        let good: AnnexJSON = .object([
            "version": .integer(1), "serviceName": .string("clubhouse"), "serviceInstanceId": .string("33333333-3333-4333-8333-333333333333"),
            "peerServiceInstanceId": hello["serviceInstanceId"]!, "connectionAttemptId": hello["connectionAttemptId"]!,
            "connectionId": .string("44444444-4444-4444-8444-444444444444"), "traceContext": .string("w3c-v00")])
        var wrongAttempt = good
        if case .object(var fields) = good { fields["connectionAttemptId"] = .string("55555555-5555-4555-8555-555555555555"); wrongAttempt = .object(fields) }
        // A payload-less ack, then one for another attempt, then the real one; acks precede the snapshot.
        let frames = [try JSONEncoder().encode(AnnexJSON.object(["type": .string("telemetry:hello:ack")])), try ackFrame(wrongAttempt), try ackFrame(good)]
        messages.insert(contentsOf: frames, at: 0)
    }
    private(set) var pings = 0
    func ping() throws { if closed { throw AnnexTransportError.disconnected }; pings += 1 }
    func close() {
        closed = true
        pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil
    }
}

private actor FailureSessionIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    private let capabilities: String
    private var openFailures: [Error]
    private let firstExtra: [String]
    private let firstSendFailure: Error?
    private let ack: FailureSocket.Ack
    private(set) var sockets: [FailureSocket] = []
    private(set) var openAttempts = 0
    private(set) var paths: [String] = []
    init(capabilities: String = failureCapabilities, openFailures: [Error] = [], firstExtra: [String] = [],
         firstSendFailure: Error? = nil, ack: FailureSocket.Ack = .none) {
        self.capabilities = capabilities; self.openFailures = openFailures; self.firstExtra = firstExtra
        self.firstSendFailure = firstSendFailure; self.ack = ack
    }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        if path.hasSuffix("/identity") {
            let body: AnnexJSON = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
            return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
        }
        return AnnexHTTPResponse(status: 200, data: Data(capabilities.utf8))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        openAttempts += 1
        if !openFailures.isEmpty { throw openFailures.removeFirst() }
        let first = sockets.isEmpty
        let socket = FailureSocket(extra: first ? firstExtra : [], sendFailure: first ? firstSendFailure : nil, ack: ack)
        sockets.append(socket)
        return socket
    }
}

private func liveTransport(_ io: FailureSessionIO, telemetry: AnnexTelemetry = AnnexTelemetry(), clock: AnnexClock = .live) async throws -> AnnexTransport {
    let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try failureHost(hostID)
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io, backoff: AnnexBackoff(initialSeconds: 0.01, maximumSeconds: 0.01), telemetry: telemetry, clock: clock)
}

/// Collects events until `stop` matches; the time limit only guards against a hang.
private func collect(_ stream: AsyncThrowingStream<AnnexTransportEvent, Error>, until stop: (AnnexTransportEvent) -> Bool) async throws -> [AnnexTransportEvent] {
    var seen: [AnnexTransportEvent] = []
    for try await event in stream {
        seen.append(event)
        if stop(event) { break }
    }
    return seen
}
private func isFailed(_ event: AnnexTransportEvent) -> Bool { if case .connection(.failed) = event { true } else { false } }
private func reconnectAttempts(_ events: [AnnexTransportEvent]) -> [Int] {
    events.compactMap { if case .connection(.reconnecting(let attempt, _)) = $0 { attempt } else { nil } }
}

@Test(.timeLimit(.minutes(1))) func malformedFrameFailsClosedWithoutReconnecting() async throws {
    let io = FailureSessionIO(firstExtra: ["this is not json"])
    let transport = try await liveTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    let events = try await collect(stream, until: isFailed)
    #expect(events.last == .connection(.failed(.malformedResponse)))
    #expect(events.contains(.connection(.connected)))
    #expect(await io.openAttempts == 1)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func snapshotFromAnotherEpochFailsClosed() async throws {
    let io = FailureSessionIO(firstExtra: [#"{"type":"snapshot","epoch":"other-epoch","payload":{"lastSeq":0}}"#])
    let transport = try await liveTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    let events = try await collect(stream, until: isFailed)
    #expect(events.last == .connection(.failed(.malformedResponse)))
    #expect(await io.openAttempts == 1)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func replayGapMidStreamForcesResyncAndReconnect() async throws {
    let io = FailureSessionIO(firstExtra: [#"{"type":"chat:event","seq":1}"#, #"{"type":"chat:event","seq":5}"#])
    let transport = try await liveTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    var connections = 0
    let events = try await collect(stream) { event in
        if event == .connection(.connected) { connections += 1 }
        return connections == 2
    }
    let gap = try #require(events.firstIndex(of: .resyncRequired(.sequenceGap)))
    let reconnected = try #require(events.firstIndex(of: .resyncRequired(.reconnected)))
    #expect(gap < reconnected)
    #expect(reconnectAttempts(events) == [1])
    // seq 5 was never delivered; seq 1 was.
    let delivered = events.compactMap { if case .message(let envelope) = $0 { envelope.seq } else { nil } }
    #expect(delivered == [1])
    #expect(await io.sockets.count == 2)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func tlsClassURLErrorsStopWithTrustRequired() async throws {
    for code in [URLError.Code.serverCertificateUntrusted, .clientCertificateRejected, .secureConnectionFailed, .cancelled] {
        let io = FailureSessionIO(openFailures: [URLError(code)])
        let transport = try await liveTransport(io)
        let stream = await transport.events()
        try await transport.connect()
        let events = try await collect(stream, until: isFailed)
        #expect(events.last == .connection(.failed(.trustRequired)))
        #expect(reconnectAttempts(events).isEmpty)
        #expect(await io.openAttempts == 1)
        await transport.disconnect()
    }
}

private struct OpaqueFailure: Error {}
@Test(.timeLimit(.minutes(1))) func transientAndUnknownErrorsBackOffAndRecover() async throws {
    let io = FailureSessionIO(openFailures: [URLError(.timedOut), OpaqueFailure(), AnnexTransportError.disconnected])
    let transport = try await liveTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    let events = try await collect(stream) { $0 == .connection(.connected) }
    #expect(reconnectAttempts(events) == [1, 2, 3])
    #expect(await io.openAttempts == 4)
    // Each attempt re-verifies identity and capabilities before opening the socket.
    #expect(await io.paths.filter { $0.hasSuffix("/identity") }.count == 4)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func failedTelemetryHelloSendReconnectsAndRecordsFailure() async throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = FailureSessionIO(firstSendFailure: URLError(.networkConnectionLost))
    let transport = try await liveTransport(io, telemetry: telemetry)
    let stream = await transport.events()
    try await transport.connect()
    let events = try await collect(stream) { $0 == .connection(.connected) }
    #expect(reconnectAttempts(events) == [1])
    #expect(await io.sockets.count == 2)
    #expect(telemetry.snapshot().records.contains { $0.operation == .handshake && $0.failure == .offline })
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func invalidTelemetryAcksAreIgnoredUntilAValidOneBinds() async throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = FailureSessionIO(ack: .badThenGood)
    let transport = try await liveTransport(io, telemetry: telemetry)
    let stream = await transport.events()
    try await transport.connect()
    _ = try await collect(stream) { $0 == .connection(.connected) }
    let handshake = try #require(telemetry.snapshot().records.first { $0.operation == .handshake })
    #expect(handshake.events.filter { $0 == "rejected" }.count == 2)
    #expect(handshake.failure == .none)
    #expect(handshake.identifiers["peer.service.instance.id"] == "33333333-3333-4333-8333-333333333333")
    // Later authorized requests carry the negotiated connection identity.
    _ = try await transport.read(.status)
    #expect(telemetry.snapshot().records.contains { $0.operation == .status && $0.identifiers["annex.connection.id"] == "44444444-4444-4444-8444-444444444444" })
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func nonInputTerminalFramesAreSentWhole() async throws {
    let caps = failureCapabilities.replacingOccurrences(of: #""commands":"#, with: #""terminal":{"version":1,"projectShell":true,"agentShell":true,"agentAttach":true,"maxShellsPerConnection":8,"maxInputLength":4},"commands":"#)
    let io = FailureSessionIO(capabilities: caps)
    let transport = try await liveTransport(io)
    let stream = await transport.events()
    try await transport.connect()
    _ = try await collect(stream) { $0 == .connection(.connected) }
    try await transport.sendTerminal(.resize(id: "s1", cols: 200, rows: 50))
    let socket = try #require(await io.sockets.first)
    let resizes = await socket.sent.filter { $0["type"]?.string == "pty:resize" }
    #expect(resizes.count == 1)
    #expect(resizes.first?["payload"]?["cols"] == .integer(200))
    await transport.disconnect()
}

// MARK: Protocol defaults

private struct ReadOnlyTransport: AnnexTransporting {
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func connect() async throws {}
    func disconnect() async {}
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON { .null }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
}
@Test func gatewayTransportsWithoutOptionalFeaturesReportUnsupported() async throws {
    let transport: any AnnexTransporting = ReadOnlyTransport()
    await #expect(throws: AnnexTransportError.unsupportedCapability("session-revocation")) { try await transport.revokeSessionPairing() }
    await #expect(throws: AnnexTransportError.unsupportedCapability("attachments")) {
        try await transport.upload(agentID: "a", data: Data([1]), mimeType: "image/png")
    }
    await #expect(throws: AnnexTransportError.unsupportedCapability("terminal")) { try await transport.sendTerminal(.close(sessionID: "s")) }
    var terminal = await transport.terminalEvents().makeAsyncIterator()
    #expect(await terminal.next() == nil)
}

// MARK: Timers on an injected clock

/// Waits for work the code under test has already scheduled, by yielding rather than sleeping.
private func settle(_ done: () async -> Bool) async throws {
    for _ in 0..<10_000 { if await done() { return }; await Task.yield() }
    Issue.record("Condition never settled"); throw CancellationError()
}

@Test func commandsOlderThanTheDesktopsRetentionAreUnknownAndNeverSent() async throws {
    let clock = AnnexManualClock()
    let oneMinute = failureCapabilities.replacingOccurrences(of: #""ttlMs":3600000"#, with: #""ttlMs":60000"#)
    let receipt = #"{"version":1,"commandId":"kept","epoch":"epoch1","status":"completed"}"#
    let io = QueueIO([ok(oneMinute), ok(receipt)])
    let transport = try await queueTransport(io, clock: clock.clock)
    _ = try await transport.read(.capabilities)
    let kept = AnnexCommand(commandID: "kept", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s"))
    let stale = AnnexCommand(commandID: "stale", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s"))
    #expect(try await transport.execute(kept).status == .completed)
    clock.advance(by: .seconds(30))
    // Within retention a repeat returns the recorded receipt without a request.
    #expect(try await transport.execute(kept).status == .completed)
    clock.advance(by: .seconds(31))
    // Past the desktop's one-minute horizon it may have forgotten the id: never resend.
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "stale")) { try await transport.execute(stale) }
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "kept")) { try await transport.execute(kept) }
    #expect(await io.requests.count == 2)
}

@Test(.timeLimit(.minutes(1))) func anUnansweredTelemetryHelloTimesOutAfterFiveSeconds() async throws {
    let clock = AnnexManualClock()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = FailureSessionIO()
    let transport = try await liveTransport(io, telemetry: telemetry, clock: clock.clock)
    let stream = await transport.events()
    try await transport.connect()
    _ = try await collect(stream) { $0 == .connection(.connected) }
    // The hello deadline (5 s) and the ping interval (20 s) are both waiting.
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(4))
    #expect(!telemetry.snapshot().records.contains { $0.operation == .handshake }, "Still pending before the deadline")
    clock.advance(by: .seconds(1))
    try await settle { telemetry.snapshot().records.contains { $0.operation == .handshake } }
    let handshake = try #require(telemetry.snapshot().records.first { $0.operation == .handshake })
    #expect(handshake.failure == .timeout)
    #expect(handshake.events.contains("unsupported"))
    #expect(await io.sockets.count == 1, "An old desktop that ignores the hello keeps its connection")
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func theConnectionPingsEveryTwentySeconds() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO()
    let transport = try await liveTransport(io, clock: clock.clock)
    let stream = await transport.events()
    try await transport.connect()
    _ = try await collect(stream) { $0 == .connection(.connected) }
    let socket = try #require(await io.sockets.first)
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(19))
    #expect(await socket.pings == 0)
    clock.advance(by: .seconds(1))
    try await settle { await socket.pings == 1 }
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(20))
    try await settle { await socket.pings == 2 }
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func reconnectWaitsOutTheBackoffOnTheClock() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(openFailures: [URLError(.networkConnectionLost)])
    let host = try failureHost(try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: host.hostID)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io, backoff: AnnexBackoff(initialSeconds: 4, maximumSeconds: 4),
                                   telemetry: AnnexTelemetry(), clock: clock.clock)
    let stream = await transport.events()
    try await transport.connect()
    let waiting = try await collect(stream) { if case .connection(.reconnecting) = $0 { true } else { false } }
    #expect(reconnectAttempts(waiting) == [1])
    await clock.waitForSleepers(1)
    // Equal jitter puts a 4 s ceiling between 2 and 4 s: just under 2 s is always too early.
    clock.advance(by: .milliseconds(1999))
    for _ in 0..<100 { await Task.yield() }
    #expect(await io.openAttempts == 1, "No second attempt until the backoff has passed")
    clock.advance(by: .seconds(2))
    _ = try await collect(stream) { $0 == .connection(.connected) }
    #expect(await io.openAttempts == 2)
    await transport.disconnect()
}
