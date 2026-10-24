import Testing
import Foundation
@testable import ClubhouseTransport

private actor TestSocket: AnnexWebSocket {
    private var messages: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var sent: [Data] = []
    private(set) var closeCount = 0
    init() { messages = [Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)] }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ json: String) {
        let data = Data(json.utf8)
        if let pending { self.pending = nil; pending.resume(returning: data) }
        else { messages.append(data) }
    }
    func send(_ data: Data) { sent.append(data) }
    func ping() throws { if closed { throw AnnexTransportError.disconnected } }
    func close() {
        closeCount += 1; closed = true
        pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil
    }
}
private actor SessionIO: AnnexIO {
    private let identity: AnnexPairingIdentity
    private let unauthorized: Bool
    private(set) var sockets: [TestSocket] = []
    private(set) var requestCount = 0
    init(identity: AnnexPairingIdentity, unauthorized: Bool = false) { self.identity = identity; self.unauthorized = unauthorized }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requestCount += 1
        if unauthorized { return AnnexHTTPResponse(status: 401, data: Data()) }
        let body: AnnexJSON
        if request.url?.path.hasSuffix("identity") == true {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else {
            body = .object(["version": .integer(1), "epoch": .string("test-epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]),
                "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])])
        }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = TestSocket(); sockets.append(socket); return socket
    }
}
private func sessionFixture(unauthorized: Bool = false) async throws -> (AnnexTransport, SessionIO) {
    let identity = AnnexPairingIdentity()
    let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: fingerprint,
                                  verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: host.hostID)
    let io = SessionIO(identity: identity, unauthorized: unauthorized)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io, backoff: AnnexBackoff(initialSeconds: 0.05, maximumSeconds: 0.05))
    return (transport, io)
}

@Test func disconnectCancelsSocketAndPreventsReconnect() async throws {
    let (transport, io) = try await sessionFixture()
    let stream = await transport.events()
    try await transport.connect()
    for try await event in stream {
        if case .message(let envelope) = event, envelope.type == "snapshot" { break }
    }
    let socket = try #require(await io.sockets.first)
    // Replay requests preserve the negotiated host epoch and top-level 'since'.
    for _ in 0..<30 {
        if await !socket.sent.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let replay = try JSONDecoder().decode(AnnexJSON.self, from: #require(await socket.sent.first))
    #expect(replay["type"]?.string == "mobile:replay")
    #expect(replay["epoch"]?.string == "test-epoch")
    #expect(replay["since"]?.integer == 0)
    await transport.disconnect()
    try await Task.sleep(for: .milliseconds(150))
    #expect(await socket.closeCount >= 1)
    #expect(await io.sockets.count == 1)
}

@Test func unauthorizedStopsWithoutReconnectLoop() async throws {
    let (transport, io) = try await sessionFixture(unauthorized: true)
    let stream = await transport.events()
    try await transport.connect()
    for try await event in stream {
        if case .connection(.failed(let error)) = event { #expect(error == .unauthorized); break }
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(await io.requestCount == 1)
    #expect(await io.sockets.isEmpty)
    await transport.disconnect()
}

@Test func reconnectExplicitlyRequiresHistoryRefresh() async throws {
    let (transport, io) = try await sessionFixture()
    let stream = await transport.events()
    try await transport.connect()
    var snapshots = 0
    var needsRefresh = false
    for try await event in stream {
        if case .resyncRequired(.reconnected) = event { needsRefresh = true }
        if case .message(let envelope) = event, envelope.type == "snapshot" {
            snapshots += 1
            if snapshots == 1 { await io.sockets.first?.close() }
            else { break }
        }
    }
    #expect(needsRefresh)
    #expect(snapshots == 2)
    #expect(await io.sockets.count == 2)
    await transport.disconnect()
}

@Test func aheadRefreshReplaysFromLastDeliveredEvent() async throws {
    let (transport, io) = try await sessionFixture()
    let stream = await transport.events()
    try await transport.connect()
    var receivedInitial = false
    var sawGap = false
    for try await event in stream {
        if case .resyncRequired(.sequenceGap) = event { sawGap = true }
        if case .message(let envelope) = event, envelope.type == "snapshot" {
            if receivedInitial { break }
            receivedInitial = true
            await io.sockets.first?.push(#"{"type":"chat:event","seq":1,"payload":{}}"#)
            await io.sockets.first?.push(#"{"type":"snapshot","payload":{"lastSeq":3}}"#)
        }
    }
    let socket = try #require(await io.sockets.first)
    for _ in 0..<30 {
        if await socket.sent.count >= 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let replay = try JSONDecoder().decode(AnnexJSON.self, from: #require(await socket.sent.last))
    #expect(sawGap)
    #expect(replay["since"]?.integer == 1)
    await transport.disconnect()
}

@Test func malformedSnapshotFailsClosedWithoutReconnectLoop() async throws {
    let (transport, io) = try await sessionFixture()
    let stream = await transport.events()
    try await transport.connect()
    for try await event in stream {
        if case .message(let envelope) = event, envelope.type == "snapshot" {
            await io.sockets.first?.push(#"{"type":"snapshot","payload":{"lastSeq":-1}}"#)
        }
        if case .connection(.failed(let error)) = event {
            #expect(error == .malformedResponse); break
        }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await io.sockets.count == 1)
    await transport.disconnect()
}

@Test func lateDuplicateEventsAreNotDeliveredTwice() async throws {
    let (transport, io) = try await sessionFixture()
    let stream = await transport.events()
    try await transport.connect()
    var sequence: [Int64] = []
    for try await event in stream {
        if case .message(let envelope) = event {
            if envelope.type == "snapshot" {
                for value in [1, 2, 1, 2, 3] {
                    await io.sockets.first?.push("{\"type\":\"chat:event\",\"seq\":\(value)}")
                }
            } else if let seq = envelope.seq {
                sequence.append(seq)
                if seq == 3 { break }
            }
        }
    }
    #expect(sequence == [1, 2, 3])
    await transport.disconnect()
}

private actor HandshakeSocket: AnnexWebSocket {
    let supported: Bool
    private var messages = [Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)]
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var hellos: [AnnexJSON] = []
    init(supported: Bool) { self.supported = supported }
    func receive() async throws -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) throws {
        let message = try JSONDecoder().decode(AnnexJSON.self, from: data)
        guard message["type"]?.string == "telemetry:hello", let incoming = message["payload"] else { return }
        hellos.append(incoming)
        guard supported else { return }
        let ack: AnnexJSON = .object(["type": .string("telemetry:hello:ack"), "payload": .object([
            "version": .integer(1), "serviceName": .string("clubhouse"), "serviceInstanceId": .string("33333333-3333-4333-8333-333333333333"),
            "peerServiceInstanceId": incoming["serviceInstanceId"]!, "connectionAttemptId": incoming["connectionAttemptId"]!,
            "connectionId": .string(UUID().uuidString.lowercased()), "traceContext": .string("w3c-v00")])])
        messages.insert(try JSONEncoder().encode(ack), at: 0)
    }
    func ping() {}
    func close() { pending?.resume(throwing: CancellationError()); pending = nil }
}
private actor HandshakeSessionIO: AnnexIO {
    let identity: AnnexPairingIdentity
    let supported: Bool
    private(set) var sockets: [HandshakeSocket] = []
    init(identity: AnnexPairingIdentity, supported: Bool) { self.identity = identity; self.supported = supported }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let body: AnnexJSON
        if request.url?.path.hasSuffix("/identity") == true {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else {
            body = .object(["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]),
                "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])])
        }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = HandshakeSocket(supported: supported); sockets.append(socket); return socket
    }
}

@Test func transportNegotiatesPerSocketIdentityWithoutChangingLegacyOrOffBehavior() async throws {
    for supported in [true, false] {
        let identity = AnnexPairingIdentity()
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: hostID,
            verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
        let io = HandshakeSessionIO(identity: identity, supported: supported)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: telemetry)
        for iteration in 0..<3 {
            if iteration == 2 { telemetry.setEnabled(false) }
            let events = await transport.events()
            try await transport.connect()
            for try await event in events {
                if case .connection(.connected) = event { break }
            }
            if iteration < 2 {
                #expect(telemetry.snapshot().records.contains { $0.operation == .handshake && $0.identifiers["peer.service.instance.id"] != nil } == supported)
            }
            await transport.disconnect()
        }
        let sockets = await io.sockets
        #expect(sockets.count == 3)
        let first = await sockets[0].hellos, second = await sockets[1].hellos
        #expect(first.count == 1); #expect(second.count == 1)
        #expect(await sockets[2].hellos.isEmpty)
        #expect(first[0]["serviceInstanceId"] == second[0]["serviceInstanceId"])
        #expect(first[0]["connectionAttemptId"] != second[0]["connectionAttemptId"])
        #expect(first[0]["serviceInstanceId"]?.string == telemetry.instanceID.uuidString.lowercased())
    }
}
