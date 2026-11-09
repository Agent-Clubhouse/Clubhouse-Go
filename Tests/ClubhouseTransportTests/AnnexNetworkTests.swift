import Foundation
import Testing
@testable import ClubhouseTransport

private let networkDate = "2026-11-08T10:00:00.000Z"
private let phonePairing = AnnexNetworkPairing(id: "phone-pair", joinedAt: networkDate)
private let phoneIdentity = Result { try AnnexClientIdentity.ephemeral() }
private let desktopA = Result { try AnnexClientIdentity.ephemeral() }
private let desktopB = Result { try AnnexClientIdentity.ephemeral() }

private func fixture(_ name: String) throws -> AnnexJSON {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/AnnexNetwork")
    return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: directory.appending(path: name + ".json")))
}

private func member(_ identity: AnnexClientIdentity, name: String = "Desktop", pairingID: String? = "desktop-pair", joinedAt: String = networkDate, isSelf: Bool = false) throws -> AnnexNetworkMember {
    .init(fingerprint: try identity.fingerprint, publicKey: identity.pairingIdentity.publicKeyBase64, name: name, icon: "computer", color: "indigo", kind: "desktop",
          hosts: ["127.0.0.1", "studio.tail1234.ts.net"], port: 7432, certFingerprint: identity.certificateFingerprint,
          certPem: "-----BEGIN CERTIFICATE-----\n" + identity.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n",
          online: false, isSelf: isSelf, joinedAt: joinedAt, pairingId: pairingID)
}
private func snapshot(_ members: [AnnexNetworkMember], removals: [AnnexNetworkRemoval] = [], joined: Bool = true) -> AnnexNetworkSnapshot {
    .init(version: 1, joined: joined, members: members, removals: removals)
}
private func removal(_ id: String, pairingID: String? = "desktop-pair", joinedAt: String? = networkDate) -> AnnexNetworkRemoval {
    .init(fingerprint: id, removedAt: "2026-11-08T12:00:00.000Z", pairingId: pairingID, joinedAt: joinedAt)
}

private actor NetworkIO: AnnexIO {
    let desktop: AnnexClientIdentity
    var joined: Bool
    var view: AnnexNetworkSnapshot
    private(set) var requests: [URLRequest] = []
    init(_ desktop: AnnexClientIdentity, joined: Bool = true, view: AnnexNetworkSnapshot? = nil) throws {
        self.desktop = desktop; self.joined = joined
        self.view = try view ?? snapshot([member(desktop, isSelf: true)])
    }
    func setView(_ value: AnnexNetworkSnapshot) { view = value }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        let value: AnnexJSON
        if request.url?.path == "/pair" {
            let body = try JSONDecoder().decode(AnnexJSON.self, from: request.httpBody!)
            var fields: [String: AnnexJSON] = ["token": .string("test-only"), "alias": .string("Desktop"), "publicKey": .string(desktop.pairingIdentity.publicKeyBase64),
                "fingerprint": .string(try desktop.fingerprint), "tlsCertificateFingerprint": .string(desktop.certificateFingerprint),
                "mobileProtocolVersion": .integer(1), "pairingMode": body["pairingMode"]!]
            if joined, body["network"] == .integer(1) {
                fields["network"] = .integer(1)
                fields["pairing"] = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(phonePairing))
                fields["serverPairing"] = .object(["id": .string("desktop-pair"), "joinedAt": .string(networkDate)])
            }
            value = .object(fields)
        } else if request.httpMethod == "POST" {
            value = .object(["added": .array([]), "skipped": .array([])])
        } else if request.url?.path.hasSuffix("/network") == true {
            value = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(view))
        } else { return .init(status: 404, data: Data()) }
        return .init(status: 200, data: try JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

private func pairedNetwork(joined: Bool = true) async throws -> (AnnexTransportRegistry, MemoryAnnexPairingStore, NetworkIO, AnnexNetworkMember) {
    let a = try member(desktopA.get(), isSelf: true)
    let io = try NetworkIO(desktopA.get(), joined: joined)
    let store = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: store, pairingIO: { _, _ in io })
    try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    return (registry, store, io, a)
}

