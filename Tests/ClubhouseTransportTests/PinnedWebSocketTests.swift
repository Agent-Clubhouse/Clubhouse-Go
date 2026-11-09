#if os(macOS)
import Testing
import Foundation
@testable import ClubhouseTransport

// The real URLSession WebSocket and OTLP sender against an isolated Node fixture
// (Fixtures/ws-server.mjs): pinned TLS, client certificate, text/binary frames, ping/pong,
// cancellation and close, plus a plain-HTTP collector stand-in on loopback.

private struct WSFixture {
    struct Info: Decodable { let port: UInt16; let httpPort: UInt16; let pin: String }
    let process: Process
    let info: Info
    let host: TrustedAnnexHost
    static func start() throws -> WSFixture {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", try #require(Bundle.module.url(forResource: "ws-server", withExtension: "mjs", subdirectory: "Fixtures")).path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
            line.append(byte)
            guard line.count < 4096 else { throw AnnexTransportError.malformedResponse }
        }
        let info = try JSONDecoder().decode(Info.self, from: line)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: info.port),
                                        verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: info.pin))
        return WSFixture(process: process, info: info, host: host)
    }
    func stop() { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    func webSocketRequest(token: String = "fake-only") throws -> URLRequest {
        var request = URLRequest(url: try host.endpoint.url(path: ["ws"], webSocket: true))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
/// RSA key generation costs about a second; one throwaway client identity serves every test here.
private let socketIdentity = Result { try AnnexClientIdentity.ephemeral() }
private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test(.timeLimit(.minutes(1))) func urlSessionOversizeErrorAndPeerCloseCodeOnLoopback() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let delegate = AnnexPinnedSessionDelegate(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    for kind in ["text", "binary"] {
        for size in [1023, 1024, 1025] {
            let task = session.webSocketTask(with: try fixture.webSocketRequest())
            task.maximumMessageSize = 1024
            task.resume()
            _ = try await task.receive() // greeting
            let started = ContinuousClock.now
            try await task.send(.string("size:\(kind):\(size)"))
            do {
                let message = try await task.receive()
                let count: Int
                switch message {
                case .data(let bytes): count = bytes.count
                case .string(let value): count = value.utf8.count
                @unknown default: count = -1
                }
                #expect(size <= 1024)
                #expect(count == size)
                print("Loopback \(kind) \(size)/1024 bytes: received in \(ContinuousClock.now - started)")
            } catch {
                let failure = error as NSError
                print("Loopback \(kind) \(size)/1024 bytes: \(failure.domain) code \(failure.code) in \(ContinuousClock.now - started); classified \(AnnexDiagnosticFailure.classify(error))")
                #expect(size == 1025)
                #expect(failure.domain == NSPOSIXErrorDomain)
                #expect(failure.code == Int(EMSGSIZE))
            }
            task.cancel(with: .goingAway, reason: nil)
        }
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(fixture.info.httpPort)/closes"))
    var closes: AnnexJSON = .null
    for _ in 0..<100 {
        let (data, _) = try await URLSession.shared.data(from: url)
        closes = try JSONDecoder().decode(AnnexJSON.self, from: data)
        if case .array(let rows) = closes, rows.filter({ $0["size"]?.integer == 1025 }).count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard case .array(let rows) = closes else { Issue.record("Missing close observations"); return }
    let oversize = rows.filter { $0["size"]?.integer == 1025 }
    print("Loopback server close observations: \(closes)")
    #expect(oversize.count == 2)
    #expect(oversize.allSatisfy { $0["code"]?.integer == 1009 })
}

@Test(.timeLimit(.minutes(1))) func revokedPeerClose4401PreservesTheExplicitRemovalReason() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    _ = try await socket.receive()
    try await socket.send(Data("close:4401".utf8))
    await #expect(throws: AnnexTransportError.rejected(status: 401, code: "peer_not_paired")) {
        try await socket.receive()
    }
    await socket.close()
}

@Test(.timeLimit(.minutes(1))) func serverOverrunClose1013UsesRecoverableURLSessionFailure() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    _ = try await socket.receive()
    try await socket.send(Data("close:1013".utf8))
    do {
        _ = try await socket.receive()
        Issue.record("The server closed with 1013")
    } catch {
        let failure = error as NSError
        print("Server close 1013: \(failure.domain) code \(failure.code); classification \(AnnexDiagnosticFailure.classify(error))")
        #expect(failure.domain == NSPOSIXErrorDomain)
        #expect(failure.code == Int(ENOTCONN))
        #expect(AnnexDiagnosticFailure.classify(error) == .unknown)
    }
    await socket.close()
}

@Test(.timeLimit(.minutes(1))) func pinnedWebSocketCarriesTextBinaryAndPings() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let client = try socketIdentity.get()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: client, telemetry: telemetry)
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    let greeting = try JSONDecoder().decode(AnnexJSON.self, from: await socket.receive())
    #expect(greeting["path"] == .string("/ws"))
    #expect(greeting["authorized"] == .bool(true))
    #expect(greeting["clientCN"]?.string == (try client.fingerprint))
    #expect(greeting["traceparent"]?.string.flatMap { AnnexTraceContext(traceparent: $0) } != nil)
    try await socket.send(Data("hello".utf8))
    #expect(text(try await socket.receive()) == "hello")
    try await socket.send(Data("binary".utf8))
    #expect(try await socket.receive() == Data([0xde, 0xad, 0xbe, 0xef]))
    // Frames are always sent as text; bytes that are not UTF-8 never reach the wire.
    await #expect(throws: AnnexTransportError.malformedResponse) { try await socket.send(Data([0xff, 0xfe])) }
    // URLSession only reads pongs while a receive is outstanding, as the transport's receive loop always is.
    let reader = Task { try await socket.receive() }
    try await socket.ping()
    try await socket.ping()
    try await socket.send(Data("after-ping".utf8))
    #expect(text(try await reader.value) == "after-ping")
    // Answered pings are counted, not recorded one span each (they would crowd out the ring).
    #expect(!telemetry.snapshot().records.contains { $0.operation == .ping })
    #expect(telemetry.drainSummaries().first { $0.operation == .ping }.map { [$0.count, $0.failed] } == [2, 0])
    #expect(telemetry.snapshot().records.contains { $0.operation == .websocket })
    await socket.close()
}

