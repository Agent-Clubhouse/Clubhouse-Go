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
        AppLog.shared.info("Keychain", "Saving instance \(id.value) (proto=\(protocolConfig.label), hasServerKey=\(serverPublicKey != nil))")
        let saved = SavedInstance(
            id: id, token: token,
            protocolConfig: protocolConfig,
            serverPublicKey: serverPublicKey
        )
        guard let data = try? JSONEncoder().encode(saved) else {
            AppLog.shared.error("Keychain", "Failed to encode instance \(id.value)")
            return
        }
        save(account: "instance-\(id.value)", data: data)

        var ids = loadInstanceIDs()
        if !ids.contains(id) { ids.append(id) }
        guard let indexData = try? JSONEncoder().encode(ids) else { return }
        save(account: "instance-index", data: indexData)
        AppLog.shared.info("Keychain", "Instance saved. Index now has \(ids.count) instance(s)")
    }

    static func loadAllInstances() -> [SavedInstance] {
        let ids = loadInstanceIDs()
        AppLog.shared.info("Keychain", "Loading all instances (index has \(ids.count) id(s))")
        let result = ids.compactMap { loadInstance(id: $0) }
        AppLog.shared.info("Keychain", "Loaded \(result.count) instance(s) of \(ids.count)")
        return result
    }

    static func loadInstance(id: ServerInstanceID) -> SavedInstance? {
        guard let data = load(account: "instance-\(id.value)") else {
            AppLog.shared.warn("Keychain", "No data for instance \(id.value)")
            return nil
        }
        guard let saved = try? JSONDecoder().decode(SavedInstance.self, from: data) else {
            AppLog.shared.error("Keychain", "Failed to decode instance \(id.value)")
            return nil
        }
        AppLog.shared.debug("Keychain", "Loaded instance \(id.value) (proto=\(saved.protocolConfig.label))")
        return saved
    }

    static func deleteInstance(id: ServerInstanceID) {
        AppLog.shared.info("Keychain", "Deleting instance \(id.value)")
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
        AppLog.shared.info("Keychain", "Clearing all instances and legacy data")
        let ids = loadInstanceIDs()
        for id in ids {
            delete(account: "instance-\(id.value)")
        }
        delete(account: "instance-index")
    }

    // MARK: - Ed25519 Identity (app-global)

    static func saveEd25519PrivateKey(_ keyData: Data) {
        AppLog.shared.info("Keychain", "Saving Ed25519 private key (\(keyData.count) bytes)")
        save(account: "ed25519-private-key", data: keyData)
    }

    static func loadEd25519PrivateKey() -> Data? {
        let data = load(account: "ed25519-private-key")
        AppLog.shared.debug("Keychain", "Load Ed25519 key: \(data != nil ? "\(data!.count) bytes" : "not found")")
        return data
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
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.shared.error("Keychain", "SecItemAdd failed for '\(account)': OSStatus \(status)")
        }
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
