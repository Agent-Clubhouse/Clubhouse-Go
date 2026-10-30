import Foundation
import Testing
@testable import ClubhouseTransport

// AnnexTransportRegistry: restoration, explicit session revocation, busy-host exclusion,
// durable pairing and disconnectAll, through injected pairing IO (never real TLS).

private actor RegistryGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private struct Desktop {
    let server = AnnexPairingIdentity()
    let host: TrustedAnnexHost
    init(port: UInt16 = 4321) throws {
        host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: port),
                                    verifiedHostID: AnnexPairingIdentity.fingerprint(publicKeyBase64: server.publicKeyBase64),
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    }
    func pairBody(mode: String) throws -> Data {
        try JSONEncoder().encode(AnnexJSON.object(["token": .string("fake-\(mode)"), "publicKey": .string(server.publicKeyBase64),
            "fingerprint": .string(host.hostID), "alias": .string("Desk"), "tlsCertificateFingerprint": .string(host.certificatePin.sha256),
            "mobileProtocolVersion": .integer(1), "pairingMode": .string(mode)]))
    }
}

private let revocableCapabilities = Data(#"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"pairing":{"sessionRevokePath":"/api/v1/mobile/pairing"},"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}}"#.utf8)

/// Answers pairing, capabilities and the revocation DELETE; pairing may be held open to make the host busy.
private actor RegistryIO: AnnexIO {
    let pairBody: Data
    let revokeResponse: AnnexHTTPResponse
    let entered = RegistryGate()
    let release = RegistryGate()
    private let gatePairing: Bool
    private(set) var deletes = 0
    init(pairBody: Data, revokeStatus: Int = 200, gatePairing: Bool = false) {
        self.pairBody = pairBody; self.gatePairing = gatePairing
        let receipt = revokeStatus == 200 ? #"{"version":1,"epoch":"epoch1","revoked":true,"pairingMode":"session"}"# : #"{"error":"persistent_pairing_requires_desktop"}"#
        revokeResponse = AnnexHTTPResponse(status: revokeStatus, data: Data(receipt.utf8))
    }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        if path == "/pair" {
            if gatePairing { await entered.release(); await release.wait() }
            return AnnexHTTPResponse(status: 200, data: pairBody)
        }
        if path.hasSuffix("/capabilities") { return AnnexHTTPResponse(status: 200, data: revocableCapabilities) }
        if request.httpMethod == "DELETE", path == "/api/v1/mobile/pairing" { deletes += 1; return revokeResponse }
        return AnnexHTTPResponse(status: 404, data: Data())
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

/// RSA key generation costs about a second; one throwaway identity serves every test here.
private let registryIdentity = Result { try AnnexClientIdentity.ephemeral() }

private func savedPairing(_ desktop: Desktop, alias: String = "Saved") throws -> AnnexSavedPairing {
    try AnnexSavedPairing(host: desktop.host, alias: alias, identity: registryIdentity.get(), credential: AnnexCredential(bearerToken: "fake-saved"))
}

@Test func restoreNeedsAStoredCredentialAndReplacesThePreviousTransport() async throws {
    let desktop = try Desktop()
    let credentials = MemoryAnnexCredentialStore()
    let registry = AnnexTransportRegistry(credentials: credentials)
    let identity = try registryIdentity.get()
    await #expect(throws: AnnexTransportError.credentialMissing) {
        try await registry.restore(host: desktop.host, alias: "Desk", clientIdentity: identity)
    }
    #expect(await registry.all().isEmpty)
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: desktop.host.hostID)
    let first = try await registry.restore(host: desktop.host, alias: "Desk", clientIdentity: identity)
    #expect(first.alias == "Desk")
    var firstEvents = await first.transport.events().makeAsyncIterator()
    #expect(try await firstEvents.next() == .connection(.disconnected))
    let second = try await registry.restore(host: desktop.host, alias: "Renamed", clientIdentity: identity)
    // The superseded transport is disconnected, and only the new one is registered.
    #expect(try await firstEvents.next() == .connection(.disconnected))
    #expect(await registry.all().map(\.alias) == ["Renamed"])
    #expect(await registry.routes(for: desktop.host.hostID) == [desktop.host.endpoint])
    #expect(second.host == desktop.host)
}

@Test func busyHostRefusesRestoreRevokeRemoveAndRepair() async throws {
    let desktop = try Desktop()
    let io = RegistryIO(pairBody: try desktop.pairBody(mode: "session"), gatePairing: true)
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: desktop.host.hostID)
    let registry = AnnexTransportRegistry(credentials: credentials, pairings: nil, pairingIO: { _, _ in io })
    let pairing = Task { try await registry.pair(host: desktop.host, pin: "123456", alias: "Phone", clientIdentity: registryIdentity.get()) }
    await io.entered.wait()
    let identity = try registryIdentity.get()
    await #expect(throws: AnnexTransportError.commandInFlight) { try await registry.restore(host: desktop.host, alias: "Desk", clientIdentity: identity) }
    await #expect(throws: AnnexTransportError.commandInFlight) { try await registry.revokeSessionAndRemove(hostID: desktop.host.hostID) }
    await #expect(throws: AnnexTransportError.commandInFlight) { try await registry.remove(hostID: desktop.host.hostID) }
    await #expect(throws: AnnexTransportError.commandInFlight) {
        try await registry.pair(host: desktop.host, pin: "123456", alias: "Phone", clientIdentity: registryIdentity.get())
    }
    await io.release.release()
    _ = try await pairing.value
    #expect(await registry.all().count == 1)
    #expect(await io.deletes == 0)
}

