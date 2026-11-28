import Foundation
import Testing
@testable import ClubhouseTransport

private let networkDate = "2026-11-08T10:00:00.000Z"
private let phonePairing = AnnexNetworkPairing(id: "phone-pair", joinedAt: networkDate)
private let phoneIdentity = SharedEphemeralIdentity()
private let desktopA = SharedEphemeralIdentity()
private let desktopB = SharedEphemeralIdentity()

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
    var serverPairing = AnnexNetworkPairing(id: "desktop-pair", joinedAt: networkDate)
    private(set) var requests: [URLRequest] = []
    init(_ desktop: AnnexClientIdentity, joined: Bool = true, view: AnnexNetworkSnapshot? = nil) throws {
        self.desktop = desktop; self.joined = joined
        self.view = try view ?? snapshot([member(desktop, isSelf: true)])
    }
    func setView(_ value: AnnexNetworkSnapshot) { view = value }
    func setServerPairing(_ value: AnnexNetworkPairing) { serverPairing = value }
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
                fields["serverPairing"] = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(serverPairing))
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
    let a = try await member(desktopA.get(), isSelf: true)
    let io = try await NetworkIO(desktopA.get(), joined: joined)
    let store = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: store, pairingIO: { _, _ in io })
    try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    return (registry, store, io, a)
}

@Test func desktopNetworkFixturesDecodeWithoutChangingTheirWireRecords() throws {
    let pair = try AnnexContract.json("network-pairing.json")
    #expect(pair["request"]?["body"]?["network"] == .integer(1))
    let pairing = try #require(pair["response"]?["body"]?["pairing"]).decode(AnnexNetworkPairing.self)
    #expect(pairing.id.hasSuffix("0035"))
    #expect(try #require(pair["response"]?["body"]?["serverPairing"]).decode(AnnexNetworkPairing.self).id.hasSuffix("0031"))
    let list = try AnnexContract.json("network-list.json")
    let view = try #require(list["member"]?["response"]?["body"]).decode(AnnexNetworkSnapshot.self)
    #expect(view.joined && view.members.count == 3 && view.removals.count == 1)
    #expect(view.members[1].online == false && view.members[1].pairingId?.hasSuffix("0032") == true)
    #expect(!view.removals[0].ends(pairingID: "later", joinedAt: "2026-11-06T10:00:00.000Z"))
    let oneToOne = try #require(list["oneToOne"]?["response"]?["body"]).decode(AnnexNetworkSnapshot.self)
    #expect(!oneToOne.joined && oneToOne.members.count == 1)
    let envelope = try #require(AnnexContract.json("network-changed.json")["frame"]).decode(AnnexEnvelope.self)
    #expect(envelope.type == "network:changed")
    #expect(try envelope.payload?.decode(AnnexNetworkSnapshot.self) == view)
    let posted = try #require(AnnexContract.json("network-members.json")["accepted"]?["request"]?["body"]?["members"]).decode([AnnexNetworkMember].self)
    #expect(posted == view.members)
    #expect(try AnnexContract.json("capabilities.json")["response"]?["body"]?.decode(AnnexCapabilities.self).supportsNetwork == true)
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
    #expect(restored.identity.certificateDER == (try await phoneIdentity.get().certificateDER))
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
    let b = try await member(desktopB.get())
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
    let b = try await member(desktopB.get(), name: "Travel")
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await registry.all().count == 2)
    let learned = try #require(await store.loadAll().first { $0.host.hostID == b.fingerprint })
    #expect(learned.alias == "Travel" && learned.network?.learned == true)
    #expect(learned.identity.certificateDER == (try await phoneIdentity.get().certificateDER))
    #expect(learned.host.certificatePin == (try b.trustedHost().certificatePin))
    #expect(await registry.routes(for: b.fingerprint).count == 2)
    #expect(await io.requests.filter { $0.url?.path == "/pair" }.count == 1)
    let restored = AnnexTransportRegistry(pairings: store)
    #expect(try await restored.restoreSaved().count == 2)
    #expect(await restored.routes(for: b.fingerprint).count == 2)
}

@Test func invalidIdentityOrCertificateRecordNeverCreatesAHost() async throws {
    let (registry, _, _, a) = try await pairedNetwork()
    let valid = try await JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(member(desktopB.get())))
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
    let b = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    try await registry.reconcileNetwork(snapshot([a, b], removals: [removal(b.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: b.fingerprint) == nil)
    let restored = AnnexTransportRegistry(pairings: store)
    _ = try await restored.restoreSaved()
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await restored.all().count == 1)
    let repaired = try await member(desktopB.get(), pairingID: "new-pair", joinedAt: "2026-11-08T10:01:00.000Z")
    try await restored.reconcileNetwork(snapshot([a, repaired], removals: [removal(b.fingerprint)]), from: a.fingerprint)
    #expect(await restored.all().count == 2)
    // An old pairing record from another member cannot roll this back.
    try await restored.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await store.loadAll().first { $0.host.hostID == b.fingerprint }?.network?.member?.pairingId == "new-pair")
}

