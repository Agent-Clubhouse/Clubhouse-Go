import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionReconnectPerformanceTests {
    @Test func profileActualCatalogFanoutAndHistoryReplacement() async throws {
        guard ProcessInfo.processInfo.environment["CLUBHOUSE_PROFILE_LONG_CHAT"] == "1" else { return }
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setProjects(.array((0..<26).map { .object(["id": .string($0 == 0 ? "project" : "p\($0)"), "name": .string("Fixture \($0)")]) }))
        })
        defer { harness.stop() }
        let events = (1...5_000).map { i in
            LiveServiceHarness.chatEvent("s1", sequence: Int64(i), type: "user_message", data: ["messageId": .string("history-\(i)"), "source": .string("mcp"),
                "content": .array([.object(["type": .string("text"), "text": .string(i % 20 == 0 ? String(repeating: "[FROM:River] Long **delivery**.\n\n", count: 50) : "[FROM:River] Update \(i)")])])])
        }
        let snapshot = LiveServiceHarness.chatSnapshot(fields: ["events": .array(events)])
        try await harness.loadSession(snapshot)
        let stream = harness.service.events()
        var catalogs = 0, timelines = 0, upserts = 0
        let watcher = Task { @MainActor in
            for await event in stream {
                switch event {
                case .hosts: catalogs += 1
                case .timeline: timelines += 1
                case .upsert: upserts += 1
                default: break
                }
            }
        }
        defer { watcher.cancel() }
        await Task.yield()
        let readsBefore = await harness.transport.readRoutes.count
        let started = Date()
        try await harness.refreshCatalog()
        for _ in 0..<2 { await harness.store.load(harness.target, force: true) }
        await Task.yield()
        let elapsed = Date().timeIntervalSince(started) * 1000
        let reads = Array(await harness.transport.readRoutes.dropFirst(readsBefore))
        let agentReads = reads.filter { $0.name == "agents" }.count
        print("LONG_CHAT_REAL_RECONNECT rows=5000 agentReads=\(agentReads) totalReads=\(reads.count) hostPublications=\(catalogs) timelinePublications=\(timelines) upsertPublications=\(upserts) elapsedMs=\(elapsed) retained=\(harness.store.conversation(for: harness.target).items.count)")
        #expect(harness.store.conversation(for: harness.target).items.count == 5_000)
    }
}
