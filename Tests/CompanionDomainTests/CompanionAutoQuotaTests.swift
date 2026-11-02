import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Locked desktop contract; no provider, account or real Auto start is exercised.
@MainActor @Suite struct CompanionAutoQuotaTests {
    @Test func autoScopesPreserveEffectiveOutcomeAndDesktopWords() throws {
        let fixture = try ContractFixtures.json("helper-routing-auto.json")
        guard case .object(let cases)? = fixture["cases"] else { Issue.record("Missing Auto cases"); return }
        let labels = try CompanionHelperRouting(json: ContractFixtures.json("helper-routing.json")["bare"]!["response"]!["body"]!).labels
        for (_, value) in cases {
            let auto = try #require(CompanionHelperAuto(json: value))
            #expect(auto.effective == value["effective"]?.boolOrNil)
            #expect(auto.source == value["source"]?.string && auto.reason == value["reason"]?.string)
            #expect(auto.sourceText(labels: labels) != "Other")
            if !auto.effective { #expect(auto.reasonText(labels: labels) != nil) }
        }
        let dispatcher = try #require(CompanionHelperAuto(json: cases["dispatcherLocked"]))
        #expect(dispatcher.scopes.values.allSatisfy { !$0.editable })
        let mcp = try #require(CompanionHelperAuto(json: cases["mcpOff"]))
        #expect(mcp.scopes["agent"]?.editable == true && !mcp.effective)
        // An own true value must not override the desktop's effective false result.
        let contradictory: AnnexJSON = .object(["effective": .bool(false), "source": .string("persona"), "reason": .string("persona_off"),
            "scopes": .object(["agent": .object(["value": .bool(true), "editable": .bool(true)]), "persona": .object(["value": .bool(false), "editable": .bool(false)])])])
        let blocked = try #require(CompanionHelperAuto(json: contradictory))
        #expect(!blocked.effective && blocked.scopes["agent"]?.value == .enabled(true))
        #expect(blocked.reasonText(labels: labels) == labels["autoOff"]?["persona_off"])
    }

    @Test func quotaStatesAndPollingFollowCommittedMixedAndMissingTTLs() throws {
        let fixture = try ContractFixtures.json("helper-routing-quota.json")
        guard case .object(let cases)? = fixture["cases"], case .object(let full)? = fixture["fullResponses"] else { Issue.record("Missing quota fixtures"); return }
        for (_, value) in cases {
            let quota = try #require(CompanionHelperQuota(json: value))
            #expect(quota.state == value["state"]?.string && quota.unknownReason == value["unknownReason"]?.string)
            #expect(quota.modelWindows.map(\.name) == value["modelWindows"].arrayValue.compactMap { $0["name"]?.string })
        }
        for (_, item) in full {
            let raw = try #require(item["response"])
            let quotas = raw["providers"].map { value -> [CompanionHelperQuota] in
                guard case .object(let providers) = value else { return [] }
                return providers.values.compactMap { .init(json: $0["quota"]) }
            } ?? []
            #expect(CompanionHelperQuota.nextRefreshDelay(quotas) == item["nextFetchSeconds"]?.integer.map(Double.init))
        }
        #expect(CompanionHelperQuota.nextRefreshDelay([.init(state: "unknown", refreshAfterSeconds: 0)]) == 5)
        #expect(CompanionHelperQuota.nextRefreshDelay([.init(state: "unknown")]) == nil)
        #expect(CompanionHelperQuota.nextRefreshDelay([.init(state: "unknown", refreshAfterSeconds: -1)]) == nil)
        let old = Date(timeIntervalSince1970: 10), server = Date(timeIntervalSince1970: 70)
        #expect(CompanionHelperQuota.age(asOf: old, serverTime: server, elapsed: .seconds(30)) == 90)
        #expect(CompanionHelperQuota.age(asOf: nil, serverTime: server, elapsed: .seconds(30)) == nil)
    }

    @Test func warningsAndSavedDecisionsKeepHistoryAndUnknownCodesReadable() throws {
        let fixture = try ContractFixtures.json("helper-routing-auto.json")
        let held = try #require(fixture["heldStartWithWarning"])
        let requests = CompanionLiveService.helperRequests(from: .array([held]), hostID: "h")
        #expect(requests.first?.startWarning?.message == held["startWarning"]?["message"]?.string)
        let routing = try #require(CompanionHelperRoutingDecision(json: fixture["settingsRouting"]?["explicitWithWarning"]))
        #expect(routing.warning?.message == routing.displayWarning)
        #expect(routing.warning?.asOf != nil && routing.decidedAt != nil)
        let unknown = try #require(CompanionHelperStartWarning(json: .object(["code": .string("future_code"), "asOf": .null, "message": .string("Desktop warning.")])))
        #expect(unknown.message == "Desktop warning." && unknown.asOf == nil)
        let unknownQuota = try #require(CompanionHelperRoutingDecision(json: fixture["settingsRouting"]?["unknownQuota"]))
        #expect(unknownQuota.quota["codex-cli"]?.state == "unknown")
        #expect(unknownQuota.quota["codex-cli"]?.unknownReason == "not_applicable")
    }

    @Test func ownAutoFieldAndEffectiveFieldStayIndependentAndClearIsExplicit() throws {
        for item in try ContractFixtures.cases("commands/agent.update.json") {
            guard let raw = item["request"]?["orchestration"]?["autoHelpers"], let result = item["response"]?["body"]?["result"] else { continue }
            let settings = try CompanionAgentSettings(json: result)
            #expect(settings.orchestration?.autoHelpers == result["orchestration"]?["autoHelpers"]?.boolOrNil)
            #expect(settings.orchestration?.autoHelpersEffective == result["orchestration"]?["autoHelpersEffective"]?.boolOrNil)
            let change = CompanionSettingsChange(orchestration: .init(autoHelpers: raw.boolOrNil.map { .set($0) } ?? .clear))
            let command = AnnexCommand(commandID: try #require(item["request"]?["commandId"]?.string), epoch: try #require(item["request"]?["epoch"]?.string),
                kind: .update(.init(agentID: try #require(item["request"]?["agentId"]?.string), change: change)))
            #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == item["request"])
        }
    }

    @Test func definiteAutoRefusalsConsumeAndWarnedApprovalRemainsSuccessful() async throws {
        let caps = try ContractFixtures.body("capabilities.json")
        let page = try #require(ContractFixtures.json("helper-routing.json")["bare"]?["response"]?["body"])
        let cases = try ContractFixtures.cases("commands/helper.approve.json")
        for name in ["auto_off", "no_candidate", "accepted start, with a warning"] {
            let item = try #require(cases.first { $0["name"]?.string == name })
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            let h = try await LiveServiceHarness.start { transport in
                await transport.setEpoch(caps["epoch"]?.string ?? "")
                await transport.setCommands(caps["commands"].arrayValue.compactMap(\.string))
                await transport.setFeature("helperRouting", caps["helperRouting"] ?? .null)
                await transport.setFeature("helperRequests", caps["helperRequests"] ?? .null)
                await transport.setRead("helperRouting", page)
            }
            defer { h.stop() }
            let fixture = try ContractFixtures.json("helper-routing-auto.json")
            guard case .object(var held) = try #require(fixture["heldStart"]) else { Issue.record("Missing held start"); return }
            held["requestId"] = item["request"]?["requestId"]
            await h.transport.emit(h.snapshotEvent(["helperRequests": .array([.object(held)])]))
            try await h.waitUntil { h.host?.helperRequests.count == 1 }
            let request = try #require(h.host?.helperRequests.first)
            await h.transport.enqueue(.receipt(receipt))
            await h.store.answer(request, approve: true)
            if receipt.status == .rejected { #expect(h.store.helperRequestNotice == receipt.error?.message) }
            else { try await h.waitUntil { h.store.helperStartWarning?.message == receipt.result?["warning"]?["message"]?.string } }
            #expect(!h.store.canAnswer(request))
            await h.store.answer(request, approve: true)
            #expect(await h.transport.executed.count == 1)
        }
    }
    @Test func scopedStaleWriteKeepsProjectOffAndNeverRetriesNullClear() async throws {
        let caps = try ContractFixtures.body("capabilities.json")
        let item = try #require(ContractFixtures.cases("commands/helperRouting.update.json").first { $0["name"]?.string == "helper_routing_stale (project scope, fresh values for that project)" })
        let request = try #require(item["request"]).decode(AnnexHelperRoutingUpdate.self)
        let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
        let page = try #require(ContractFixtures.json("helper-routing.json")["project"]?["response"]?["body"])
        let h = try await LiveServiceHarness.start { transport in
            await transport.setEpoch(caps["epoch"]?.string ?? "")
            await transport.setCommands(caps["commands"].arrayValue.compactMap(\.string))
            await transport.setFeature("helperRouting", caps["helperRouting"] ?? .null)
            await transport.setRead("helperRouting", page)
        }
        defer { h.stop() }
        let screen = CompanionHelperPresetsScreen()
        await screen.load { try await h.store.helperRouting(hostID: LiveServiceHarness.hostID, projectID: request.projectId) }
        await h.transport.enqueue(.receipt(receipt))
        let reads = await h.transport.readRoutes.count
        await screen.save { _ in try await h.store.updateHelperRouting(request, hostID: LiveServiceHarness.hostID) }
        #expect(request.auto == .inherit)
        #expect(screen.settings?.auto?.scopes["project"]?.value == .off)
        #expect(screen.settings?.auto?.effective == false && screen.settings?.revision == receipt.revision)
        #expect(screen.error == receipt.error?.message)
        #expect(await h.transport.executed.count == 1)
        #expect(await h.transport.readRoutes.count == reads)
        let receivedAt = screen.receivedAt
        await screen.save { _ in throw CompanionServiceError.unavailable("Offline") }
        #expect(screen.receivedAt == receivedAt, "A failed save cannot make an old quota reading look fresh")
    }

    @Test func previewShowsLockedScopesAndHistoricalWarningsWithoutChangingPolicyLocally() async throws {
        let app = CompanionPreviewService.autoQuotaPage(projectID: nil, agentID: nil, mcpEnabled: true)
        #expect(app.auto?.effective == true)
        #expect(app.providers["claude-code"]?.quota?.modelWindows.first?.name == "Fable")
        #expect(app.providers["codex-cli"]?.quota?.unknownReason == "stale")
        #expect(app.providers["copilot-cli"]?.quota?.unknownReason == "not_supported")
        #expect(app.nextRefreshDelay == 300)
        let project = CompanionPreviewService.autoQuotaPage(projectID: "website", agentID: nil, mcpEnabled: true)
        #expect(project.auto?.reason == "project_off")
        let persona = CompanionPreviewService.autoQuotaPage(projectID: nil, agentID: "juniper", mcpEnabled: true)
        #expect(persona.auto?.reason == "persona_off" && persona.auto?.scopes["agent"]?.value == .enabled(true))
        let mcp = CompanionPreviewService.autoQuotaPage(projectID: nil, agentID: "river", mcpEnabled: false)
        #expect(mcp.auto?.reason == "mcp_off" && mcp.auto?.scopes["agent"]?.editable == true)
        let dispatcher = CompanionPreviewService.autoQuotaPage(projectID: nil, agentID: CompanionPreviewService.dispatcherTarget.agentID, mcpEnabled: true)
        #expect(dispatcher.auto?.scopes.values.allSatisfy { !$0.editable } == true)
        let service = CompanionPreviewService(showsAutoQuota: true)
        #expect(try await service.helperRouting(hostID: "preview-studio", projectID: "clubhouse", agentID: nil).auto?.effective == true)
        let saved = try await service.settings(for: CompanionPreviewService.sleepingTarget)
        #expect(saved.routing?.warning?.message == CompanionPreviewService.previewStartWarning.message)
        #expect(saved.orchestration?.autoHelpers == true && saved.orchestration?.autoHelpersEffective == false)
        #expect(CompanionPreviewService.autoQuotaCapability?.modes.contains("auto") == true)
    }

}
