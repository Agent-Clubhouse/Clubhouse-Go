import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Local additive-contract payloads until the desktop's recorded fixtures are available.
@MainActor @Suite(.serialized) struct AnnexContractDispatcherMCPOffTests {
    enum Source: String, CaseIterable { case snapshot, change, capabilities }
    private let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_dispatcher")
    private let allowed = ["chat.interrupt", "agent.stop", "chat.permission", "chat.question", "chat.queue.remove", "dispatcher.setEnabled"]

    private func block(reason: String? = "mcp_off", running: Bool = true, commands: [String]? = nil, enabled: Bool = false, flagOn: Bool? = nil, newLayout: Bool = true) -> AnnexJSON {
        var value: [String: AnnexJSON] = [
            "version": .integer(1), "enabled": .bool(enabled), "flagOn": .bool(flagOn ?? enabled), "newLayout": .bool(newLayout), "projectId": .string(target.projectID),
            "agentId": enabled ? .string(target.agentID) : .null,
            // Even a stopped or user-disabled Dispatcher keeps its desktop record. This never implies enabled.
            "agent": .object(["id": .string(target.agentID), "name": .string("Dispatcher"), "kind": .string("durable"),
                              "projectId": .string(target.projectID), "status": .string(running ? "running" : "sleeping"),
                              "isDispatcher": .bool(true), "hasSession": .bool(true)]),
        ]
        if !enabled {
            value["running"] = .bool(running)
            value["status"] = .string(running ? "running" : "sleeping")
            value["detail"] = .string(running ? "MCP off; session running" : "MCP off")
            value["commandsWhileOff"] = .array((commands ?? allowed).map(AnnexJSON.string))
            if let reason { value["offReason"] = .string(reason) }
        }
        return .object(value)
    }

    private func start(pending: Bool = false) async throws -> LiveServiceHarness {
        let on = block(reason: nil, enabled: true)
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

    private func apply(_ value: AnnexJSON, via source: Source, to harness: LiveServiceHarness) async throws {
        await harness.transport.setFeature("dispatcher", value)
        switch source {
        case .snapshot: await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        case .change: await harness.transport.emit(.message(.init(type: "dispatcher:changed", payload: value)))
        case .capabilities: try await harness.refreshCatalog()
        }
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == value["enabled"].boolValue && harness.host?.dispatcher?.mcpOff?.running == (value["offReason"]?.string == "mcp_off" ? value["running"].boolValue : nil) }
    }

