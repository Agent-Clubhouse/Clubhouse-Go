import Foundation
import Security

/// Full pairing is one atomic Keychain item: host trust, client identity and
/// bearer credential cannot be restored from mismatched partial writes.
nonisolated public struct AnnexSavedPairing: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let host: TrustedAnnexHost
    public let alias: String
    let identity: AnnexClientIdentity
    let credential: AnnexCredential
    public var description: String { "AnnexSavedPairing(<redacted>)" }
    public var debugDescription: String { description }
    init(host: TrustedAnnexHost, alias: String, identity: AnnexClientIdentity, credential: AnnexCredential) {
        self.host = host; self.alias = alias; self.identity = identity; self.credential = credential
    }
    private struct Archive: Codable {
        let version: Int
        let host: TrustedAnnexHost
        let alias: String
        let identity: AnnexClientIdentity.Archive
        let bearerToken: String
    }
    func encoded() throws -> Data {
        try JSONEncoder().encode(Archive(version: 1, host: host, alias: alias, identity: identity.archive(), bearerToken: credential.bearerToken))
    }
    static func decode(_ data: Data) throws -> AnnexSavedPairing {
        let value = try JSONDecoder().decode(Archive.self, from: data)
        guard value.version == 1 else { throw AnnexTransportError.malformedResponse }
        return try AnnexSavedPairing(host: value.host, alias: value.alias, identity: AnnexClientIdentity.restore(value.identity), credential: AnnexCredential(bearerToken: value.bearerToken))
    }
}

nonisolated public protocol AnnexPairingStore: Sendable {
    func loadAll() async throws -> [AnnexSavedPairing]
    func save(_ pairing: AnnexSavedPairing) async throws
    func remove(hostID: String) async throws
}

public actor MemoryAnnexPairingStore: AnnexPairingStore {
    private var records: [String: AnnexSavedPairing] = [:]
    public init() {}
    public func loadAll() -> [AnnexSavedPairing] { Array(records.values) }
    public func save(_ pairing: AnnexSavedPairing) { records[pairing.host.hostID] = pairing }
    public func remove(hostID: String) { records.removeValue(forKey: hostID) }
}

/// Instantiating this type performs no writes. save is called only after the
/// user explicitly chooses persistent pairing. Tests never use this store.
public actor KeychainAnnexPairingStore: AnnexPairingStore {
    private let service: String
    public init(service: String = "com.agentclubhouse.go.pairings.v1") { self.service = service }
    private func query(hostID: String? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        if let hostID { value[kSecAttrAccount as String] = hostID }
        return value
    }
    public func loadAll() throws -> [AnnexSavedPairing] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let records = result as? [Data] else { throw AnnexTransportError.persistenceFailed(status) }
        // Surface corrupt data rather than silently resetting identity and pairing.
        return try records.map(AnnexSavedPairing.decode)
    }
    public func save(_ pairing: AnnexSavedPairing) throws {
        let q = query(hostID: pairing.host.hostID)
        let values: [String: Any] = [kSecValueData as String: try pairing.encoded(),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw AnnexTransportError.persistenceFailed(added) }
        } else if status != errSecSuccess { throw AnnexTransportError.persistenceFailed(status) }
    }
    public func remove(hostID: String) throws {
        let status = SecItemDelete(query(hostID: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AnnexTransportError.persistenceFailed(status) }
    }
}
