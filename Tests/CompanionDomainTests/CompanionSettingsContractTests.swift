import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionSettingsContractTests {
    @Test func helperIdentityComesFromTheSettingsRouteAndIsNotRetainedAfterHandoff() throws {
        let helper = try CompanionAgentSettings(json: ContractFixtures.body("agent-settings-helper.json"))
        #expect(helper.parentAgentID == "durable_chat")
        #expect(helper.orchestration?.connectToDispatcher == false)
        #expect(helper.name.editable == .sleeping && helper.model.editable == .sleeping)
        guard case .object(var handedOffBody) = try ContractFixtures.body("agent-settings-running.json") else { return }
        handedOffBody.removeValue(forKey: "options") // agent.update results omit options, so merging is required.
        let topLevel = try CompanionAgentSettings(json: .object(handedOffBody))
        #expect(topLevel.parentAgentID == nil)
        let merged = topLevel.keepingOptions(of: helper)
        #expect(merged.options == helper.options)
        #expect(merged.parentAgentID == nil, "Handoff removes helper identity; it isn't an option to retain")
        guard case .object(var body) = try ContractFixtures.body("agent-settings-helper.json") else { return }
        for value in [AnnexJSON.null, .bool(true), .integer(42), .array([])] {
            body["parentAgentId"] = value
            #expect(try CompanionAgentSettings(json: .object(body)).parentAgentID == nil)
        }
    }

    @Test func mcpEnabledDefaultsTrueUnlessABooleanIsSent() throws {
        for (raw, expected) in [("true", true), ("false", false), ("null", true), (#""false""#, true), ("0", true)] {
            let json = try JSONDecoder().decode(AnnexJSON.self, from: Data("{\"mcpEnabled\":\(raw)}".utf8))
            #expect(CompanionOrchestration(json: json)?.mcpEnabled == expected)
        }
        #expect(CompanionOrchestration(json: .object([:]))?.mcpEnabled == true)
    }

    @Test func reportOnlyIsTolerantAndDoesNotGrantFullMCPAuthority() throws {
        for value in [AnnexJSON.bool(true), .bool(false), .null, .string("true"), .integer(1)] {
            let policy = try #require(CompanionOrchestration(json: .object(["mcpEnabled": .bool(true), "mcpReportOnly": value])))
            #expect(policy.mcpEnabled, "Report-only retains the bridge")
            #expect(policy.mcpReportOnly == (value == .bool(true)))
            #expect(policy.hasFullMCP == (value != .bool(true)))
            #expect(policy.canChangeMCPOption(current: true))
            #expect(policy.canChangeMCPOption(current: false) == (value != .bool(true)))
        }
        #expect(CompanionOrchestration(json: .object([:]))?.hasFullMCP == true)
        #expect(CompanionOrchestration(json: .object(["mcpEnabled": .bool(false)]))?.hasFullMCP == false)
        guard case .object(var body) = try ContractFixtures.body("agent-settings-helper.json"),
              case .object(var policy)? = body["orchestration"] else { Issue.record("Missing helper policy"); return }
        policy["mcpEnabled"] = .bool(true); policy["mcpReportOnly"] = .bool(true)
        body["orchestration"] = .object(policy)
        #expect(try CompanionAgentSettings(json: .object(body)).orchestration?.mcpReportOnly == true)
    }

    @MainActor @Test func reportOnlyPreventsNewHelperApprovalsButKeepsDeclineAvailable() throws {
        var hosts = CompanionPreviewService.hosts(now: .now, helperRequests: CompanionPreviewService.helperRequests)
        let request = try #require(hosts[0].helperRequests.first { $0.kind == .start })
        let project = try #require(hosts[0].projects.firstIndex { $0.id == request.projectID })
        let agent = try #require(hosts[0].projects[project].agents.firstIndex { $0.id.agentID == request.requesterID })
        hosts[0].projects[project].agents[agent].orchestration = .init(mcpReportOnly: true)
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts(hosts))
        #expect(store.isMCPReportOnly(request.agentTarget))
        #expect(store.canAnswer(request) && !store.canApprove(request))
        hosts[0].projects[project].agents[agent].orchestration?.mcpReportOnly = false
        store.apply(.hosts(hosts))
        #expect(store.canApprove(request), "An absent or false report-only flag keeps the existing behavior")
    }

    @Test func cliSessionWarningDefaultsFalseAndUsesTheDesktopSentence() throws {
        let original = try ContractFixtures.body("agent-settings.json")
        for (raw, expected) in [(AnnexJSON.bool(true), true), (.bool(false), false), (.null, false), (.string("true"), false)] {
            guard case .object(var body) = original, case .object(var settings)? = body["settings"],
                  case .object(var cli)? = settings["orchestrator"] else { Issue.record("Missing fixture settings"); return }
            cli["changeStartsNewSession"] = raw
            settings["orchestrator"] = .object(cli); body["settings"] = .object(settings)
            let decoded = try CompanionAgentSettings(json: .object(body))
            #expect(decoded.changeStartsNewSession == expected)
            #expect(decoded.orchestratorChangeWarning(to: "codex-cli", agentName: "Juniper") == (expected
                    ? "Juniper starts a new session on Codex the next time it wakes. Its current conversation can't move to another CLI." : nil))
            #expect(decoded.orchestratorChangeWarning(to: decoded.resolvedOrchestrator, agentName: "Juniper") == nil)
            cli.removeValue(forKey: "changeStartsNewSession")
            settings["orchestrator"] = .object(cli); body["settings"] = .object(settings)
            #expect(try CompanionAgentSettings(json: .object(body)).changeStartsNewSession == false)
        }
    }

    @Test func mcpOffFixtureKeepsSourcesAndDisablesEffectivePolicy() throws {
        let settings = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-mcp-off.json"))
        let policy = try #require(settings.orchestration)
        #expect(!policy.mcpEnabled && !policy.orchestrate && !policy.crossProjectHelpers && !policy.connectToDispatcher)
        #expect(policy.sources["orchestrate"] == .agent && policy.sources["maxHelpers"] == .agent)
        #expect(settings.changeStartsNewSession)
        #expect(try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-running.json")).orchestration?.mcpEnabled == true)
    }

    @Test func patchesNeverCarryUntouchedOrchestrationFields() throws {
        let changes: [(CompanionOrchestrationChange, String, AnnexJSON)] = [
            (.init(orchestrate: .set(false)), "orchestrate", .bool(false)),
            (.init(access: .set("auto")), "access", .string("auto")),
            (.init(control: .clear), "control", .null),
            (.init(maxHelpers: .set(2)), "maxHelpers", .integer(2)),
            (.init(crossProjectHelpers: .set(true)), "crossProjectHelpers", .bool(true)),
            (.init(connectToDispatcher: .set(false)), "connectToDispatcher", .bool(false)),
        ]
        for (change, key, value) in changes {
            // Unset connection follows orchestrate, even with the Dispatcher off. Never echo the resolved policy.
            let policy = CompanionOrchestration(orchestrate: true, connectToDispatcher: true, sources: ["connectToDispatcher": .default])
            #expect(change.applied(to: policy).connectToDispatcher == (key == "connectToDispatcher" ? false : true))
            let command = AnnexCommand(commandID: "c", epoch: "e", kind: .update(.init(agentID: "a", change: .init(orchestration: change))))
            let sent = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
            #expect(sent["orchestration"] == .object([key: value]))
        }
        let command = AnnexCommand(commandID: "c", epoch: "e", kind: .update(.init(agentID: "a", change: .init(orchestrator: "codex-cli"))))
        let sent = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
        #expect(sent == .object(["version": .integer(1), "commandId": .string("c"), "epoch": .string("e"),
                                "type": .string("agent.update"), "agentId": .string("a"), "orchestrator": .string("codex-cli")]))
    }

    @Test func mcpOffPrefersTheDesktopSentence() throws {
        let item = try #require(try ContractFixtures.cases("commands/agent.update.json").first { $0["name"]?.string == "mcp_off" })
        let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
        #expect(receipt.error?.code == "mcp_off")
        let desktop = try #require(receipt.error?.message)
        #expect(CompanionAgentCommandError.message(code: "mcp_off", message: desktop) == desktop)
        for message: String? in [nil, "", "mcp_off"] {
            #expect(CompanionAgentCommandError.message(code: "mcp_off", message: message) == CompanionOrchestration.mcpRequiredHelp)
        }
    }
}