@Test func qa341LaterSourcePairingSurvivesAnOlderRemovalInTheSameView() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let transportID = try #require(await registry.all().first { $0.host.hostID == b.fingerprint }).transportID
    let repaired = try await member(desktopB.get(), pairingID: "new-pair", joinedAt: "2026-11-08T10:01:00.000Z", isSelf: true)
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
    let b = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let trusted = try #require(await store.loadAll().first { $0.host.hostID == b.fingerprint })
    let attacker = try await ephemeralIdentity()
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
    let b = try await member(desktopB.get())
    let c = try await member(ephemeralIdentity())
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    let updatedA = a.keepingPairing(id: "new-a-pair", joinedAt: "2026-11-08T10:01:00.000Z")
    try await registry.reconcileNetwork(snapshot([updatedA, c], removals: [removal(b.fingerprint)]), from: b.fingerprint)
    #expect(await registry.all().map(\.host.hostID) == [a.fingerprint])
    #expect(await store.loadAll().map(\.host.hostID) == [a.fingerprint])
    #expect(await store.loadAll().first?.network?.member?.pairingId == "new-a-pair")
    #expect(await store.loadAll().allSatisfy { $0.network?.observations?[c.fingerprint] == nil })
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
    let b = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, b], removals: [removal(try phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]), from: a.fingerprint)
    #expect(await registry.all().isEmpty)
    #expect(await store.loadAll().isEmpty)
    try await registry.reconcileNetwork(snapshot([a, b]), from: a.fingerprint)
    #expect(await registry.all().isEmpty)
}

