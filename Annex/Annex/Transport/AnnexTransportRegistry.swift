import Foundation
import Security

/// Composition root for presentation. UI never reads bearer tokens or private
/// keys. Legacy trust-all credentials are deliberately not migrated implicitly.
public actor AnnexTransportRegistry {
    public struct Registration: Sendable {
        /// Stable across snapshot copies; a replacement transport gets a new identity.
        public let transportID = UUID()
        public let host: TrustedAnnexHost
        public let alias: String
        public let transport: any AnnexTransporting
    }
    public enum Persistence: Sendable { case sessionOnly, persistent }
    private let pairings: (any AnnexPairingStore)?
    private var busyHosts: Set<String> = []
    private var revision = UUID()
    private let credentials: any AnnexCredentialStore
    private let sessionCredentials = MemoryAnnexCredentialStore()
    private let pairingIO: @Sendable (TrustedAnnexHost, AnnexClientIdentity) -> any AnnexIO
    private var registrations: [String: Registration] = [:]
    private var networkStates: [String: AnnexNetworkState] = [:]
    private var networkRefusals: Set<String> = []
    private var networkQueue: [(String, AnnexNetworkSnapshot)] = []
    private var applyingNetwork = false
    private var introducingNetwork = false
    private var identities: [String: AnnexClientIdentity] = [:]
    /// Other addresses each desktop answers on, best first; the registration's endpoint is the current one.
    private var alternates: [String: [AnnexEndpoint]] = [:]
    /// Kept short: enough for home Wi-Fi, Tailscale and a couple of stale names.
    static let maximumRoutes = 6
    public init(credentials: any AnnexCredentialStore = MemoryAnnexCredentialStore(), pairings: (any AnnexPairingStore)? = nil) { self.credentials = credentials; self.pairings = pairings
        self.pairingIO = { PinnedAnnexIO(host: $0, clientIdentity: $1) }
    }
    // Internal injection for isolated protocol tests; production always uses pinned TLS.
    init(credentials: any AnnexCredentialStore, pairings: (any AnnexPairingStore)?,
         pairingIO: @escaping @Sendable (TrustedAnnexHost, AnnexClientIdentity) -> any AnnexIO) {
        self.credentials = credentials; self.pairings = pairings; self.pairingIO = pairingIO
    }
    public func all() -> [Registration] { Array(registrations.values) }
    public func transport(for hostID: String) -> (any AnnexTransporting)? { registrations[hostID]?.transport }
    /// Every known address for a desktop, current first.
    public func routes(for hostID: String) -> [AnnexEndpoint] {
        guard let current = registrations[hostID]?.host.endpoint else { return [] }
        return Self.merge([current], alternates[hostID] ?? [])
    }
    private static func merge(_ lists: [AnnexEndpoint]...) -> [AnnexEndpoint] {
        var merged: [AnnexEndpoint] = []
        for route in lists.joined() where !merged.contains(where: { $0.sameAddress(as: route) }) { merged.append(route) }
        return Array(merged.prefix(maximumRoutes))
    }
    private func setAlternates(_ routes: [AnnexEndpoint], hostID: String) {
        guard let current = registrations[hostID]?.host.endpoint else { return }
        alternates[hostID] = Self.merge(routes).filter { !$0.sameAddress(as: current) }
    }

    /// This call is the explicit user-authorized pairing action. For isolated
    /// integration use MemoryAnnexCredentialStore (default); identity remains in
    /// memory and is never installed in the simulator or system trust store.
    /// `alias` is this device's own name, sent to the desktop. `label` is what this
    /// device calls the desktop; without one the desktop's reported alias is kept.
    @discardableResult
    public func pair(host: TrustedAnnexHost, pin: String, alias: String, label: String? = nil, routes: [AnnexEndpoint] = [],
                     clientIdentity: AnnexClientIdentity? = nil, persistence: Persistence = .sessionOnly) async throws -> Registration {
        return try await AnnexTelemetry.shared.measure(.pairing) {
            guard !busyHosts.contains(host.hostID) else { throw AnnexTransportError.commandInFlight }
            if persistence == .persistent && pairings == nil { throw AnnexTransportError.persistenceFailed(errSecNotAvailable) }
            revision = UUID()
            busyHosts.insert(host.hostID)
            defer { busyHosts.remove(host.hostID) }
            // Network desktops must see the same client certificate and identity.
            // Session pairing retains the existing ephemeral identity policy.
            let memberIdentity = persistence == .persistent ? networkStates.keys.sorted().compactMap { identities[$0] }.first : nil
            let identity = try memberIdentity ?? clientIdentity ?? AnnexClientIdentity.ephemeral()
            let keptPairing = persistence == .persistent ? networkStates.values.first?.pairing : nil
            let io = pairingIO(host, identity)
            let temporary = MemoryAnnexCredentialStore()
            let result = try await AnnexPairingClient(host: host, clientIdentity: identity, credentials: temporary, io: io).pair(pin: pin, alias: alias, mode: persistence == .persistent ? .persistent : .session, selfPairing: keptPairing)
            guard let credential = await temporary.credential(for: host.hostID) else { throw AnnexTransportError.credentialMissing }
            let network = result.pairing.map { AnnexNetworkState(pairing: $0, serverPairing: result.serverPairing,
                member: nil, learned: false, removals: networkStates.values.flatMap(\.removals), needsIntroduction: keptPairing != nil) }
            let hostLabel = label.flatMap { $0.isEmpty ? nil : $0 } ?? result.alias
            if persistence == .persistent, let pairings {
                try await pairings.save(AnnexSavedPairing(host: host, alias: hostLabel, routes: Self.merge(routes).filter { !$0.sameAddress(as: host.endpoint) },
                                                          identity: identity, credential: credential, network: network))
            } else {
                // Choosing session-only must not leave an older durable pairing to
                // silently reappear on the next app launch.
                try await pairings?.remove(hostID: host.hostID)
                try await credentials.remove(for: host.hostID)
            }
            let activeCredentials: any AnnexCredentialStore = persistence == .sessionOnly ? sessionCredentials : credentials
            try await activeCredentials.save(credential, for: host.hostID)
            let transport = AnnexTransport(host: host, credentials: activeCredentials, clientIdentity: identity, io: io)
            if let old = registrations[host.hostID] { await old.transport.disconnect() }
            let registration = Registration(host: host, alias: hostLabel, transport: transport)
            networkStates[host.hostID] = network
            if let network {
                for id in Array(networkStates.keys) where id != host.hostID {
                    networkStates[id]?.pairing = network.pairing
                    try await saveNetworkState(for: id)
                }
            }
            networkRefusals.remove(host.hostID)
            identities[host.hostID] = identity
            registrations[host.hostID] = registration
            setAlternates(routes, hostID: host.hostID)
            return registration

        }
    }

    /// Inject an already approved identity and host at app restoration. The
    /// identity store is an application policy, separate from endpoint discovery.
    @discardableResult
    public func restore(host: TrustedAnnexHost, alias: String, clientIdentity: AnnexClientIdentity) async throws -> Registration {
        guard !busyHosts.contains(host.hostID) else { throw AnnexTransportError.commandInFlight }
        revision = UUID()
        busyHosts.insert(host.hostID)
        defer { busyHosts.remove(host.hostID) }
        return try await restoreRegistration(host: host, alias: alias, clientIdentity: clientIdentity)
    }
    private func restoreRegistration(host: TrustedAnnexHost, alias: String, clientIdentity: AnnexClientIdentity) async throws -> Registration {
        guard try await credentials.credential(for: host.hostID) != nil else { throw AnnexTransportError.credentialMissing }
        if let old = registrations[host.hostID] { await old.transport.disconnect() }
        let transport = AnnexTransport(host: host, credentials: credentials, clientIdentity: clientIdentity)
        let registration = Registration(host: host, alias: alias, transport: transport)
        identities[host.hostID] = clientIdentity; registrations[host.hostID] = registration
        return registration
    }
    /// The paired desktop answered at a new address with its pinned certificate
    /// (see AnnexRediscovery). Identity, credential and pin stay the same; only the
    /// route changes, and a saved pairing is updated to match.
    @discardableResult
    public func relocate(hostID: String, to endpoint: AnnexEndpoint) async throws -> Registration {
        guard !busyHosts.contains(hostID) else { throw AnnexTransportError.commandInFlight }
        guard let current = registrations[hostID], let identity = identities[hostID] else { throw AnnexTransportError.credentialMissing }
        revision = UUID()
        busyHosts.insert(hostID)
        defer { busyHosts.remove(hostID) }
        let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: current.host.hostID, verifiedCertificatePin: current.host.certificatePin)
        // The old address stays known: it is the right one again back at home.
        let others = Self.merge([current.host.endpoint], alternates[hostID] ?? []).filter { !$0.sameAddress(as: endpoint) }
        if let pairings, let saved = try await pairings.loadAll().first(where: { $0.host.hostID == hostID }) {
            try await pairings.save(AnnexSavedPairing(host: host, alias: saved.alias, routes: others, identity: saved.identity, credential: saved.credential, network: saved.network))
        }
        let store: any AnnexCredentialStore = try await credentials.credential(for: hostID) != nil ? credentials : sessionCredentials
        await current.transport.disconnect()
        let transport = AnnexTransport(host: host, credentials: store, clientIdentity: identity)
        let registration = Registration(host: host, alias: current.alias, transport: transport)
        registrations[hostID] = registration
        alternates[hostID] = others
        return registration
    }

    /// The connected desktop reported where else it answers. Keeps known routes, adds
    /// new ones after the desktop's own order, and saves them with a remembered pairing.
    public func learnRoutes(hostID: String, _ reported: [AnnexEndpoint]) async throws {
        guard let current = registrations[hostID]?.host.endpoint, !busyHosts.contains(hostID) else { return }
        let before = alternates[hostID] ?? []
        let after = Self.merge(reported, before).filter { !$0.sameAddress(as: current) }
        guard !after.elementsEqual(before, by: { $0.sameAddress(as: $1) }) else { return }
        alternates[hostID] = after
        if let pairings, let saved = try await pairings.loadAll().first(where: { $0.host.hostID == hostID }),
           saved.host.endpoint.sameAddress(as: current) {
            try await pairings.save(AnnexSavedPairing(host: saved.host, alias: saved.alias, routes: after, identity: saved.identity, credential: saved.credential, network: saved.network))
        }
    }
    /// Loads only already authorized saved pairings; never generates identity or
    /// migrates legacy trust-all credentials. Caller invokes connect explicitly.
    @discardableResult
    public func restoreSaved() async throws -> [Registration] {
        return try await AnnexTelemetry.shared.measure(.restore) {
            guard let pairings else { return [] }
            let requestedRevision = revision
            var saved = try await pairings.loadAll()
            guard requestedRevision == revision else { return all() }
            var journal: [AnnexNetworkRemoval] = []
            for removal in saved.compactMap(\.network).flatMap(\.removals) where !journal.contains(removal) { journal.append(removal) }
            // A previous process may have stopped after copying the journal to
            // only some items. Spread it before deleting any ended pairing.
            for index in saved.indices where saved[index].network != nil {
                guard requestedRevision == revision else { return all() }
                if saved[index].network?.removals != journal {
                    saved[index].network?.removals = journal
                    try await pairings.save(saved[index])
                }
            }
            for pairing in saved where registrations[pairing.host.hostID] == nil {
                guard requestedRevision == revision else { break }
                guard !busyHosts.contains(pairing.host.hostID) else { continue }
                if let network = pairing.network {
                    let phone = try pairing.identity.fingerprint
                    let serverID = network.member?.pairingId ?? network.serverPairing?.id
                    let serverJoin = network.member?.joinedAt ?? network.serverPairing?.joinedAt
                    if journal.contains(where: { removal in
                        (removal.fingerprint.lowercased() == phone && removal.ends(pairingID: network.pairing.id, joinedAt: network.pairing.joinedAt)) ||
                        (removal.fingerprint.lowercased() == pairing.host.hostID && serverJoin.map { removal.ends(pairingID: serverID, joinedAt: $0) } == true)
                    }) {
                        try await pairings.remove(hostID: pairing.host.hostID)
                        continue
                    }
                }
                busyHosts.insert(pairing.host.hostID)
                do {
                    try await credentials.save(pairing.credential, for: pairing.host.hostID)
                    _ = try await restoreRegistration(host: pairing.host, alias: pairing.alias, clientIdentity: pairing.identity)
                    networkStates[pairing.host.hostID] = pairing.network
                    setAlternates(pairing.routes, hostID: pairing.host.hostID)
                    busyHosts.remove(pairing.host.hostID)
                } catch { busyHosts.remove(pairing.host.hostID); throw error }
            }
            return all()

        }
    }
    public func remove(hostID: String) async throws {
        return try await AnnexTelemetry.shared.measure(.forget) {
            guard !busyHosts.contains(hostID) else { throw AnnexTransportError.commandInFlight }
            revision = UUID()
            busyHosts.insert(hostID)
            defer { busyHosts.remove(hostID) }
            try await removeRegistration(hostID: hostID)

        }
    }
    /// Explicit online self-revocation. Failure preserves local material.
    public func revokeSessionAndRemove(hostID: String) async throws {
        guard !busyHosts.contains(hostID) else { throw AnnexTransportError.commandInFlight }
        guard let registration = registrations[hostID] else { throw AnnexTransportError.credentialMissing }
        revision = UUID()
        busyHosts.insert(hostID)
        defer { busyHosts.remove(hostID) }
        try await registration.transport.revokeSessionPairing()
        try await removeRegistration(hostID: hostID)
    }
    private func removeRegistration(hostID: String) async throws {
        try await pairings?.remove(hostID: hostID)
        if let registration = registrations.removeValue(forKey: hostID) { await registration.transport.disconnect() }
        networkStates.removeValue(forKey: hostID)
        networkRefusals.remove(hostID)
        identities.removeValue(forKey: hostID)
        alternates.removeValue(forKey: hostID)
        try await credentials.remove(for: hostID)
        await sessionCredentials.remove(for: hostID)
    }
    public func disconnectAll() async {
        for registration in registrations.values { await registration.transport.disconnect() }
    }
}

