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
    #expect(telemetry.snapshot().records.filter { $0.operation == .ping && $0.failure == .none }.count == 2)
    #expect(telemetry.snapshot().records.contains { $0.operation == .websocket })
    await socket.close()
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