@Test func onlyAllExplicitPeerNotPairedRefusalsForgetTheNetwork() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let b = try await member(desktopB.get())
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
    let a = try await member(desktopA.get(), isSelf: true)
    let b = try await member(desktopB.get(), isSelf: true)
    let ioA = try await NetworkIO(desktopA.get(), view: snapshot([a]))
    let ioB = try await NetworkIO(desktopB.get(), view: snapshot([b]))
    let store = MemoryAnnexPairingStore()
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: store, pairingIO: { host, _ in host.hostID == a.fingerprint ? ioA : ioB })
    try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    try await registry.pair(host: b.trustedHost(), pin: "123456", alias: "Phone", persistence: .persistent)
    let body = try JSONDecoder().decode(AnnexJSON.self, from: #require(await ioB.requests.first?.httpBody))
    #expect(try body["selfPairing"]?.decode(AnnexNetworkPairing.self) == phonePairing)
    #expect(body["publicKey"] == .string(try await phoneIdentity.get().pairingIdentity.publicKeyBase64))
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
    let b = try await member(desktopB.get())
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
    savedA.network?.removals = [removal(try await phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]
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
    let b = try await member(desktopB.get())
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

// Matches Clubhouse#3611: an addressless member has hosts:[] and no port.
// Only cryptographic placeholders are replaced with ephemeral test identities.
private func addressless3611(_ identity: AnnexClientIdentity) throws -> AnnexNetworkMember {
    let url = try #require(Bundle.module.url(forResource: "network-addressless-3611", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try Data(contentsOf: url)
    let fixture = try JSONDecoder().decode(AnnexNetworkSnapshot.self, from: raw)
    let shape = try #require(fixture.members.first)
    #expect(shape.hosts.isEmpty && shape.port == nil)
    let trusted = try member(identity)
    return AnnexNetworkMember(fingerprint: trusted.fingerprint, publicKey: trusted.publicKey, name: shape.name, icon: shape.icon, color: shape.color,
        kind: shape.kind, hosts: shape.hosts, port: shape.port, certFingerprint: trusted.certFingerprint, certPem: trusted.certPem,
        online: shape.online, isSelf: shape.isSelf, joinedAt: shape.joinedAt, pairingId: shape.pairingId)
}

private func altering(_ member: AnnexNetworkMember, _ fields: [String: AnnexJSON]) throws -> AnnexNetworkMember {
    let encoded = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(member))
    guard case .object(var object) = encoded else { throw AnnexTransportError.malformedResponse }
    for (key, value) in fields { object[key] = value }
    return try AnnexJSON.object(object).decode(AnnexNetworkMember.self)
}

// Serializes every item through the production archive codec. A new registry and
// credentials store therefore recover from durable bytes, not shared live state.
private actor ArchivedNetworkPairingStore: AnnexPairingStore {
    private var records: [String: Data] = [:]
    func loadAll() throws -> [AnnexSavedPairing] { try records.values.map(AnnexSavedPairing.decode) }
    func save(_ pairing: AnnexSavedPairing) throws { records[pairing.host.hostID] = try pairing.encoded() }
    func remove(hostID: String) { records.removeValue(forKey: hostID) }
    func saveRaw(_ data: Data, hostID: String) { records[hostID] = data }
    func raw(hostID: String) -> Data? { records[hostID] }
}

@Test(arguments: [false, true]) func addresslessNewerPairingPreventsOtherDesktopStaleRemovalWithoutChangingTrustOrRoutes(legacyPort: Bool) async throws {
    let (registry, store, io, sourceB) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    let sourceC = try await member(ephemeralIdentity(), name: "Lagging C")
    try await registry.reconcileNetwork(snapshot([sourceB, sourceC, f]), from: sourceB.fingerprint)
    let before = try #require(await store.loadAll().first { $0.host.hostID == f.fingerprint })
    let registration = try #require(await registry.all().first { $0.host.hostID == f.fingerprint })
    let routes = await registry.routes(for: f.fingerprint)
    let addressless = try await addressless3611(desktopB.get())
    let p2 = try legacyPort ? altering(addressless, ["port": .integer(7555)]) : addressless
    #expect(p2.endpoints.isEmpty)
    #expect(throws: AnnexTransportError.identityMismatch) { try p2.trustedHost() }
    try await registry.reconcileNetwork(snapshot([sourceB, p2]), from: sourceB.fingerprint)
    try await registry.reconcileNetwork(snapshot([sourceC], removals: [removal(f.fingerprint)]), from: sourceC.fingerprint)
    let after = try #require(await store.loadAll().first { $0.host.hostID == f.fingerprint })
    #expect(after.network?.serverPairing?.id == "P2")
    #expect(after.network?.member?.pairingId == "P2")
    #expect(after.host == before.host && after.routes == before.routes)
    #expect(after.credential == before.credential)
    #expect(after.identity.certificateDER == before.identity.certificateDER)
    #expect(await registry.routes(for: f.fingerprint) == routes)
    #expect(await registry.all().first { $0.host.hostID == f.fingerprint }?.transportID == registration.transportID)
    #expect(await io.requests.filter { $0.url?.path == "/pair" }.count == 1)
}

@Test(arguments: [false, true]) func durablyKnownAddresslessPairingSurvivesEitherSourceArrivalOrderAndOfflineCatchup(removalFirst: Bool) async throws {
    let (registry, memory, _, sourceB) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    let sourceC = try await member(ephemeralIdentity(), name: "C")
    try await registry.reconcileNetwork(snapshot([sourceB, sourceC, f]), from: sourceB.fingerprint)
    let p2 = try await addressless3611(desktopB.get())
    try await registry.reconcileNetwork(snapshot([sourceB, p2]), from: sourceB.fingerprint)
    let disk = ArchivedNetworkPairingStore()
    for saved in await memory.loadAll() { try await disk.save(saved) }
    let credentials = MemoryAnnexCredentialStore()
    let restarted = AnnexTransportRegistry(credentials: credentials, pairings: disk)
    #expect(try await restarted.restoreSaved().count == 3)
    let newer = snapshot([sourceB, p2])
    let lagging = snapshot([sourceC, f], removals: [removal(f.fingerprint)])
    if removalFirst {
        try await restarted.reconcileNetwork(lagging, from: sourceC.fingerprint)
        try await restarted.reconcileNetwork(newer, from: sourceB.fingerprint)
    } else {
        try await restarted.reconcileNetwork(newer, from: sourceB.fingerprint)
        try await restarted.reconcileNetwork(lagging, from: sourceC.fingerprint)
    }
    // The newer source can be offline indefinitely; repeated stale catch-up cannot
    // roll back its already observed generation, even through another restart.
    for _ in 0..<3 { try await restarted.reconcileNetwork(lagging, from: sourceC.fingerprint) }
    #expect(await credentials.credential(for: f.fingerprint) != nil)
    let savedF = try #require(try await disk.loadAll().first { $0.host.hostID == f.fingerprint })
    #expect(savedF.network?.member?.pairingId == "P2")
    #expect(savedF.network?.observations?[f.fingerprint]?.pairing.id == "P2")
    let again = AnnexTransportRegistry(pairings: disk)
    #expect(try await again.restoreSaved().count == 3)
    try await again.reconcileNetwork(lagging, from: sourceC.fingerprint)
    #expect(await again.transport(for: f.fingerprint) != nil)
}

@Test(arguments: [false, true]) func restartMergesObservationBeforeApplyingJournalWhenTargetItemWasNotYetSaved(observationInOtherItem: Bool) async throws {
    let (registry, memory, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let disk = ArchivedNetworkPairingStore()
    for saved in await memory.loadAll() { try await disk.save(saved) }
    // Interrupted multi-item commit: A has atomically received P1's removal and
    // P2's observation, while F still has its old P1 stamp and an empty journal.
    var savedA = try #require(try await disk.loadAll().first { $0.host.hostID == a.fingerprint })
    savedA.network?.removals = [removal(f.fingerprint)]
    let p2 = try await addressless3611(desktopB.get())
    let evidence = AnnexNetworkObservation(certFingerprint: p2.certFingerprint, pairing: .init(id: "P2", joinedAt: p2.joinedAt))
    if observationInOtherItem {
        var savedF = try #require(try await disk.loadAll().first { $0.host.hostID == f.fingerprint })
        savedF.network?.observations?[f.fingerprint] = evidence
        try await disk.save(savedF)
    } else { savedA.network?.observations?[f.fingerprint] = evidence }
    try await disk.save(savedA)
    #expect(try await disk.loadAll().first { $0.host.hostID == f.fingerprint }?.network?.member?.pairingId == "desktop-pair")
    let restored = AnnexTransportRegistry(pairings: disk)
    #expect(try await restored.restoreSaved().count == 2)
    let preserved = try #require(try await disk.loadAll().first { $0.host.hostID == f.fingerprint })
    #expect(preserved.network?.member?.pairingId == "P2")
    #expect(preserved.network?.removals == [removal(f.fingerprint)])
    #expect(preserved.network?.observations?[f.fingerprint] == evidence)
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 2)
}

@Test func unknownAddresslessMemberRetainsOnlyBoundedOrderingEvidenceUntilItHasRoutes() async throws {
    let (registry, memory, _, a) = try await pairedNetwork()
    let p2 = try await addressless3611(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, p2]), from: a.fingerprint)
    #expect(await registry.transport(for: p2.fingerprint) == nil)
    #expect(await registry.routes(for: p2.fingerprint).isEmpty)
    #expect(await memory.loadAll().count == 1)
    #expect(await memory.loadAll().first?.network?.observations?[p2.fingerprint]?.pairing.id == "P2")
    let disk = ArchivedNetworkPairingStore()
    for saved in await memory.loadAll() { try await disk.save(saved) }
    let restored = AnnexTransportRegistry(pairings: disk)
    _ = try await restored.restoreSaved()
    let routable = try await member(desktopB.get(), pairingID: "P2", joinedAt: p2.joinedAt)
    try await restored.reconcileNetwork(snapshot([a, routable], removals: [removal(p2.fingerprint)]), from: a.fingerprint)
    #expect(await restored.transport(for: p2.fingerprint) != nil)
    let authoritative = removal(p2.fingerprint, pairingID: "P2", joinedAt: p2.joinedAt)
    try await restored.reconcileNetwork(snapshot([a], removals: [authoritative]), from: a.fingerprint)
    #expect(await restored.transport(for: p2.fingerprint) == nil)
    #expect(try await disk.loadAll().allSatisfy { $0.network?.observations?[p2.fingerprint] == nil })
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 1)
}

