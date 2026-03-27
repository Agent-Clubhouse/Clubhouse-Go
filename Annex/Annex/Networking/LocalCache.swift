import Foundation

/// File-based cache for snapshot and activity data, enabling cold-launch restore.
/// Stores per-instance data in the app's caches directory.
enum LocalCache {
    private static let fileManager = FileManager.default

    private static var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClubhouseGoCache", isDirectory: true)
    }

    private static func ensureDirectory() -> URL? {
        guard let dir = cacheDirectory else { return nil }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Snapshot Caching

    /// Cached subset of snapshot data for cold launch.
    struct CachedSnapshot: Codable {
        let projects: [Project]
        let agents: [String: [DurableAgent]]
        let quickAgents: [String: [QuickAgent]]
        let theme: ThemeColors
        let orchestrators: [String: OrchestratorEntry]
        let serverName: String
        let lastSeq: Int?
        let savedAt: Date
    }

    /// Save the current state as a cached snapshot for cold launch.
    static func saveSnapshot(_ snapshot: CachedSnapshot, instanceId: ServerInstanceID) {
        guard let dir = ensureDirectory() else { return }
        let file = dir.appendingPathComponent("snapshot-\(instanceId.value).json")
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
            AppLog.shared.debug("Cache", "Saved snapshot for \(instanceId.value) (\(data.count) bytes)")
        } catch {
            AppLog.shared.error("Cache", "Failed to save snapshot: \(error)")
        }
    }

    /// Load a cached snapshot for an instance.
    static func loadSnapshot(instanceId: ServerInstanceID) -> CachedSnapshot? {
        guard let dir = cacheDirectory else { return nil }
        let file = dir.appendingPathComponent("snapshot-\(instanceId.value).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(CachedSnapshot.self, from: data)
            AppLog.shared.debug("Cache", "Loaded snapshot for \(instanceId.value) (saved \(snapshot.savedAt))")
            return snapshot
        } catch {
            AppLog.shared.error("Cache", "Failed to decode cached snapshot: \(error)")
            return nil
        }
    }

    // MARK: - Activity Caching

    /// Save recent hook events for all agents of an instance.
    static func saveActivity(_ activity: [String: [HookEvent]], instanceId: ServerInstanceID) {
        guard let dir = ensureDirectory() else { return }
        let file = dir.appendingPathComponent("activity-\(instanceId.value).json")
        // Keep only last 50 events per agent
        let trimmed = activity.mapValues { events in
            Array(events.suffix(50))
        }
        do {
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: file, options: .atomic)
        } catch {
            AppLog.shared.error("Cache", "Failed to save activity: \(error)")
        }
    }

    /// Load cached activity for an instance.
    static func loadActivity(instanceId: ServerInstanceID) -> [String: [HookEvent]]? {
        guard let dir = cacheDirectory else { return nil }
        let file = dir.appendingPathComponent("activity-\(instanceId.value).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String: [HookEvent]].self, from: data)
    }

    // MARK: - Cleanup

    /// Remove all cached data for an instance.
    static func clearInstance(_ instanceId: ServerInstanceID) {
        guard let dir = cacheDirectory else { return }
        let files = [
            "snapshot-\(instanceId.value).json",
            "activity-\(instanceId.value).json"
        ]
        for name in files {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Remove all cached data.
    static func clearAll() {
        guard let dir = cacheDirectory else { return }
        try? fileManager.removeItem(at: dir)
    }
}
