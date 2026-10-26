import Foundation
import Testing
@testable import ClubhouseTransport

private let hostID = "0c:58:38:3d:cd:b0:e0:89:72:8b:dc:b6:25:1d:71:43"
private let otherID = "aa:58:38:3d:cd:b0:e0:89:72:8b:dc:b6:25:1d:71:43"
private let pin = try! AnnexCertificatePin(sha256: String(repeating: "ab", count: 32))
private let impostorPin = try! AnnexCertificatePin(sha256: String(repeating: "cd", count: 32))

private func remembered(_ host: String = "old-name.local.") throws -> TrustedAnnexHost {
    try TrustedAnnexHost(endpoint: AnnexEndpoint(host: host, port: 57696), verifiedHostID: hostID, verifiedCertificatePin: pin)
}
private func candidate(_ host: String, fingerprint: String? = nil, port: UInt16 = 57696) throws -> AnnexDiscoveredHost {
    try AnnexDiscoveredHost(id: host, name: host, host: host, port: port,
                            txt: fingerprint.map { ["fingerprint": Data($0.utf8)] } ?? [:])
}
private actor ProbeLog {
    var probed: [String] = []
    func note(_ host: String) { probed.append(host) }
}

@Test func rediscoveryAcceptsOnlyTheAddressServingThePinnedCertificate() async throws {
    let log = ProbeLog()
    let pins = ["impostor.local.": impostorPin, "new-name.local.": pin]
    let found = await AnnexRediscovery.locate(try remembered(), in: [
        try candidate("impostor.local.", fingerprint: hostID),
        try candidate("new-name.local.", fingerprint: hostID),
    ]) { endpoint in
        await log.note(endpoint.host)
        guard let served = pins[endpoint.host] else { throw AnnexTransportError.disconnected }
        return served
    }
    // Advertising the right fingerprint is a hint only: the impostor's certificate is not the pinned one.
    #expect(found?.host == "new-name.local.")
    #expect(found?.port == 57696)
    #expect(await log.probed == ["impostor.local.", "new-name.local."])
}

@Test func rediscoveryIgnoresTheStaleAddressAndOtherDesktopsAndProbesHintedOnesFirst() async throws {
    let log = ProbeLog()
    let found = await AnnexRediscovery.locate(try remembered(), in: [
        try candidate("unhinted.local."),
        try candidate("old-name.local.", fingerprint: hostID),
        try candidate("other-desktop.local.", fingerprint: otherID),
        try candidate("hinted.local.", fingerprint: hostID),
    ]) { endpoint in
        await log.note(endpoint.host)
        return endpoint.host == "unhinted.local." ? pin : impostorPin
    }
    #expect(found?.host == "unhinted.local.")
    #expect(await log.probed == ["hinted.local.", "unhinted.local."])
}

@Test func rediscoveryFindsNothingWhenNoCandidateServesThePin() async throws {
    let found = await AnnexRediscovery.locate(try remembered(), in: [try candidate("a.local."), try candidate("b.local.")]) { _ in impostorPin }
    #expect(found == nil)
    let unreachable = await AnnexRediscovery.locate(try remembered(), in: [try candidate("a.local.")]) { _ in throw AnnexTransportError.disconnected }
    #expect(unreachable == nil)
}

@Test func relocatingASavedPairingKeepsItsTrustAndPersistsTheNewAddress() async throws {
    let host = try remembered()
    let identity = try AnnexClientIdentity.ephemeral()
    let credential = try AnnexCredential(bearerToken: "fake-only")
    let pairings = MemoryAnnexPairingStore()
    await pairings.save(AnnexSavedPairing(host: host, alias: "Mac", identity: identity, credential: credential))
    let registry = AnnexTransportRegistry(pairings: pairings)
    _ = try await registry.restoreSaved()

    let moved = try AnnexEndpoint(host: "new-name.local.", port: 57696, route: .localNetwork)
    let registration = try await registry.relocate(hostID: host.hostID, to: moved)
    #expect(registration.host.endpoint == moved)
    #expect(registration.host.hostID == host.hostID)
    #expect(registration.host.certificatePin == pin)
    #expect(registration.alias == "Mac")
    #expect(await registry.transport(for: host.hostID) != nil)
    let saved = try #require(await pairings.loadAll().first)
    #expect(saved.host.endpoint == moved)
    #expect(saved.host.certificatePin == pin)
    #expect(saved.credential == credential)
    #expect(saved.identity.certificateDER == identity.certificateDER)
    await #expect(throws: AnnexTransportError.credentialMissing) {
        try await registry.relocate(hostID: otherID, to: moved)
    }
}

// MARK: - Routes (home Wi-Fi and Tailscale)

private func lan() throws -> AnnexEndpoint { try .advertised(host: "192.168.1.26", port: 57696) }
private func tailnet() throws -> AnnexEndpoint { try .advertised(host: "100.81.200.13", port: 57696) }

