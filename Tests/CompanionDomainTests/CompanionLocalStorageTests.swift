import Foundation
import Testing
@testable import CompanionDomain

/// The phone's own drafts and finished list in UserDefaults, and the fresh-install reset, each in a private suite.
@MainActor struct CompanionLocalStorageTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "companion-storage-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
    private let first = CompanionTarget(hostID: "host", projectID: "project", agentID: "a")
    private let second = CompanionTarget(hostID: "host", projectID: "project", agentID: "b")

    @Test func draftsRoundTripAndEmptyOnesAreDropped() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let drafts = CompanionLocalDrafts(defaults: defaults)
        #expect(drafts.load().isEmpty)
        drafts.save([first: "Half a thought", second: ""])
        #expect(CompanionLocalDrafts(defaults: defaults).load() == [first: "Half a thought"])
        drafts.save([:])
        #expect(drafts.load().isEmpty)
    }

    @Test func unreadableDraftsLoadAsNone() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "clubhouse.companion.drafts.v1")
        #expect(CompanionLocalDrafts(defaults: defaults).load().isEmpty)
        defaults.set("a string, not data", forKey: "clubhouse.companion.drafts.v1")
        #expect(CompanionLocalDrafts(defaults: defaults).load().isEmpty)
    }

    @Test func duplicateDraftEntriesKeepTheLaterOne() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        struct Entry: Encodable { var target: CompanionTarget; var text: String }
        defaults.set(try JSONEncoder().encode([Entry(target: first, text: "old"), Entry(target: first, text: "new")]),
                     forKey: "clubhouse.companion.drafts.v1")
        #expect(CompanionLocalDrafts(defaults: defaults).load() == [first: "new"])
    }

    @Test func finishedRunsRoundTrip() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompanionLocalFinished(defaults: defaults)
        #expect(store.load() == nil)
        var runs = CompanionFinishedRuns()
        var agent = CompanionAgent(id: first, name: "brave-otter", subtitle: "Fix the build", status: .failed, model: nil, capabilities: [],
                                   isQuick: true, hasExited: true, exitCode: 2)
        agent.lastActivity = Date(timeIntervalSince1970: 1_800_000_000)
        let recorded = runs.record(agent, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(recorded)
        runs.dismiss(second)
        store.save(runs)
        let loaded = try #require(CompanionLocalFinished(defaults: defaults).load())
        #expect(loaded == runs)
        #expect(loaded.runs.first?.detail == "Exited with code 2")
        #expect(loaded.dismissed == [second])
    }

    @Test func unreadableFinishedRunsLoadAsNone() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("{\"runs\": 3}".utf8), forKey: "clubhouse.companion.finished.v1")
        #expect(CompanionLocalFinished(defaults: defaults).load() == nil)
    }

    @Test func withoutABundleIdentifierALaunchCountsAsFresh() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var deleted: [String] = []
        #expect(CompanionInstallReset.clearLeftoversIfFreshInstall(defaults: defaults, domain: nil) { deleted.append($0) })
        #expect(deleted == CompanionInstallReset.keychainServices)
        #expect(defaults.bool(forKey: CompanionInstallReset.markerKey))
    }

    @Test func deletingAMissingKeychainServiceIsHarmless() {
        // A service no app uses: nothing to delete, and nothing thrown.
        CompanionInstallReset.deleteGenericPasswords(service: "com.agentclubhouse.tests.\(UUID().uuidString)")
    }
}
