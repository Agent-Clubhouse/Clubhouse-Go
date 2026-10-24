import Foundation
import Security

/// Operations must commit atomically or throw. Scope is endpoint + game, never build SHA.
/// One Client owns a scope; do not share it with another client, process or app extension.
public protocol EnrollmentStore: Sendable {
    func load(scope: String) throws -> EnrollmentRecord
    func save(_ record: EnrollmentRecord, scope: String) throws
}
public protocol FeedbackStore: Sendable {
    func load(scope: String) throws -> [QueuedFeedback]
    func save(_ items: [QueuedFeedback], scope: String) throws
}

/// Refresh credentials only, device-local and available only while unlocked. No iCloud sync.
public struct KeychainEnrollmentStore: EnrollmentStore {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: scope, kSecAttrSynchronizable as String: false]
    }
    public func load(scope: String) throws -> EnrollmentRecord {
        var q = query(scope); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return EnrollmentRecord() }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 4096,
              let record = try? JSONDecoder().decode(EnrollmentRecord.self, from: data) else { throw FramebriarError.storage }
        return record
    }
    public func save(_ record: EnrollmentRecord, scope: String) throws {
        let data = try JSONEncoder().encode(record)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(scope) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(scope).merging(attrs) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw FramebriarError.storage }
        } else if status != errSecSuccess { throw FramebriarError.storage }
    }
}

/// Atomic protected file in a host-selected Application Support directory, excluded from backup.
/// An error never causes the SDK to silently replace corrupt or inaccessible queued feedback.
public struct FileFeedbackStore: FeedbackStore {
    private let directory: URL
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw FramebriarError.storage }
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { throw FramebriarError.storage }
    }
    private func url(_ scope: String) -> URL { directory.appendingPathComponent(digest(Data(scope.utf8)) + ".json") }
    public func load(scope: String) throws -> [QueuedFeedback] {
        let file = url(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 46 * 1024 * 1024 else { throw FramebriarError.storage }
            return try JSONDecoder().decode([QueuedFeedback].self, from: Data(contentsOf: file))
        } catch { throw FramebriarError.storage }
    }
    public func save(_ items: [QueuedFeedback], scope: String) throws {
        do {
            let data = try JSONEncoder().encode(items)
            guard items.count <= ClientStatus.maxItems, data.count <= 46 * 1024 * 1024 else { throw FramebriarError.capacity }
            #if os(iOS)
            try data.write(to: url(scope), options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url(scope), options: .atomic)
            #endif
            // The containing directory is private and excluded from backups, including atomic replacements.
        } catch let error as FramebriarError { throw error }
        catch { throw FramebriarError.storage }
    }
}
