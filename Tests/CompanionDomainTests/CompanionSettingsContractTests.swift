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
        let topLevel = try CompanionAgentSettings(json: ContractFixtures.body("agent-settings-running.json"))
        #expect(topLevel.parentAgentID == nil)
        #expect(topLevel.keepingOptions(of: helper).parentAgentID == nil, "Handoff removes helper identity; it isn't an option to retain")
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