@Test(.timeLimit(.minutes(1))) func pinnedWebSocketMapsOversizeToResponseTooLarge() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    for kind in ["text", "binary"] {
        let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
        let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), maximumResponseBytes: 1024, telemetry: telemetry)
        let socket = try await io.openWebSocket(fixture.webSocketRequest())
        _ = try await socket.receive()
        try await socket.send(Data("size:\(kind):1023".utf8))
        #expect(try await socket.receive().count == 1023)
        try await socket.send(Data("size:\(kind):1024".utf8))
        #expect(try await socket.receive().count == 1024)
        try await socket.send(Data("size:\(kind):1025".utf8))
        await #expect(throws: AnnexTransportError.responseTooLarge) { _ = try await socket.receive() }
        let failure = try #require(telemetry.snapshot().records.first { $0.failure == .tooLarge })
        #expect(failure.measurements == ["webSocketMessageLimitBytes": 1024])
        await socket.close()
    }
}

@Test(.timeLimit(.minutes(1))) func cancelledPingResolvesWithoutAPongAndClosesTheSocket() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    _ = try await socket.receive() // greeting
    try await socket.send(Data("mute".utf8))
    #expect(text(try await socket.receive()) == "muted")
    let ping = Task { try await socket.ping() }
    // The server reports the ping instead of answering it, so the ping is provably in flight.
    #expect(text(try await socket.receive()) == "got-ping")
    ping.cancel()
    await #expect(throws: (any Error).self) { try await ping.value }
    // Cancelling an unanswered ping tears the socket down rather than leaving it half-alive.
    await #expect(throws: (any Error).self) { _ = try await socket.receive() }
}

