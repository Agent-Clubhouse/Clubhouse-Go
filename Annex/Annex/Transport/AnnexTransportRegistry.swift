import Foundation
import Security

/// Composition root for presentation. UI never reads bearer tokens or private
/// keys. Legacy trust-all credentials are deliberately not migrated implicitly.
public actor AnnexTransportRegistry {
    public struct Registration: Sendable {
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
            let identity = try clientIdentity ?? AnnexClientIdentity.ephemeral()
            let io = pairingIO(host, identity)
            let temporary = MemoryAnnexCredentialStore()
            let result = try await AnnexPairingClient(host: host, clientIdentity: identity, credentials: temporary, io: io).pair(pin: pin, alias: alias, mode: persistence == .persistent ? .persistent : .session)
            guard let credential = await temporary.credential(for: host.hostID) else { throw AnnexTransportError.credentialMissing }
            let hostLabel = label.flatMap { $0.isEmpty ? nil : $0 } ?? result.alias
            if persistence == .persistent, let pairings {
                try await pairings.save(AnnexSavedPairing(host: host, alias: hostLabel, routes: Self.merge(routes).filter { !$0.sameAddress(as: host.endpoint) },
                                                          identity: identity, credential: credential))
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
            try await pairings.save(AnnexSavedPairing(host: host, alias: saved.alias, routes: others, identity: saved.identity, credential: saved.credential))
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
            try await pairings.save(AnnexSavedPairing(host: saved.host, alias: saved.alias, routes: after, identity: saved.identity, credential: saved.credential))
        }
    }
    /// Loads only already authorized saved pairings; never generates identity or
    /// migrates legacy trust-all credentials. Caller invokes connect explicitly.
    @discardableResult
    public func restoreSaved() async throws -> [Registration] {
        return try await AnnexTelemetry.shared.measure(.restore) {
            guard let pairings else { return [] }
            let requestedRevision = revision
            let saved = try await pairings.loadAll()
            guard requestedRevision == revision else { return all() }
            for pairing in saved where registrations[pairing.host.hostID] == nil {
                guard requestedRevision == revision else { break }
                guard !busyHosts.contains(pairing.host.hostID) else { continue }
                busyHosts.insert(pairing.host.hostID)
                do {
                    try await credentials.save(pairing.credential, for: pairing.host.hostID)
                    _ = try await restoreRegistration(host: pairing.host, alias: pairing.alias, clientIdentity: pairing.identity)
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
        identities.removeValue(forKey: hostID)
        alternates.removeValue(forKey: hostID)
        try await credentials.remove(for: hostID)
        await sessionCredentials.remove(for: hostID)
    }
    public func disconnectAll() async {
        for registration in registrations.values { await registration.transport.disconnect() }
    }
}