@Test func advertisedAddressesAreClassifiedAsTailscaleOrLocal() throws {
    #expect(try lan().route == .localNetwork)
    #expect(try tailnet().route == .tailscale)
    #expect(try AnnexEndpoint.advertised(host: "mac.tail1234.ts.net", port: 1).route == .tailscale)
    #expect(try AnnexEndpoint.advertised(host: "100.63.0.1", port: 1).route == .localNetwork)
    #expect(try lan().sameAddress(as: AnnexEndpoint(host: "192.168.1.26", port: 57696, route: .manual)))
}

@Test func raceTakesTheFirstAnsweringRouteWhenHomeIsUnreachable() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let best = await AnnexRediscovery.firstAnswering(try remembered("192.168.1.26"), routes: [try lan(), try tailnet()], timeout: .seconds(5)) { endpoint in
        // Away from home: the LAN address never answers, Tailscale does quickly.
        if endpoint.route == .localNetwork { try await Task.sleep(for: .seconds(30)) }
        return pin
    }
    #expect(best?.host == "100.81.200.13")
    #expect(clock.now - start < .seconds(2), "Must not wait for the dead home address")
}

@Test func racePrefersTheEarlierRouteWhenBothAnswerWithinGrace() async throws {
    let best = await AnnexRediscovery.firstAnswering(try remembered("192.168.1.26"), routes: [try lan(), try tailnet()]) { endpoint in
        // At home Tailscale may answer a moment sooner; the LAN route is still preferred.
        if endpoint.route == .localNetwork { try await Task.sleep(for: .milliseconds(80)) }
        return pin
    }
    #expect(best?.host == "192.168.1.26")
}

@Test func raceRejectsRoutesServingAnotherCertificateAndEndsWhenAllFail() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let none = await AnnexRediscovery.firstAnswering(try remembered(), routes: [try lan(), try tailnet()], timeout: .seconds(5)) { endpoint in
        if endpoint.route == .tailscale { return impostorPin }
        throw AnnexTransportError.disconnected
    }
    #expect(none == nil)
    #expect(clock.now - start < .seconds(2), "All probes failed, so it must not wait for the timeout")
}

@Test func pairingsSavedBeforeRoutesStillLoad() throws {
    let record = AnnexSavedPairing(host: try remembered(), alias: "Mac", routes: [try tailnet()],
                                   identity: try AnnexClientIdentity.ephemeral(), credential: try AnnexCredential(bearerToken: "fake-only"))
    #expect(try AnnexSavedPairing.decode(record.encoded()).routes.map(\.host) == ["100.81.200.13"])
    var archive = try #require(try JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
    archive.removeValue(forKey: "routes")
    let legacy = try AnnexSavedPairing.decode(JSONSerialization.data(withJSONObject: archive))
    #expect(legacy.routes.isEmpty)
    #expect(legacy.host == record.host)
}

@Test func registryRemembersLearnsAndKeepsRoutesAcrossMoves() async throws {
    let host = try remembered("192.168.1.26")
    let identity = try AnnexClientIdentity.ephemeral()
    let credential = try AnnexCredential(bearerToken: "fake-only")
    let pairings = MemoryAnnexPairingStore()
    // Paired over nearby: only the home address is known at first.
    await pairings.save(AnnexSavedPairing(host: host, alias: "Mac", identity: identity, credential: credential))
    let registry = AnnexTransportRegistry(pairings: pairings)
    _ = try await registry.restoreSaved()
    #expect(await registry.routes(for: hostID).map(\.host) == ["192.168.1.26"])

    // The connected desktop reports its routes; Tailscale is learned and saved.
    let reported = AnnexCapabilities.Routes(hosts: ["192.168.1.26", "100.81.200.13"], port: 57696)
    try await registry.learnRoutes(hostID: hostID, reported.endpoints)
    #expect(await registry.routes(for: hostID).map(\.host) == ["192.168.1.26", "100.81.200.13"])
    #expect(await pairings.loadAll().first?.routes.map(\.host) == ["100.81.200.13"])

    // Away from home it moves to Tailscale and still knows the way back.
    _ = try await registry.relocate(hostID: hostID, to: try tailnet())
    #expect(await registry.routes(for: hostID).map(\.host) == ["100.81.200.13", "192.168.1.26"])
    let saved = try #require(await pairings.loadAll().first)
    #expect(saved.host.endpoint.host == "100.81.200.13")
    #expect(saved.routes.map(\.host) == ["192.168.1.26"])
    #expect(saved.host.certificatePin == pin)
}

@Test func capabilitiesDecodeRoutesAndToleratesTheirAbsence() throws {
    let base = #"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","commands":[],"idempotency":{"scope":"s","maxEntries":1,"ttlMs":1}"#
    let with = try JSONDecoder().decode(AnnexCapabilities.self, from: Data((base + #","routes":{"hosts":["192.168.1.26","100.81.200.13"],"port":57696}}"#).utf8))
    #expect(with.routes?.endpoints.map(\.route) == [.localNetwork, .tailscale])
    let without = try JSONDecoder().decode(AnnexCapabilities.self, from: Data((base + "}").utf8))
    #expect(without.routes == nil)
}
