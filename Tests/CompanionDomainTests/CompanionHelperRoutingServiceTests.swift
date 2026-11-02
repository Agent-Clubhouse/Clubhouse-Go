import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor @Suite struct CompanionHelperRoutingServiceTests {
    private func body(_ name: String = "bare") throws -> AnnexJSON {
        try #require(ContractFixtures.json("helper-routing.json")[name]?["response"]?["body"])
    }
    private func commandCase(_ name: String, file: String = "commands/helperRouting.update.json") throws -> AnnexJSON {
        try #require(ContractFixtures.cases(file).first { $0["name"]?.string == name })
    }
    private func start() async throws -> LiveServiceHarness {
        let caps = try ContractFixtures.body("capabilities.json")
        let bare = try body()
        return try await LiveServiceHarness.start(configure: { transport in
            await transport.setEpoch(caps["epoch"]?.string ?? "")
            await transport.setCommands(caps["commands"].arrayValue.compactMap(\.string))
            await transport.setFeature("helperRouting", caps["helperRouting"] ?? .null)
            await transport.setFeature("helperRequests", caps["helperRequests"] ?? .null)
            await transport.setRead("helperRouting", bare)
        })
    }
    @Test func labelsAreReadOncePerRevisionAndSnapshotAndEventInvalidate() async throws {
        let h = try await start(); defer { h.stop() }
        try await h.waitUntil { h.host?.helperRoutingRevision == "r0.0" }
        #expect(h.host?.helperRoutingLabels["reason"]?["preset_on_cli"] == "From the helper settings for this difficulty")
        let reads = await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count
        await h.transport.emit(h.snapshotEvent(["helperRoutingRevision": .string("r0.0")]))
        try await h.refreshCatalog()
        #expect(await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count == reads)
        let stale = try commandCase("helper_routing_stale")
        let fresh = try #require(stale["response"]?["body"]?["settings"])
        await h.transport.setRead("helperRouting", fresh)
        let event = try #require(ContractFixtures.json("helper-routing-changed.json")["frames"].arrayValue.first).decode(AnnexEnvelope.self)
        await h.transport.emit(.message(event))
        try await h.waitUntil { h.host?.helperRoutingRevision == "r1.3" }
        try await h.waitUntil { await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count == reads + 1 }
        await h.transport.emit(h.snapshotEvent(["helperRoutingRevision": .string("r1.3")]))
        try await h.refreshCatalog()
        #expect(await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count == reads + 1)
        await h.transport.setRead("helperRouting", try body("stalePreset"))
        await h.transport.emit(h.snapshotEvent(["helperRoutingRevision": .string("r0.1")]))
        try await h.waitUntil { await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count == reads + 2 }
        _ = try await h.service.helperRouting(hostID: LiveServiceHarness.hostID, projectID: "profile project", agentID: "helper/id")
        let last = await h.transport.readRoutes.last
        #expect(last?.projectID == "profile project" && last?.agentID == "helper/id")
    }
    @Test func staleWriteReplacesPageAndNeverRetriesAndNextHumanEditUsesNewRevision() async throws {
        let h = try await start(); defer { h.stop() }
        let screen = CompanionHelperPresetsScreen()
        await screen.load { try await h.store.helperRouting(hostID: LiveServiceHarness.hostID) }
        let item = try commandCase("helper_routing_stale")
        let request = try #require(item["request"]).decode(AnnexHelperRoutingUpdate.self)
        let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
        await h.transport.enqueue(.receipt(receipt))
        await screen.save { _ in try await h.store.updateHelperRouting(request, hostID: LiveServiceHarness.hostID) }
        #expect(screen.settings?.revision == receipt.revision && screen.error == receipt.error?.message)
        #expect(!screen.saving)
        #expect(await h.transport.executed.count == 1)
        let accepted = try commandCase("accepted reset one cell")
        let result = try #require(accepted["response"]?["body"]?["result"])
        await h.transport.enqueue(.completed(result))
        let reads = await h.transport.readRoutes.count
        await screen.save { revision in
            #expect(revision == receipt.revision)
            return try await h.store.updateHelperRouting(.init(revision: revision, reset: .init(provider: "codex-cli", difficulty: "easy")), hostID: LiveServiceHarness.hostID)
        }
        #expect(screen.error == nil && screen.settings?.revision == result["revision"]?.string)
        #expect(await h.transport.executed.count == 2)
        #expect(await h.transport.readRoutes.count == reads, "Success carries the fresh page, with no extra read")
        let encoded = try JSONDecoder().decode(AnnexJSON.self, from: #require(await h.transport.executed.last).encoded())
        #expect(encoded["revision"]?.string == receipt.revision)
    }
    @Test func unavailableModelAndEffortShowDesktopMessageWithoutRetryOrChangingValues() async throws {
        let h = try await start(); defer { h.stop() }
        let screen = CompanionHelperPresetsScreen()
        await screen.load { try await h.store.helperRouting(hostID: LiveServiceHarness.hostID) }
        let original = screen.settings
        for name in ["model_unavailable", "effort_unavailable"] {
            let item = try commandCase(name)
            let request = try #require(item["request"]).decode(AnnexHelperRoutingUpdate.self)
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            await h.transport.enqueue(.receipt(receipt))
            await screen.save { _ in try await h.store.updateHelperRouting(request, hostID: LiveServiceHarness.hostID) }
            #expect(screen.error == receipt.error?.message && screen.settings == original)
        }
        #expect(await h.transport.executed.count == 2)
    }
    @Test func noValidMappingIsConsumedWithMessageInEitherReceiptSnapshotOrder() async throws {
        for snapshotFirst in [false, true] {
            let h = try await start(); defer { h.stop() }
            let item = try commandCase("no_valid_mapping", file: "commands/helper.approve.json")
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            let requestID = try #require(item["request"]?["requestId"]?.string)
            var requests = try #require(ContractFixtures.json("snapshot-helper-requests.json")["value"])
            guard case .array(var rows) = requests, case .object(var row) = try #require(rows.first) else { Issue.record("No fixture rows"); return }
            row["requestId"] = .string(requestID); rows = [.object(row)]; requests = .array(rows)
            await h.transport.emit(h.snapshotEvent(["helperRequests": requests]))
            try await h.waitUntil { h.host?.helperRequests.first?.id == requestID }
            let request = try #require(h.host?.helperRequests.first)
            if snapshotFirst {
                await h.transport.emit(h.snapshotEvent(["helperRequests": .array([])]))
                try await h.waitUntil { h.host?.helperRequests.isEmpty == true }
                // A tap was authorized before the snapshot arrived. Exercise the service's complete receipt.
                await h.transport.enqueue(.receipt(receipt))
                do { try await h.service.answerHelperRequest(request, approve: true, force: false, clientCommandID: "original") }
                catch let error as CompanionHelperRequestConsumed { #expect(error.message == receipt.error?.message) }
            } else {
                await h.transport.enqueue(.receipt(receipt))
                await h.store.answer(request, approve: true)
                #expect(h.store.helperRequestNotice == receipt.error?.message)
                await h.transport.emit(h.snapshotEvent(["helperRequests": .array([])]))
            }
            try await h.waitUntil { h.host?.helperRequests.isEmpty == true }
            await h.store.answer(request, approve: true)
            #expect(!h.store.canAnswer(request))
            #expect(await h.transport.executed.count == 1)
        }
    }
    @Test func absentCapabilityPreventsReadsAndWrites() async throws {
        let h = try await LiveServiceHarness.start(); defer { h.stop() }
        #expect(h.host?.helperRouting == nil)
        #expect(await serviceErrorText { _ = try await h.service.helperRouting(hostID: LiveServiceHarness.hostID) } != nil)
        #expect(await serviceErrorText { _ = try await h.service.updateHelperRouting(.init(revision: "r", reset: .init()), hostID: LiveServiceHarness.hostID, clientCommandID: "c") } != nil)
        #expect(await h.transport.executed.isEmpty)
        #expect(await h.transport.readRoutes.allSatisfy { $0.name != "helperRouting" })
    }
}
