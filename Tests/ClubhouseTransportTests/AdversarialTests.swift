import Foundation
import Testing
@testable import ClubhouseTransport

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
private let adversarialCapabilities = Data(#"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":["chat.send","chat.interrupt"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#.utf8)
private func adversarialHost() throws -> TrustedAnnexHost {
    try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "localhost", port: 4321),
                         verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                         verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
}
private actor GatedIO: AnnexIO {
    let entered = Gate()
    let release = Gate()
    private let gateCapabilities: Bool
    private let failCommand: Bool
    private(set) var postCount = 0
    init(gateCapabilities: Bool = false, failCommand: Bool = false) {
        self.gateCapabilities = gateCapabilities; self.failCommand = failCommand
    }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        if request.httpMethod == "POST" {
            postCount += 1
            await entered.release(); await release.wait()
            if failCommand { throw CancellationError() }
            let body = try JSONDecoder().decode(AnnexJSON.self, from: request.httpBody!)
            let receipt: AnnexJSON = .object(["version": .integer(1), "commandId": body["commandId"]!, "epoch": body["epoch"]!, "status": .string("completed")])
            return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(receipt))
        }
        if gateCapabilities { await entered.release(); await release.wait() }
        return AnnexHTTPResponse(status: 200, data: adversarialCapabilities)
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}
private actor GatedCredentials: AnnexCredentialStore {
    let entered = Gate()
    let release = Gate()
    private var shouldBlock = false
    private var credential: AnnexCredential? = try! AnnexCredential(bearerToken: "fake-only")
    func block() { shouldBlock = true }
    func credential(for hostID: String) async -> AnnexCredential? {
        if shouldBlock { await entered.release(); await release.wait() }
        return credential
    }
    func save(_ credential: AnnexCredential, for hostID: String) { self.credential = credential }
    func remove(for hostID: String) { credential = nil }
}

@Test func capabilityResponseAfterDisconnectCannotReenableCommands() async throws {
    let io = GatedIO(gateCapabilities: true)
    let transport = try AnnexTransport(host: adversarialHost(), credentials: GatedCredentials(), io: io)
    let read = Task { try await transport.read(.capabilities) }
    await io.entered.wait()
    await transport.disconnect()
    await io.release.release()
    await #expect(throws: AnnexTransportError.disconnected) { try await read.value }
    await #expect(throws: AnnexTransportError.unsupportedCapability("chat.interrupt")) {
        try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s")))
    }
    #expect(await io.postCount == 0)
}

@Test func disconnectDuringCredentialLookupPreventsCommandDispatch() async throws {
    let io = GatedIO()
    let credentials = GatedCredentials()
    let transport = try AnnexTransport(host: adversarialHost(), credentials: credentials, io: io)
    _ = try await transport.read(.capabilities)
    await credentials.block()
    let command = Task { try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .interrupt(agentID: "a", sessionID: "s"))) }
    await credentials.entered.wait()
    await transport.disconnect()
    await credentials.release.release()
    await io.release.release()
    await #expect(throws: AnnexTransportError.disconnected) { try await command.value }
    #expect(await io.postCount == 0)
}

@Test func cancellationAfterDispatchRemainsUncertainAndCannotResend() async throws {
    let io = GatedIO(failCommand: true)
    let transport = try AnnexTransport(host: adversarialHost(), credentials: GatedCredentials(), io: io)
    _ = try await transport.read(.capabilities)
    let command = AnnexCommand(commandID: "cancelled", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "once"))
    let send = Task { try await transport.execute(command) }
    await io.entered.wait()
    send.cancel()
    await io.release.release()
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "cancelled")) { try await send.value }
    await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: "cancelled")) { try await transport.execute(command) }
    #expect(await io.postCount == 1)
}

@Test func definitiveReceiptWinsDisconnectAndCancellationRace() async throws {
    let io = GatedIO()
    let transport = try AnnexTransport(host: adversarialHost(), credentials: GatedCredentials(), io: io)
    _ = try await transport.read(.capabilities)
    let command = AnnexCommand(commandID: "acknowledged", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "once"))
    let send = Task { try await transport.execute(command) }
    await io.entered.wait()
    await transport.disconnect(); send.cancel()
    await io.release.release()
    #expect(try await send.value.isDispatchAcknowledged)
    #expect(try await transport.execute(command).isDispatchAcknowledged)
    #expect(await io.postCount == 1)
}