@Test func desktopNetworkFixturesDecodeWithoutChangingTheirWireRecords() throws {
    let pair = try fixture("network-pairing")
    #expect(pair["request"]?["body"]?["network"] == .integer(1))
    let pairing = try #require(pair["response"]?["body"]?["pairing"]).decode(AnnexNetworkPairing.self)
    #expect(pairing.id.hasSuffix("0025"))
    #expect(try #require(pair["response"]?["body"]?["serverPairing"]).decode(AnnexNetworkPairing.self).id.hasSuffix("0021"))
    let list = try fixture("network-list")
    let view = try #require(list["member"]?["response"]?["body"]).decode(AnnexNetworkSnapshot.self)
    #expect(view.joined && view.members.count == 3 && view.removals.count == 1)
    #expect(view.members[1].online == false && view.members[1].pairingId?.hasSuffix("0022") == true)
    #expect(!view.removals[0].ends(pairingID: "later", joinedAt: "2026-11-06T10:00:00.000Z"))
    let oneToOne = try #require(list["oneToOne"]?["response"]?["body"]).decode(AnnexNetworkSnapshot.self)
    #expect(!oneToOne.joined && oneToOne.members.count == 1)
    let envelope = try #require(fixture("network-changed")["frame"]).decode(AnnexEnvelope.self)
    #expect(envelope.type == "network:changed")
    #expect(try envelope.payload?.decode(AnnexNetworkSnapshot.self) == view)
    let posted = try #require(fixture("network-members")["accepted"]?["request"]?["body"]?["members"]).decode([AnnexNetworkMember].self)
    #expect(posted == view.members)
    #expect(try fixture("capabilities")["response"]?["body"]?.decode(AnnexCapabilities.self).supportsNetwork == true)
    // Fixture keys and certs are deliberately redacted, so they cannot establish trust.
    #expect(throws: AnnexTransportError.identityMismatch) { try view.members[0].trustedHost() }
}

@Test func persistentPairJoinsAndSessionBodyRetainsTheOriginalFieldsOnly() async throws {
    let (registry, store, io, a) = try await pairedNetwork()
    let request = try #require(await io.requests.first?.httpBody)
    let body = try JSONDecoder().decode(AnnexJSON.self, from: request)
    #expect(body["network"] == .integer(1) && body["selfPairing"] == nil)
    #expect(body["pairingMode"] == .string("persistent"))
    let saved = try #require(await store.loadAll().first)
    let restored = try AnnexSavedPairing.decode(saved.encoded())
    #expect(restored.network?.pairing == phonePairing)
    #expect(restored.network?.serverPairing?.id == "desktop-pair")
    #expect(restored.identity.certificateDER == (try phoneIdentity.get().certificateDER))
    // A later session is still a session, even on a network-enabled desktop.
    try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get())
    let session = try JSONDecoder().decode(AnnexJSON.self, from: #require(await io.requests.last?.httpBody))
    #expect(Optional(session).keys == ["pin", "publicKey", "alias", "icon", "color", "pairingMode"])
    #expect(session["pairingMode"] == .string("session"))
    #expect(await store.loadAll().isEmpty)
}

@Test func noNetworkReplyAndUnjoinedViewDoNotAddOrPersistMembership() async throws {
    let (registry, store, _, a) = try await pairedNetwork(joined: false)
    #expect(await store.loadAll().first?.network == nil)
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await registry.all().count == 1)
    let (memberRegistry, _, _, _) = try await pairedNetwork()
    try await memberRegistry.reconcileNetwork(snapshot([a, b], joined: false), from: a.fingerprint)
    #expect(await memberRegistry.all().count == 1)
    let caps = try JSONDecoder().decode(AnnexCapabilities.self, from: Data(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","commands":[],"idempotency":{"scope":"peer-and-epoch","maxEntries":1,"ttlMs":1}}"#.utf8))
    #expect(!caps.supportsNetwork)
}

@Test func memberAddsPinnedHostWithSharedIdentityAndNoPairRequestThenRestores() async throws {
    let (registry, store, io, a) = try await pairedNetwork()
    let b = try member(desktopB.get(), name: "Travel")
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await registry.all().count == 2)
    let learned = try #require(await store.loadAll().first { $0.host.hostID == b.fingerprint })
    #expect(learned.alias == "Travel" && learned.network?.learned == true)
    #expect(learned.identity.certificateDER == (try phoneIdentity.get().certificateDER))
    #expect(learned.host.certificatePin == (try b.trustedHost().certificatePin))
    #expect(await registry.routes(for: b.fingerprint).count == 2)
    #expect(await io.requests.filter { $0.url?.path == "/pair" }.count == 1)
    let restored = AnnexTransportRegistry(pairings: store)
    #expect(try await restored.restoreSaved().count == 2)
    #expect(await restored.routes(for: b.fingerprint).count == 2)
}

