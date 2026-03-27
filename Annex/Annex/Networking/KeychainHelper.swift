import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.Agent-Clubhouse.Go"
    private static let legacyService = "com.Agent-Clubhouse.Annex"
    private static let indexLock = NSLock()

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

        indexLock.lock()
        defer { indexLock.unlock() }
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

        indexLock.lock()
        defer { indexLock.unlock() }
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

    // MARK: - Service Migration

    /// Migrate Keychain items from legacy "Annex" service to "Go" service.
    static func migrateServiceIfNeeded() {
        // Check if legacy service has data but new service doesn't
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: "instance-index",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        guard legacyStatus == errSecSuccess, let legacyData = legacyResult as? Data else { return }

        // Check if new service already has data
        if load(account: "instance-index") != nil { return }

        // Migrate: copy all items from legacy to new service
        AppLog.shared.info("Keychain", "Migrating from legacy Annex service to Go service")
        let allLegacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var allResult: AnyObject?
        let allStatus = SecItemCopyMatching(allLegacyQuery as CFDictionary, &allResult)
        guard allStatus == errSecSuccess, let items = allResult as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            save(account: account, data: data)
        }
        AppLog.shared.info("Keychain", "Migrated \(items.count) item(s) from legacy service")
    }

    // MARK: - Internal

    private static func loadInstanceIDs() -> [ServerInstanceID] {
        guard let data = load(account: "instance-index") else { return [] }
        return (try? JSONDecoder().decode([ServerInstanceID].self, from: data)) ?? []
    }

    private static func save(account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        // Try update first — if the item already exists, this is the safe path.
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        // Item doesn't exist yet — add it.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Race: another caller added between our update and add — update again.
            SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        } else if addStatus != errSecSuccess {
            AppLog.shared.error("Keychain", "SecItemAdd failed for '\(account)': OSStatus \(addStatus)")
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