@Test func revokingAnUnknownHostIsCredentialMissing() async throws {
    let registry = AnnexTransportRegistry()
    await #expect(throws: AnnexTransportError.credentialMissing) {
        try await registry.revokeSessionAndRemove(hostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef")
    }
}

@Test func sessionRevocationRemovesEverythingOnlyAfterTheDesktopConfirms() async throws {
    let desktop = try Desktop()
    let io = RegistryIO(pairBody: try desktop.pairBody(mode: "session"))
    let credentials = MemoryAnnexCredentialStore()
    let pairings = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: credentials, pairings: pairings, pairingIO: { _, _ in io })
    try await registry.pair(host: desktop.host, pin: "123456", alias: "Phone", clientIdentity: registryIdentity.get())
    try await registry.revokeSessionAndRemove(hostID: desktop.host.hostID)
    #expect(await io.deletes == 1)
    #expect(await registry.all().isEmpty)
    #expect(await registry.transport(for: desktop.host.hostID) == nil)
    #expect(await credentials.credential(for: desktop.host.hostID) == nil)
    // Removed again: nothing left to revoke.
    await #expect(throws: AnnexTransportError.credentialMissing) { try await registry.revokeSessionAndRemove(hostID: desktop.host.hostID) }
}

@Test func refusedRevocationPreservesTheRegistration() async throws {
    let desktop = try Desktop()
    let io = RegistryIO(pairBody: try desktop.pairBody(mode: "session"), revokeStatus: 409)
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: nil, pairingIO: { _, _ in io })
    try await registry.pair(host: desktop.host, pin: "123456", alias: "Phone", clientIdentity: registryIdentity.get())
    await #expect(throws: AnnexTransportError.rejected(status: 409, code: "persistent_pairing_requires_desktop")) {
        try await registry.revokeSessionAndRemove(hostID: desktop.host.hostID)
    }
    #expect(await registry.all().count == 1)
    // The host is no longer busy after the failure.
    try await registry.remove(hostID: desktop.host.hostID)
    #expect(await registry.all().isEmpty)
}

@Test func persistentPairingSavesHostIdentityCredentialAndAlternateRoutes() async throws {
    let desktop = try Desktop()
    let io = RegistryIO(pairBody: try desktop.pairBody(mode: "persistent"))
    let credentials = MemoryAnnexCredentialStore()
    let pairings = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: credentials, pairings: pairings, pairingIO: { _, _ in io })
    let tailscale = try AnnexEndpoint(host: "desk.tail0.ts.net", port: 4321, route: .tailscale)
    let routes = [desktop.host.endpoint, tailscale, tailscale]
    let registration = try await registry.pair(host: desktop.host, pin: "123456", alias: "Phone", label: "", routes: routes, clientIdentity: registryIdentity.get(), persistence: .persistent)
    #expect(registration.alias == "Desk") // an empty label keeps the desktop's own alias
    let saved = try #require(await pairings.loadAll().first)
    #expect(saved.host == desktop.host)
    #expect(saved.alias == "Desk")
    #expect(saved.routes == [tailscale]) // the current address and duplicates are dropped
    #expect(saved.credential == (try AnnexCredential(bearerToken: "fake-persistent")))
    #expect(await credentials.credential(for: desktop.host.hostID) != nil)
    #expect(await registry.routes(for: desktop.host.hostID) == [desktop.host.endpoint, tailscale])
}

@Test func disconnectAllDisconnectsEveryRegisteredTransport() async throws {
    let first = try Desktop(port: 4321), second = try Desktop(port: 4322)
    let pairings = MemoryAnnexPairingStore()
    await pairings.save(try savedPairing(first, alias: "One"))
    await pairings.save(try savedPairing(second, alias: "Two"))
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: pairings)
    let restored = try await registry.restoreSaved()
    #expect(Set(restored.map(\.alias)) == ["One", "Two"])
    var iterators: [AsyncThrowingStream<AnnexTransportEvent, Error>.AsyncIterator] = []
    for registration in restored {
        var iterator = await registration.transport.events().makeAsyncIterator()
        #expect(try await iterator.next() == .connection(.disconnected))
        iterators.append(iterator)
    }
    await registry.disconnectAll()
    for index in iterators.indices {
        #expect(try await iterators[index].next() == .connection(.disconnected))
    }
    // Restoring again is a no-op for hosts that are already registered.
    #expect(try await registry.restoreSaved().count == 2)
}