@Test(.timeLimit(.minutes(1))) func anUnansweredPingTimesOutAfterTenSecondsAndClosesTheSocket() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let clock = AnnexManualClock()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: telemetry, clock: clock.clock)
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    _ = try await socket.receive() // greeting
    try await socket.send(Data("mute".utf8))
    #expect(text(try await socket.receive()) == "muted")
    let ping = Task { try await socket.ping() }
    #expect(text(try await socket.receive()) == "got-ping")
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(10))
    await #expect(throws: URLError(.timedOut)) { try await ping.value }
    #expect(telemetry.snapshot().records.contains { $0.operation == .ping && $0.failure != .none })
    #expect(telemetry.drainSummaries().first { $0.operation == .ping }?.failed == 1)
    // A ping that never came back means the path is dead: the socket is torn down.
    await #expect(throws: (any Error).self) { _ = try await socket.receive() }
}

@Test(.timeLimit(.minutes(1))) func closedSocketStopsReceivingAndBadRequestsNeverOpen() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let socket = try await io.openWebSocket(fixture.webSocketRequest())
    _ = try await socket.receive()
    await socket.close()
    await #expect(throws: (any Error).self) { _ = try await socket.receive() }
    // Only wss to the exact pinned endpoint may be opened.
    var plain = try fixture.webSocketRequest()
    plain.url = try fixture.host.endpoint.url(path: ["ws"])
    await #expect(throws: AnnexTransportError.invalidEndpoint) { _ = try await io.openWebSocket(plain) }
    var otherPort = try fixture.webSocketRequest()
    otherPort.url = URL(string: "wss://127.0.0.1:\(fixture.info.port == 1 ? 2 : 1)/ws")
    await #expect(throws: AnnexTransportError.invalidEndpoint) { _ = try await io.openWebSocket(otherPort) }
}

@Test(.timeLimit(.minutes(1))) func webSocketWithoutClientIdentityOrWithWrongPinNeverConnects() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let anonymous = PinnedAnnexIO(host: fixture.host, clientIdentity: nil, telemetry: AnnexTelemetry())
    let refused = try await anonymous.openWebSocket(fixture.webSocketRequest())
    await #expect(throws: (any Error).self) { _ = try await refused.receive() }
    let wrongHost = try TrustedAnnexHost(endpoint: fixture.host.endpoint, verifiedHostID: fixture.host.hostID,
                                         verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "00", count: 32)))
    let wrongPin = PinnedAnnexIO(host: wrongHost, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let untrusted = try await wrongPin.openWebSocket(fixture.webSocketRequest())
    await #expect(throws: (any Error).self) { _ = try await untrusted.receive() }
}

@Test(.timeLimit(.minutes(1))) func responseTraceContextInTheRequestsTraceIsRecorded() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: telemetry)
    var request = URLRequest(url: try fixture.host.endpoint.url(path: ["trace"]))
    request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
    let response = try await io.perform(request)
    #expect(response.status == 200)
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: response.data)["traced"] == .bool(true))
    let records = telemetry.snapshot().records
    let http = try #require(records.first { $0.operation == .http })
    let received = try #require(records.first { $0.operation == .response })
    #expect(received.traceID == http.traceID)
    #expect(received.measurements["statusCode"] == 200)
}

// MARK: OTLP sender

@Test(.timeLimit(.minutes(1))) func OTLPHTTPSenderParsesCollectorReplies() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let sender = AnnexOTLPHTTP()
    func post(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.info.httpPort)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        return request
    }
    let partial = try await sender.send(post("/ok"))
    #expect(partial.status == 200)
    #expect(partial.rejectedSpans == 2)
    let empty = try await sender.send(post("/empty"))
    #expect(empty.status == 200)
    #expect(empty.rejectedSpans == 0)
    let busy = try await sender.send(post("/busy"))
    #expect(busy.status == 429)
    #expect(busy.retryAfter == 7)
    // Redirects are surfaced, never followed.
    #expect(try await sender.send(post("/redirect")).status == 302)
    await #expect(throws: AnnexTransportError.malformedResponse) { try await sender.send(post("/bad")) }
    await #expect(throws: AnnexTransportError.responseTooLarge) { try await sender.send(post("/huge")) }
}
#endif

