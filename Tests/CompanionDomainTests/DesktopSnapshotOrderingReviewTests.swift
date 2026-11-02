import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct DesktopSnapshotOrderingReviewTests {
    private let quick: AnnexJSON = .object([
        "id": .string("q5"), "kind": .string("quick"), "projectId": .string("project"),
        "name": .string("swift-heron"), "status": .string("running")])
    private let helper: AnnexJSON = .object([
        "requestId": .string("hstart_1"), "kind": .string("start"), "projectId": .string("project"),
        "requester": .object(["agentId": .string("agent"), "name": .string("Planner")]),
        "helper": .object(["name": .string("Builder")])])

    private func snapshot(_ harness: LiveServiceHarness, sequence: Int64, quicks: [AnnexJSON], helpers: [AnnexJSON]) throws -> AnnexEnvelope {
        let event = harness.snapshotEvent(["quickAgents": .object(["project": .array(quicks)]), "helperRequests": .array(helpers)])
        guard case .message(let frame) = event else { throw AnnexTransportError.malformedResponse }
        return AnnexEnvelope(type: "snapshot", payload: frame.payload, lastSeq: sequence)
    }

    @Test func snapshotStateFollowedByItsHeldSpawnDoesNotDuplicateTheAgent() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["quickAgents": .object(["project": .array([quick])])]))
        try await harness.waitUntil { harness.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true }
        await harness.transport.emit(.message(.init(type: "agent:spawned", payload: quick, seq: 101)))
        try await harness.refreshCatalog()
        #expect(harness.host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count == 1)
    }

    // Characterizes server payload consistency, using the real cursor to filter replay/refresh,
    // and the real service/store for the resulting catalog and helper approval list.
    @Test(arguments: [Int64(100), Int64(101)])
    func alreadyAppliedStateAndHelperApprovalAcrossAStaleRefresh(staleCheckpoint: Int64) async throws {
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("helperRequests", .object(["version": .integer(1)]))
            await transport.addCommands(["helper.approve", "helper.decline"])
        })
        defer { harness.stop() }
        var cursor = AnnexReplayCursor()
        let initial = try snapshot(harness, sequence: 100, quicks: [], helpers: [helper])
        #expect(cursor.accept(initial) == .deliver)
        await harness.transport.emit(.message(initial))
        try await harness.waitUntil { harness.host?.helperRequests.count == 1 }

        let spawned = AnnexEnvelope(type: "agent:spawned", payload: quick, seq: 101)
        #expect(cursor.accept(spawned) == .deliver)
        await harness.transport.emit(.message(spawned))
        try await harness.waitUntil { harness.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true }
        let request = try #require(harness.host?.helperRequests.first)
        try await harness.service.answerHelperRequest(request, approve: true, force: false, clientCommandID: "approve-once")
        try await harness.waitUntil { harness.host?.helperRequests.isEmpty == true }
        #expect(cursor.lastSequence == 101, "Newer catalog state and local helper approval are already applied")

        let stale = try snapshot(harness, sequence: staleCheckpoint, quicks: [], helpers: [helper])
        let decision = cursor.accept(stale)
        if decision == .deliver { await harness.transport.emit(.message(stale)) }
        else { #expect(decision == .duplicate) }
        let replayedSpawn = AnnexEnvelope(type: "agent:spawned", payload: quick, seq: 101, replayed: true)
        #expect(cursor.accept(replayedSpawn) == .duplicate)
        // Complete recovery, including the service's REST catalog pass. It preserves the
        // snapshot's quick catalog and helper list; replay101 cannot repair a stale payload.
        try await harness.refreshCatalog()
        let quickCount = harness.host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count
        let approvals = harness.host?.helperRequests.map(\.id)
        if staleCheckpoint == 100 {
            #expect(quickCount == 1)
            #expect(approvals == [])
        } else {
            #expect(quickCount == 0)
            #expect(approvals == ["hstart_1"])
        }
        print("After recovery: stale lastSeq=\(staleCheckpoint), cursor=\(cursor.lastSequence!), q5 count=\(quickCount!), pending helper approvals=\(approvals!)")

        let fresh = try snapshot(harness, sequence: 101, quicks: [quick], helpers: [])
        #expect(cursor.accept(fresh) == .deliver)
        await harness.transport.emit(.message(fresh))
        try await harness.refreshCatalog()
        #expect(harness.host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count == 1)
        #expect(harness.host?.helperRequests.isEmpty == true)
        #expect(await harness.transport.executed.filter { $0.type == "helper.approve" }.count == 1)
    }
}
