import XCTest
@testable import ClubhouseGo

@MainActor private final class DefaultCacheService: CompanionService {
    let preview = CompanionPreviewService()
    var defaultAccess: CompanionPermissionLevel = .auto
    var holdNextRead = false
    let held = XCTestExpectation(description: "Default response suspended")
    var pending: CheckedContinuation<Void, Never>?

    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { try await preview.history(for: target) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        var result = try await preview.createOptions(for: project)
        result.defaultAccess = defaultAccess
        await suspendIfRequested()
        return result
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings { try await settingsResult(target) }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        try await settingsResult(target)
    }
    private func settingsResult(_ target: CompanionTarget) async throws -> CompanionAgentSettings {
        var result = try await preview.settings(for: target)
        result.access?.defaultLevel = defaultAccess
        await suspendIfRequested()
        return result
    }
    private func suspendIfRequested() async {
        guard holdNextRead else { return }
        holdNextRead = false
        await withCheckedContinuation { pending = $0; held.fulfill() }
    }
    func release() {
        holdNextRead = false
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

@MainActor final class CompanionAgentDefaultCacheTests: XCTestCase {
    private enum Read: CaseIterable { case options, settings, update }
    private enum Rotation { case reconnect, epoch, pairing, endpoint, agentCatalog, projectCatalog }
    private let target = CompanionPreviewService.target
    private var project: CompanionProjectTarget { .init(hostID: target.hostID, projectID: target.projectID) }

    func testLateRepliesCannotCrossDisconnectAndReconnect() async throws { try await rejectsLateReplies(.reconnect) }
    func testLateRepliesCannotCrossEpochChanges() async throws { try await rejectsLateReplies(.epoch) }
    func testLateRepliesCannotCrossPairingRemovalAndReadd() async throws { try await rejectsLateReplies(.pairing) }
    func testLateRepliesCannotCrossEndpointReplacement() async throws { try await rejectsLateReplies(.endpoint) }
    func testLateRepliesCannotCrossAgentRemovalAndReadd() async throws { try await rejectsLateReplies(.agentCatalog) }
    func testLateRepliesCannotCrossProjectRemovalAndReadd() async throws { try await rejectsLateReplies(.projectCatalog) }

    private func read(_ kind: Read, from store: CompanionStore) async throws {
        switch kind {
        case .options: _ = try await store.createOptions(for: project)
        case .settings: _ = try await store.settings(for: target)
        case .update: _ = try await store.updateSettings(.init(name: "River"), target: target)
        }
    }

    private func cached(_ kind: Read, in store: CompanionStore) -> CompanionPermissionLevel? {
        kind == .options ? store.projectAccessDefaults[project] : store.agentAccessDefaults[target]
    }

    private func fixtureHost() throws -> CompanionHost {
        var host = try XCTUnwrap(CompanionPreviewService.hosts(now: Date()).first { $0.id == target.hostID })
        host.controlEpoch = "original-epoch"
        return host
    }

    private func rotate(_ rotation: Rotation, store: CompanionStore, host: inout CompanionHost) {
        switch rotation {
        case .reconnect:
            var disconnected = host
            disconnected.connection = .offline
            store.apply(.hosts([disconnected]))
        case .epoch: host.controlEpoch = "replacement-epoch"
        case .pairing: store.apply(.hosts([]))
        case .endpoint: host.endpoint += "/replacement-pairing"
        case .agentCatalog:
            var removed = host
            for index in removed.projects.indices { removed.projects[index].agents.removeAll { $0.id == target } }
            store.apply(.hosts([removed]))
        case .projectCatalog:
            var removed = host
            removed.projects.removeAll { $0.id == project.projectID }
            store.apply(.hosts([removed]))
        }
        // Same IDs are present again before the old reply arrives. Membership alone cannot fence it.
        store.apply(.hosts([host]))
    }

    private func rejectsLateReplies(_ rotation: Rotation) async throws {
        for kind in Read.allCases {
            let service = DefaultCacheService()
            let store = CompanionStore(service: service)
            var host = try fixtureHost()
            store.apply(.hosts([host]))
            service.holdNextRead = true
            let reply = Task { try await read(kind, from: store) }
            await fulfillment(of: [service.held], timeout: 10)
            XCTAssertNotNil(service.pending, "\(rotation), \(kind): the response must be in flight before rotation")
            rotate(rotation, store: store, host: &host)
            service.release()
            try await reply.value
            XCTAssertNil(cached(kind, in: store), "\(rotation), \(kind): stale response cannot become a known default")
            service.defaultAccess = .ask
            try await read(kind, from: store)
            XCTAssertEqual(cached(kind, in: store), .ask, "\(rotation), \(kind): a fresh response after rotation must cache")
            store.shutdown()
        }
    }

    func testEpochAndPairingChangesInvalidatePreviouslyCachedDefaults() async throws {
        for rotation in [Rotation.epoch, .pairing, .endpoint] {
            let service = DefaultCacheService()
            let store = CompanionStore(service: service)
            var host = try fixtureHost()
            store.apply(.hosts([host]))
            try await read(.options, from: store)
            try await read(.settings, from: store)
            XCTAssertEqual(store.projectAccessDefaults[project], .auto)
            XCTAssertEqual(store.agentAccessDefaults[target], .auto)
            rotate(rotation, store: store, host: &host)
            XCTAssertTrue(store.projectAccessDefaults.isEmpty && store.agentAccessDefaults.isEmpty, "\(rotation): cached evidence belongs to the old context")
            service.defaultAccess = .ask
            try await read(.options, from: store)
            try await read(.settings, from: store)
            XCTAssertEqual(store.projectAccessDefaults[project], .ask)
            XCTAssertEqual(store.agentAccessDefaults[target], .ask)
            store.shutdown()
        }
    }

    func testCatalogPruningDropsRemovedKeysAndKeepsUnchangedEntries() async throws {
        let service = DefaultCacheService()
        let store = CompanionStore(service: service)
        var host = try fixtureHost()
        let original = host
        store.apply(.hosts([host]))
        let sibling = try XCTUnwrap(host.projects.first { $0.id == project.projectID }?.agents.first { $0.id != target && !$0.isQuick })
        try await read(.options, from: store)
        try await read(.settings, from: store)
        _ = try await store.settings(for: sibling.id)
        for index in host.projects.indices { host.projects[index].agents.removeAll { $0.id == target } }
        store.apply(.hosts([host]))
        XCTAssertNil(store.agentAccessDefaults[target])
        XCTAssertEqual(store.agentAccessDefaults[sibling.id], .auto)
        XCTAssertEqual(store.projectAccessDefaults[project], .auto)
        host.projects.removeAll { $0.id == project.projectID }
        store.apply(.hosts([host]))
        XCTAssertTrue(store.agentAccessDefaults.isEmpty && store.projectAccessDefaults.isEmpty)
        store.apply(.hosts([original]))
        XCTAssertTrue(store.agentAccessDefaults.isEmpty && store.projectAccessDefaults.isEmpty, "Reappearing IDs cannot resurrect pruned evidence")
        service.defaultAccess = .ask
        try await read(.options, from: store)
        try await read(.settings, from: store)
        XCTAssertEqual(store.projectAccessDefaults[project], .ask)
        XCTAssertEqual(store.agentAccessDefaults[target], .ask)
        store.shutdown()
    }
}