@Test func explicitForgetAndPhoneRevocationStillEraseNewerAddresslessPairings() async throws {
    for revokePhone in [false, true] {
        let (registry, store, _, a) = try await pairedNetwork()
        let f = try await member(desktopB.get())
        try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
        try await registry.reconcileNetwork(snapshot([a, addressless3611(desktopB.get())]), from: a.fingerprint)
        if revokePhone {
            try await registry.reconcileNetwork(snapshot([a], removals: [removal(try phoneIdentity.get().fingerprint, pairingID: phonePairing.id)]), from: a.fingerprint)
            #expect(await store.loadAll().isEmpty)
        } else {
            try await registry.remove(hostID: f.fingerprint)
            #expect(await store.loadAll().allSatisfy { $0.network?.observations?[f.fingerprint] == nil })
            #expect(try await AnnexTransportRegistry(pairings: store).restoreSaved().count == 1)
        }
        #expect(await registry.transport(for: f.fingerprint) == nil)
        #expect(await registry.routes(for: f.fingerprint).isEmpty)
    }
}

@Test func malformedAddresslessEvidenceCannotProtectAnOldPairingFromRevocation() async throws {
    let valid = try await addressless3611(desktopB.get())
    let mutations: [[String: AnnexJSON]] = [
        ["publicKey": .string("invalid")], ["certPem": .string("invalid")],
        ["certFingerprint": .string(String(repeating: "00", count: 32))],
        ["joinedAt": .string("invalid")], ["pairingId": .string("")], ["kind": .string("phone")],
        ["hosts": .array([.string("https://invalid/path")]), "port": .integer(7432)],
        ["hosts": .array([.string("https://invalid/path")])], ["port": .integer(0)]
    ]
    for mutation in mutations {
        let (registry, store, _, a) = try await pairedNetwork()
        let f = try await member(desktopB.get())
        try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
        let bad = try altering(valid, mutation)
        do { try await registry.reconcileNetwork(snapshot([a, bad]), from: a.fingerprint) }
        catch { #expect(error as? AnnexTransportError == .identityMismatch) }
        #expect(await store.loadAll().first { $0.host.hostID == f.fingerprint }?.network?.serverPairing?.id == "desktop-pair")
        try await registry.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
        #expect(await registry.transport(for: f.fingerprint) == nil)
    }
}

@Test func addresslessForgedPinAndUnauthenticatedSourceCannotChangeOrderingEvidence() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let p2 = try await addressless3611(desktopB.get())
    let attacker = try await member(ephemeralIdentity())
    let forged = try altering(p2, ["certFingerprint": .string(attacker.certFingerprint), "certPem": .string(attacker.certPem!)])
    await #expect(throws: AnnexTransportError.identityMismatch) {
        try await registry.reconcileNetwork(snapshot([a, forged]), from: a.fingerprint)
    }
    try await registry.reconcileNetwork(snapshot([p2]), from: "unpaired-source")
    #expect(await store.loadAll().first { $0.host.hostID == f.fingerprint }?.network?.serverPairing?.id == "desktop-pair")
    try await registry.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) == nil)
}

@Test func oldNetworkArchiveWithoutObservationMapStillLoadsAndMigrates() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let disk = ArchivedNetworkPairingStore()
    for saved in await store.loadAll() {
        var archive = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
        var network = try #require(archive["network"] as? [String: Any])
        network.removeValue(forKey: "observations")
        archive["network"] = network
        let old = try AnnexSavedPairing.decode(JSONSerialization.data(withJSONObject: archive))
        #expect(old.network?.observations == nil)
        try await disk.save(old)
    }
    let restored = AnnexTransportRegistry(pairings: disk)
    #expect(try await restored.restoreSaved().count == 2)
    #expect(try await disk.loadAll().allSatisfy { $0.network?.observations?[f.fingerprint]?.pairing.id == "desktop-pair" })
    try await restored.reconcileNetwork(snapshot([a, addressless3611(desktopB.get())]), from: a.fingerprint)
    try await restored.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
    #expect(await restored.transport(for: f.fingerprint) != nil)
}

