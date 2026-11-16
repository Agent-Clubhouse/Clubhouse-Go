import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor struct CompanionProjectStateReceiptTests {
    private func state(pinned: Bool = false, inactive: Bool = false, linked: Bool) -> AnnexJSON {
        .object(["pinned": .bool(pinned), "inactive": .bool(inactive), "idle": .bool(inactive), "linked": .bool(linked)])
    }

    private func snapshot(_ state: AnnexJSON, linked: Bool) -> AnnexTransportEvent {
        var payload: [String: AnnexJSON] = [
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")]),
                                .object(["id": .string("other"), "name": .string("Other")])]),
            "agents": .object(["project": .array([]), "other": .array([])]),
            "projectState": .object(["project": state, "other": state])
        ]
        if linked {
            payload["projectLinks"] = .array([.object(["id": .string("group"), "projects": .array(
                ["project", "other"].map { .object(["machine": .string(LiveServiceHarness.hostID), "projectId": .string($0)]) })])])
        }
        // Peer project-state updates are ordinary unsequenced snapshots.
        return .message(.init(type: "snapshot", payload: .object(payload)))
    }

    private func start(linked: Bool, inactive: Bool = false) async throws -> LiveServiceHarness {
        let harness = try await LiveServiceHarness.start { transport in
            await transport.addCommands(["project.setPinned", "project.setInactive"])
            await transport.setFeature("projectState", .object(["version": .integer(1)]))
            if linked {
                await transport.setFeature("linkedProjectState", .object(["version": .integer(1)]))
                await transport.setFeature("projectLinks", .object(["version": .integer(1), "snapshotField": .string("projectLinks"), "event": .string("project-links:changed")]))
            }
        }
        await harness.transport.emit(snapshot(state(inactive: inactive, linked: linked), linked: linked))
        try await harness.waitUntil { harness.host?.projectState?["project"]?.inactive == inactive }
        #expect(harness.store.projectEntry(containing: harness.project)?.isLinked == linked)
        return harness
    }

    private func command(_ h: LiveServiceHarness, pin: Bool, whileHeld: () async throws -> Void) async throws {
        let task = Task {
            if pin { await h.store.setProject(h.project, pinned: true) }
            else { await h.store.setProject(h.project, inactive: false) }
        }
        do {
            try await h.waitUntil { await h.transport.executed.count == 1 }
            try await whileHeld()
        } catch {
            await h.transport.releaseCommand(); await task.value
            throw error
        }
        await h.transport.releaseCommand(); await task.value
    }

    @Test(arguments: [false, true], [false, true])
    func newerSnapshotSurvivesALatePinOrActiveReceipt(linked: Bool, pin: Bool) async throws {
        let h = try await start(linked: linked)
        defer { h.stop() }
        await h.transport.enqueue(.heldCompleted(state(pinned: pin, linked: linked)))
        try await command(h, pin: pin) {
            await h.transport.emit(snapshot(state(inactive: true, linked: linked), linked: linked))
            try await h.waitUntil { h.host?.projectState?["project"]?.inactive == true }
        }
        // Observe both the Store projection and a subsequent LiveService emission. Either layer
        // restoring the older receipt must fail, even when the other layer has a fence.
        #expect(h.host?.projectState?["project"] == .init(inactive: true, idle: true, linked: linked))
        var observer = h.service.events().makeAsyncIterator()
        let event = await observer.next()
        guard case .hosts(let hosts) = event else { Issue.record("Expected current LiveService hosts"); return }
        #expect(hosts.first?.projectState?["project"] == .init(inactive: true, idle: true, linked: linked))
        #expect(h.store.pendingProjectStates.isEmpty)
        #expect(h.store.projectStateError == nil)
        #expect(await h.transport.executed.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func receiptStillProjectsWithoutANewerSnapshot(linked: Bool, pin: Bool) async throws {
        let h = try await start(linked: linked, inactive: !pin)
        defer { h.stop() }
        await h.transport.enqueue(.heldCompleted(state(pinned: pin, linked: linked)))
        try await command(h, pin: pin) {}
        try await h.waitUntil { h.host?.projectState?["project"] == .init(pinned: pin, linked: linked) }
        #expect(h.store.sharedProjectState(h.project) == .init(pinned: pin, linked: linked))
    }

    @Test(arguments: [false, true])
    func identicalSnapshotContentsStillFenceAnOlderReceipt(linked: Bool) async throws {
        let h = try await start(linked: linked)
        defer { h.stop() }
        let revision = try #require(h.host?.projectStateRevision)
        await h.transport.enqueue(.heldCompleted(state(pinned: true, linked: linked)))
        try await command(h, pin: true) {
            await h.transport.emit(snapshot(state(linked: linked), linked: linked))
            try await h.waitUntil { h.host?.projectStateRevision != revision }
        }
        #expect(h.host?.projectState?["project"] == .init(linked: linked))
    }

    @Test(arguments: [false, true])
    func unrelatedHostPublicationDoesNotFenceTheReceipt(linked: Bool) async throws {
        let h = try await start(linked: linked)
        defer { h.stop() }
        let stateRevision = h.host?.projectStateRevision, updateRevision = h.host?.appUpdateRevision
        await h.transport.enqueue(.heldCompleted(state(pinned: true, linked: linked)))
        try await command(h, pin: true) {
            await h.transport.emit(.message(.init(type: "app_update:changed", payload: .object([
                "state": .string("none"), "currentVersion": .string("1.0"), "availableVersion": .null
            ]))))
            try await h.waitUntil { h.host?.appUpdateRevision != updateRevision }
            #expect(h.host?.projectStateRevision == stateRevision)
        }
        try await h.waitUntil { h.host?.projectState?["project"]?.pinned == true }
    }
}
