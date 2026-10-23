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
    private let credentials: any AnnexCredentialStore
    private var registrations: [String: Registration] = [:]
    private var identities: [String: AnnexClientIdentity] = [:]
    public init(credentials: any AnnexCredentialStore = MemoryAnnexCredentialStore(), pairings: (any AnnexPairingStore)? = nil) { self.credentials = credentials; self.pairings = pairings }
    public func all() -> [Registration] { Array(registrations.values) }
    public func transport(for hostID: String) -> (any AnnexTransporting)? { registrations[hostID]?.transport }

    /// This call is the explicit user-authorized pairing action. For isolated
    /// integration use MemoryAnnexCredentialStore (default); identity remains in
    /// memory and is never installed in the simulator or system trust store.
    @discardableResult
    public func pair(host: TrustedAnnexHost, pin: String, alias: String, clientIdentity: AnnexClientIdentity? = nil, persistence: Persistence = .sessionOnly) async throws -> Registration {
        guard !busyHosts.contains(host.hostID) else { throw AnnexTransportError.commandInFlight }
        if persistence == .persistent && pairings == nil { throw AnnexTransportError.persistenceFailed(errSecNotAvailable) }
        busyHosts.insert(host.hostID)
        defer { busyHosts.remove(host.hostID) }
        let identity = try clientIdentity ?? AnnexClientIdentity.ephemeral()
        let io = PinnedAnnexIO(host: host, clientIdentity: identity)
        let temporary = MemoryAnnexCredentialStore()
        let result = try await AnnexPairingClient(host: host, clientIdentity: identity, credentials: temporary, io: io).pair(pin: pin, alias: alias, mode: persistence == .persistent ? .persistent : .session)
        guard let credential = await temporary.credential(for: host.hostID) else { throw AnnexTransportError.credentialMissing }
        if persistence == .persistent, let pairings {
            try await pairings.save(AnnexSavedPairing(host: host, alias: result.alias, identity: identity, credential: credential))
        }
        try await credentials.save(credential, for: host.hostID)
        let transport = AnnexTransport(host: host, credentials: credentials, clientIdentity: identity, io: io)
        if let old = registrations[host.hostID] { await old.transport.disconnect() }
        let registration = Registration(host: host, alias: result.alias, transport: transport)
        identities[host.hostID] = identity
        registrations[host.hostID] = registration
        return registration
    }

    /// Inject an already approved identity and host at app restoration. The
    /// identity store is an application policy, separate from endpoint discovery.
    @discardableResult
    public func restore(host: TrustedAnnexHost, alias: String, clientIdentity: AnnexClientIdentity) async throws -> Registration {
        guard try await credentials.credential(for: host.hostID) != nil else { throw AnnexTransportError.credentialMissing }
        if let old = registrations[host.hostID] { await old.transport.disconnect() }
        let transport = AnnexTransport(host: host, credentials: credentials, clientIdentity: clientIdentity)
        let registration = Registration(host: host, alias: alias, transport: transport)
        identities[host.hostID] = clientIdentity; registrations[host.hostID] = registration
        return registration
    }
    /// Loads only already authorized saved pairings; never generates identity or
    /// migrates legacy trust-all credentials. Caller invokes connect explicitly.
    @discardableResult
    public func restoreSaved() async throws -> [Registration] {
        guard let pairings else { return [] }
        let saved = try await pairings.loadAll()
        for pairing in saved where registrations[pairing.host.hostID] == nil {
            guard !busyHosts.contains(pairing.host.hostID) else { continue }
            busyHosts.insert(pairing.host.hostID)
            do {
                try await credentials.save(pairing.credential, for: pairing.host.hostID)
                _ = try await restore(host: pairing.host, alias: pairing.alias, clientIdentity: pairing.identity)
                busyHosts.remove(pairing.host.hostID)
            } catch { busyHosts.remove(pairing.host.hostID); throw error }
        }
        return all()
    }
    public func remove(hostID: String) async throws {
        guard !busyHosts.contains(hostID) else { throw AnnexTransportError.commandInFlight }
        busyHosts.insert(hostID)
        defer { busyHosts.remove(hostID) }
        try await pairings?.remove(hostID: hostID)
        if let registration = registrations.removeValue(forKey: hostID) { await registration.transport.disconnect() }
        identities.removeValue(forKey: hostID)
        try await credentials.remove(for: hostID)
    }
    public func disconnectAll() async {
        for registration in registrations.values { await registration.transport.disconnect() }
    }
}
