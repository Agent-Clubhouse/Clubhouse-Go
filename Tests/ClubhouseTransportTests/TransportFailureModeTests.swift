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

@Test func chatContentPreservesDesktopHomePathThroughSingleQueryEncoding() async throws {
    let io = QueueIO([ok("{}"), ok("{}")])
    let transport = try await queueTransport(io)
    for path in ["~/scratch/a #é%20.txt", "~\\scratch\\a.txt"] {
        _ = try await transport.read(.chatContent(agentID: "scratch-agent", mediaRef: nil, filePath: path))
        #expect(await io.lastQuery() == ["path": path])
        #expect(await io.requests.last?.url?.path == "/api/v1/mobile/agents/scratch-agent/content")
        #expect(await io.requests.last?.url?.fragment == nil)
    }
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
    private(set) var closed = false
    private let sendFailure: Error?
    private let receiveFailure: Error?
    private let ack: Ack
    private(set) var sent: [AnnexJSON] = []
    init(extra: [String], sendFailure: Error?, ack: Ack, initial: [String]? = nil, receiveFailure: Error? = nil) {
        messages = (initial ?? [#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#]).map { Data($0.utf8) } + extra.map { Data($0.utf8) }
        self.sendFailure = sendFailure; self.ack = ack
        self.receiveFailure = receiveFailure
    }
    private(set) var receiveCalls = 0
    func receive() async throws -> Data {
        receiveCalls += 1
        if closed { throw AnnexTransportError.disconnected }
        if !messages.isEmpty { return messages.removeFirst() }
        if let receiveFailure { throw receiveFailure }
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
    private let firstInitial: [String]?
    private let firstSendFailure: Error?
    private let ack: FailureSocket.Ack
    private let sessionInitials: [[String]]
    private let sessionReceiveFailures: [AnnexTransportError]
    private(set) var sockets: [FailureSocket] = []
    private(set) var openAttempts = 0
    private(set) var paths: [String] = []
    init(capabilities: String = failureCapabilities, openFailures: [Error] = [], firstExtra: [String] = [],
         firstSendFailure: Error? = nil, ack: FailureSocket.Ack = .none, firstInitial: [String]? = nil,
         sessionInitials: [[String]] = [], sessionReceiveFailures: [AnnexTransportError] = []) {
        self.capabilities = capabilities; self.openFailures = openFailures; self.firstExtra = firstExtra
        self.firstSendFailure = firstSendFailure; self.ack = ack; self.firstInitial = firstInitial
        self.sessionInitials = sessionInitials; self.sessionReceiveFailures = sessionReceiveFailures
    }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        if path.hasSuffix("/identity") {
            let body: AnnexJSON = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
            return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
        }
        if request.httpMethod == "POST", let data = request.httpBody {
            let command = try JSONDecoder().decode(AnnexJSON.self, from: data)
            let receipt: AnnexJSON = .object(["version": .integer(1), "epoch": command["epoch"]!,
                "commandId": command["commandId"]!, "status": .string("completed")])
            return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(receipt))
        }
        return AnnexHTTPResponse(status: 200, data: Data(capabilities.utf8))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        openAttempts += 1
        if !openFailures.isEmpty { throw openFailures.removeFirst() }
        let first = sockets.isEmpty
        let index = sockets.count
        let initial = sessionInitials.indices.contains(index) ? sessionInitials[index] : (first ? firstInitial : nil)
        let failure = sessionReceiveFailures.indices.contains(index) ? sessionReceiveFailures[index] : nil
        let socket = FailureSocket(extra: first ? firstExtra : [], sendFailure: first ? firstSendFailure : nil,
                                   ack: ack, initial: initial, receiveFailure: failure)
        sockets.append(socket)
        return socket
    }
}

private func liveTransport(_ io: FailureSessionIO, telemetry: AnnexTelemetry = AnnexTelemetry(), clock: AnnexClock = .live,
                           backoff: AnnexBackoff = AnnexBackoff(initialSeconds: 0.01, maximumSeconds: 0.01)) async throws -> AnnexTransport {
    let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try failureHost(hostID)
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io, backoff: backoff, telemetry: telemetry, clock: clock)
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

private struct ScheduledConditionTimeout: Error {}

/// Wait for scheduled work's actual condition, giving other executors a chance to run.
/// A yield count can expire in milliseconds while the actor we await has not been scheduled.
private func settle(_ done: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    repeat {
        if await done() { return }
        try await Task.sleep(for: .milliseconds(1))
    } while ContinuousClock.now < deadline
    Issue.record("Scheduled condition did not become true within 10 seconds")
    throw ScheduledConditionTimeout()
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

// #205: a desktop can admit a socket and send snapshot_failed instead of its initial snapshot.
private let initialSnapshot = #"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#
private let snapshotFailure = #"{"type":"error","payload":{"message":"snapshot_failed"}}"#

@Test(.timeLimit(.minutes(1))) func snapshotFailureKeepsCommandsUsableDuringGraceThenRecoversThroughBackoff() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(firstInitial: [snapshotFailure])
    let transport = try await liveTransport(io, clock: clock.clock)
    let stream = await transport.events()
    defer { Task { await transport.disconnect() } }
    try await transport.connect()
    try await settle {
        guard let socket = await io.sockets.first else { return false }
        let calls = await socket.receiveCalls, closed = await socket.closed
        return closed || (calls >= 2 && clock.sleeperCount == 2)
    }
    try #require(await io.sockets.first?.closed == false, "Keep the authenticated socket open during grace")
    let before = try await collect(stream) { if case .message(let frame) = $0 { frame.type == "error" } else { false } }
    #expect(reconnectAttempts(before).isEmpty)
    clock.advance(by: .seconds(29))
    let receipt = try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    #expect(receipt.status == .completed, "REST commands must remain usable while the socket awaits a snapshot")
    #expect(await io.sockets.first?.closed == false)
    #expect(await io.openAttempts == 1)
    clock.advance(by: .seconds(1))
    try await settle { await io.sockets.first?.closed == true }
    let waiting = try await collect(stream) { if case .connection(.reconnecting) = $0 { true } else { false } }
    #expect(reconnectAttempts(waiting) == [1])
    await clock.waitForSleepers(1)
    #expect(await io.openAttempts == 1, "Grace expiry uses the existing backoff, not immediate reconnects")
    clock.advance(by: .seconds(1))
    _ = try await collect(stream) { $0 == .connection(.connected) }
    #expect(await io.openAttempts == 2)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func aSameSocketSnapshotCancelsSnapshotFailureGrace() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(firstInitial: [snapshotFailure])
    let transport = try await liveTransport(io, clock: clock.clock)
    let stream = await transport.events()
    defer { Task { await transport.disconnect() } }
    try await transport.connect()
    try await settle {
        guard let socket = await io.sockets.first else { return false }
        let calls = await socket.receiveCalls, closed = await socket.closed
        return closed || (calls >= 2 && clock.sleeperCount == 2)
    }
    let socket = try #require(await io.sockets.first)
    try #require(await socket.closed == false)
    clock.advance(by: .seconds(29))
    await socket.push(initialSnapshot)
    let events = try await collect(stream) { $0 == .connection(.connected) }
    #expect(reconnectAttempts(events).isEmpty)
    try await settle { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(31))
    #expect(await io.openAttempts == 1)
    #expect(await socket.closed == false)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func silenceAloneDoesNotPutASlowInitialSnapshotOnADeadline() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(firstInitial: [])
    let transport = try await liveTransport(io, clock: clock.clock)
    let stream = await transport.events()
    defer { Task { await transport.disconnect() } }
    try await transport.connect()
    try await settle { clock.sleeperCount >= 1 }
    #expect(clock.sleeperCount == 1, "Only the ping interval runs before any explicit snapshot failure")
    clock.advance(by: .seconds(31))
    let socket = try #require(await io.sockets.first)
    try await settle { await socket.pings == 1 }
    #expect(await socket.closed == false)
    await socket.push(initialSnapshot)
    _ = try await collect(stream) { $0 == .connection(.connected) }
    #expect(await io.openAttempts == 1)
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func otherErrorsAndTerminalErrorsKeepTheirRoutingAroundTheFirstSnapshot() async throws {
    let clock = AnnexManualClock()
    let other = #"{"type":"error","payload":{"message":"other_error"}}"#
    let terminal = #"{"type":"error","payload":{"op":"pty:spawn","message":"snapshot_failed"}}"#
    let io = FailureSessionIO(firstInitial: [other, terminal, initialSnapshot, snapshotFailure, other, #"{"type":"fixture:end"}"#])
    let transport = try await liveTransport(io, clock: clock.clock)
    let stream = await transport.events()
    var terminalStream = await transport.terminalEvents().makeAsyncIterator()
    try await transport.connect()
    let events = try await collect(stream) { if case .message(let frame) = $0 { frame.type == "fixture:end" } else { false } }
    let errors = events.compactMap { event -> AnnexEnvelope? in
        guard case .message(let frame) = event, frame.type == "error" else { return nil }; return frame
    }
    #expect(errors.count == 3, "Unrelated errors and snapshot_failed after a snapshot remain ordinary messages")
    var terminalFrame: AnnexEnvelope?
    while let event = await terminalStream.next() {
        if case .frame(let frame) = event { terminalFrame = frame; break }
    }
    #expect(terminalFrame?.payload?["op"]?.string == "pty:spawn")
    #expect(reconnectAttempts(events).isEmpty)
    try await settle { clock.sleeperCount >= 1 }
    #expect(clock.sleeperCount == 1, "These errors never start snapshot-failure grace")
    clock.advance(by: .seconds(31))
    #expect(await io.openAttempts == 1)
    #expect(await io.sockets.first?.closed == false)
    await transport.disconnect()
}

// Oversized desktop snapshots are recoverable, but must not cause fast downloads or rediscovery.
@Test(.timeLimit(.minutes(1))) func oversizedResponsesWaitAtLeastTheBackoffCeilingThenRecover() async throws {
    let clock = AnnexManualClock()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = FailureSessionIO(sessionInitials: [[], []], sessionReceiveFailures: [.responseTooLarge, .responseTooLarge])
    let transport = try await liveTransport(io, telemetry: telemetry, clock: clock.clock, backoff: AnnexBackoff())
    let stream = await transport.events()
    try await transport.connect()
    for expected in 1...2 {
        let events = try await collect(stream) { if case .connection(.retrying) = $0 { true } else { isFailed($0) } }
        let last = try #require(events.last)
        guard case .connection(.retrying(let attempt, let delay, let error)) = last else {
            Issue.record("Oversized responses must schedule recovery, not fail permanently"); await transport.disconnect(); return
        }
        #expect(attempt == expected)
        #expect(error == .responseTooLarge)
        #expect((30...45).contains(delay))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(delay - 0.001))
        for _ in 0..<100 { await Task.yield() }
        #expect(await io.openAttempts == expected)
        clock.advance(by: .milliseconds(2))
    }
    _ = try await collect(stream) { $0 == .connection(.connected) }
    #expect(await io.openAttempts == 3)
    #expect(telemetry.snapshot().records.filter { $0.operation == .backoff }.allSatisfy { $0.failure == .tooLarge })
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func explicitReconnectCancelsAnOversizeWaitAndTriesImmediatelyOnce() async throws {
    let clock = AnnexManualClock()
    let oversized = metadataSnapshot(bytes: 16 * 1024 * 1024 + 1)
    let io = FailureSessionIO(sessionInitials: [[oversized], [oversized]])
    let transport = try await liveTransport(io, clock: clock.clock, backoff: AnnexBackoff())
    let stream = await transport.events()
    try await transport.connect()
    _ = try await collect(stream) { if case .connection(.retrying) = $0 { true } else { false } }
    await clock.waitForSleepers(1)
    await transport.disconnect()
    try await transport.connect()
    let events = try await collect(stream) { if case .connection(.retrying) = $0 { true } else { false } }
    #expect(await io.openAttempts == 2, "An explicit reconnect bypasses the old wait without advancing the clock")
    #expect(events.contains { if case .connection(.retrying(attempt: 1, delaySeconds: let delay, error: .responseTooLarge)) = $0 { delay >= 30 } else { false } })
    await clock.waitForSleepers(1)
    #expect(await io.openAttempts == 2, "The new run also waits after its immediate attempt fails")
    await transport.disconnect()
    try await settle { clock.sleeperCount == 0 }
    clock.advance(by: .seconds(100))
    #expect(await io.openAttempts == 2)
}

private func metadataSnapshot(bytes: Int) -> String {
    let prefix = #"{"type":"snapshot","payload":{"lastSeq":0,"padding":""#
    let suffix = #""}}"#
    return prefix + String(repeating: "x", count: bytes - prefix.utf8.count - suffix.utf8.count) + suffix
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func transportEnforcesItsByteLimitBeforeDecodingAndAcceptsTheBoundary(refresh: Bool, oversized: Bool) async throws {
    let limit = 16 * 1024 * 1024
    let frame = metadataSnapshot(bytes: limit + (oversized ? 1 : 0))
    #expect(frame.utf8.count == limit + (oversized ? 1 : 0))
    let io = FailureSessionIO(firstInitial: (refresh ? [initialSnapshot] : []) + [frame])
    let clock = AnnexManualClock()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let transport = try await liveTransport(io, telemetry: telemetry, clock: clock.clock, backoff: AnnexBackoff())
    let stream = await transport.events()
    try await transport.connect()
    let events = try await collect(stream) {
        if case .connection(.retrying) = $0 { return true }
        if case .message(let envelope) = $0 { return envelope.payload?["padding"] != nil }
        return isFailed($0)
    }
    let connections = events.filter { $0 == .connection(.connected) }.count
    #expect(connections == (refresh ? 1 : 0) + (oversized ? 0 : 1))
    let records = telemetry.snapshot().records
    if oversized {
        #expect(events.contains { if case .connection(.retrying(_, let delay, .responseTooLarge)) = $0 { delay >= 30 } else { false } })
        let failure = try #require(records.first { $0.measurements["transportFrameLimitBytes"] != nil })
        #expect(failure.failure == .tooLarge)
        #expect(failure.measurements == ["transportFrameLimitBytes": Double(limit), "responseBytes": Double(limit + 1)])
    } else {
        #expect(!events.contains { if case .connection(.retrying) = $0 { true } else { false } })
        #expect(records.contains { $0.measurements == ["snapshotBytes": Double(limit)] && $0.events == ["snapshot"] })
    }
    #expect(await io.openAttempts == 1)
    // Neither metadata strings nor icon/base64 content can appear in these records.
    let exported = String(decoding: try JSONEncoder().encode(telemetry.snapshot()), as: UTF8.self)
    #expect(!exported.contains("padding"))
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func shortLivedSocketsIncreaseBackoffInsteadOfResettingIt() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(sessionInitials: Array(repeating: [], count: 7))
    let transport = try await liveTransport(io, clock: clock.clock, backoff: AnnexBackoff())
    let stream = await transport.events()
    try await transport.connect()
    var measured: [Double] = []
    for expected in 1...7 {
        await clock.waitForSleepers(1) // this connection's ping interval, after open
        #expect(await io.sockets.count == expected)
        let socket = try #require(await io.sockets.last)
        clock.advance(by: .milliseconds(170))
        await socket.close()
        let events = try await collect(stream) { if case .connection(.reconnecting) = $0 { true } else { false } }
        guard case .connection(.reconnecting(let attempt, let delay)) = events.last else { Issue.record("Missing retry"); break }
        #expect(attempt == expected)
        let ceiling = min(30.0, 0.5 * pow(2, Double(expected - 1)))
        #expect((ceiling / 2...ceiling).contains(delay))
        measured.append(delay + 0.17)
        await clock.waitForSleepers(1)
        if expected < 7 { clock.advance(by: .seconds(delay)) }
    }
    print("170ms socket lifetimes; accept-to-accept intervals (seconds, injected clock): \(measured)")
    #expect(await io.openAttempts == 7)
    await transport.disconnect()
}

@Test func oversizedResponseBackoffStartsAtTheCeilingAndKeepsJitterBounded() {
    let backoff = AnnexBackoff()
    #expect(backoff.delayAfterOversizedResponse(randomUnit: 0) == 30)
    #expect(backoff.delayAfterOversizedResponse(randomUnit: 1) == 45)
    #expect(backoff.delayAfterOversizedResponse(randomUnit: -1) == 30)
    #expect(backoff.delayAfterOversizedResponse(randomUnit: 2) == 45)
    #expect(backoff.delayAfterOversizedResponse(randomUnit: .nan) == 37.5)
}

// Uses the live clock deliberately: run's 30-second attempt reset uses ContinuousClock,
// so advancing AnnexManualClock alone cannot prove the production cadence.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANNEX_REAL_CADENCE_TESTS"] == "1"), .timeLimit(.minutes(2))) func persistentSnapshotFailureGraceResetsTheAttemptCounterOn147() async throws {
    let io = FailureSessionIO(sessionInitials: [[snapshotFailure], [snapshotFailure]])
    let transport = try await liveTransport(io, backoff: AnnexBackoff())
    let stream = await transport.events()
    let started = ContinuousClock.now
    try await transport.connect()
    var attempts: [Int] = []
    var elapsed: [Duration] = []
    var delays: [Double] = []
    for try await frame in stream {
        if case .connection(.reconnecting(let attempt, let delay)) = frame {
            attempts.append(attempt); delays.append(delay); elapsed.append(ContinuousClock.now - started)
            if attempts.count == 2 { break }
        }
    }
    #expect(attempts == [1, 1], "Each 30-second snapshot_failed grace exceeds run's reset threshold")
    #expect(delays.allSatisfy { (0.25...0.5).contains($0) })
    #expect(elapsed.last! >= .seconds(60))
    print("Persistent snapshot_failed real-clock retries: attempts=\(attempts), delays=\(delays), elapsed=\(elapsed)")
    await transport.disconnect()
}

@Suite(.serialized) struct OutboundFrameBudgetReviewTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true], [false, true])
    func anOversizedToolFrameRetriesSlowlyAndNeedsAFreshCheckpoint(replayed: Bool, duplicateRawOutput: Bool) async throws {
        let text = String(repeating: "x", count: 20 * 1024 * 1024)
        let frame = #"{"type":"chat:event","seq":1,"replayed":\#(replayed),"payload":{"agentId":"a","event":{"seq":1,"type":"tool_call_update","data":{"toolCallId":"t","output":"\#(text)"\#(duplicateRawOutput ? ",\"rawOutput\":\"" + text + "\"" : "")}}}}"#
        let clock = AnnexManualClock()
        let io = FailureSessionIO(sessionInitials: Array(repeating: [initialSnapshot, frame], count: 3) + [[#"{"type":"snapshot","payload":{"lastSeq":1,"projects":[],"agents":{}}}"#]])
        let transport = try await liveTransport(io, clock: clock.clock, backoff: AnnexBackoff())
        let events = await transport.events()
        try await transport.connect()
        var delays: [Double] = []
        for _ in 0..<3 {
            let frames = try await collect(events) { if case .connection(.retrying) = $0 { true } else { false } }
            #expect(!frames.contains { if case .message(let e) = $0 { e.seq == 1 } else { false } })
            guard case .connection(.retrying(_, let delay, .responseTooLarge)) = frames.last else { Issue.record("Expected recoverable oversize"); return }
            #expect((30...45).contains(delay)); delays.append(delay)
            let socket = try #require(await io.sockets.last)
            #expect(await socket.sent.contains { $0["type"]?.string == "mobile:replay" && $0["since"]?.integer == 0 })
            await clock.waitForSleepers(1); clock.advance(by: .seconds(delay))
        }
        let recovered = try await collect(events) { if case .message(let e) = $0 { e.type == "snapshot" } else { false } }
        #expect(recovered.contains(.resyncRequired(.reconnected)))
        let socket = try #require(await io.sockets.last)
        try await settle { await socket.sent.contains { $0["type"]?.string == "mobile:replay" && $0["since"]?.integer == 1 } }
        #expect(await io.openAttempts == 4)
        print("Tool frame replayed=\(replayed) duplicateRawOutput=\(duplicateRawOutput), bytes=\(frame.utf8.count): stale checkpoint0 repeats slow retry \(delays); fresh checkpoint1 advances/replays since1 and escapes")
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(2)), arguments: [1_247_805, 26 * 1024 * 1024, 66 * 1024 * 1024])
    func attachAcknowledgmentUsesTheSameFrameBudget(bytes: Int) async throws {
        let ack = #"{"type":"pty:attach:ack","payload":{"agentId":"a","buffer":"\#(String(repeating: "x", count: bytes))","cols":120,"rows":40}}"#
        let io = FailureSessionIO(firstInitial: [initialSnapshot, ack])
        let clock = AnnexManualClock()
        let transport = try await liveTransport(io, clock: clock.clock, backoff: AnnexBackoff())
        let events = await transport.events(), terminals = await transport.terminalEvents()
        try await transport.connect()
        if bytes < 16 * 1024 * 1024 {
            for await frame in terminals {
                if case .frame(let e) = frame {
                    #expect(e.type == "pty:attach:ack")
                    #expect(e.payload?["buffer"]?.string?.utf8.count == bytes); break
                }
            }
        } else {
            let frames = try await collect(events) { if case .connection(.retrying) = $0 { true } else { false } }
            #expect(frames.contains { if case .connection(.retrying(_, let delay, .responseTooLarge)) = $0 { delay >= 30 } else { false } })
        }
        print("PTY attach buffer=\(bytes) frame=\(ack.utf8.count): \(bytes < 16 * 1024 * 1024 ? "delivered" : "socket closes, slow retry")")
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func HTTPCommandCompletesWhileInitialSnapshotAndWebSocketRepliesAreHeld() async throws {
        let io = FailureSessionIO(firstInitial: [])
        let transport = try await liveTransport(io)
        try await transport.connect()
        try await settle { await io.openAttempts == 1 }
        let started = ContinuousClock.now
        let receipt = try await transport.execute(.init(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
        #expect(receipt.status == .completed)
        print("HTTP mutation completed with no first snapshot/WS reply in \(ContinuousClock.now - started)")
        await transport.disconnect()
    }
}

@Test(.timeLimit(.minutes(1))) func unsequencedRepliesBeforeFirstSnapshotPreserveCursorAndHTTPCommandCorrelation() async throws {
    let reply = AnnexEnvelope(type: "mobile:command:result", payload: .object(["commandId": .string("c"), "status": .string("failed")]))
    let ack = AnnexEnvelope(type: "pty:attach:ack", payload: .object(["agentId": .string("a"), "buffer": .string("early")]))
    var cursor = AnnexReplayCursor()
    #expect(cursor.accept(reply) == .deliver)
    #expect(cursor.accept(ack) == .deliver)
    #expect(cursor.lastSequence == nil)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 0)) == .deliver)
    #expect(cursor.lastSequence == 0)
    func wire(_ e: AnnexEnvelope) throws -> String { String(decoding: try JSONEncoder().encode(e), as: UTF8.self) }
    let io = FailureSessionIO(firstInitial: [try wire(reply), try wire(ack), #"{"type":"fixture:before-snapshot"}"#])
    let transport = try await liveTransport(io)
    let stream = await transport.events(), terminals = await transport.terminalEvents()
    try await transport.connect()
    let before = try await collect(stream) { if case .message(let e) = $0 { e.type == "fixture:before-snapshot" } else { false } }
    #expect(before.contains(.message(reply)))
    #expect(!before.contains { if case .resyncRequired = $0 { true } else { false } })
    for await frame in terminals { if case .frame(let e) = frame { #expect(e == ack); break } }
    let receipt = try await transport.execute(.init(commandID: "c", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    #expect(receipt.status == .completed, "WS message claiming failure cannot resolve/override an HTTP command receipt")
    await io.sockets.first?.push(initialSnapshot)
    let after = try await collect(stream) { $0 == .connection(.connected) }
    #expect(!after.contains { if case .resyncRequired = $0 { true } else { false } })
    await transport.disconnect()
}

@Test(.timeLimit(.minutes(1))) func watchdogFailureAtFifteenSecondsStartsThirtySecondGraceAndKeepsRepliesFlowing() async throws {
    let clock = AnnexManualClock()
    let io = FailureSessionIO(firstInitial: [])
    let transport = try await liveTransport(io, clock: clock.clock, backoff: AnnexBackoff())
    let events = await transport.events()
    try await transport.connect()
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(15))
    let socket = try #require(await io.sockets.first)
    await socket.push(snapshotFailure)
    _ = try await collect(events) { if case .message(let e) = $0 { e.type == "error" } else { false } }
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(29))
    await socket.push(#"{"type":"fixture:reply","payload":{"ok":true}}"#)
    _ = try await collect(events) { if case .message(let e) = $0 { e.type == "fixture:reply" } else { false } }
    #expect(await socket.closed == false)
    clock.advance(by: .seconds(1))
    _ = try await collect(events) { if case .connection(.reconnecting) = $0 { true } else { false } }
    #expect(await socket.closed == true)
    print("147: no snapshot deadline before watchdog; snapshot_failed at15s starts30s grace; replies accepted at44s; reconnect at45s + ordinary backoff")
    await transport.disconnect()
}