@Test func corruptObservationMapDoesNotBlockRestorationOrEraseSecrets() async throws {
    let (_, store, _, _) = try await pairedNetwork()
    let saved = try #require(await store.loadAll().first)
    var archive = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
    var network = try #require(archive["network"] as? [String: Any])
    network["observations"] = ["invalid": ["pairing": 12]]
    archive["network"] = network
    let corrupt = try JSONSerialization.data(withJSONObject: archive)
    let disk = ArchivedNetworkPairingStore()
    await disk.saveRaw(corrupt, hostID: saved.host.hostID)
    let credentials = MemoryAnnexCredentialStore()
    let registry = AnnexTransportRegistry(credentials: credentials, pairings: disk)
    #expect(try await registry.restoreSaved().count == 1)
    #expect(try await disk.loadAll().first?.network?.observations?["invalid"] == nil)
    #expect(await credentials.credential(for: saved.host.hostID) == saved.credential)
    #expect(await registry.all().count == 1)
    #expect(await store.loadAll().count == 1)
}

@Test func fullObservationMapRefusesUnknownGrowthButStillAppliesAuthoritativeRemoval() async throws {
    let (initial, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await initial.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    var saved = await store.loadAll()
    var observations = try #require(saved.first?.network?.observations)
    let placeholder = AnnexNetworkObservation(certFingerprint: a.certFingerprint, pairing: .init(id: "old", joinedAt: networkDate))
    for index in 0..<(AnnexNetworkObservation.maximumCount - observations.count) {
        observations[observationID(index)] = placeholder
    }
    #expect(observations.count == AnnexNetworkObservation.maximumCount)
    for index in saved.indices {
        saved[index].network?.observations = observations
        await store.save(saved[index])
    }
    let registry = AnnexTransportRegistry(pairings: store)
    _ = try await registry.restoreSaved()
    let unknown = try await addressless3611(ephemeralIdentity())
    try await registry.reconcileNetwork(snapshot([a, unknown]), from: a.fingerprint)
    #expect(await store.loadAll().allSatisfy { $0.network?.observations == observations })
    #expect(await store.loadAll().allSatisfy { $0.network?.observations?[unknown.fingerprint] == nil })
    #expect(await registry.transport(for: f.fingerprint) != nil)
    // An authoritative removal frees its entry, so bounded retention doesn't
    // prevent legitimate revocation or subsequent new evidence.
    let excess = try await addressless3611(ephemeralIdentity())
    try await registry.reconcileNetwork(snapshot([a, unknown, excess], removals: [removal(f.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) == nil)
    #expect(await store.loadAll().allSatisfy { $0.network?.removals.contains(removal(f.fingerprint)) == true && $0.network?.observations?[excess.fingerprint] == nil })
    #expect(await store.loadAll().first?.network?.observations?.count == AnnexNetworkObservation.maximumCount)
    #expect(await store.loadAll().first?.network?.observations?[unknown.fingerprint] != nil)
}

@Test func corruptObservationValuesAreSkippedAndOversizedArchivesAreBounded() async throws {
    let (_, store, _, a) = try await pairedNetwork()
    let saved = try #require(await store.loadAll().first)
    let archive = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
    let valid: [String: Any] = ["certFingerprint": a.certFingerprint, "pairing": ["id": "P2", "joinedAt": "2026-11-08T10:01:00Z"]]
    for (key, observation) in [
        (a.fingerprint, ["certFingerprint": "bad", "pairing": ["id": "P2", "joinedAt": networkDate]] as [String: Any]),
        (a.fingerprint, ["certFingerprint": a.certFingerprint, "pairing": ["id": "P2", "joinedAt": "bad"]] as [String: Any]),
        ("not-a-fingerprint", valid)
    ] {
        var corrupt = archive
        var network = try #require(corrupt["network"] as? [String: Any])
        network["observations"] = [key: observation]
        corrupt["network"] = network
        let decoded = try AnnexSavedPairing.decode(JSONSerialization.data(withJSONObject: corrupt))
        #expect(decoded.network?.observations?.isEmpty == true)
    }
    var oversized = archive
    var network = try #require(oversized["network"] as? [String: Any])
    network["observations"] = Dictionary(uniqueKeysWithValues: (0...AnnexNetworkObservation.maximumCount).map { (observationID($0), valid) })
    oversized["network"] = network
    let decoded = try AnnexSavedPairing.decode(JSONSerialization.data(withJSONObject: oversized))
    #expect(decoded.network?.observations?.count == AnnexNetworkObservation.maximumCount)
    #expect(await store.loadAll().count == 1)
}

@Test func addresslessSameIdAndUnstampedViewsCannotMoveKnownPairingClock() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let p2 = try await addressless3611(desktopB.get())
    for record in [p2.keepingPairing(id: "desktop-pair", joinedAt: "2099-01-01T00:00:00Z"),
                   p2.keepingPairing(id: nil, joinedAt: "2099-01-01T00:00:00Z")] {
        try await registry.reconcileNetwork(snapshot([a, record]), from: a.fingerprint)
        #expect(await store.loadAll().first { $0.host.hostID == f.fingerprint }?.network?.serverPairing == .init(id: "desktop-pair", joinedAt: networkDate))
    }
    try await registry.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) == nil)
}

@Test func unknownAddresslessObservationCannotLaterHaveItsCertificateReplaced() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let p2 = try await addressless3611(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, p2]), from: a.fingerprint)
    let attacker = try await member(ephemeralIdentity())
    let forged = try await altering(member(desktopB.get(), pairingID: "P3", joinedAt: "2026-11-08T10:02:00Z"),
                              ["certFingerprint": .string(attacker.certFingerprint), "certPem": .string(attacker.certPem!)])
    try await registry.reconcileNetwork(snapshot([a, forged]), from: a.fingerprint)
    #expect(await registry.transport(for: p2.fingerprint) == nil)
    #expect(await store.loadAll().first?.network?.observations?[p2.fingerprint]?.pairing.id == "P2")
}

