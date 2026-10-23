import Foundation

/// Composition root for presentation. UI never reads bearer tokens or private
/// keys. Legacy trust-all credentials are deliberately not migrated implicitly.
public actor AnnexTransportRegistry {
    public struct Registration: Sendable {
        public let host: TrustedAnnexHost
        public let alias: String
        public let transport: any AnnexTransporting
    }
    private let credentials: any AnnexCredentialStore
    private var registrations: [String: Registration] = [:]
    private var identities: [String: AnnexClientIdentity] = [:]
    public init(credentials: any AnnexCredentialStore = MemoryAnnexCredentialStore()) { self.credentials = credentials }
    public func all() -> [Registration] { Array(registrations.values) }
    public func transport(for hostID: String) -> (any AnnexTransporting)? { registrations[hostID]?.transport }

    /// This call is the explicit user-authorized pairing action. For isolated
    /// integration use MemoryAnnexCredentialStore (default); identity remains in
    /// memory and is never installed in the simulator or system trust store.
    @discardableResult
    public func pair(host: TrustedAnnexHost, pin: String, alias: String, clientIdentity: AnnexClientIdentity? = nil) async throws -> Registration {
        let identity = try clientIdentity ?? AnnexClientIdentity.ephemeral()
        let io = PinnedAnnexIO(host: host, clientIdentity: identity)
        let result = try await AnnexPairingClient(host: host, clientIdentity: identity, credentials: credentials, io: io).pair(pin: pin, alias: alias)
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
    public func remove(hostID: String) async throws {
        if let registration = registrations.removeValue(forKey: hostID) { await registration.transport.disconnect() }
        identities.removeValue(forKey: hostID)
        try await credentials.remove(for: hostID)
    }
    public func disconnectAll() async {
        for registration in registrations.values { await registration.transport.disconnect() }
    }
}