@Test func invalidIdentityOrCertificateRecordNeverCreatesAHost() async throws {
    let (registry, _, _, a) = try await pairedNetwork()
    let valid = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(member(desktopB.get())))
    for (field, bad) in [("fingerprint", a.fingerprint), ("certFingerprint", String(repeating: "00", count: 32)), ("certPem", "untrusted")] {
        guard case .object(var fields) = valid else { return }
        fields[field] = .string(bad)
        let altered = try AnnexJSON.object(fields).decode(AnnexNetworkMember.self)
        if field == "fingerprint" {
            // Existing host pin cannot be replaced by a network record either.
            await #expect(throws: AnnexTransportError.identityMismatch) { try await registry.reconcileNetwork(snapshot([altered]), from: a.fingerprint) }
        } else { try await registry.reconcileNetwork(snapshot([altered]), from: a.fingerprint) }
        #expect(await registry.all().count == 1)
    }
}

@Test func removalSurvivesReconnectRestartAndDoesNotEndALaterPairing() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    try await registry.reconcileNetwork(snapshot([a, b], removals: [removal(b.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: b.fingerprint) == nil)
    let restored = AnnexTransportRegistry(pairings: store)
    _ = try await restored.restoreSaved()
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await restored.all().count == 1)
    let repaired = try member(desktopB.get(), pairingID: "new-pair", joinedAt: "2026-11-08T10:01:00.000Z")
    try await restored.reconcileNetwork(snapshot([a, repaired], removals: [removal(b.fingerprint)]), from: a.fingerprint)
    #expect(await restored.all().count == 2)
    // An old pairing record from another member cannot roll this back.
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.network?.member?.pairingId == "new-pair")
}

@Test func qa341LaterSourcePairingSurvivesAnOlderRemovalInTheSameView() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let transportID = try #require(await registry.all().first { $0.host.hostID == b.fingerprint }).transportID
    let repaired = try member(desktopB.get(), pairingID: "new-pair", joinedAt: "2026-11-08T10:01:00.000Z", isSelf: true)
    try await registry.reconcileNetwork(snapshot([a, repaired], removals: [removal(b.fingerprint)]), from: b.fingerprint)
    #expect(await registry.transport(for: b.fingerprint) != nil)
    #expect(await registry.all().first { $0.host.hostID == b.fingerprint }?.transportID == transportID)
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.network?.member?.pairingId == "new-pair")
    let restored = AnnexTransportRegistry(pairings: store)
    #expect(try await restored.restoreSaved().count == 2)
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.network?.member?.pairingId == "new-pair")
}

@Test func newerMemberWithAnOlderRemovalCannotReplaceAKnownCertificatePin() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let trusted = try #require(await store.loadAll().first { $0.host.hostID == b.fingerprint })
    let attacker = try AnnexClientIdentity.ephemeral()
    let forged = AnnexNetworkMember(fingerprint: b.fingerprint, publicKey: b.publicKey, name: b.name, icon: b.icon, color: b.color, kind: b.kind,
        hosts: ["attacker.invalid"], port: 9443, certFingerprint: attacker.certificateFingerprint,
        certPem: "-----BEGIN CERTIFICATE-----\n" + attacker.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n",
        online: true, isSelf: false, joinedAt: "2026-11-08T10:01:00.000Z", pairingId: "forged-pairing")
    await #expect(throws: AnnexTransportError.identityMismatch) {
        try await registry.reconcileNetwork(snapshot([a, forged], removals: [removal(b.fingerprint)]), from: a.fingerprint)
    }
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.host == trusted.host)
    #expect(await registry.routes(for: b.fingerprint).allSatisfy { $0.host != "attacker.invalid" })
}