private func observationID(_ index: Int) -> String {
    (Array(repeating: UInt8(0), count: 14) + [UInt8(index / 256), UInt8(index % 256)])
        .map { String(format: "%02x", $0) }.joined(separator: ":")
}

@Test(arguments: [false, true]) func hostsWithoutPortRetainStampButNeverCreateRoutesOrTransports(zeroPort: Bool) async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    var record = try await altering(addressless3611(desktopB.get()), ["hosts": .array([.string("10.20.0.5")])])
    if zeroPort { record = try altering(record, ["port": .integer(0)]) }
    try await registry.reconcileNetwork(snapshot([a, record]), from: a.fingerprint)
    #expect(record.endpoints.isEmpty)
    #expect(await registry.transport(for: record.fingerprint) == nil)
    #expect(await registry.routes(for: record.fingerprint).isEmpty)
    #expect(await store.loadAll().count == 1)
    #expect((await store.loadAll().first?.network?.observations?[record.fingerprint] != nil) == !zeroPort)
}

@Test(arguments: ["2026-11-08T09:59:00Z", "2026-11-08T10:00:00Z", "2026-11-08T10:01:00Z"])
func differentPairingIdsAdvanceOnlyWithStrictlyLaterJoinTime(joinedAt: String) async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let candidate = try await addressless3611(desktopB.get()).keepingPairing(id: "P2", joinedAt: joinedAt)
    try await registry.reconcileNetwork(snapshot([a, candidate]), from: a.fingerprint)
    let later = joinedAt == "2026-11-08T10:01:00Z"
    #expect(await store.loadAll().first { $0.host.hostID == f.fingerprint }?.network?.serverPairing?.id == (later ? "P2" : "desktop-pair"))
    try await registry.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
    #expect((await registry.transport(for: f.fingerprint) != nil) == later)
}

@Test func stampedRemovalWithoutJoinTimeCannotUseRemovalTimeAgainstADifferentEpoch() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    try await registry.reconcileNetwork(snapshot([a, addressless3611(desktopB.get())]), from: a.fingerprint)
    let old = AnnexNetworkRemoval(fingerprint: f.fingerprint, removedAt: "2099-01-01T00:00:00Z", pairingId: "desktop-pair", joinedAt: nil)
    #expect(!old.ends(pairingID: "P2", joinedAt: "2026-11-08T10:01:00Z"))
    #expect(old.ends(pairingID: "desktop-pair", joinedAt: "2099-01-02T00:00:00Z"))
    #expect(old.ends(pairingID: nil, joinedAt: "2099-01-02T00:00:00Z"))
    try await registry.reconcileNetwork(snapshot([a], removals: [old]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) != nil)
    #expect(try await AnnexTransportRegistry(pairings: store).restoreSaved().count == 2)
    let current = AnnexNetworkRemoval(fingerprint: f.fingerprint, removedAt: networkDate, pairingId: "P2", joinedAt: nil)
    try await registry.reconcileNetwork(snapshot([a], removals: [current]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) == nil)
}

@Test func validRejoinedSourceCanVouchForUnknownEvidenceWhileItsOldRemovalIsStale() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    let c = try await addressless3611(ephemeralIdentity())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let rejoined = f.keepingPairing(id: "P2", joinedAt: "2026-11-08T10:01:00Z")
    try await registry.reconcileNetwork(snapshot([rejoined, c], removals: [removal(f.fingerprint)]), from: f.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) != nil)
    #expect(await registry.transport(for: c.fingerprint) == nil)
    #expect(await store.loadAll().allSatisfy { $0.network?.observations?[c.fingerprint]?.pairing.id == "P2" })
    #expect(try await AnnexTransportRegistry(pairings: store).restoreSaved().count == 2)
}

@Test func unknownPinConflictIsIsolatedAndAnEndedUnknownEpochCanAdoptANewCertificate() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let old = try await addressless3611(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, old]), from: a.fingerprint)
    let newCertificate = try await member(ephemeralIdentity())
    let updated = try altering(old.keepingPairing(id: "P3", joinedAt: "2026-11-08T10:02:00Z"),
                               ["certFingerprint": .string(newCertificate.certFingerprint), "certPem": .string(newCertificate.certPem!)])
    // An unrelated unknown pin conflict cannot block removal of a known desktop.
    let other = try await member(ephemeralIdentity())
    try await registry.reconcileNetwork(snapshot([a, other]), from: a.fingerprint)
    try await registry.reconcileNetwork(snapshot([a, updated], removals: [removal(other.fingerprint)]), from: a.fingerprint)
    #expect(await registry.transport(for: other.fingerprint) == nil)
    #expect(await store.loadAll().first?.network?.observations?[old.fingerprint]?.pairing.id == "P2")
    // The old epoch is explicitly ended before a new, pinned-source-vouched pin
    // is admitted. No existing registered host's pin is ever replaced.
    try await registry.reconcileNetwork(snapshot([a, updated], removals: [removal(old.fingerprint, pairingID: "P2", joinedAt: old.joinedAt)]), from: a.fingerprint)
    #expect(await store.loadAll().first?.network?.observations?[old.fingerprint]?.pairing.id == "P3")
    #expect(await store.loadAll().first?.network?.observations?[old.fingerprint]?.certFingerprint == newCertificate.certFingerprint)
}

