import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.Agent-Clubhouse.Annex"

    // MARK: - Per-Instance Storage

    struct SavedInstance: Codable {
        let id: ServerInstanceID
        let token: String
        let protocolConfig: ServerProtocol
        let serverPublicKey: String?
    }

    static func saveInstance(
        id: ServerInstanceID,
        token: String,
        protocolConfig: ServerProtocol,
        serverPublicKey: String? = nil
    ) {
        let saved = SavedInstance(
            id: id, token: token,
            protocolConfig: protocolConfig,
            serverPublicKey: serverPublicKey
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        save(account: "instance-\(id.value)", data: data)

        var ids = loadInstanceIDs()
        if !ids.contains(id) { ids.append(id) }
        guard let indexData = try? JSONEncoder().encode(ids) else { return }
        save(account: "instance-index", data: indexData)
    }

    static func loadAllInstances() -> [SavedInstance] {
        loadInstanceIDs().compactMap { loadInstance(id: $0) }
    }

    static func loadInstance(id: ServerInstanceID) -> SavedInstance? {
        guard let data = load(account: "instance-\(id.value)") else { return nil }
        return try? JSONDecoder().decode(SavedInstance.self, from: data)
    }

    static func deleteInstance(id: ServerInstanceID) {
        delete(account: "instance-\(id.value)")
        var ids = loadInstanceIDs()
        ids.removeAll { $0 == id }
        if ids.isEmpty {
            delete(account: "instance-index")
        } else {
            if let data = try? JSONEncoder().encode(ids) {
                save(account: "instance-index", data: data)
            }
        }
    }

    static func clearAll() {
        let ids = loadInstanceIDs()
        for id in ids {
            delete(account: "instance-\(id.value)")
        }
        delete(account: "instance-index")
        // Legacy cleanup
        delete(account: "session-token")
        delete(account: "server-host")
        delete(account: "server-port")
    }

    // MARK: - Ed25519 Identity (app-global)

    static func saveEd25519PrivateKey(_ keyData: Data) {
        save(account: "ed25519-private-key", data: keyData)
    }

    static func loadEd25519PrivateKey() -> Data? {
        load(account: "ed25519-private-key")
    }

    // MARK: - Migration from Legacy Single-Instance Format

    static func migrateIfNeeded() {
        guard let tokenData = load(account: "session-token"),
              let token = String(data: tokenData, encoding: .utf8),
              let hostData = load(account: "server-host"),
              let host = String(data: hostData, encoding: .utf8),
              let portData = load(account: "server-port"),
              let portStr = String(data: portData, encoding: .utf8),
              let port = UInt16(portStr) else { return }

        // Already migrated?
        if !loadInstanceIDs().isEmpty { return }

        let id = ServerInstanceID(value: UUID().uuidString)
        let config = ServerProtocol.v1(host: host, port: port)
        saveInstance(id: id, token: token, protocolConfig: config)

        delete(account: "session-token")
        delete(account: "server-host")
        delete(account: "server-port")
    }

    // MARK: - Internal

    private static func loadInstanceIDs() -> [ServerInstanceID] {
        guard let data = load(account: "instance-index") else { return [] }
        return (try? JSONDecoder().decode([ServerInstanceID].self, from: data)) ?? []
    }

    private static func save(account: String, data: Data) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
