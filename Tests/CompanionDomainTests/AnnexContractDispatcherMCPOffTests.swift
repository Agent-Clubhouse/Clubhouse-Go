import CryptoKit
import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Recorded desktop off states/routes, with local variants only for unrecorded compatibility and race cases.
/// Current desktops never send the MCP-off states: the Clubhouse MCP always runs (Clubhouse #2901). These use the
/// recordings pinned in `Fixtures/AnnexContractLegacy`, so the phone keeps handling an older desktop that sends them.
@MainActor @Suite(.serialized) struct AnnexContractDispatcherMCPOffTests {
    enum Source: String, CaseIterable { case snapshot, change, capabilities }
    private let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_dispatcher")

    private func fixture(_ state: String, source: Source) throws -> AnnexJSON {
        if state == "mcpOffRunning", source == .snapshot {
            return try #require(ContractFixtures.legacy("snapshot-dispatcher-mcp-off-running.json")["value"])
        }
        let key = source == .change ? "dispatcher:changed" : source.rawValue
        return try #require(ContractFixtures.legacy("dispatcher-off-states.json")["states"]?[state]?[key])
    }

    private func route(_ state: String, _ name: String) throws -> AnnexJSON {
        try #require(ContractFixtures.legacyCases("dispatcher-off-routes.json").first { $0["state"]?.string == state && $0["name"]?.string == name })
    }

    /// Route fixtures record HTTP outcomes; only the fake transport's receipt envelope is synthetic.
    private func receipt(_ route: AnnexJSON, id: String = "off-command") throws -> AnnexCommandReceipt {
        try AnnexJSON.object([
            "version": .integer(1), "commandId": .string(id), "epoch": .string("epoch"),
            "status": .string(route["response"]?["status"]?.integer == 200 ? "completed" : "rejected"),
            "error": route["response"]?["error"] ?? .null,
        ]).decode(AnnexCommandReceipt.self)
    }

    /// Variants not recorded by the desktop: on/return transitions, unknown/missing reasons, per-command
    /// restrictions and switch-off while MCP is also off. Always derive the record from a canonical state.
    private func variant(reason: String? = "mcp_off", running: Bool = true, commands: [String]? = nil, enabled: Bool = false, flagOn: Bool? = nil, newLayout: Bool = true) throws -> AnnexJSON {
        guard case .object(var value) = try fixture(running ? "mcpOffRunning" : "mcpOffStopped", source: .capabilities) else {
            throw AnnexTransportError.malformedResponse
        }
        value["enabled"] = .bool(enabled); value["flagOn"] = .bool(flagOn ?? enabled); value["newLayout"] = .bool(newLayout)
        if enabled {
            for key in ["offReason", "running", "status", "detail", "commandsWhileOff"] { value.removeValue(forKey: key) }
            value["agentId"] = .string(target.agentID)
        } else {
            value["offReason"] = reason.map(AnnexJSON.string)
            if let commands { value["commandsWhileOff"] = .array(commands.map(AnnexJSON.string)) }
        }
        return .object(value)
    }

    private func applyFixture(_ state: String, via source: Source, to harness: LiveServiceHarness) async throws {
        try await apply(fixture(state, source: source), via: source, to: harness, capabilities: fixture(state, source: .capabilities))
    }