@Test func malformedPairResponseCannotWriteAnUnrestorableObservation() async throws {
    let (_, existing, _, a) = try await pairedNetwork()
    let io = try await NetworkIO(desktopA.get())
    await io.setServerPairing(.init(id: "desktop-pair", joinedAt: "invalid"))
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: existing, pairingIO: { _, _ in io })
    await #expect(throws: AnnexTransportError.malformedResponse) {
        try await registry.pair(host: a.trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    }
    let disk = ArchivedNetworkPairingStore()
    for pairing in await existing.loadAll() { try await disk.save(pairing) }
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 1)
}

@Test(arguments: [false, true]) func invalidLegacySavedStampDoesNotPoisonMapOrBlockNextLaunch(inMember: Bool) async throws {
    let (_, memory, _, a) = try await pairedNetwork()
    var saved = try #require(await memory.loadAll().first)
    saved.network?.observations = nil
    if inMember { saved.network?.member = a.keepingPairing(id: "desktop-pair", joinedAt: "invalid") }
    else { saved.network?.serverPairing = .init(id: "desktop-pair", joinedAt: "invalid") }
    let disk = ArchivedNetworkPairingStore()
    try await disk.save(saved)
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 1)
    #expect(try await disk.loadAll().first?.network?.observations?[a.fingerprint] == nil)
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 1)
}

@Test func malformedRemovalCannotEraseValidPairingsOrPoisonTheirJournal() async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    for record in [AnnexNetworkRemoval(fingerprint: a.fingerprint, removedAt: "invalid", pairingId: "desktop-pair", joinedAt: networkDate),
                   AnnexNetworkRemoval(fingerprint: a.fingerprint, removedAt: networkDate, pairingId: "desktop-pair", joinedAt: "invalid")] {
        try await registry.reconcileNetwork(snapshot([a], removals: [record]), from: a.fingerprint)
        #expect(await registry.transport(for: a.fingerprint) != nil)
        #expect(await store.loadAll().first?.network?.removals.isEmpty == true)
    }
}

@Test func divergentFullMapsRestoreWithoutBlockingAndPreserveWinningStampBeforeBounding() async throws {
    let (registry, memory, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let placeholder = try #require(AnnexNetworkObservation(certFingerprint: a.certFingerprint, pairing: .init(id: "old", joinedAt: networkDate)))
    let p2 = try await addressless3611(desktopB.get())
    let disk = ArchivedNetworkPairingStore()
    for var saved in await memory.loadAll() {
        let offset = saved.host.hostID == a.fingerprint ? 0 : 510
        var map = Dictionary(uniqueKeysWithValues: (offset..<(offset + 510)).map { (observationID($0), placeholder) })
        map[a.fingerprint] = saved.network?.observations?[a.fingerprint]
        map[f.fingerprint] = .init(certFingerprint: f.certFingerprint, pairing: .init(id: saved.host.hostID == a.fingerprint ? "P2" : "desktop-pair", joinedAt: saved.host.hostID == a.fingerprint ? p2.joinedAt : networkDate))
        saved.network?.observations = map
        if saved.host.hostID == a.fingerprint { saved.network?.removals = [removal(f.fingerprint)] }
        #expect(map.count == AnnexNetworkObservation.maximumCount)
        try await disk.save(saved)
    }
    let restored = AnnexTransportRegistry(pairings: disk)
    #expect(try await restored.restoreSaved().count == 2)
    let expectedKeys = Set([a.fingerprint, f.fingerprint] + (0..<510).map(observationID))
    #expect(try await disk.loadAll().allSatisfy { Set($0.network?.observations?.keys.map { $0 } ?? []) == expectedKeys && $0.network?.removals == [removal(f.fingerprint)] })
    let preserved = try #require(try await disk.loadAll().first { $0.host.hostID == f.fingerprint })
    #expect(preserved.network?.serverPairing?.id == "P2")
    #expect(preserved.network?.member?.pairingId == "P2")
    #expect(preserved.host == (try f.trustedHost()))
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 2)
}

@Test func fullEvidenceMapRefusesNewExplicitPairBeforeSendingAnyRequest() async throws {
    let (_, store, _, a) = try await pairedNetwork()
    var saved = try #require(await store.loadAll().first)
    let placeholder = try #require(AnnexNetworkObservation(certFingerprint: a.certFingerprint, pairing: .init(id: "old", joinedAt: networkDate)))
    var map = Dictionary(uniqueKeysWithValues: (0..<(AnnexNetworkObservation.maximumCount - 1)).map { (observationID($0), placeholder) })
    map[a.fingerprint] = saved.network?.observations?[a.fingerprint]
    saved.network?.observations = map
    await store.save(saved)
    let io = try await NetworkIO(desktopB.get())
    let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: store, pairingIO: { _, _ in io })
    _ = try await registry.restoreSaved()
    await #expect(throws: AnnexTransportError.commandTooLarge) {
        try await registry.pair(host: member(desktopB.get()).trustedHost(), pin: "123456", alias: "Phone", clientIdentity: phoneIdentity.get(), persistence: .persistent)
    }
    #expect(await io.requests.count == 0)
    #expect(await store.loadAll().count == 1)
}