#if os(macOS)
private actor HeldReceiptIO: AnnexIO {
    let pinned: PinnedAnnexIO
    let host: TrustedAnnexHost
    var errorDomain: String?, errorCode: Int?
    private(set) var dispatches = 0
    init(pinned: PinnedAnnexIO, host: TrustedAnnexHost) { self.pinned = pinned; self.host = host }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        if request.url?.path.hasSuffix("capabilities") == true {
            return AnnexHTTPResponse(status: 200, data: Data(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":["chat.interrupt"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#.utf8))
        }
        dispatches += 1
        var held = request
        held.url = try host.endpoint.url(path: ["hold-command"])
        do { return try await pinned.perform(held) }
        catch { let value = error as NSError; errorDomain = value.domain; errorCode = value.code; throw error }
    }
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ANNEX_REAL_CADENCE_TESTS"] == "1"), .timeLimit(.minutes(2)))
func aHeldHTTPCommandReceiptTimesOutToOutcomeUnknownOnRealURLSession() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let io = HeldReceiptIO(pinned: PinnedAnnexIO(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry()), host: fixture.host)
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: fixture.host.hostID)
    let transport = AnnexTransport(host: fixture.host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
    _ = try await transport.read(.capabilities)
    let command = AnnexCommand(commandID: "held", epoch: "e", kind: .interrupt(agentID: "a", sessionID: "s"))
    let started = ContinuousClock.now
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "held")) { try await transport.execute(command) }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed >= .seconds(29) && elapsed < .seconds(70))
    #expect(await io.errorDomain == NSURLErrorDomain)
    #expect(await io.errorCode == URLError.timedOut.rawValue)
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "held")) { try await transport.execute(command) }
    #expect(await io.dispatches == 1)
    print("Real held HTTP receipt: \(await io.errorDomain ?? "") \(await io.errorCode ?? 0), elapsed=\(elapsed), execute=commandOutcomeUnknown; duplicate command not re-dispatched")
}
#endif

#if os(macOS)
@Test(.timeLimit(.minutes(2))) func actualLargeTerminalAndToolSizesHitTheProductionURLSessionLimit() async throws {
    let fixture = try WSFixture.start()
    defer { fixture.stop() }
    let delegate = AnnexPinnedSessionDelegate(host: fixture.host, clientIdentity: try socketIdentity.get(), telemetry: AnnexTelemetry())
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    for size in [1_247_805, 20 * 1024 * 1024, 26 * 1024 * 1024, 40 * 1024 * 1024, 66 * 1024 * 1024] {
        let task = session.webSocketTask(with: try fixture.webSocketRequest())
        task.maximumMessageSize = 16 * 1024 * 1024; task.resume()
        _ = try await task.receive()
        let started = ContinuousClock.now
        try await task.send(.string("size:text:\(size)"))
        do {
            let frame = try await task.receive()
            guard case .string(let value) = frame else { Issue.record("Expected text"); return }
            #expect(size < 16 * 1024 * 1024)
            #expect(value.utf8.count == size)
            print("Production-limit URLSession size \(size): accepted in \(ContinuousClock.now - started)")
        } catch {
            let value = error as NSError
            #expect(size > 16 * 1024 * 1024)
            #expect(value.domain == NSPOSIXErrorDomain && value.code == Int(EMSGSIZE))
            print("Production-limit URLSession size \(size): \(value.domain)/\(value.code) in \(ContinuousClock.now - started)")
        }
        task.cancel(with: .goingAway, reason: nil)
    }
}
#endif