    @Test(arguments: Source.allCases) func aColdOffReportCarriesItsOwnAgentRecord(source: Source) async throws {
        let off = block()
        let on = block(reason: nil, enabled: true)
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", source == .capabilities ? off : on)
            await transport.addCommands(["dispatcher.setEnabled"])
        })
        defer { harness.stop() }
        if source != .capabilities { try await apply(off, via: source, to: harness) }
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
        #expect(off["agentId"] == .null, "Off events keep the legacy id null")
        #expect(harness.store.agent(for: target)?.name == "Dispatcher")
        #expect(harness.store.allAgents.filter { $0.id == target }.count == 1)
        #expect(harness.host?.dispatcher?.mcpOff?.running == true)
    }

    @Test func offChangeReadsAgentAndKeepsTheCachedTranscriptWithLegacyNullID() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        guard case .object(var value) = block(), case .object(var agent)? = value["agent"] else { Issue.record("Missing local agent"); return }
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
        try await apply(block(), via: source, to: harness)
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
        #expect(!harness.store.canSend(target) && !harness.store.canWake(target) && !harness.store.mayWake(target))
        #expect(harness.store.canSleepDispatcher(target))
        #expect(harness.host?.dispatcher?.turnOnBlocker == "MCP is off on the desktop.")
        #expect(harness.host?.dispatcher?.isLoading == false)
    }

    @Test(arguments: Source.allCases) func stoppedUnderMCPOffKeepsHistoryAndReturningMCPDoesNotStartIt(source: Source) async throws {
        let harness = try await start()
        defer { harness.stop() }
        let items = harness.store.conversation(for: target).items
        try await apply(block(), via: .snapshot, to: harness)
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object([
            "agentId": .string(target.agentID),
            "event": LiveServiceHarness.chatEvent("d1", sequence: 2, type: "session_ended", data: ["reason": .string("stopped")]),
        ]))))
        try await harness.waitUntil { harness.store.agent(for: target)?.status == .stopped }
        try await apply(block(running: false, commands: ["dispatcher.setEnabled"]), via: source, to: harness)
        #expect(harness.store.agent(for: target)?.status == .sleeping)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(harness.store.agent(for: target)?.capabilities.isEmpty == true)
        #expect(!harness.store.canSleepDispatcher(target) && !harness.store.canSend(target) && !harness.store.canWake(target))
        #expect(harness.host?.dispatcher?.statusNote == "MCP is off on the desktop.")
        let history = try await harness.service.history(for: target)
        #expect(history.items == items && history.capabilities?.isEmpty == true, "Even a stale running chat read cannot grant wake/send while stopped under MCP off")

        try await apply(block(reason: nil, running: false, enabled: true), via: .snapshot, to: harness)
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
        try await apply(block(), via: .snapshot, to: harness)
        try await apply(block(reason: nil, enabled: true), via: .change, to: harness)
        #expect(harness.store.canSend(target))
        #expect(harness.store.allAgents.filter { $0.id == target }.count == 1)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test(arguments: ["switched_off", "classic_layout", "future_reason", ""]) func otherReasonsAndOldDesktopsStillDropDisabledRecords(reason: String) async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(reason: reason.isEmpty ? nil : reason), via: .snapshot, to: harness)
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
        try await apply(block(), via: .snapshot, to: harness)
        try await apply(block(reason: "switched_off", running: false), via: .change, to: harness)
        try await harness.waitUntil { harness.store.agent(for: target) == nil }
        #expect(!harness.store.conversation(for: target).isLoaded)
    }

    @Test(arguments: [true, false]) func reconnectRetainsRunningOrStoppedMCPOff(running: Bool) async throws {
        let harness = try await start(pending: running)
        defer { harness.stop() }
        try await apply(block(running: running), via: .snapshot, to: harness)
        let items = harness.store.conversation(for: target).items
        await harness.transport.emit(.connection(.disconnected))
        try await harness.waitUntil { harness.host?.connection == .offline }
        try await harness.refreshCatalog()
        #expect(harness.store.agent(for: target) != nil)
        #expect(harness.store.conversation(for: target).items == items)
        #expect(harness.host?.dispatcher?.mcpOff?.running == running)
        #expect(!harness.store.canWake(target) && !harness.store.canSend(target))
    }

    @Test(arguments: ["chat.send", "chat.interrupt", "agent.stop", "chat.permission", "chat.question", "chat.queue.remove", "dispatcher.setEnabled", "agent.start", "agent.update", "chat.setModel", "chat.setLevel", ""]) func eachCommandRequiresItsOffAllowlistEntry(command: String) async throws {
        let harness = try await start(pending: true)
        defer { harness.stop() }
        try await apply(block(commands: command.isEmpty ? [] : [command]), via: .snapshot, to: harness)
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
        try await apply(block(commands: ["chat.send", "agent.start"]), via: .snapshot, to: harness)
        await harness.transport.setRead("chat", .object(["sessionId": .null, "readOnly": .bool(true), "canStart": .bool(true), "state": .string("sleeping"), "events": .array([])]))
        await harness.store.load(target, force: true)
        #expect(!harness.store.canWake(target) && !harness.store.canSend(target))
        #expect(await serviceErrorText { _ = try await harness.service.send(.init(target: target, text: "Hello", clientCommandID: "never-start", isSteering: false)) } != nil)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func anOffAllowlistCannotGrantAMissingSessionCapability() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(), via: .snapshot, to: harness)
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1", fields: ["capabilities": .object(["interrupt": .bool(false)])]))
        await harness.store.load(target, force: true)
        #expect(harness.store.agent(for: target)?.capabilities.contains(.cancel) == false)
        await harness.store.cancel(target)
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func aRetainedRecordWithoutFlagsCannotTurnItselfOn() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(reason: "switched_off", running: false), via: .snapshot, to: harness)
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": .object([
            "agent": .object(["id": .string(target.agentID), "name": .string("Dispatcher"), "status": .string("sleeping")]),
        ])]))
        try await harness.refreshCatalog()
        #expect(harness.store.agent(for: target) == nil && harness.host?.dispatcher?.enabled == false)
    }

    @Test func aSessionEndingDuringSendRestoresDraftAndShowsTheDesktopMessage() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(commands: ["chat.send"]), via: .snapshot, to: harness)
        let message = "Clubhouse MCP is off, so the Dispatcher can only be stopped or answered from a phone. Turn on Clubhouse MCP on the desktop."
        let receipt = try AnnexJSON.object([
            "version": .integer(1), "commandId": .string("held"), "epoch": .string("epoch"), "status": .string("rejected"),
            "error": .object(["code": .string("mcp_off"), "message": .string(message)]),
        ]).decode(AnnexCommandReceipt.self)
        await harness.transport.enqueue(.heldReceipt(receipt))
        let draft = "  Keep this draft after the session stops.  "
        harness.store.drafts[target] = draft
        let submission = Task { await harness.store.sendDraft(to: target) }
        defer { Task { await harness.transport.releaseCommand() } }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        try await apply(block(running: false, commands: ["dispatcher.setEnabled"]), via: .change, to: harness)
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
        try await apply(block(commands: ["chat.send"]), via: .snapshot, to: harness)
        harness.store.drafts[target] = "Keep composing"
        try await apply(block(running: false, commands: ["dispatcher.setEnabled"]), via: .change, to: harness)
        await harness.store.sendDraft(to: target)
        #expect(harness.store.drafts[target] == "Keep composing")
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func uncertainDeliveryDoesNotRestoreADraftForAccidentalResending() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(commands: ["chat.send"]), via: .snapshot, to: harness)
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
        try await apply(block(), via: .snapshot, to: harness)
        let approval = try #require(harness.store.pinnedApproval(for: target))
        let option = try #require(approval.options.first)
        let message = "This request is too large to review here. Review it on the desktop to approve it, or deny it here."
        await harness.transport.enqueue(.rejected(code: "incomplete_representation", message: message))
        await harness.store.respond(approval, option: option, target: target)
        #expect(harness.store.operationErrors[target] == message)
        #expect(harness.store.pinnedApproval(for: target)?.resolution == .pending)
        #expect(await harness.transport.executed.map(\.type) == ["chat.permission"])
    }

    @Test func onlyUserSwitchedOffWithMCPOnOffersEnableAndKeepsLegacyReceiptShape() async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(reason: "switched_off", running: false, flagOn: true), via: .snapshot, to: harness)
        #expect(harness.host?.dispatcher?.turnOnBlocker == nil)
        await harness.transport.enqueue(.completed(.object(["enabled": .bool(true), "flagOn": .bool(true), "agentId": .string(target.agentID)])))
        await harness.store.setDispatcher(enabled: true, hostID: target.hostID)
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == true }
        #expect(harness.host?.dispatcher?.isLoading == true, "The unchanged setEnabled receipt still waits for the agent snapshot")
        #expect(await harness.transport.executed.map(\.type) == ["dispatcher.setEnabled"])
        for off in [block(reason: "switched_off", running: false), block(reason: "classic_layout", running: false, flagOn: true, newLayout: false), block()] {
            try await apply(off, via: .snapshot, to: harness)
            #expect(harness.host?.dispatcher?.turnOnBlocker != nil)
            await harness.store.setDispatcher(enabled: true, hostID: target.hostID)
        }
        #expect(await harness.transport.executed.count == 1, "MCP off and classic states do not offer enable")
    }

    @Test func enableRefusalCodesKeepTheirDistinctDesktopMessages() throws {
        #expect(CompanionDispatcher.layoutOffNote == "Turn off Classic layout in Settings > Display & UI on the desktop.")
        #expect(CompanionAgentCommandError.message(code: "dispatcher_layout_off", message: "Desktop-specific layout reason.") == "Desktop-specific layout reason.")
        for (code, message) in [
            ("mcp_off", "Clubhouse MCP is off, so the Dispatcher can only be stopped or answered from a phone. Turn on Clubhouse MCP on the desktop."),
            ("dispatcher_flag_off", "Clubhouse MCP is off. Turn on Clubhouse MCP on the desktop first."),
            ("dispatcher_layout_off", "Turn off Classic layout in Settings > Display & UI on the desktop."),
        ] {
            let receipt = try AnnexJSON.object([
                "version": .integer(1), "commandId": .string("enable"), "epoch": .string("epoch"), "status": .string("rejected"),
                "error": .object(["code": .string(code), "message": .string(message)]),
            ]).decode(AnnexCommandReceipt.self)
            #expect(CompanionLiveService.receiptError(receipt)?.localizedDescription == message)
        }
    }

    @Test(arguments: ["switched_off", "classic_layout"]) func otherOffReasonsDoNotKeepHistoryRoutes(reason: String) async throws {
        let harness = try await start()
        defer { harness.stop() }
        try await apply(block(reason: reason, running: false, flagOn: true, newLayout: reason != "classic_layout"), via: .snapshot, to: harness)
        await harness.transport.failRead("chat", .rejected(status: 404, code: "agent_not_found"))
        await harness.transport.failRead("chatSessions", .rejected(status: 404, code: "agent_not_found"))
        #expect(await serviceErrorText { _ = try await harness.service.history(for: target) } != nil)
        #expect(await serviceErrorText { _ = try await harness.service.sessions(for: target) } != nil)
        #expect(harness.store.agent(for: target) == nil && !harness.store.conversation(for: target).isLoaded)
    }

    @Test func desktopMCPOffRefusalIsShownThroughTheMessagePath() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let message = "MCP is off. You can still interrupt this session."
        await harness.transport.enqueue(.rejected(code: "mcp_off", message: message))
        harness.store.drafts[target] = "Hello"
        await harness.store.sendDraft(to: target)
        #expect(harness.store.operationErrors[target] == message)
    }
}