extension AnnexTransportRegistry {
    /// Only views delivered through an authenticated, pinned network host can add
    /// trust. A stale view can never undo a saved removal, including after restart.
    public func reconcileNetwork(_ snapshot: AnnexNetworkSnapshot, from hostID: String) async throws {
        guard snapshot.version == 1, snapshot.joined, networkStates[hostID] != nil else { return }
        networkQueue.append((hostID, snapshot))
        guard !applyingNetwork else { return }
        applyingNetwork = true
        defer { applyingNetwork = false; networkQueue.removeAll() }
        while !networkQueue.isEmpty {
            let (source, view) = networkQueue.removeFirst()
            try await applyNetwork(view, from: source)
        }
    }

    private func applyNetwork(_ view: AnnexNetworkSnapshot, from source: String) async throws {
        guard let own = networkStates[source], let identity = identities[source] else { return }
        let networkRevision = revision
        let phone = try AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.pairingIdentity.publicKeyBase64)
        // Leaving takes nothing else from this view (#3107), especially new hosts.
        if view.removals.contains(where: { $0.fingerprint.lowercased() == phone && $0.ends(pairingID: own.pairing.id, joinedAt: own.pairing.joinedAt) }) {
            try await forgetNetwork()
            return
        }
        networkRefusals.remove(source)
        var journal: [AnnexNetworkRemoval] = []
        for removal in networkStates.values.flatMap(\.removals) + view.removals where !journal.contains(removal) { journal.append(removal) }
        journal.sort { ($0.fingerprint, $0.pairingId ?? "", $0.joinedAt ?? "", $0.removedAt) < ($1.fingerprint, $1.pairingId ?? "", $1.joinedAt ?? "", $1.removedAt) }
        // Resolve each desktop's generation from the whole view before deleting
        // anything. A later pairing beats an old tombstone, even for the sender.
        var members: [String: AnnexNetworkMember] = [:]
        for member in view.members where member.kind == "desktop" {
            let id = member.fingerprint.lowercased()
            guard !journal.contains(where: { $0.fingerprint.lowercased() == id && $0.ends(pairingID: member.pairingId, joinedAt: member.joinedAt) }) else { continue }
            let state = networkStates[id]
            if let existing = registrations[id] {
                // Another member cannot upgrade one-to-one trust or replace a pin.
                guard state != nil else { continue }
                guard (try? AnnexCertificatePin(sha256: member.certFingerprint)) == existing.host.certificatePin else {
                    throw AnnexTransportError.identityMismatch
                }
            }
            guard (try? member.trustedHost()) != nil else { continue }
            let previousID = members[id]?.pairingId ?? state?.member?.pairingId ?? state?.serverPairing?.id
            let previousJoin = members[id]?.joinedAt ?? state?.member?.joinedAt ?? state?.serverPairing?.joinedAt
            // Same-id and unstamped records cannot move a known pairing's clock.
            if let previousJoin, member.pairingId == nil || member.pairingId == previousID ||
                (previousID != nil && (AnnexNetworkRemoval.date(member.joinedAt) ?? .distantPast) <= (AnnexNetworkRemoval.date(previousJoin) ?? .distantFuture)) {
                members[id] = member.keepingPairing(id: previousID, joinedAt: previousJoin)
            } else { members[id] = member }
        }
        // Save the winning stamp and journal together before deleting anything.
        // An interrupted write must not restore the old generation with its tombstone.
        for id in Array(networkStates.keys) {
            if let member = members[id] {
                networkStates[id]?.member = member
                if let pairingID = member.pairingId {
                    networkStates[id]?.serverPairing = .init(id: pairingID, joinedAt: member.joinedAt)
                }
            }
            networkStates[id]?.removals = journal
            try await saveNetworkState(for: id)
            guard networkRevision == revision else { return }
        }
        for id in Array(networkStates.keys) {
            guard let state = networkStates[id] else { continue }
            let stamp = (members[id] ?? state.member).map { AnnexNetworkPairing(id: $0.pairingId ?? "", joinedAt: $0.joinedAt) } ?? state.serverPairing
            if let stamp, journal.contains(where: { $0.fingerprint.lowercased() == id && $0.ends(pairingID: stamp.id.isEmpty ? nil : stamp.id, joinedAt: stamp.joinedAt) }) {
                try await removeRegistration(hostID: id)
                guard networkRevision == revision else { return }
            }
        }
        for id in members.keys.sorted() {
            guard networkRevision == revision else { return }
            guard let member = members[id] else { continue }
            if registrations[id] != nil {
                try await learnRoutes(hostID: id, member.endpoints)
                continue
            }
            // A view can finish removing its sender and updating known members,
            // but that removed sender no longer vouches for new desktop trust.
            guard networkStates[source] != nil else { continue }
            // Malformed records are ignored individually; never create an
            // unpinned transport, even when an authenticated member supplied it.
            guard let host = try? member.trustedHost() else { continue }
            let credential = try AnnexCredential(bearerToken: "mtls-network-member")
            let state = AnnexNetworkState(pairing: own.pairing, serverPairing: member.pairingId.map { .init(id: $0, joinedAt: member.joinedAt) },
                                          member: member, learned: true, removals: journal, needsIntroduction: false)
            try await pairings?.save(AnnexSavedPairing(host: host, alias: member.name, routes: member.endpoints,
                                                     identity: identity, credential: credential, network: state))
            guard networkRevision == revision else {
                try await pairings?.remove(hostID: id)
                return
            }
            try await credentials.save(credential, for: id)
            guard networkRevision == revision else {
                try await pairings?.remove(hostID: id)
                try await credentials.remove(for: id)
                return
            }
            let transport = AnnexTransport(host: host, credentials: credentials, clientIdentity: identity, io: pairingIO(host, identity))
            registrations[id] = Registration(host: host, alias: member.name, transport: transport)
            identities[id] = identity
            networkStates[id] = state
            setAlternates(member.endpoints, hostID: id)
        }
    }

    private func saveNetworkState(for hostID: String) async throws {
        let requestedRevision = revision
        guard let pairings, let saved = try await pairings.loadAll().first(where: { $0.host.hostID == hostID }),
              requestedRevision == revision, let state = networkStates[hostID] else { return }
        var updated = saved
        updated.network = state
        if updated.network != saved.network { try await pairings.save(updated) }
    }

    private func forgetNetwork() async throws {
        revision = UUID()
        // Persist a local leave marker first, so interruption partway through
        // erasing several Keychain items cannot restore the rest on launch.
        for id in Array(networkStates.keys) {
            guard let state = networkStates[id], let identity = identities[id] else { continue }
            let marker = AnnexNetworkRemoval(fingerprint: try identity.fingerprint, removedAt: state.pairing.joinedAt,
                                             pairingId: state.pairing.id, joinedAt: state.pairing.joinedAt)
            if !state.removals.contains(marker) { networkStates[id]?.removals.append(marker) }
            try await saveNetworkState(for: id)
        }
        for id in Array(networkStates.keys) { try await removeRegistration(hostID: id) }
        networkQueue.removeAll()
    }

    /// A refusal is conclusive only when every network desktop refuses. An
    /// unreachable/offline desktop is never counted as a refusal.
    public func networkPeerNotPaired(hostID: String) async throws {
        guard networkStates[hostID] != nil else { return }
        networkRefusals.insert(hostID)
        if Set(networkStates.keys).isSubset(of: networkRefusals) { try await forgetNetwork() }
    }

    private func networkRequest(hostID: String, members: [AnnexNetworkMember]? = nil) async throws -> AnnexNetworkSnapshot? {
        guard let registration = registrations[hostID], let identity = identities[hostID], networkStates[hostID] != nil else {
            throw AnnexTransportError.credentialMissing
        }
        var path = ["api", "v1", "mobile", "network"]
        if members != nil { path.append("members") }
        var request = URLRequest(url: try registration.host.endpoint.url(path: path))
        if let members {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct Body: Encodable { let members: [AnnexNetworkMember] }
            request.httpBody = try JSONEncoder().encode(Body(members: members))
            guard request.httpBody!.count <= 512 * 1024 else { throw AnnexTransportError.commandTooLarge }
        }
        // Authentication on these routes is the pinned client certificate. No
        // source desktop's bearer token is ever sent to another desktop.
        let response = try await pairingIO(registration.host, identity).perform(request)
        guard response.status == 200 else { throw AnnexHTTPValidation.error(response) }
        if members != nil {
            let result = try JSONDecoder().decode(AnnexJSON.self, from: response.data)
            guard case .array? = result["added"], case .array(let skipped)? = result["skipped"],
                  !skipped.contains(where: { $0["reason"]?.string == "invalid" }) else {
                throw AnnexTransportError.malformedResponse
            }
            return nil
        }
        let snapshot = try JSONDecoder().decode(AnnexNetworkSnapshot.self, from: response.data)
        guard snapshot.version == 1, snapshot.joined else { throw AnnexTransportError.unsupportedCapability("network") }
        return snapshot
    }

    /// The phone vouches in both directions, preserving every record's pairing
    /// stamp and certPem. Failed/offline exchanges stay pending in the Keychain.
    public func introduceNetworkMembers() async {
        guard !introducingNetwork else { return }
        introducingNetwork = true
        defer { introducingNetwork = false }
        for newcomer in networkStates.keys.sorted() where networkStates[newcomer]?.needsIntroduction == true {
            for existing in networkStates.keys.sorted() where existing != newcomer {
                do {
                    guard let old = try await networkRequest(hostID: existing), let new = try await networkRequest(hostID: newcomer),
                          let desktop = new.members.first(where: { $0.isSelf == true }) else { continue }
                    try await reconcileNetwork(old, from: existing)
                    try await reconcileNetwork(new, from: newcomer)
                    guard networkStates[newcomer] != nil, networkStates[existing] != nil else { break }
                    let journal = networkStates.values.flatMap(\.removals)
                    let active = old.members.filter { member in
                        !journal.contains { $0.fingerprint.lowercased() == member.fingerprint.lowercased() && $0.ends(pairingID: member.pairingId, joinedAt: member.joinedAt) }
                    }
                    _ = try await networkRequest(hostID: newcomer, members: active)
                    _ = try await networkRequest(hostID: existing, members: [desktop])
                    guard networkStates[newcomer] != nil, networkStates[existing] != nil else { break }
                    networkStates[newcomer]?.needsIntroduction = false
                    try await saveNetworkState(for: newcomer)
                    break
                } catch { /* Retries on the next authenticated refresh/reconnect. */ }
            }
        }
    }
}