@MainActor @Suite struct CompanionSettingsContractLiveTests {
    private func start() async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start { transport in
            await transport.addCommands(["agent.create", "agent.update"])
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            await transport.setFeature("createOptions", .object(["version": .integer(1)]))
            await transport.setFeature("orchestration", .object(["version": .integer(1)]))
        }
    }

    @Test func desktopResultWinsWhenAHelperCannotConnect() async throws {
        let harness = try await start()
        defer { harness.stop() }
        guard case .object(var result) = try ContractFixtures.body("agent-settings-helper.json") else { return }
        // Older desktops resolve helpers false too, but do not identify them. Their visible switch must still
        // follow this returned value rather than optimistically applying the submitted true.
        result.removeValue(forKey: "parentAgentId")
        await harness.transport.enqueue(.completed(.object(result)))
        let saved = try await harness.store.updateSettings(.init(orchestration: .init(connectToDispatcher: .set(true))), target: harness.target)
        var previous = saved
        previous.orchestration?.connectToDispatcher = true
        #expect(saved.keepingOptions(of: previous).orchestration?.connectToDispatcher == false,
                "The sheet uses the returned policy; it must not apply true over it")
        guard case .update(let sent)? = await harness.transport.executed.first?.kind else { Issue.record("Missing update"); return }
        #expect(sent.orchestration == .init(connectToDispatcher: .set(true)))
    }

    @Test func snapshotAfterSessionResetRemovesResumeWithoutNewStateCode() async throws {
        let harness = try await start()
        defer { harness.stop() }
        func snapshot(_ hasSession: Bool) -> AnnexTransportEvent {
            harness.snapshotEvent(["agents": .object(["project": .array([.object([
                "id": .string("agent"), "name": .string("Agent"), "kind": .string("durable"), "status": .string("sleeping"), "hasSession": .bool(hasSession)
            ])])])])
        }
        await harness.transport.emit(snapshot(true))
        try await harness.waitUntil { harness.store.agent(for: harness.target)?.hasSession == true }
        #expect(harness.store.wakeChoices(for: harness.target).count == 2)
        guard case .object(var result) = try ContractFixtures.body("agent-settings.json") else { Issue.record("Missing settings"); return }
        result["sessionReset"] = .bool(true)
        await harness.transport.enqueue(.completed(.object(result)))
        _ = try await harness.store.updateSettings(.init(orchestrator: "codex-cli"), target: harness.target)
        await harness.transport.emit(snapshot(false))
        try await harness.waitUntil { harness.store.agent(for: harness.target)?.hasSession == false }
        #expect(harness.store.wakeChoices(for: harness.target) == [.newSession])
    }

    @Test func staleReportOnlySettingsShowTheServersRefusal() async throws {
        let harness = try await start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["agents": .object(["project": .array([.object([
            "id": .string("agent"), "name": .string("Helper"), "status": .string("running"),
            "orchestration": .object(["mcpEnabled": .bool(true), "mcpReportOnly": .bool(true)]),
        ])])])]))
        try await harness.waitUntil { harness.store.isMCPReportOnly(harness.target) }
        let message = "This helper can only report to its parent while Clubhouse MCP is off."
        await harness.transport.enqueue(.rejected(code: "mcp_off", message: message))
        #expect(await serviceErrorText { _ = try await harness.store.updateSettings(.init(orchestration: .init(orchestrate: .set(true))), target: harness.target) } == message)
        #expect(await harness.transport.executed.count == 1, "A stale client still shows the authoritative server refusal")
    }

    @Test func reportOnlyRefusesEnableWithoutSavingAndAcceptsClearing() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let caps = try ContractFixtures.body("capabilities.json")
        await harness.transport.setFeature("helperRouting", caps["helperRouting"] ?? .null)
        try await harness.refreshCatalog()
        guard case .object(var body) = try ContractFixtures.body("agent-settings-helper.json"),
              case .object(var policy)? = body["orchestration"] else { Issue.record("Missing helper policy"); return }
        policy["mcpEnabled"] = .bool(true); policy["mcpReportOnly"] = .bool(true)
        for key in ["orchestrate", "crossProjectHelpers", "autoHelpers", "connectToDispatcher"] { policy[key] = .bool(false) }
        body["orchestration"] = .object(policy)
        await harness.transport.setRead("agentSettings", .object(body))
        let before = try await harness.store.settings(for: harness.target)
        let message = CompanionOrchestration.mcpRequiredHelp
        let enables: [CompanionOrchestrationChange] = [.init(orchestrate: .set(true)), .init(crossProjectHelpers: .set(true)),
            .init(autoHelpers: .set(true)), .init(connectToDispatcher: .set(true))]
        for change in enables {
            await harness.transport.enqueue(.rejected(code: "mcp_off", message: message))
            #expect(await serviceErrorText { _ = try await harness.store.updateSettings(.init(orchestration: change), target: harness.target) } == message)
            let reloaded = try await harness.store.settings(for: harness.target)
            #expect(reloaded.orchestration == before.orchestration, "A stale enable refusal does not become an optimistic saved value")
        }
        let clears: [CompanionOrchestrationChange] = [.init(orchestrate: .clear), .init(crossProjectHelpers: .clear),
            .init(autoHelpers: .clear), .init(connectToDispatcher: .clear)]
        for change in clears {
            policy["autoHelpers"] = .null
            body["orchestration"] = .object(policy)
            await harness.transport.enqueue(.completed(.object(body)))
            let saved = try await harness.store.updateSettings(.init(orchestration: change), target: harness.target)
            #expect(saved.orchestration?.mcpReportOnly == true && saved.orchestration?.orchestrate == false)
            #expect(saved.orchestration?.autoHelpers == nil && saved.orchestration?.connectToDispatcher == false)
        }
        #expect(await harness.transport.executed.count == 8)
    }

    @Test func createAndUpdateShowTheMcpOffSentence() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let sentence = "Turn on Clubhouse MCP for this project to let agents orchestrate."
        await harness.transport.enqueue(.rejected(code: "mcp_off", message: sentence))
        #expect(await serviceErrorText { _ = try await harness.service.updateSettings(.init(orchestration: .init(orchestrate: .set(true))), target: harness.target, clientCommandID: "u") } == sentence)
        await harness.transport.enqueue(.rejected(code: "mcp_off", message: sentence))
        #expect(await harness.store.create(.init(project: harness.project, name: "planner", color: "indigo", orchestrate: true, clientCommandID: "c")) == false)
        #expect(harness.store.createError == sentence, "New agent renders createError as its error label")
    }
}
