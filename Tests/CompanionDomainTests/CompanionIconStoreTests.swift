import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionIconStoreTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/icon-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func key(_ id: String = "private/id", host: String = "desktop", token: String = "v1") -> CompanionIconReference {
        .init(host: host, kind: .agent, id: id, version: token)
    }
    static func png(width: Int = 12, height: Int = 12) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func byteBoundariesAndInvalidFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try Self.png()
        let store = CompanionIconStore(directory: root, limits: .init(totalBytes: png.count * 3, imageBytes: png.count))
        #expect(await store.insert(png, for: key()))
        #expect(await store.image(for: key(), points: 20) != nil)
        #expect(await store.insert(png + Data([0]), for: key("over")) == false)
        #expect(await store.insert(Data("not an image".utf8), for: key("text")) == false)
        #expect(await store.insert(Data(png.prefix(25)), for: key("truncated")) == false)
        let path = await store.fileURL(for: key())
        try Data([0, 1]).write(to: path)
        let reopened = CompanionIconStore(directory: root)
        #expect(await reopened.image(for: key(), points: 20) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func exactDefaultImageBudgetAndTruncatedDiskRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Self.png()
        let limit = CompanionIconStore.Limits().imageBytes
        #expect(limit == 1024 * 1024)
        #expect(CompanionIconStore.Limits().totalBytes == 64 * 1024 * 1024)
        let exact = original + Data(repeating: 0, count: limit - original.count)
        let store = CompanionIconStore(directory: root)
        #expect(await store.insert(exact, for: key()))
        #expect(await store.insert(exact + Data([0]), for: key("one-over")) == false)
        let path = await store.fileURL(for: key())
        try original.prefix(25).write(to: path, options: .atomic)
        let reopened = CompanionIconStore(directory: root)
        let fetcher = Fetcher(response: .init(status: 200, contentType: "image/png", data: original))
        await reopened.setFetcher(for: "desktop") { _, _ in await fetcher.fetch() }
        #expect(await reopened.image(for: key(), points: 32) != nil)
        #expect(await fetcher.calls == 1)
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func thrownOfflineFailuresBackOffAndVersionChangesFetchIndependently() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let fetcher = Fetcher(response: .init(status: 200, contentType: "image/png", data: try Self.png()))
        let store = CompanionIconStore(directory: root, now: { clock.now })
        await store.setFetcher(for: "desktop") { _, _ in
            _ = await fetcher.fetch()
            throw URLError(.notConnectedToInternet)
        }
        for _ in 0..<10 { #expect(await store.image(for: key(), points: 32) == nil) }
        #expect(await fetcher.calls == 1)
        // New tokens have independent failure state; old bytes never stand in for a new token.
        await store.setFetcher(for: "desktop") { _, _ in await fetcher.fetch() }
        #expect(await store.image(for: key(token: "v2"), points: 32) != nil)
        #expect(await store.image(for: key(), points: 32) == nil)
        #expect(await fetcher.calls == 2)
        clock.advance(31)
        #expect(await store.image(for: key(), points: 32) != nil)
        #expect(await fetcher.calls == 3)
    }

    @Test func svgAndOversizedFetchesUseBoundedRasterFallback() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="1000000" height="1000000"><rect width="1000000" height="1000000" fill="#6366f1"/></svg>"##.utf8)
        let store = CompanionIconStore(directory: root)
        #expect(await store.ingest(dataURL: "data:image/svg+xml;base64," + svg.base64EncodedString(), host: "desktop", kind: .agent, id: "svg") == nil)
        #expect(await store.insert(svg, for: key("direct-svg")) == false)
        await store.setFetcher(for: "desktop") { _, limit in
            .init(status: 200, contentType: "image/png", data: Data(repeating: 0, count: limit + 1))
        }
        #expect(await store.image(for: key("oversize"), points: 32) == nil)
        #expect(await store.statistics.totalBytes == 0)
    }

    @Test func downsamplingAndPixelBound() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root, limits: .init(inputPixels: 100_000))
        #expect(await store.insert(try Self.png(width: 300, height: 300), for: key()))
        let image = try #require(await store.image(for: key(), points: 20))
        #expect(image.cgImage.width == 60 && image.cgImage.height == 60)
        #expect(await store.insert(try Self.png(width: 400, height: 400), for: key("pixels")) == false)
    }

    @Test func diskOfflineTokensHostsAndPrivacy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try Self.png()
        let store = CompanionIconStore(directory: root)
        #expect(await store.insert(data, for: key()))
        #expect(await store.insert(data, for: key(host: "other")))
        let reopened = CompanionIconStore(directory: root)
        #expect(await reopened.image(for: key(), points: 32) != nil)
        #expect(await reopened.image(for: key(token: "changed"), points: 32) == nil)
        let path = await store.fileURL(for: key())
        #expect(!path.path.contains("private") && !path.path.contains("desktop"))
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await reopened.remove(host: "desktop")
        #expect(await reopened.image(for: key(), points: 32) == nil)
        #expect(await reopened.image(for: key(host: "other"), points: 32) != nil)
    }

    @Test func startupRemovesAbandonedAtomicFilesAndUnrecognizedNames() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let path = await store.fileURL(for: key())
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let abandoned = path.deletingLastPathComponent().appendingPathComponent(".atomic-leftover")
        let unknown = path.deletingLastPathComponent().appendingPathComponent(String(repeating: "z", count: 64))
        try Data([1, 2]).write(to: abandoned)
        try Data([1, 2]).write(to: unknown)
        #expect(await store.statistics.totalBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
        #expect(await store.ingest(dataURL: "data:image/png;base64,AQID", host: "desktop", kind: .agent, id: "invalid") == nil)
        #expect(await store.statistics.failures == 1)
    }

    @Test func lruAndStartupEviction() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try Self.png()
        let store = CompanionIconStore(directory: root, limits: .init(totalBytes: data.count * 2))
        #expect(await store.insert(data, for: key("one")))
        #expect(await store.insert(data, for: key("two")))
        #expect(await store.image(for: key("one"), points: 32) != nil)
        #expect(await store.insert(data, for: key("three")))
        #expect(await store.image(for: key("two"), points: 32) == nil)
        #expect(await store.image(for: key("one"), points: 32) != nil)
        #expect(await store.statistics.evictions == 1)
        let reopened = CompanionIconStore(directory: root, limits: .init(totalBytes: data.count))
        #expect(await reopened.statistics.totalBytes <= data.count)
    }

    @Test func failuresBackOffWithoutLoopAndRejectNonImages() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let fetcher = Fetcher(response: .init(status: 404, contentType: "application/json", data: Data()))
        let store = CompanionIconStore(directory: root, now: { clock.now })
        await store.setFetcher(for: "desktop") { _, _ in await fetcher.fetch() }
        for _ in 0..<20 { #expect(await store.image(for: key(), points: 32) == nil) }
        #expect(await fetcher.calls == 1)
        clock.advance(31)
        #expect(await store.image(for: key(), points: 32) == nil)
        #expect(await fetcher.calls == 2)
        clock.advance(31)
        #expect(await store.image(for: key(), points: 32) == nil)
        #expect(await fetcher.calls == 2)
        await fetcher.respond(.init(status: 200, contentType: "text/plain", data: try Self.png()))
        #expect(await store.image(for: key("mime"), points: 32) == nil)
        await fetcher.respond(.init(status: 200, contentType: "image/png", data: Data([1, 2])))
        #expect(await store.image(for: key("invalid"), points: 32) == nil)
        #expect(await store.statistics.failures == 4)
    }

    @Test func deduplicationConcurrencyCancellationAndNoRedownload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher(response: .init(status: 200, contentType: "image/png", data: try Self.png()), delayed: true)
        let store = CompanionIconStore(directory: root)
        await store.setFetcher(for: "desktop") { _, _ in try await fetcher.fetchDelayed() }
        let first = Task { await store.image(for: key(), points: 24) }
        let duplicate = Task { await store.image(for: key(), points: 32) }
        let second = Task { await store.image(for: key("two"), points: 32) }
        let third = Task { await store.image(for: key("three"), points: 32) }
        try await wait { await fetcher.calls == 2 }
        first.cancel()
        await fetcher.release()
        #expect(await first.value == nil)
        #expect(await duplicate.value != nil)
        #expect(await second.value != nil)
        #expect(await third.value != nil)
        #expect(await fetcher.peak == 2)
        #expect(await fetcher.calls == 3)
        #expect(await store.image(for: key(), points: 40) != nil)
        #expect(await fetcher.calls == 3)
    }

    @Test func cancellingLastWaiterAndForgettingHostFenceLateWrites() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher(response: .init(status: 200, contentType: "image/png", data: try Self.png()), delayed: true)
        let store = CompanionIconStore(directory: root)
        await store.setFetcher(for: "desktop") { _, _ in try await fetcher.fetchDelayed() }
        let first = Task { await store.image(for: key(), points: 32) }
        try await wait { await fetcher.calls == 1 }
        first.cancel()
        #expect(await first.value == nil)
        let second = Task { await store.image(for: key("two"), points: 32) }
        try await wait { await fetcher.calls == 2 }
        await store.remove(host: "desktop")
        await fetcher.release()
        #expect(await second.value == nil)
        #expect(await store.statistics.totalBytes == 0)
    }

    @MainActor @Test func snapshotRemovalOfflineFallbackAndFailedIconsDoNotBlockChat() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let icons = CompanionIconStore(directory: root)
        let harness = try await LiveServiceHarness.start(iconStore: icons)
        defer { harness.stop() }
        let png = try Self.png()
        await harness.transport.emit(harness.snapshotEvent([
            "projectIcons": .object(["project": .string("data:image/png;base64," + png.base64EncodedString())]),
            "agentIcons": .object(["agent": .string("data:image/png;base64," + png.base64EncodedString())])
        ]))
        try await harness.waitUntil { harness.host?.projects.first?.agents.first?.icon != nil }
        let reference = try #require(harness.host?.projects.first?.agents.first?.icon)
        await harness.transport.emit(.connection(.suspended))
        try await harness.waitUntil { harness.host?.connection == .offline }
        #expect(await icons.image(for: reference, points: 32) != nil)
        // A complete snapshot with no icons removes the appearance, even after a REST refresh.
        await harness.transport.emit(harness.snapshotEvent([:]))
        try await harness.waitUntil { harness.host?.projects.first?.agents.first?.icon == nil }
        try await harness.refreshCatalog()
        #expect(harness.host?.projects.first?.icon == nil)
        #expect(harness.host?.projects.first?.agents.first?.icon == nil)
        await harness.transport.emit(harness.snapshotEvent([
            "agentIcons": .object(["agent": .string("data:image/png;base64,AQID")]),
            "projectIcons": .object(["project": .string("data:image/png;base64,AQID")])
        ]))
        try await harness.loadSession()
        let history = try await harness.service.history(for: harness.target)
        #expect(!history.items.isEmpty)
        #expect(harness.host?.connection == .connected)
        #expect(harness.host?.projects.first?.agents.first?.icon == nil)
    }

    @Test func aLargeInlineSnapshotRetainsOnlySmallReferences() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let png = try Self.png() + Data(repeating: 0, count: 256 * 1024)
        let url = "data:image/png;base64," + png.base64EncodedString()
        let maps = Dictionary(uniqueKeysWithValues: (0..<40).map { ("agent-\($0)", AnnexJSON.string(url)) })
        #expect(url.utf8.count * maps.count > 10 * 1024 * 1024)
        let catalog = await CompanionIconCatalog.inline(projects: nil, agents: .object(maps), host: "desktop", store: store)
        #expect(catalog.agents.count == 40)
        let retained = String(reflecting: catalog)
        #expect(retained.utf8.count < 32 * 1024)
        #expect(!retained.contains("base64") && !retained.contains(url))
        let again = await CompanionIconCatalog.inline(projects: nil, agents: .object(maps), host: "desktop", store: store)
        #expect(catalog == again)
        let removed = await CompanionIconCatalog.inline(projects: nil, agents: nil, host: "desktop", store: store)
        #expect(removed.agents.isEmpty)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Condition timed out")
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 0)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: Double) { lock.withLock { value.addTimeInterval(seconds) } }
    }
    private actor Fetcher {
        var response: CompanionIconStore.Response
        var calls = 0; var active = 0; var peak = 0; var delayed: Bool
        init(response: CompanionIconStore.Response, delayed: Bool = false) { self.response = response; self.delayed = delayed }
        func respond(_ response: CompanionIconStore.Response) { self.response = response }
        func fetch() -> CompanionIconStore.Response { calls += 1; return response }
        func fetchDelayed() async throws -> CompanionIconStore.Response {
            calls += 1; active += 1; peak = max(peak, active)
            defer { active -= 1 }
            while delayed { try await Task.sleep(for: .milliseconds(2)) }
            return response
        }
        func release() { delayed = false }
    }
}
