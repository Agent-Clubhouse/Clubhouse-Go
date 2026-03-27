import Foundation
import UIKit

/// Thread-safe LRU cache for agent and project icon data.
/// Provides in-memory caching with size limits and on-demand loading.
@Observable final class IconCache {
    private var cache: [String: CacheEntry] = [:]
    private var accessOrder: [String] = [] // most recent at end
    private var inFlight: Set<String> = []
    private let maxEntries: Int
    private let lock = NSLock()

    struct CacheEntry {
        let data: Data
        let image: UIImage
        let fetchedAt: Date
    }

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    /// Get a cached image for the given key, or nil if not cached.
    func image(for key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        touchLocked(key)
        return entry.image
    }

    /// Store icon data in the cache.
    func store(key: String, data: Data) {
        guard let image = UIImage(data: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        cache[key] = CacheEntry(data: data, image: image, fetchedAt: Date())
        touchLocked(key)
        evictIfNeededLocked()
    }

    /// Store raw Data (from snapshot base64 or REST fetch) for an agent or project.
    func storeIfNeeded(key: String, data: Data) {
        lock.lock()
        let exists = cache[key] != nil
        lock.unlock()
        if !exists {
            store(key: key, data: data)
        }
    }

    /// Check if a key is already cached.
    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[key] != nil
    }

    /// Remove a specific entry.
    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    /// Clear the entire cache.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        accessOrder.removeAll()
        inFlight.removeAll()
    }

    /// Number of cached entries.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: - On-Demand Loading

    /// Load an icon on demand if not cached and not already in-flight.
    /// Fetches from the REST API and caches the result.
    func loadIfNeeded(
        key: String,
        fetch: @escaping () async -> Data?
    ) {
        lock.lock()
        let cached = cache[key] != nil
        let flying = inFlight.contains(key)
        if !cached && !flying {
            inFlight.insert(key)
        }
        lock.unlock()

        guard !cached && !flying else { return }

        Task {
            if let data = await fetch() {
                store(key: key, data: data)
            }
            lock.lock()
            inFlight.remove(key)
            lock.unlock()
        }
    }

    // MARK: - Batch Loading

    /// Load icons from snapshot base64 data dictionaries.
    func loadFromSnapshot(agentIcons: [String: Data], projectIcons: [String: Data]) {
        for (id, data) in agentIcons {
            storeIfNeeded(key: "agent:\(id)", data: data)
        }
        for (id, data) in projectIcons {
            storeIfNeeded(key: "project:\(id)", data: data)
        }
    }

    // MARK: - Convenience Accessors

    func agentImage(id: String) -> UIImage? {
        image(for: "agent:\(id)")
    }

    func projectImage(id: String) -> UIImage? {
        image(for: "project:\(id)")
    }

    func storeAgentIcon(id: String, data: Data) {
        store(key: "agent:\(id)", data: data)
    }

    func storeProjectIcon(id: String, data: Data) {
        store(key: "project:\(id)", data: data)
    }

    // MARK: - Private

    private func touchLocked(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeededLocked() {
        while cache.count > maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }
}