@Test func refreshSnapshotsCannotRewindCursorOrSkipChatDeltas() {
    var cursor = AnnexReplayCursor()
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 10)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 11)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 10)) == .duplicate)
    #expect(cursor.lastSequence == 11)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 11)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 13)) == .resync(.sequenceGap))
    #expect(cursor.lastSequence == 11)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 12, replayed: true)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 13, replayed: true)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: 12)) == .duplicate)
    cursor.beginConnection()
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 0)) == .resync(.serverRestart))
}

@Test func malformedSnapshotNeverPoisonsCursorOrOverflowsArithmetic() {
    var cursor = AnnexReplayCursor()
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: -1)) == .resync(.sequenceGap))
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot")) == .resync(.sequenceGap))
    #expect(cursor.lastSequence == nil)
    #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 0)) == .deliver)
    #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: Int64.max)) == .resync(.sequenceGap))
    #expect(cursor.lastSequence == 0)
}

private actor GatedPairings: AnnexPairingStore {
    let entered = Gate()
    let release = Gate()
    private var saved: AnnexSavedPairing?
    init(_ saved: AnnexSavedPairing) { self.saved = saved }
    func loadAll() async -> [AnnexSavedPairing] {
        let snapshot = saved.map { [$0] } ?? []
        await entered.release(); await release.wait()
        return snapshot
    }
    func save(_ pairing: AnnexSavedPairing) { saved = pairing }
    func remove(hostID: String) { saved = nil }
}
@Test func removedPairingCannotBeResurrectedByInFlightRestore() async throws {
    let host = try adversarialHost()
    let saved = try AnnexSavedPairing(host: host, alias: "Fake", identity: AnnexClientIdentity.ephemeral(), credential: AnnexCredential(bearerToken: "fake-only"))
    let pairings = GatedPairings(saved)
    let credentials = MemoryAnnexCredentialStore()
    let registry = AnnexTransportRegistry(credentials: credentials, pairings: pairings)
    let restore = Task { try await registry.restoreSaved() }
    await pairings.entered.wait()
    try await registry.remove(hostID: host.hostID)
    await pairings.release.release()
    #expect(try await restore.value.isEmpty)
    #expect(await registry.all().isEmpty)
    #expect(await credentials.credential(for: host.hostID) == nil)
}

private actor PairResponseIO: AnnexIO {
    let response: Data
    init(_ response: Data) { self.response = response }
    func perform(_ request: URLRequest) -> AnnexHTTPResponse { AnnexHTTPResponse(status: 200, data: response) }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}
@Test func sessionOnlyPairingNeverWritesInjectedDurableCredentialsAndRemovesOldRecord() async throws {
    let server = AnnexPairingIdentity()
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "localhost", port: 4321),
                                   verifiedHostID: AnnexPairingIdentity.fingerprint(publicKeyBase64: server.publicKeyBase64),
                                   verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let identity = try AnnexClientIdentity.ephemeral()
    let credential = try AnnexCredential(bearerToken: "fake-only")
    let durable = MemoryAnnexCredentialStore() // fake substitute for a caller-supplied persistent store
    await durable.save(credential, for: host.hostID)
    let pairings = MemoryAnnexPairingStore()
    await pairings.save(AnnexSavedPairing(host: host, alias: "Old", identity: identity, credential: credential))
    let body: AnnexJSON = .object(["token": .string("fake-session-only"), "publicKey": .string(server.publicKeyBase64),
        "fingerprint": .string(host.hostID), "alias": .string("Fake"), "tlsCertificateFingerprint": .string(host.certificatePin.sha256),
        "mobileProtocolVersion": .integer(1), "pairingMode": .string("session")])
    let io = try PairResponseIO(JSONEncoder().encode(body))
    let registry = AnnexTransportRegistry(credentials: durable, pairings: pairings, pairingIO: { _, _ in io })
    _ = try await registry.pair(host: host, pin: "123456", alias: "Fake", clientIdentity: identity, persistence: .sessionOnly)
    #expect(await durable.credential(for: host.hostID) == nil)
    #expect(await pairings.loadAll().isEmpty)
    #expect(await registry.all().count == 1)
    try await registry.remove(hostID: host.hostID)
    #expect(await registry.all().isEmpty)
}
