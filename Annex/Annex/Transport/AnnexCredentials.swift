import Foundation
import Security

/// Redacted by default, including debugger descriptions. Never put tokens in URLs.
public struct AnnexCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, Equatable {
    let bearerToken: String
    public init(bearerToken: String) throws {
        guard !bearerToken.isEmpty, bearerToken.count <= 8192,
              !bearerToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw AnnexTransportError.credentialMissing
        }
        self.bearerToken = bearerToken
    }
    public var description: String { "AnnexCredential(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol AnnexCredentialStore: Sendable {
    func credential(for hostID: String) async throws -> AnnexCredential?
    func save(_ credential: AnnexCredential, for hostID: String) async throws
    func remove(for hostID: String) async throws
}

/// Default test/development store. No real credentials are generated or persisted.
public actor MemoryAnnexCredentialStore: AnnexCredentialStore {
    private var values: [String: AnnexCredential] = [:]
    public init() {}
    public func credential(for hostID: String) -> AnnexCredential? { values[hostID] }
    public func save(_ credential: AnnexCredential, for hostID: String) { values[hostID] = credential }
    public func remove(for hostID: String) { values.removeValue(forKey: hostID) }
}

/// Explicitly injected by the app after pairing approval. No access groups,
/// synchronization, automatic migration, identity generation or credential logging.
public actor KeychainAnnexCredentialStore: AnnexCredentialStore {
    private let service: String
    public init(service: String = "com.agentclubhouse.go.secure-transport") { self.service = service }
    private func query(_ hostID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: hostID, kSecAttrSynchronizable as String: false]
    }
    public func credential(for hostID: String) throws -> AnnexCredential? {
        var q = query(hostID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AnnexTransportError.persistenceFailed(status)
        }
        return try AnnexCredential(bearerToken: token)
    }
    public func save(_ credential: AnnexCredential, for hostID: String) throws {
        let q = query(hostID)
        let values: [String: Any] = [kSecValueData as String: Data(credential.bearerToken.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw AnnexTransportError.persistenceFailed(status) }
        } else if updated != errSecSuccess { throw AnnexTransportError.persistenceFailed(updated) }
    }
    public func remove(for hostID: String) throws {
        let status = SecItemDelete(query(hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AnnexTransportError.persistenceFailed(status) }
    }
}