@Test func removedSourceCannotVouchForAnUnknownDesktopInItsLastView() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    let c = try member(AnnexClientIdentity.ephemeral())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let updatedA = a.keepingPairing(id: "new-a-pair", joinedAt: "2026-11-08T10:01:00.000Z")
    try await registry.reconcileNetwork(snapshot([updatedA, c], removals: [removal(b.fingerprint)]), from: b.fingerprint)
    #expect(await registry.all().map(\.host.hostID) == [a.fingerprint])
    #expect(await store.loadAll().map(\.host.hostID) == [a.fingerprint])
    #expect(await store.loadAll().first?.network?.member?.pairingId == "new-a-pair")
}

@Test func removalComparesPairingStampsRatherThanRemovalTimeOrPhoneClock() {
    let r = removal("f")
    #expect(r.ends(pairingID: "desktop-pair", joinedAt: "2099-01-01T00:00:00Z"))
    #expect(r.ends(pairingID: nil, joinedAt: "2099-01-01T00:00:00Z"))
    #expect(r.ends(pairingID: "other", joinedAt: "2026-11-08T09:59:00Z"))
    #expect(!r.ends(pairingID: "new", joinedAt: "2026-11-08T10:01:00Z"))
    let legacy = removal("f", pairingID: nil, joinedAt: nil)
    #expect(legacy.ends(pairingID: "any", joinedAt: "2026-11-08T11:59:00Z"))
    #expect(!legacy.ends(pairingID: "any", joinedAt: "2026-11-08T12:01:00Z"))
}

@Test func phoneRemovalTakesNothingElseFromTheViewAndForgetsAllNetworkHosts() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b], removals: [removal(try phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]), from: a.fingerprint)
    #expect(await registry.all().isEmpty)
    #expect(await store.loadAll().isEmpty)
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await registry.all().isEmpty)
}

@Test func onlyAllExplicitPeerNotPairedRefusalsForgetTheNetwork() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    try await registry.networkPeerNotPaired(hostID: a.fingerprint)
    #expect(await registry.all().count == 2)
    // A successful authenticated read clears that desktop's earlier refusal.
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    try await registry.networkPeerNotPaired(hostID: b.fingerprint)
    #expect(await registry.all().count == 2)
    try await registry.networkPeerNotPaired(hostID: a.fingerprint)
    #expect(await registry.all().isEmpty)
    #expect(await store.loadAll().isEmpty)
}

@Test func secondDesktopKeepsPhonePairingAndExchangesUnmodifiedMemberRecordsBothWays() async throws {
    let a = try member(desktopA.get(), isSelf: true)
    let b = try member(desktopB.get(), isSelf: true)
    let ioA = try NetworkIO(desktopA.get(), view: snapshot([a]))
    let ioB = try NetworkIO(desktopB.get(), view: snapshot([b]))
    let store = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: store, pairingIO: { host, _ in host.hostID == a.fingerprint ? ioA : ioB })
    try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    try await registry.pair(host: b.trustedHost(), pin: "123456", alias: "Phone", persistence: .persistent)
    let body = try JSONDecoder().decode(AnnexJSON.self, from: #require(await ioB.requests.first?.httpBody))
    #expect(try body["selfPairing"]?.decode(AnnexNetworkPairing.self) == phonePairing)
    #expect(body["publicKey"] == .string(try phoneIdentity.get().pairingIdentity.publicKeyBase64))
    await registry.introduceNetworkMembers()
    let toA = try #require(await ioA.requests.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/members") == true })
    let toB = try #require(await ioB.requests.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/members") == true })
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: toA.httpBody!)["members"]?.decode([AnnexNetworkMember].self) == [b])
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: toB.httpBody!)["members"]?.decode([AnnexNetworkMember].self) == [a])
    #expect(toA.value(forHTTPHeaderField: "Authorization") == nil && toB.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(await store.loadAll().allSatisfy { $0.network?.needsIntroduction == false })
}

