import Testing
import Foundation
import Security
@testable import ClubhouseTransport

private let testFingerprint = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
private func testHost(_ host: String = "127.0.0.1") throws -> TrustedAnnexHost {
    try TrustedAnnexHost(endpoint: AnnexEndpoint(host: host, port: 4321), verifiedHostID: testFingerprint,
                         verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
}

@Test func endpointsEncodeIdentifiersAndRejectURLInjection() throws {
    let host = try AnnexEndpoint(host: "my-host.tail123.ts.net", port: 443, route: .tailscale)
    let url = try host.url(path: ["api", "agent/one?x=#%"], query: [URLQueryItem(name: "q", value: "a&b")])
    #expect(url.scheme == "https")
    #expect(url.absoluteString.contains("agent%2Fone%3Fx%3D%23%25"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a&b")
    for invalid in ["https://evil.test", "alice@evil.test", "evil.test/path", "evil.test?x", "evil.test#x", "foo bar"] {
        #expect(throws: AnnexTransportError.self) { try AnnexEndpoint(host: invalid, port: 443) }
    }
    #expect(throws: AnnexTransportError.self) { try AnnexEndpoint(host: "localhost", port: 0) }
}

@Test func ipv6AndScopedIPv6StayBracketed() throws {
    for value in ["::1", "[::1]", "fe80::1%en0"] {
        let endpoint = try AnnexEndpoint(host: value, port: 4321)
        let url = try endpoint.url(path: ["ws"], webSocket: true)
        #expect(url.scheme == "wss")
        #expect(url.port == 4321)
        #expect(url.absoluteString.contains("["))
    }
}

@Test func decodingCannotBypassEndpointOrPinValidation() throws {
    #expect(throws: Error.self) { try JSONDecoder().decode(AnnexEndpoint.self, from: Data(#"{"host":"bad/path","port":443,"route":"manual"}"#.utf8)) }
    #expect(throws: Error.self) { try JSONDecoder().decode(AnnexCertificatePin.self, from: Data(#"{"sha256":"short"}"#.utf8)) }
    #expect(throws: Error.self) { try testHost().endpoint.url(path: ["..", "pair"]) }
}

@Test func pinsUseFullCertificateSHA256() throws {
    let bytes = Data("public-test-certificate".utf8)
    let pin = try AnnexCertificatePin(sha256: AnnexCertificatePin.digest(bytes).uppercased())
    #expect(pin.matches(certificateDER: bytes))
    #expect(!pin.matches(certificateDER: Data("other".utf8)))
    #expect(throws: AnnexTransportError.self) { try AnnexCertificatePin(sha256: testFingerprint) }
}

@Test func topLevelReplayMetadataAndUnknownEventsSurvive() throws {
    let replay = try JSONDecoder().decode(AnnexEnvelope.self, from: Data(#"{"type":"replay:start","epoch":"epoch1","fromSeq":3,"toSeq":9,"count":7}"#.utf8))
    #expect(replay.replayUpperBound == 9)
    #expect(replay.count == 7)
    let unknown = try JSONDecoder().decode(AnnexEnvelope.self, from: Data(#"{"type":"future:thing","payload":{"id":9007199254740993},"seq":42}"#.utf8))
    #expect(unknown.payload?["id"]?.integer == 9007199254740993)
}

@Test func replayCursorDeduplicatesAndFlagsGapsRestarts() {
    var cursor = AnnexReplayCursor()
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", payload: .object(["lastSeq": .integer(10)]))) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 11)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 11, replayed: true)) == .duplicate)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 13)) == .resync(.sequenceGap))
    #expect(cursor.lastSequence == 11)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 0)) == .resync(.serverRestart))
    #expect(cursor.lastSequence == 0)
    #expect(cursor.accept(AnnexEnvelope(type: "replay:gap")) == .resync(.replayGap))
}

@Test func backoffIsBoundedAndJittered() {
    let backoff = AnnexBackoff(initialSeconds: 1, maximumSeconds: 30)
    #expect(backoff.delay(attempt: 1, randomUnit: 0) == 0.5)
    #expect(backoff.delay(attempt: 2, randomUnit: 1) == 2)
    #expect(backoff.delay(attempt: Int.max, randomUnit: 1) == 30)
    #expect(backoff.delay(attempt: 4, randomUnit: .nan).isFinite)
}

@Test func credentialsAreHostScopedAndRedacted() async throws {
    let store = MemoryAnnexCredentialStore()
    let secret = try AnnexCredential(bearerToken: "test-only-secret")
    await store.save(secret, for: "first")
    #expect(await store.credential(for: "second") == nil)
    #expect(!String(reflecting: secret).contains("test-only-secret"))
    await store.remove(for: "first")
    #expect(await store.credential(for: "first") == nil)
}

@Test func ephemeralClientIdentityHasBoundCertificateAndNoPersistence() throws {
    let identity = try AnnexClientIdentity.ephemeral()
    let cert = try #require(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
    var commonName: CFString?
    #expect(SecCertificateCopyCommonName(cert, &commonName) == errSecSuccess)
    #expect(commonName as String? == (try identity.fingerprint))
    let publicKey = try #require(SecCertificateCopyKey(cert))
    let attributes = try #require(SecKeyCopyAttributes(publicKey) as? [String: Any])
    #expect(attributes[kSecAttrKeySizeInBits as String] as? Int == 2048)
    #expect(identity.certificateFingerprint.count == 64)
}

private actor StubIO: AnnexIO {
    var requests: [URLRequest] = []
    var responses: [AnnexHTTPResponse]
    let failure: Bool
    init(responses: [AnnexHTTPResponse] = [], failure: Bool = false) { self.responses = responses; self.failure = failure }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        if !responses.isEmpty { return responses.removeFirst() }
        if failure { throw URLError(.networkConnectionLost) }
        throw AnnexTransportError.malformedResponse
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
}
private func jsonResponse(_ value: String, status: Int = 200) -> AnnexHTTPResponse { AnnexHTTPResponse(status: status, data: Data(value.utf8)) }
private let capabilityJSON = #"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","commands":["chat.send","chat.interrupt"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#
private func configured(io: StubIO, capacity: Int = 256) async throws -> AnnexTransport {
    let host = try testHost()
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-token"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io, eventCapacity: capacity)
}

@Test func typedCommandsMatchDesktopAndEncodeNoExtraFields() throws {
    let command = AnnexCommand(commandID: "cmd1", epoch: "epoch1", kind: .send(agentID: "agent1", sessionID: "session1", text: "Continue"))
    let value = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
    #expect(value["commandId"]?.string == "cmd1")
    #expect(value["type"]?.string == "chat.send")
    #expect(value["sessionId"]?.string == "session1")
    #expect(value["delivery"]?.string == "auto")
    #expect(value["clientCommandID"] == nil)
}

@Test func commandReceiptDeduplicationAndConflict() async throws {
    let io = StubIO(responses: [jsonResponse(capabilityJSON), jsonResponse(#"{"version":1,"commandId":"cmd1","epoch":"epoch1","status":"completed","result":{"delivery":"steer"}}"#)])
    let transport = try await configured(io: io)
    _ = try await transport.read(.capabilities)
    let command = AnnexCommand(commandID: "cmd1", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "go"))
    let receipt = try await transport.execute(command)
    #expect(receipt.isDispatchAcknowledged)
    #expect(try await transport.execute(command) == receipt)
    #expect(await io.count() == 2)
    await #expect(throws: AnnexTransportError.duplicateCommandConflict) {
        try await transport.execute(AnnexCommand(commandID: "cmd1", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
    let request = try #require(await io.last())
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    #expect(request.url?.query == nil)
}

@Test func lostReplyNeverAutomaticallyRetries() async throws {
    let io = StubIO(responses: [jsonResponse(capabilityJSON)], failure: true)
    let transport = try await configured(io: io)
    _ = try await transport.read(.capabilities)
    let command = AnnexCommand(commandID: "uncertain", epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s"))
    for _ in 0..<2 {
        await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "uncertain")) { try await transport.execute(command) }
    }
    #expect(await io.count() == 2)
}

@Test func staleEpochIsRejectedBeforeNetwork() async throws {
    let io = StubIO(responses: [jsonResponse(capabilityJSON)])
    let transport = try await configured(io: io)
    _ = try await transport.read(.capabilities)
    await #expect(throws: AnnexTransportError.self) {
        try await transport.execute(AnnexCommand(epoch: "old", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
    #expect(await io.count() == 1)
}

@Test func pairingValidatesHostPublicKeyBeforeSaving() async throws {
    let client = try AnnexClientIdentity.ephemeral()
    let server = AnnexPairingIdentity()
    let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: server.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "localhost", port: 4321), verifiedHostID: fingerprint,
                                   verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let body = try JSONEncoder().encode(AnnexJSON.object(["token": .string("fake-only"), "publicKey": .string(server.publicKeyBase64), "fingerprint": .string(fingerprint), "alias": .string("Test")]))
    let io = StubIO(responses: [AnnexHTTPResponse(status: 200, data: body)])
    let store = MemoryAnnexCredentialStore()
    let result = try await AnnexPairingClient(host: host, clientIdentity: client, credentials: store, io: io).pair(pin: "123456", alias: "Mobile")
    #expect(result.publicKey == server.publicKeyBase64)
    #expect(await store.credential(for: host.hostID) != nil)
    #expect(await io.last()?.url?.scheme == "https")
    let wrongStore = MemoryAnnexCredentialStore()
    let wrongIO = StubIO(responses: [AnnexHTTPResponse(status: 200, data: body)])
    await #expect(throws: AnnexTransportError.identityMismatch) {
        try await AnnexPairingClient(host: testHost(), clientIdentity: client, credentials: wrongStore, io: wrongIO).pair(pin: "123456", alias: "Mobile")
    }
    #expect(await wrongStore.credential(for: testFingerprint) == nil)
}

@Test func boundedEventStreamFailsInsteadOfDroppingSilently() async throws {
    let io = StubIO()
    let transport = try await configured(io: io, capacity: 1)
    let stream = await transport.events() // fills one slot with disconnected
    await transport.disconnect() // second event cannot fit
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == .connection(.disconnected))
    await #expect(throws: AnnexTransportError.queueOverflow) { try await iterator.next() }
}