    private func start(pending: Bool = false) async throws -> LiveServiceHarness {
        let on = try variant(reason: nil, enabled: true)
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", on)
            await transport.addCommands(["dispatcher.setEnabled", "agent.stop", "agent.update"])
        })
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": on]))
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
        var events: [AnnexJSON] = []
        if pending {
            events = [LiveServiceHarness.chatEvent("d1", sequence: 2, type: "permission_request", data: [
                "requestId": .string("perm-1"), "toolName": .string("Bash"), "title": .string("Run ls"),
                "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")])]),
            ])]
        }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1", events: events, fields: [
            "state": .string(pending ? "waiting_permission" : "idle"),
            "capabilities": .object(["interrupt": .bool(true), "steer": .bool(true), "questions": .bool(true), "queue": .string("client")]),
        ]))
        await harness.store.load(target)
        harness.store.selection = target
        return harness
    }

    private func apply(_ value: AnnexJSON, via source: Source, to harness: LiveServiceHarness, capabilities: AnnexJSON? = nil) async throws {
        var feature = capabilities ?? value
        if capabilities == nil, case .object(var fields) = value {
            fields["version"] = .integer(1)
            fields["newLayout"] = value["newLayout"] ?? .bool(harness.host?.dispatcher?.newLayout ?? true)
            feature = .object(fields)
        }
        await harness.transport.setFeature("dispatcher", feature)
        switch source {
        case .snapshot: await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        case .change: await harness.transport.emit(.message(.init(type: "dispatcher:changed", payload: value)))
        case .capabilities: try await harness.refreshCatalog()
        }
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == value["enabled"].boolValue && harness.host?.dispatcher?.mcpOff?.running == (value["offReason"]?.string == "mcp_off" ? value["running"].boolValue : nil) }
    }

    @Test func legacyFixturesMatchTheirPinnedBytes() throws {
        let source = try ContractFixtures.legacy("SOURCE.json")
        #expect(source["commit"]?.string == "4b3b4f59e67adcbe9df477b5f091ae1d9fb81953")
        guard case .object(let hashes)? = source["files"] else { Issue.record("Missing legacy fixture hashes"); return }
        #expect(hashes.count == 5)
        for (file, hash) in hashes {
            let data = try Data(contentsOf: ContractFixtures.legacyDirectory.appending(path: file))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash.string, "\(file) changed from its pinned recording")
            // The current desktop recordings dropped these; a file it still writes under the same name is newer, not legacy.
            if !file.hasPrefix("commands/") && !file.hasPrefix("dispatcher-off-") {
                #expect(try !ContractFixtures.files().contains(file), "\(file) is a current desktop fixture again")
            }
        }
        // The current recordings keep only the switched-off and classic layout states.
        guard case .object(let current)? = try ContractFixtures.json("dispatcher-off-states.json")["states"] else { Issue.record("Missing current off states"); return }
        #expect(current.keys.sorted() == ["classicLayout", "switchedOff"])
    }

    @Test func advertisedProviderControlCannotBypassMCPOffDispatcherRestrictions() async throws {
        let harness = try await start(); defer { harness.stop() }
        await harness.transport.setFeature("providerControl", CompanionProviderFlowTests.capability)
        await harness.transport.addCommands(["agent.providerPreview", "agent.providerChange"])
        try await applyFixture("mcpOffStopped", via: .capabilities, to: harness)
        #expect(harness.host?.canControlProvider == true)
        let flow = harness.store.providerFlow(for: target)
        await flow.select("codex-cli")
        do { _ = try await harness.service.providerPreview(target, provider: "codex-cli"); Issue.record("MCP-off preview must refuse") } catch {}
        do { try await harness.service.startNewProvider(target, provider: "codex-cli", clientCommandID: "off-start"); Issue.record("MCP-off start must refuse") } catch {}
        #expect(await harness.transport.executed.isEmpty)
        #expect(!harness.store.canEditSettings(target) && !harness.store.canWake(target))
    }

    @Test func recordedStatesAgreeAcrossAllSurfacesAndRoutesDecode() throws {
        for state in ["mcpOffRunning", "mcpOffStopped", "switchedOff", "classicLayout"] {
            let snapshot = try fixture(state, source: .snapshot)
            for source in Source.allCases {
                let value = try fixture(state, source: source)
                for field in ["enabled", "flagOn", "offReason", "running", "status", "detail", "commandsWhileOff", "agent"] {
                    #expect(value[field] == snapshot[field], "\(state), \(source.rawValue), \(field)")
                }
                #expect(value["status"] == value["agent"]?["status"])
                #expect(["running", "sleeping"].contains(value["status"]?.string ?? ""))
            }
            #expect(try fixture(state, source: .change)["agentId"] == .null)
        }
        #expect(try fixture("mcpOffRunning", source: .snapshot) == ContractFixtures.legacy("dispatcher-off-states.json")["states"]?["mcpOffRunning"]?["snapshot"])
        for item in try ContractFixtures.legacyCases("dispatcher-off-routes.json") {
            let state = try #require(item["state"]?.string)
            if item["name"]?.string == "read" {
                #expect(item["response"]?["status"]?.integer == (state.hasPrefix("mcpOff") ? 200 : 404))
            } else if item["response"]?["status"]?.integer == 200 {
                let command = try #require(item["request"]?["type"]?.string)
                #expect(try fixture(state, source: .snapshot)["commandsWhileOff"].arrayValue.contains(.string(command)))
                #expect(try CompanionLiveService.receiptError(receipt(item)) == nil)
            } else {
                let error = try #require(CompanionLiveService.receiptError(receipt(item)))
                if ["mcp_off", "dispatcher_layout_off", "incomplete_representation"].contains(item["response"]?["error"]?["code"]?.string ?? "") {
                    #expect(error.localizedDescription == item["response"]?["error"]?["message"]?.string)
                }
            }
        }
    }

    @Test(arguments: Source.allCases) func knownNonMCPReasonsStillRemoveTheAgent(source: Source) async throws {
        for state in ["switchedOff", "classicLayout"] {
            let harness = try await start()
            defer { harness.stop() }
            try await applyFixture(state, via: source, to: harness)
            try await harness.waitUntil { harness.store.agent(for: target) == nil }
            #expect(!harness.store.conversation(for: target).isLoaded)
            var navigation = CompanionNavigation(startScreen: .dispatcher)
            navigation.update(hosts: harness.store.hosts)
            #expect(!navigation.tabs.contains(.dispatcher))
        }
    }

    @Test(arguments: Source.allCases) func aColdOffReportCarriesItsOwnAgentRecord(source: Source) async throws {
        let off = try fixture("mcpOffRunning", source: .capabilities)
        let on = try variant(reason: nil, enabled: true)
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", source == .capabilities ? off : on)
            await transport.addCommands(["dispatcher.setEnabled"])
        })
        defer { harness.stop() }
        if source != .capabilities { try await applyFixture("mcpOffRunning", via: source, to: harness) }
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
        #expect(try fixture("mcpOffRunning", source: .change)["agentId"] == .null, "Off events keep the legacy id null")
        #expect(harness.store.agent(for: target)?.name == "Dispatcher")
        #expect(harness.store.allAgents.filter { $0.id == target }.count == 1)
        #expect(harness.host?.dispatcher?.mcpOff?.running == true)
    }

    @Test func offChangeReadsAgentAndKeepsTheCachedTranscriptWithLegacyNullID() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        guard case .object(var value) = try fixture("mcpOffRunning", source: .change), case .object(var agent)? = value["agent"] else { Issue.record("Missing local agent"); return }
        agent["name"] = .string("Desktop Dispatcher")
        value["agent"] = .object(agent)
        try await apply(.object(value), via: .change, to: harness)
        #expect(value["agentId"] == .null)
        #expect(harness.store.agent(for: target)?.name == "Desktop Dispatcher", "The new agent record is consumed even with agentId null")
        #expect(harness.store.conversation(for: target).items == items)
    }

    @Test(arguments: Source.allCases) func eachMetadataPathRetainsOpenChatNavigationAndApproval(source: Source) async throws {
        let harness = try await start(pending: true)
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        var navigation = CompanionNavigation(startScreen: .dispatcher)
        navigation.update(hosts: harness.store.hosts)
        navigation.open(target, hosts: harness.store.hosts)
        try await applyFixture("mcpOffRunning", via: source, to: harness)
        #expect(harness.store.conversation(for: target).items == items, "Resync must preserve cached content before the view reloads it")
        // The mounted conversation performs this read after a resync; the domain harness has no SwiftUI view.
        if source == .capabilities { await harness.store.load(target, force: true) }
        try await harness.waitUntil { harness.store.canOperate(target) }
        navigation.update(hosts: harness.store.hosts)
        #expect(harness.store.agent(for: target)?.isDispatcher == true)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(harness.store.selection == target && navigation.visibleAgent == target && navigation.tab == .dispatcher)
        #expect(harness.store.attentionItems().contains { $0.agent.id == target && $0.projectName == "Dispatcher" })
        #expect(harness.store.reviewEntries.contains { $0.agent.id == target })
        #expect(harness.store.dispatcherNeedsYouCount == 1)
        #expect(harness.store.canSend(target) && !harness.store.canWake(target) && !harness.store.mayWake(target))
        #expect(harness.store.canSleepDispatcher(target))
        #expect(harness.host?.dispatcher?.turnOnBlocker == "MCP is off on the desktop.")
        #expect(harness.host?.dispatcher?.isLoading == false)
    }

    @Test func sleepRequestWaitsForStoppedMetadataAndNeverEnablesDispatcherSettings() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .capabilities, to: harness)
        await harness.store.load(target, force: true)
        await harness.transport.enqueue(.completed(.object(["stopRequested": .bool(true)])))
        await harness.store.sleepDispatcher(target)
        #expect(harness.store.sleepRequests.contains(target))
        #expect(!harness.store.canWake(target) && !harness.store.canEditSettings(target))
        try await applyFixture("mcpOffStopped", via: .change, to: harness)
        try await harness.waitUntil { !harness.store.sleepRequests.contains(target) }
        #expect(!harness.store.canWake(target) && !harness.store.canSend(target) && !harness.store.canEditSettings(target))
        #expect(await harness.transport.executed.map(\.type) == ["agent.stop"])
    }

    @Test(arguments: Source.allCases) func stoppedUnderMCPOffKeepsHistoryAndReturningMCPDoesNotStartIt(source: Source) async throws {
        let harness = try await start()
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object([
            "agentId": .string(target.agentID),
            "event": LiveServiceHarness.chatEvent("d1", sequence: 2, type: "session_ended", data: ["reason": .string("stopped")]),
        ]))))
        try await harness.waitUntil { harness.store.agent(for: target)?.status == .stopped }
        try await applyFixture("mcpOffStopped", via: source, to: harness)
        #expect(harness.store.agent(for: target)?.status == .sleeping)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(harness.store.agent(for: target)?.capabilities.isEmpty == true)
        #expect(!harness.store.canSleepDispatcher(target) && !harness.store.canSend(target) && !harness.store.canWake(target))
        #expect(harness.host?.dispatcher?.statusNote == "MCP is off on the desktop.")
        let history = try await harness.service.history(for: target)
        #expect(history.items == items && history.capabilities?.isEmpty == true, "Even a stale running chat read cannot grant wake/send while stopped under MCP off")

        try await apply(variant(reason: nil, running: false, enabled: true), via: .snapshot, to: harness)
        #expect(harness.host?.dispatcher?.mcpOff == nil)
        #expect(harness.store.agent(for: target)?.status == .sleeping)
        #expect(harness.store.allAgents.filter { $0.id == target }.count == 1)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(await harness.transport.executed.isEmpty, "Restoring MCP never auto-starts a session")
    }

    @Test func runningMCPReturnRestoresCapabilitiesWithoutLosingChat() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        try await apply(variant(reason: nil, enabled: true), via: .change, to: harness)
        #expect(harness.store.canSend(target))
        #expect(harness.store.allAgents.filter { $0.id == target }.count == 1)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test(arguments: ["future_reason", ""]) func unknownReasonsAndOldDesktopsStillDropDisabledRecords(reason: String) async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(variant(reason: reason.isEmpty ? nil : reason), via: .snapshot, to: harness)
        try await harness.waitUntil { harness.store.agent(for: target) == nil }
        #expect(!harness.store.conversation(for: target).isLoaded)
        #expect(harness.host?.dispatcher?.liveAgent == nil)
        #expect(harness.host?.dispatcher?.turnOnBlocker == CompanionDispatcher.flagOffNote)
        var navigation = CompanionNavigation(startScreen: .dispatcher)
        navigation.update(hosts: harness.store.hosts)
        #expect(!navigation.tabs.contains(.dispatcher))
    }

    @Test func userSwitchOffWinsAfterMCPOff() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        try await applyFixture("switchedOff", via: .change, to: harness)
        try await harness.waitUntil { harness.store.agent(for: target) == nil }
        #expect(!harness.store.conversation(for: target).isLoaded)
    }

    @Test(arguments: [true, false]) func reconnectRetainsRunningOrStoppedMCPOff(running: Bool) async throws {
        let harness = try await start(pending: running)
        defer { harness.stop() }
        try await applyFixture(running ? "mcpOffRunning" : "mcpOffStopped", via: .snapshot, to: harness)
        let items = harness.store.conversation(for: target).items
        await harness.transport.emit(.connection(.disconnected))
        try await harness.waitUntil { harness.host?.connection == .offline }
        try await harness.refreshCatalog()
        #expect(harness.store.agent(for: target) != nil)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(harness.host?.dispatcher?.mcpOff?.running == running)
        #expect(!harness.store.canWake(target))
        if !running { #expect(!harness.store.canSend(target)) }
    }

    @Test(arguments: ["chat.send", "chat.interrupt", "agent.stop", "chat.permission", "chat.question", "chat.queue.remove", "dispatcher.setEnabled", "agent.start", "agent.update", "chat.setModel", "chat.setLevel", ""]) func eachCommandRequiresItsOffAllowlistEntry(command: String) async throws {
        let harness = try await start(pending: true)
        defer { harness.stop() }
        try await apply(variant(commands: command.isEmpty ? [] : [command]), via: .snapshot, to: harness)
        let caps = try #require(harness.store.agent(for: target)?.capabilities)
        #expect(caps.contains(.chat) == (command == "chat.send"))
        #expect(caps.contains(.cancel) == (command == "chat.interrupt"))
        #expect(caps.contains(.approve) == (command == "chat.permission"))
        #expect(caps.contains(.answer) == (command == "chat.question"))
        #expect(caps.contains(.removeQueued) == (command == "chat.queue.remove"))
        #expect(harness.store.canSleepDispatcher(target) == (command == "agent.stop"))
        #expect(!harness.store.canWake(target) && !caps.contains(.wake) && !harness.store.canEditSettings(target))
        let sendError = await serviceErrorText {
            _ = try await harness.service.send(.init(target: target, text: "Hello", clientCommandID: UUID().uuidString, isSteering: false))
        }
        #expect((sendError == nil) == (command == "chat.send"))
        let cancelError = await serviceErrorText { try await harness.service.cancel(target, clientCommandID: UUID().uuidString) }
        #expect((cancelError == nil) == (command == "chat.interrupt"))
        let sleepError = await serviceErrorText { try await harness.service.sleepDispatcher(target, clientCommandID: UUID().uuidString) }
        #expect((sleepError == nil) == (command == "agent.stop"))
        let permissionError = await serviceErrorText { try await harness.service.respond(to: "perm-1", optionID: "allow", target: target, clientCommandID: UUID().uuidString) }
        #expect((permissionError == nil) == (command == "chat.permission"))
        let enableError = await serviceErrorText { try await harness.service.setDispatcher(enabled: true, hostID: target.hostID, clientCommandID: UUID().uuidString) }
        #expect(enableError != nil, "Listing setEnabled never authorizes true")
        let wakeError = await serviceErrorText { try await harness.service.wake(target, resume: true, clientCommandID: UUID().uuidString) }
        #expect(wakeError != nil)
        let executed = await harness.transport.executed
        #expect(!executed.contains { $0.type == "agent.start" || $0.type == "dispatcher.setEnabled" })
    }

    @Test func allowlistedSendNeverFallsBackToStartingAStoppedSession() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(variant(commands: ["chat.send", "agent.start"]), via: .snapshot, to: harness)
        await harness.transport.setRead("chat", .object(["sessionId": .null, "readOnly": .bool(true), "canStart": .bool(true), "state": .string("sleeping"), "events": .array([])]))
        await harness.store.load(target, force: true)
        #expect(!harness.store.canWake(target) && !harness.store.canSend(target))
        #expect(await serviceErrorText { _ = try await harness.service.send(.init(target: target, text: "Hello", clientCommandID: "never-start", isSteering: false)) } != nil)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func anOffAllowlistCannotGrantAMissingSessionCapability() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1", fields: ["capabilities": .object(["interrupt": .bool(false)])]))
        await harness.store.load(target, force: true)
        #expect(harness.store.agent(for: target)?.capabilities.contains(.cancel) == false)
        await harness.store.cancel(target)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func aRetainedRecordWithoutFlagsCannotTurnItselfOn() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("switchedOff", via: .snapshot, to: harness)
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": .object([
            "agent": .object(["id": .string(target.agentID), "name": .string("Dispatcher"), "status": .string("sleeping")]),
        ])]))
        try await harness.refreshCatalog()
        #expect(harness.store.agent(for: target) == nil && harness.host?.dispatcher?.enabled == false)
    }

    @Test func aSessionEndingDuringSendRestoresDraftAndShowsTheDesktopMessage() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        let stoppedSend = try route("mcpOffStopped", "chat.send")
        let message = try #require(stoppedSend["response"]?["error"]?["message"]?.string)
        await harness.transport.enqueue(.heldReceipt(try receipt(stoppedSend, id: "held")))
        let draft = "  Keep this draft after the session stops.  "
        harness.store.drafts[target] = draft
        let submission = Task { await harness.store.sendDraft(to: target) }
        defer { Task { await harness.transport.releaseCommand() } }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        try await applyFixture("mcpOffStopped", via: .change, to: harness)
        await harness.transport.releaseCommand()
        await submission.value
        #expect(harness.store.drafts[target] == draft)
        #expect(harness.store.operationErrors[target] == message)
        #expect(harness.store.conversation(for: target).items.contains { item in
            if case .message(let sent) = item, case .failed(let detail) = sent.delivery { return detail == message }
            return false
        })
        #expect(!harness.store.canSend(target) && !harness.store.canWake(target))
        #expect(await harness.transport.executed.map(\.type) == ["chat.send"])
    }

    @Test func anEndedSessionKeepsAnUnsubmittedDraftAndCannotWakeFromSend() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        harness.store.drafts[target] = "Keep composing"
        try await applyFixture("mcpOffStopped", via: .change, to: harness)
        await harness.store.sendDraft(to: target)
        #expect(harness.store.drafts[target] == "Keep composing")
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func uncertainDeliveryDoesNotRestoreADraftForAccidentalResending() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "uncertain-send")))
        harness.store.drafts[target] = "May already be delivered"
        await harness.store.sendDraft(to: target)
        #expect(harness.store.drafts[target] == "")
        #expect(harness.store.conversation(for: target).items.contains { item in
            if case .message(let sent) = item, case .uncertain = sent.delivery { return true }
            return false
        })
    }

    @Test func anAllowedPermissionStillShowsItsOwnDesktopValidationError() async throws {
        let harness = try await start(pending: true)
        defer { harness.stop() }
        try await applyFixture("mcpOffRunning", via: .snapshot, to: harness)
        let approval = try #require(harness.store.pinnedApproval(for: target))
        let option = try #require(approval.options.first)
        let permission = try route("mcpOffRunning", "chat.permission")
        let message = try #require(permission["response"]?["error"]?["message"]?.string)
        await harness.transport.enqueue(.receipt(try receipt(permission)))
        await harness.store.respond(approval, option: option, target: target)
        #expect(harness.store.operationErrors[target] == message)
        #expect(harness.store.pinnedApproval(for: target)?.resolution == .pending)
        #expect(await harness.transport.executed.map(\.type) == ["chat.permission"])
    }

    @Test func onlyUserSwitchedOffWithMCPOnOffersEnableAndKeepsLegacyReceiptShape() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture("switchedOff", via: .snapshot, to: harness)
        #expect(harness.host?.dispatcher?.turnOnBlocker == nil)
        let accepted = try #require(ContractFixtures.cases("commands/dispatcher.setEnabled.json").first { $0["name"]?.string == "accepted" })
        let acceptedBody = try #require(accepted["response"]?["body"])
        await harness.transport.enqueue(.receipt(try acceptedBody.decode(AnnexCommandReceipt.self)))
        await harness.store.setDispatcher(enabled: true, hostID: target.hostID)
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == true }
        #expect(harness.host?.dispatcher?.isLoading == true, "The unchanged setEnabled receipt still waits for the agent snapshot")
        #expect(await harness.transport.executed.map(\.type) == ["dispatcher.setEnabled"])
        for off in try [variant(reason: "switched_off", running: false), fixture("classicLayout", source: .capabilities), fixture("mcpOffRunning", source: .capabilities)] {
            try await apply(off, via: .capabilities, to: harness)
            #expect(harness.host?.dispatcher?.turnOnBlocker != nil)
            await harness.store.setDispatcher(enabled: true, hostID: target.hostID)
        }
        #expect(await harness.transport.executed.count == 1, "MCP off and classic states do not offer enable")
    }

    @Test func enableRefusalCodesKeepTheirDistinctDesktopMessages() throws {
        let classic = try route("classicLayout", "dispatcher.setEnabled true")
        #expect(CompanionDispatcher.layoutOffNote == classic["response"]?["error"]?["message"]?.string)
        #expect(CompanionAgentCommandError.message(code: "dispatcher_layout_off", message: "Desktop-specific layout reason.") == "Desktop-specific layout reason.")
        for item in try ContractFixtures.cases("commands/dispatcher.setEnabled.json") {
            let body = try #require(item["response"]?["body"])
            let decoded = try body.decode(AnnexCommandReceipt.self)
            if decoded.status == .rejected {
                #expect(CompanionLiveService.receiptError(decoded)?.localizedDescription == body["error"]?["message"]?.string)
            }
        }
        for item in [classic, try route("mcpOffRunning", "dispatcher.setEnabled true")] {
            #expect(try CompanionLiveService.receiptError(receipt(item))?.localizedDescription == item["response"]?["error"]?["message"]?.string)
        }
    }

    @Test(arguments: ["switched_off", "classic_layout"]) func otherOffReasonsDoNotKeepHistoryRoutes(reason: String) async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await applyFixture(reason == "classic_layout" ? "classicLayout" : "switchedOff", via: .snapshot, to: harness)
        await harness.transport.failRead("chat", .rejected(status: 404, code: "agent_not_found"))
        await harness.transport.failRead("chatSessions", .rejected(status: 404, code: "agent_not_found"))
        #expect(await serviceErrorText { _ = try await harness.service.history(for: target) } != nil)
        #expect(await serviceErrorText { _ = try await harness.service.sessions(for: target) } != nil)
        #expect(harness.store.agent(for: target) == nil && !harness.store.conversation(for: target).isLoaded)
    }

    @Test func desktopMCPOffRefusalIsShownThroughTheMessagePath() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let stoppedSend = try route("mcpOffStopped", "chat.send")
        let message = try #require(stoppedSend["response"]?["error"]?["message"]?.string)
        await harness.transport.enqueue(.receipt(try receipt(stoppedSend)))
        harness.store.drafts[target] = "Hello"
        await harness.store.sendDraft(to: target)
        #expect(harness.store.operationErrors[target] == message)
    }
}
