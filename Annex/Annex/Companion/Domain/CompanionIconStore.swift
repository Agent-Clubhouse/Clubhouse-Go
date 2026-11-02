import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Local identity only. The protocol adapter supplies the opaque version; these are not wire fields.
nonisolated struct CompanionIconReference: Hashable, Sendable {
    enum Kind: String, Sendable { case agent, project }
    let host: String
    let kind: Kind
    let id: String
    let version: String

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inline(host: String, kind: Kind, id: String, data: Data) -> Self {
        .init(host: host, kind: kind, id: id, version: digest(data))
    }
    var hostDigest: String { Self.digest(Data(host.utf8)) }
    var digest: String {
        // Length-delimited fields avoid ambiguous identities without putting raw IDs on disk.
        Self.digest(Data([kind.rawValue, id, version].map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
}

nonisolated struct CompanionIconImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// A purgeable, best-effort icon-only cache. Disk IO and ImageIO work run on this actor, never in view body.
/// A miss never throws into chat or connection state. Only visible consumers start remote requests.
actor CompanionIconStore {
    static let shared = CompanionIconStore()
    struct Limits: Sendable {
        var totalBytes = 64 * 1024 * 1024
        var imageBytes = 1024 * 1024
        var inputPixels = 40_000_000
        var concurrentFetches = 2
    }
    struct Response: Sendable {
        let status: Int
        let contentType: String
        let data: Data
        /// Normalized identity of the returned bytes, supplied by the adapter (e.g. a strong ETag).
        let version: String?
        init(status: Int, contentType: String, data: Data, version: String? = nil) {
            self.status = status; self.contentType = contentType; self.data = data; self.version = version
        }
    }
    typealias Fetcher = @Sendable (CompanionIconReference, Int) async throws -> Response
    struct Statistics: Sendable {
        var hits = 0, misses = 0, failures = 0, evictions = 0, totalBytes = 0
    }
    private struct FileEntry { var bytes: Int; var access: TimeInterval }
    private struct Failure { var attempts: Int; var retry: Date }
    private struct Waiter { let pixels: Int; let continuation: CheckedContinuation<CompanionIconImage?, Never> }
    private struct Job {
        let id = UUID()
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
    }
    private final class ImageBox { let image: CompanionIconImage; init(_ image: CompanionIconImage) { self.image = image } }
    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var initialized = false
    private var files: [URL: FileEntry] = [:]
    private var stats = Statistics()
    private var lastAccess: TimeInterval = 0
    private var failures: [CompanionIconReference: Failure] = [:]
    private var fetchers: [String: Fetcher] = [:]
    private var removedHosts: Set<String> = []
    private var jobs: [CompanionIconReference: Job] = [:]
    private var queue: [CompanionIconReference] = []
    private var running = 0
    private let decoded = NSCache<NSString, ImageBox>()

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CompanionIcons", isDirectory: true), limits: Limits = .init(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
        decoded.totalCostLimit = 16 * 1024 * 1024
        decoded.countLimit = 256
    }

    var statistics: Statistics { prepare(); return stats }
    func activate(host: String) { removedHosts.remove(host) }
    func setFetcher(for host: String, _ fetcher: Fetcher?) { fetchers[host] = fetcher }
    func fileURL(for key: CompanionIconReference) -> URL {
        directory.appendingPathComponent(key.hostDigest, isDirectory: true).appendingPathComponent(key.digest)
    }

    /// Inline data is consumed once; callers retain only the returned key, never its base64 or decoded bytes.
    func ingest(dataURL: String, host: String, kind: CompanionIconReference.Kind, id: String) -> CompanionIconReference? {
        guard dataURL.utf8.count <= (limits.imageBytes + 2) / 3 * 4 + 256,
              let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].hasPrefix("data:image/"),
              dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              data.count <= limits.imageBytes else { recordFailure(); return nil }
        let key = CompanionIconReference.inline(host: host, kind: kind, id: id, data: data)
        guard insert(data, for: key) else { recordFailure(); return nil }
        return key
    }

    @discardableResult func insert(_ data: Data, for key: CompanionIconReference) -> Bool {
        prepare()
        guard !removedHosts.contains(key.host), data.count <= limits.imageBytes, data.count <= limits.totalBytes,
              thumbnail(data, pixels: 96) != nil else { return false }
        let url = fileURL(for: key)
        if files[url] != nil, read(key, pixels: 96) != nil { return true }
        do {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try data.write(to: url, options: .atomic)
            if let previous = files[url] { stats.totalBytes -= previous.bytes }
            files[url] = .init(bytes: data.count, access: tick())
            stats.totalBytes += data.count
            touch(url)
            failures.removeValue(forKey: key)
            evict(); metric()
            return true
        } catch { return false }
    }

    func image(for key: CompanionIconReference, points: Double) async -> CompanionIconImage? {
        guard !Task.isCancelled else { return nil }
        prepare()
        let pixels = max(1, min(384, Int((points.isFinite ? max(1, min(128, points)) : 32) * 3)))
        if let image = read(key, pixels: pixels) { stats.hits += 1; metric(.iconHit); return image }
        stats.misses += 1; metric(.iconMiss)
        guard fetchers[key.host] != nil, failures[key].map({ $0.retry <= now() }) ?? true else { return nil }
        let consumer = UUID()
        let result: CompanionIconImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if jobs[key] == nil {
                    guard queue.count < 256 else { continuation.resume(returning: nil); return }
                    jobs[key] = Job(); queue.append(key)
                }
                jobs[key]?.waiters[consumer] = .init(pixels: pixels, continuation: continuation)
                pump()
            }
        } onCancel: { Task { await self.cancel(key, consumer: consumer) } }
        return Task.isCancelled ? nil : result
    }

    /// Forgetting a desktop cancels pending work and fences late responses before deleting its entire scope.
    func remove(host: String) {
        prepare()
        removedHosts.insert(host)
        fetchers.removeValue(forKey: host)
        for key in Array(jobs.keys) where key.host == host { discard(key) }
        failures = failures.filter { $0.key.host != host }
        let digest = CompanionIconReference.digest(Data(host.utf8))
        for url in Array(files.keys) where url.deletingLastPathComponent().lastPathComponent == digest { delete(url, eviction: false) }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(digest))
        decoded.removeAllObjects()
        metric(); pump()
    }

    private func pump() {
        while running < max(1, min(3, limits.concurrentFetches)), !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = jobs[key], let fetch = fetchers[key.host] else { discard(key); continue }
            let id = job.id, maximumBytes = limits.imageBytes
            running += 1
            jobs[key]?.task = Task {
                let started = ContinuousClock.now
                let result: Result<Response, Error>
                do { result = .success(try await fetch(key, maximumBytes)) } catch { result = .failure(error) }
                complete(key, id: id, result: result, cancelled: Task.isCancelled,
                         duration: started.duration(to: .now))
            }
        }
    }
    private func complete(_ key: CompanionIconReference, id: UUID, result: Result<Response, Error>, cancelled: Bool, duration: Duration) {
        running -= 1
        defer { pump() }
        guard let job = jobs[key], job.id == id else { return }
        jobs.removeValue(forKey: key)
        let span = AnnexTelemetry.shared.begin(.iconFetch)
        span.number(.durationMs, Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        var success = false
        var superseded = false
        if !cancelled, case .success(let response) = result {
            span.number(.responseBytes, Double(response.data.count))
            if response.status == 200, response.contentType.lowercased().hasPrefix("image/"),
               let version = response.version, !version.isEmpty {
                let returned = CompanionIconReference(host: key.host, kind: key.kind, id: key.id, version: version)
                let admitted = insert(response.data, for: returned)
                success = admitted && returned == key
                superseded = returned != key
            }
        }
        if !success, !cancelled {
            let attempts = min(8, (failures[key]?.attempts ?? 0) + 1)
            if failures.count >= 1024, let oldest = failures.min(by: { $0.value.retry < $1.value.retry })?.key { failures.removeValue(forKey: oldest) }
            failures[key] = .init(attempts: attempts, retry: superseded ? .distantFuture : now().addingTimeInterval(min(3600, 30 * pow(2, Double(attempts - 1)))))
            recordFailure()
        }
        span.fail(success ? .none : cancelled ? .cancelled : .malformed); span.end()
        for waiter in job.waiters.values { waiter.continuation.resume(returning: success ? read(key, pixels: waiter.pixels) : nil) }
    }
    private func cancel(_ key: CompanionIconReference, consumer: UUID) {
        guard let waiter = jobs[key]?.waiters.removeValue(forKey: consumer) else { return }
        waiter.continuation.resume(returning: nil)
        if jobs[key]?.waiters.isEmpty == true { discard(key) }
    }
    private func discard(_ key: CompanionIconReference) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.task?.cancel()
        queue.removeAll { $0 == key }
        for waiter in job.waiters.values { waiter.continuation.resume(returning: nil) }
    }
    private func read(_ key: CompanionIconReference, pixels: Int) -> CompanionIconImage? {
        let url = fileURL(for: key)
        guard files[url] != nil else { return nil }
        let cacheKey = "\(key.hostDigest)/\(key.digest)/\(pixels)" as NSString
        if let cached = decoded.object(forKey: cacheKey) { touch(url); return cached.image }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= limits.imageBytes, let data = try? Data(contentsOf: url),
              let image = thumbnail(data, pixels: pixels) else { delete(url, eviction: false); return nil }
        decoded.setObject(ImageBox(image), forKey: cacheKey, cost: image.cgImage.bytesPerRow * image.cgImage.height)
        touch(url)
        return image
    }
    private func thumbnail(_ data: Data, pixels: Int) -> CompanionIconImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              [UTType.png, .jpeg, .gif, .tiff, .bmp, .heic, .heif, .webP].contains(where: { type.conforms(to: $0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width <= limits.inputPixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        return .init(cgImage: image)
    }
    private func prepare() {
        guard !initialized else { return }; initialized = true
        do {
            var root = directory
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
            let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [])
            while let url = urls?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                let isDigest: (String) -> Bool = { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
                guard isDigest(url.lastPathComponent), isDigest(url.deletingLastPathComponent().lastPathComponent), let bytes = values.fileSize, bytes > 0, bytes <= limits.imageBytes else { try? FileManager.default.removeItem(at: url); continue }
                let access = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                files[url] = .init(bytes: bytes, access: access); stats.totalBytes += bytes; lastAccess = max(lastAccess, access)
            }
            evict()
        } catch { /* A disk-cache failure cannot affect the host or chat. */ }
    }
    private func tick() -> TimeInterval { lastAccess = max(now().timeIntervalSince1970, lastAccess + 0.001); return lastAccess }
    private func touch(_ url: URL) {
        let access = tick(); files[url]?.access = access
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: access)], ofItemAtPath: url.path)
    }
    private func evict() {
        while stats.totalBytes > max(0, limits.totalBytes), let oldest = files.min(by: { $0.value.access < $1.value.access })?.key { delete(oldest, eviction: true) }
    }
    private func delete(_ url: URL, eviction: Bool) {
        if let entry = files.removeValue(forKey: url) { stats.totalBytes -= entry.bytes }
        try? FileManager.default.removeItem(at: url)
        decoded.removeAllObjects()
        if eviction { stats.evictions += 1; metric(.iconEviction) }
    }
    private func recordFailure() { stats.failures += 1; metric(.iconFailure) }
    private func metric(_ event: AnnexDiagnosticEvent? = nil) {
        let span = AnnexTelemetry.shared.begin(.iconCache)
        if let event { span.event(event) }; span.number(.cacheBytes, Double(stats.totalBytes)); span.end()
    }
}