@Test func restorationHonorsJournalEvenIfErasingAMemberWasInterrupted() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    var savedB = try #require(await store.loadAll().first { $0.host.hostID == b.fingerprint })
    savedB.network?.removals = [removal(b.fingerprint)]
    await store.save(savedB)
    let restored = AnnexTransportRegistry(pairings: store)
    #expect(try await restored.restoreSaved().map(\.host.hostID) == [a.fingerprint])
    #expect(await store.loadAll().count == 1)
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await restored.all().count == 1)
    // A leave marker in any surviving item also blocks network restoration.
    var savedA = try #require(await store.loadAll().first)
    savedA.network?.removals = [removal(try phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]
    await store.save(savedA)
    let removedPhone = AnnexTransportRegistry(pairings: store)
    #expect(try await removedPhone.restoreSaved().isEmpty)
    #expect(await store.loadAll().isEmpty)
}

@Test func samePairingIdAndUnstampedRecordsCannotMoveTheDesktopJoinTime() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let moved = a.keepingPairing(id: "desktop-pair", joinedAt: "2099-01-01T00:00:00Z")
    try await registry.reconcileNetwork(snapshot([moved]), from: a.fingerprint)
    #expect(await store.loadAll().first?.network?.member?.joinedAt == networkDate)
    let noID = a.keepingPairing(id: nil, joinedAt: "2100-01-01T00:00:00Z")
    try await registry.reconcileNetwork(snapshot([noID]), from: a.fingerprint)
    #expect(await store.loadAll().first?.network?.member?.pairingId == "desktop-pair")
    #expect(await store.loadAll().first?.network?.member?.joinedAt == networkDate)
}

@Test func routesAndRelocationKeepNetworkStampsAndLegacyArchivesRemainOneToOne() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    try await registry.learnRoutes(hostID: a.fingerprint, [AnnexEndpoint.advertised(host: "other.tail1234.ts.net", port: 7432)])
    _ = try await registry.relocate(hostID: a.fingerprint, to: AnnexEndpoint.advertised(host: "other.tail1234.ts.net", port: 7432))
    let saved = try #require(await store.loadAll().first)
    #expect(saved.network?.pairing == phonePairing && saved.network?.serverPairing?.id == "desktop-pair")
    var archive = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
    archive.removeValue(forKey: "network")
    let legacy = try AnnexSavedPairing.decode(JSONSerialization.data(withJSONObject: archive))
    #expect(legacy.network == nil)
    #expect(legacy.host.certificatePin == saved.host.certificatePin)
}

@Test func HTTPPeerRemovalIsDistinctFromAnUnrelatedAuthenticationFailure() {
    let removed = AnnexHTTPResponse(status: 401, data: Data(#"{"error":"peer_not_paired"}"#.utf8))
    let unauthenticated = AnnexHTTPResponse(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))
    #expect(AnnexHTTPValidation.error(removed) == .rejected(status: 401, code: "peer_not_paired"))
    #expect(AnnexHTTPValidation.error(unauthenticated) == .unauthorized)
}

@Test func networkRemovalPreservesAnUnrelatedOneToOneHostAndNeverUpgradesIt() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try member(desktopB.get())
    // The injected server response is not tied to B, so seed the already-approved
    // one-to-one registration through its existing restoration API.
    let credential = try AnnexCredential(bearerToken: "one-to-one-only")
    try await store.save(AnnexSavedPairing(host: b.trustedHost(), alias: "One to one", identity: phoneIdentity.get(), credential: credential))
    _ = try await registry.restoreSaved()
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.network == nil)
    try await registry.reconcileNetwork(snapshot([a], removals: [removal(try phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]), from: a.fingerprint)
    #expect(await registry.all().map(\.host.hostID) == [b.fingerprint])
    #expect(await store.loadAll().map(\.host.hostID) == [b.fingerprint])
}
