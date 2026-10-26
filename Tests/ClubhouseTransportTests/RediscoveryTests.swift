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