@Test func legacyUnstampedAndNewerDifferentEpochRemovalsStillRevokeAddresslessPairing() async throws {
    for legacy in [false, true] {
        let (registry, store, _, a) = try await pairedNetwork()
        let f = try await member(desktopB.get())
        try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
        try await registry.reconcileNetwork(snapshot([a, addressless3611(desktopB.get())]), from: a.fingerprint)
        let marker = removal(f.fingerprint, pairingID: legacy ? nil : "P3", joinedAt: legacy ? nil : "2026-11-08T10:02:00Z")
        try await registry.reconcileNetwork(snapshot([a], removals: [marker]), from: a.fingerprint)
        #expect(await registry.transport(for: f.fingerprint) == nil)
        #expect(await store.loadAll().allSatisfy { $0.network?.observations?[f.fingerprint] == nil })
        #expect(try await AnnexTransportRegistry(pairings: store).restoreSaved().count == 1)
    }
}

@Test func realSPKIFingerprintRoundTripsThroughKeychainArchiveAndTwoRestarts() async throws {
    let (registry, memory, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    try await registry.reconcileNetwork(snapshot([a, addressless3611(desktopB.get())]), from: a.fingerprint)
    let actual = try await AnnexPairingIdentity.fingerprint(publicKeyBase64: desktopB.get().pairingIdentity.publicKeyBase64)
    #expect(actual == f.fingerprint && actual.count == 47 && actual.split(separator: ":").count == 16)
    #expect(AnnexPairingIdentity.isValidFingerprint(actual))
    let disk = ArchivedNetworkPairingStore()
    for saved in await memory.loadAll() {
        let decoded = try AnnexSavedPairing.decode(saved.encoded())
        #expect(decoded.network?.observations?[actual]?.pairing.id == "P2")
        #expect(decoded.credential == saved.credential)
        #expect(decoded.identity.certificateDER == saved.identity.certificateDER)
        try await disk.save(decoded)
    }
    for _ in 0..<2 {
        let restarted = AnnexTransportRegistry(pairings: disk)
        #expect(try await restarted.restoreSaved().count == 2)
        try await restarted.reconcileNetwork(snapshot([a], removals: [removal(f.fingerprint)]), from: a.fingerprint)
        #expect(await restarted.transport(for: actual) != nil)
    }
}

@Test(arguments: ["64-hex", "uppercase", "wrong-byte-count"])
func invalidObservationKeyIsSkippedBesideValidRealKeysAndNextSaveCleansIt(shape: String) async throws {
    let (registry, memory, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let disk = ArchivedNetworkPairingStore()
    var original: [String: AnnexJSON] = [:]
    var badKey = ""
    for saved in await memory.loadAll() {
        let raw = try saved.encoded()
        original[saved.host.hostID] = try JSONDecoder().decode(AnnexJSON.self, from: raw)
        var archive = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var network = try #require(archive["network"] as? [String: Any])
        var map = try #require(network["observations"] as? [String: Any])
        switch shape {
        case "64-hex": badKey = String(repeating: "ab", count: 32)
        case "uppercase": badKey = "AB:CD:EF:AB:CD:EF:AB:CD:EF:AB:CD:EF:AB:CD:EF:AB"
        default: badKey = "ab:cd:ef:ab"
        }
        map[badKey] = map[a.fingerprint]
        network["observations"] = map
        archive["network"] = network
        await disk.saveRaw(try JSONSerialization.data(withJSONObject: archive), hostID: saved.host.hostID)
    }
    let loaded = try await disk.loadAll()
    #expect(loaded.count == 2)
    for saved in loaded {
        #expect(Set(saved.network?.observations?.keys.map { $0 } ?? []) == Set([a.fingerprint, f.fingerprint]))
        let after = try JSONDecoder().decode(AnnexJSON.self, from: saved.encoded())
        let before = try #require(original[saved.host.hostID])
        #expect(after["identity"] == before["identity"])
        #expect(after["bearerToken"] == before["bearerToken"])
        #expect(after["host"] == before["host"])
        // A following real archive save rewrites only sanitized evidence.
        try await disk.save(saved)
        let cleaned = try JSONDecoder().decode(AnnexJSON.self, from: #require(await disk.raw(hostID: saved.host.hostID)))
        #expect(cleaned["network"]?["observations"]?[badKey] == nil)
    }
    #expect(try await AnnexTransportRegistry(pairings: disk).restoreSaved().count == 2)
    #expect(try await disk.loadAll().allSatisfy { $0.network?.observations?[badKey] == nil })
}

@Test(arguments: [false, true]) func malformedTombstoneCannotBlockAnotherValidDesktopOrPhoneRevocation(phoneRevoked: Bool) async throws {
    let (registry, store, _, a) = try await pairedNetwork()
    let f = try await member(desktopB.get())
    try await registry.reconcileNetwork(snapshot([a, f]), from: a.fingerprint)
    let invalid = AnnexNetworkRemoval(fingerprint: a.fingerprint, removedAt: "invalid", pairingId: "desktop-pair", joinedAt: networkDate)
    let valid = removal(phoneRevoked ? try await phoneIdentity.get().fingerprint : f.fingerprint, pairingID: phoneRevoked ? phonePairing.id : "desktop-pair")
    try await registry.reconcileNetwork(snapshot([a, f], removals: [invalid, valid]), from: a.fingerprint)
    #expect(await registry.transport(for: f.fingerprint) == nil)
    if phoneRevoked {
        #expect(await registry.all().isEmpty)
        #expect(await store.loadAll().isEmpty)
    } else {
        #expect(await registry.all().count == 1)
        #expect(await store.loadAll().allSatisfy { $0.network?.removals == [valid] })
        #expect(try await AnnexTransportRegistry(pairings: store).restoreSaved().count == 1)
    }
}
