import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// The desktop's app-wide Dispatcher (`dispatcher` v1, desktop #2533): one durable agent outside every project.

private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }

private let dispatcherID = "durable_dispatcher"
private let dispatcherProject = "__dispatcher__"

private func dispatcherFeature(enabled: Bool = true, flagOn: Bool = true, newLayout: Bool? = nil) -> AnnexJSON {
    var fields: [String: AnnexJSON] = ["version": .integer(1), "enabled": .bool(enabled), "flagOn": .bool(flagOn), "projectId": .string(dispatcherProject),
                                       "snapshotField": .string("dispatcher"), "event": .string("dispatcher:changed")]
    if let newLayout { fields["newLayout"] = .bool(newLayout) }
    return .object(fields)
}

/// The snapshot's `dispatcher`, with its agent in the catalog's shape.
private func dispatcherSnapshot(status: String = "running", detailed: AnnexJSON? = nil) -> AnnexJSON {
    var agent: [String: AnnexJSON] = ["id": .string(dispatcherID), "name": .string("Dispatcher"), "kind": .string("durable"), "status": .string(status),
                                      "projectId": .string(dispatcherProject), "isDispatcher": .bool(true), "color": .string("cyan"),
                                      "freeAgentMode": .bool(true), "lastActivityAt": .integer(1_760_000_000_000)]
    if let detailed { agent["detailedStatus"] = detailed }
    return .object(["enabled": .bool(true), "flagOn": .bool(true), "projectId": .string(dispatcherProject), "agent": .object(agent)])
}

@MainActor private func startWithDispatcher(enabled: Bool = true, flagOn: Bool = true, toggle: Bool = true) async throws -> LiveServiceHarness {
    try await LiveServiceHarness.start(configure: { transport in
        await transport.setFeature("dispatcher", dispatcherFeature(enabled: enabled, flagOn: flagOn))
        if toggle { await transport.addCommands(["dispatcher.setEnabled", "agent.update"]) }
    })
}

@MainActor private func sendSnapshot(_ harness: LiveServiceHarness, dispatcher: AnnexJSON) async throws {
    await harness.transport.emit(harness.snapshotEvent(["dispatcher": dispatcher]))
}

private let fixtureHostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
private let dispatcherTarget = CompanionTarget(hostID: fixtureHostID, projectID: dispatcherProject, agentID: dispatcherID)

// MARK: Transport

@Suite struct DispatcherTransportTests {
    private func caps(_ extra: String) throws -> AnnexCapabilities {
        try json(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","commands":["agent.update","dispatcher.setEnabled"],"idempotency":{"scope":"s","maxEntries":1,"ttlMs":1}\#(extra)}"#)
            .decode(AnnexCapabilities.self)
    }

    @Test func capabilityDecodesAndTheToggleNeedsItsCommand() throws {
        let on = try caps(#","dispatcher":{"version":1,"enabled":true,"flagOn":true,"newLayout":false,"projectId":"__dispatcher__","snapshotField":"dispatcher"}"#)
        #expect(on.supportsDispatcher && on.supportsDispatcherToggle)
        #expect(on.dispatcher == .init(enabled: true, flagOn: true, newLayout: false, projectID: "__dispatcher__"))
        let missing = try caps("")
        #expect(missing.dispatcher == nil && !missing.supportsDispatcher && !missing.supportsDispatcherToggle, "An older desktop has no Dispatcher")
    }

    @Test func aMalformedBlockReadsAsOffWithoutFailingTheDocument() throws {
        let odd = try caps(#","dispatcher":{"version":"one","enabled":"yes","projectId":""}"#)
        #expect(odd.dispatcher?.version == 0 && odd.dispatcher?.enabled == false && odd.dispatcher?.projectID == "__dispatcher__")
        #expect(odd.dispatcher?.newLayout == true, "A draft that doesn't say is taken as the New layout")
        #expect(!odd.supportsDispatcher)
        let wrongType = try caps(#","dispatcher":"on""#)
        #expect(wrongType.dispatcher == nil)
    }

    @Test func setEnabledEncodesAsTheDesktopTakesIt() throws {
        let command = AnnexCommand(commandID: "c1", epoch: "e1", kind: .setDispatcherEnabled(true))
        #expect(command.type == "dispatcher.setEnabled")
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
                == .object(["version": .integer(1), "commandId": .string("c1"), "epoch": .string("e1"), "type": .string("dispatcher.setEnabled"), "enabled": .bool(true)]))
        #expect(command.diagnosticOperation == .command)
    }

    @Test func orchestrationPatchCarriesTheNewFields() throws {
        let update = AnnexAgentUpdate(agentID: "a", orchestration: .init(crossProjectHelpers: .set(true), connectToDispatcher: .clear))
        let encoded = try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "c", epoch: "e", kind: .update(update)).encoded())
        #expect(encoded["orchestration"] == .object(["crossProjectHelpers": .bool(true), "connectToDispatcher": .null]))
        let create = AnnexAgentCreate(projectID: "p", name: "n", color: "c", orchestration: .init(orchestrate: .set(true), connectToDispatcher: .set(true)))
        let created = try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "c", epoch: "e", kind: .create(create)).encoded())
        #expect(created["orchestration"] == .object(["orchestrate": .bool(true), "connectToDispatcher": .bool(true)]))
    }
}

// MARK: Orchestration and messages

@Suite struct DispatcherDomainTests {
    @Test func policyDecodesConnectToDispatcherAndCrossProjectHelpers() throws {
        let policy = try #require(CompanionOrchestration(json: try json(#"""
        {"orchestrate":true,"crossProjectHelpers":true,"connectToDispatcher":true,"sources":{"crossProjectHelpers":"agent","connectToDispatcher":"persona"}}
        """#)))
        #expect(policy.crossProjectHelpers && policy.connectToDispatcher)
        #expect(policy.sources == ["crossProjectHelpers": .agent, "connectToDispatcher": .persona])
        let older = try #require(CompanionOrchestration(json: try json(#"{"orchestrate":true,"connectToDispatcher":"yes"}"#)))
        #expect(!older.crossProjectHelpers && !older.connectToDispatcher, "Missing or odd fields read as off")
    }

    @Test func aChangeShowsBeforeTheDesktopAnswersAndBecomesAPatch() {
        let change = CompanionOrchestrationChange(crossProjectHelpers: .set(true), connectToDispatcher: .set(true))
        let next = change.applied(to: CompanionOrchestration(orchestrate: true))
        #expect(next.crossProjectHelpers && next.connectToDispatcher && next.sources["connectToDispatcher"] == .agent)
        #expect(AnnexOrchestrationPatch(change) == .init(crossProjectHelpers: .set(true), connectToDispatcher: .set(true)))
    }

    @Test func relayTagsAreParsed() {
        let relay = CompanionRelay(text: "[TASK:dsp-42] [FROM:Dispatcher] Finish the fix.\nThen report.")
        #expect(relay == .init(sender: "Dispatcher", taskID: "dsp-42", body: "Finish the fix.\nThen report."))
        #expect(CompanionRelay(text: "[FROM:planner@Clubhouse] hi")?.sender == "planner@Clubhouse", "The task tag is optional")
        #expect(CompanionRelay(text: "  [TASK:1]  [FROM: Atlas ]\nBody")?.body == "Body")
        #expect(CompanionRelay(text: "Just a message") == nil)
        #expect(CompanionRelay(text: "Hi [FROM:Dispatcher] later") == nil, "Only a leading tag counts")
        #expect(CompanionRelay(text: "[TASK:1] [FROM:] x") == nil)
    }

    @Test func aRelayedMessageIsCaptionedWithItsSenderAndShownWithoutItsTags() {
        var message = CompanionMessage(id: "m", role: .user, text: "[TASK:t] [FROM:Dispatcher] Do the thing", source: "mcp")
        #expect(message.sourceLabel == "From Dispatcher")
        #expect(message.displayText == "Do the thing")
        #expect(message.text == "[TASK:t] [FROM:Dispatcher] Do the thing", "The raw text stays for Copy")
        message.isSteered = true
        #expect(message.sourceLabel == "From Dispatcher · Steered into the running turn")

        let untagged = CompanionMessage(id: "m", role: .user, text: "Do the thing", source: "mcp")
        #expect(untagged.sourceLabel == "From another agent" && untagged.displayText == "Do the thing")
        let typed = CompanionMessage(id: "m", role: .user, text: "[TASK:t] [FROM:Dispatcher] x", source: "user")
        #expect(typed.relay == nil && typed.displayText == typed.text, "Only agent messages are relays")
    }

    @Test func dispatcherNotesAndTheTurnOnBlocker() {
        #expect(CompanionDispatcher(enabled: false, flagOn: false, canToggle: true).turnOnBlocker == CompanionDispatcher.flagOffNote)
        #expect(CompanionDispatcher(enabled: false, flagOn: true, newLayout: false, canToggle: true).turnOnBlocker == CompanionDispatcher.layoutOffNote)
        #expect(CompanionDispatcher(enabled: false, flagOn: true, canToggle: false).turnOnBlocker?.contains("Update Clubhouse") == true)
        #expect(CompanionDispatcher(enabled: false, flagOn: true, canToggle: true).turnOnBlocker == nil)
        #expect(CompanionDispatcher(enabled: true, flagOn: true).isLoading)
        for code in ["dispatcher_off", "dispatcher_locked", "dispatcher_flag_off", "dispatcher_layout_off"] {
            #expect(CompanionAgentCommandError.message(code: code, message: code) != nil, "\(code)")
        }
        #expect(CompanionAgentCommandError.message(code: "orchestration_has_helpers", message: nil)?.contains("other projects") == true)
    }
}

// MARK: Projects audit

@Suite struct DispatcherProjectsAuditTests {
    private func host(dispatcherStatus: CompanionAgentStatus = .idle, enabled: Bool = true) -> CompanionHost {
        var agent = CompanionAgent(id: dispatcherTarget, name: "Dispatcher", subtitle: "", status: dispatcherStatus, executionMode: "pty")
        agent.isDispatcher = true
        let worker = CompanionAgent(id: .init(hostID: fixtureHostID, projectID: "project", agentID: "agent"), name: "Agent", subtitle: "", status: .idle)
        return .init(id: fixtureHostID, name: "Mac", endpoint: "", connection: .connected,
                     projects: [.init(id: "project", name: "Project", agents: [worker])],
                     terminal: .init(projectShell: true, agentShell: true, agentAttach: true),
                     dispatcher: .init(enabled: enabled, flagOn: true, canToggle: true, agent: agent))
    }

    @Test func theDispatcherIsAnAgentButNeverAProject() {
        let host = host()
        #expect(host.projects.map(\.id) == ["project"])
        #expect(host.allAgents.map(\.id.agentID) == ["agent", dispatcherID])
        #expect(host.agent(for: dispatcherTarget)?.isDispatcher == true)
        #expect(host.isDispatcher(dispatcherTarget) && !host.isDispatcher(.init(hostID: host.id, projectID: "project", agentID: "agent")))
        #expect(!host.isDispatcher(.init(hostID: "other", projectID: dispatcherProject, agentID: dispatcherID)))
        #expect(host.placeName(for: dispatcherTarget) == "Dispatcher")
        #expect(host.placeName(for: .init(hostID: host.id, projectID: "project", agentID: "agent")) == "Project")
        var off = host
        off.dispatcher?.enabled = false
        #expect(off.allAgents.count == 1 && off.agent(for: dispatcherTarget) == nil, "Turned off, its agent is gone everywhere")
    }

    @MainActor @Test func onlyTheDispatchersOwnTerminalOpens() {
        let host = host(dispatcherStatus: .working)
        #expect(CompanionTerminalAvailability.of(.agentShell(dispatcherTarget), host: host) == .hidden, "No project shell for it")
        #expect(CompanionTerminalAvailability.of(.project(.init(hostID: host.id, projectID: dispatcherProject)), host: host) == .hidden)
        #expect(CompanionTerminalAvailability.of(.agentPTY(dispatcherTarget), host: host) == .available, "Its own terminal, when it runs in one")
        #expect(CompanionTerminalSession.title(for: .agentPTY(dispatcherTarget), host: host) == "Dispatcher")
        #expect(CompanionTerminalAvailability.of(.agentShell(.init(hostID: host.id, projectID: "project", agentID: "agent")), host: host) == .available)
    }

    @MainActor @Test func storeListsItInNeedsYouAgentsAndReviewWithoutAProject() {
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts([host(dispatcherStatus: .approval)]))
        #expect(store.agent(for: dispatcherTarget)?.isDispatcher == true && store.isDispatcher(dispatcherTarget))
        let items = store.attentionItems()
        #expect(items.map(\.agent.id) == [dispatcherTarget] && items.first?.projectName == "Dispatcher")
        #expect(store.needsYouCount == 1)
        #expect(store.agentsNeedsYouFirst().first?.id == dispatcherTarget)
        #expect(store.reviewEntries.first?.projectName == "Dispatcher")
        #expect(store.projectEntries.map(\.project.id) == ["project"], "Home's projects, pins, idle rules and spawn never see it")
        #expect(store.sleepingAgents(in: .init(hostID: fixtureHostID, projectID: dispatcherProject)).isEmpty)
    }
}

// MARK: Live service

@MainActor @Suite(.serialized) struct DispatcherLiveServiceTests {
    @Test func anOlderDesktopWithoutTheCapabilityChangesNothing() async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": dispatcherSnapshot()]))
        try await harness.waitUntil { harness.host?.projects.first?.agents.first?.name == "Agent" }
        try await harness.refreshCatalog()
        #expect(harness.host?.dispatcher == nil)
        #expect(harness.store.allAgents.map(\.id.agentID) == ["agent"])
    }

    @Test func theSnapshotsDispatcherBecomesItsOwnRowAndSurvivesRefreshes() async throws {
        let harness = try await startWithDispatcher()
        defer { harness.stop() }
        #expect(harness.host?.dispatcher?.isLoading == true, "On, before its agent arrives")
        try await sendSnapshot(harness, dispatcher: dispatcherSnapshot(detailed: .object(["state": .string("working"), "message": .string("Asking River")])))
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        let agent = try #require(harness.store.agent(for: dispatcherTarget))
        #expect(agent.isDispatcher && agent.name == "Dispatcher" && agent.orchestration == nil && agent.freeAgentMode)
        #expect(agent.detail?.message == "Asking River")
        #expect(harness.host?.projects.map(\.id) == ["project"], "Not a project")
        #expect(harness.host?.dispatcher?.canToggle == true)

        // REST refreshes never list it; the snapshot's entry stays.
        try await harness.refreshCatalog()
        #expect(harness.store.agent(for: dispatcherTarget) != nil)
    }

    @Test func itsChatAndStatusEventsReachIt() async throws {
        let harness = try await startWithDispatcher()
        defer { harness.stop() }
        try await sendSnapshot(harness, dispatcher: dispatcherSnapshot())
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1"))
        await harness.store.load(dispatcherTarget)
        #expect(harness.store.conversation(for: dispatcherTarget).isLoaded)

        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object([
            "agentId": .string(dispatcherID),
            "event": LiveServiceHarness.chatEvent("d1", sequence: 2, type: "permission_request", data: [
                "requestId": .string("perm-1"), "toolName": .string("Bash"), "title": .string("Run ls"),
                "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")])]),
            ]),
        ]))))
        try await harness.waitUntil { harness.store.agent(for: dispatcherTarget)?.status == .approval }
        #expect(harness.store.attentionItems().contains { $0.agent.id == dispatcherTarget && $0.projectName == "Dispatcher" })

        // A status change without a chat projection updates the remembered entry too.
        await harness.transport.emit(.message(.init(type: "agent:status", payload: .object(["id": .string(dispatcherID), "status": .string("sleeping")]))))
        try await harness.waitUntil { harness.store.agent(for: dispatcherTarget)?.status == .sleeping }
    }

    @Test(arguments: [true, false]) func aStoppedDispatcherRechecksWakePermissionWithoutReopening(canStart: Bool) async throws {
        let harness = try await startWithDispatcher()
        defer { harness.stop() }
        try await sendSnapshot(harness, dispatcher: dispatcherSnapshot())
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1"))
        await harness.store.load(dispatcherTarget)
        #expect(!harness.store.canWake(dispatcherTarget))
        let reads = await harness.transport.readRoutes.filter { $0.name == "chatHistory" }.count
        await harness.transport.setRead("chatHistory", .object(["sessionId": .null, "state": .string("sleeping"),
            "readOnly": .bool(true), "canStart": .bool(canStart), "events": .array([])]))
        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object([
            "agentId": .string(dispatcherID),
            "event": LiveServiceHarness.chatEvent("d1", sequence: 2, type: "session_ended", data: ["reason": .string("stopped")]),
        ]))))
        await harness.transport.emit(.message(.init(type: "agent:status", payload: .object([
            "id": .string(dispatcherID), "kind": .string("durable"), "status": .string("sleeping"), "detailedStatus": .null]))))
        try await harness.waitUntil { await harness.transport.readRoutes.filter { $0.name == "chatHistory" }.count > reads }
        if canStart { try await harness.waitUntil { harness.store.canWake(dispatcherTarget) } }
        #expect(harness.store.canWake(dispatcherTarget) == canStart, "Wake requires the desktop's current permission")
        #expect(harness.store.conversation(for: dispatcherTarget).isLoaded, "The conversation stays open")
    }

    @Test func turnedOffItsRowAndChatGoAndLaterEventsAreDropped() async throws {
        let harness = try await startWithDispatcher()
        defer { harness.stop() }
        try await sendSnapshot(harness, dispatcher: dispatcherSnapshot())
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d1"))
        await harness.store.load(dispatcherTarget)

        await harness.transport.setFeature("dispatcher", dispatcherFeature(enabled: false))
        await harness.transport.emit(.message(.init(type: "dispatcher:changed", payload: .object([
            "enabled": .bool(false), "flagOn": .bool(true), "agentId": .null]), seq: 10)))
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == false }
        #expect(harness.host?.dispatcher?.agent == nil && harness.store.agent(for: dispatcherTarget) == nil)
        #expect(!harness.store.conversation(for: dispatcherTarget).isLoaded, "Its open chat is dropped")
        #expect(harness.store.isDispatcher(dispatcherTarget), "An open chat still knows it was the Dispatcher's, to say it's off")

        await harness.transport.emit(.message(.init(type: "chat:event", payload: .object([
            "agentId": .string(dispatcherID),
            "event": LiveServiceHarness.chatEvent("d1", sequence: 3, type: "agent_message", data: ["messageId": .string("late"), "text": .string("Late")]),
        ]))))
        try await harness.refreshCatalog()
        #expect(harness.store.conversation(for: dispatcherTarget).items.isEmpty)
    }

    @Test func turningItOnSendsTheCommandAndRefusalsExplainThemselves() async throws {
        let harness = try await startWithDispatcher(enabled: false)
        defer { harness.stop() }
        #expect(harness.host?.dispatcher?.enabled == false && harness.host?.dispatcher?.turnOnBlocker == nil)
        await harness.transport.setFeature("dispatcher", dispatcherFeature(enabled: true))
        await harness.transport.enqueue(.completed(.object(["enabled": .bool(true), "flagOn": .bool(true), "agentId": .string(dispatcherID)])))
        await harness.store.setDispatcher(enabled: true, hostID: LiveServiceHarness.hostID)
        #expect(await harness.transport.executed.map(\.kind) == [.setDispatcherEnabled(true)])
        try await harness.waitUntil { harness.host?.dispatcher?.isLoading == true }
        #expect(harness.store.dispatcherErrors.isEmpty)

        await harness.transport.enqueue(.rejected(code: "dispatcher_layout_off", message: "dispatcher_layout_off"))
        await harness.store.setDispatcher(enabled: false, hostID: LiveServiceHarness.hostID)
        #expect(harness.store.dispatcherErrors[LiveServiceHarness.hostID] == CompanionDispatcher.layoutOffNote)
    }

    @Test func theFlagOffKeepsItOffWithoutSendingAnything() async throws {
        let harness = try await startWithDispatcher(enabled: false, flagOn: false)
        defer { harness.stop() }
        await harness.store.setDispatcher(enabled: true, hostID: LiveServiceHarness.hostID)
        #expect(await harness.transport.executed.isEmpty)
        #expect(harness.store.dispatcherErrors[LiveServiceHarness.hostID] == CompanionDispatcher.flagOffNote)
    }

    @Test func aDesktopWithoutTheCommandCantBeToggledFromThePhone() async throws {
        let harness = try await startWithDispatcher(enabled: false, toggle: false)
        defer { harness.stop() }
        #expect(harness.host?.dispatcher?.canToggle == false)
        #expect(await serviceErrorKind { try await harness.service.setDispatcher(enabled: true, hostID: LiveServiceHarness.hostID, clientCommandID: "c") } == .unavailable)
    }

    @Test func turnedBackOnTheNextSnapshotBringsItsAgent() async throws {
        let harness = try await startWithDispatcher(enabled: false)
        defer { harness.stop() }
        await harness.transport.setFeature("dispatcher", dispatcherFeature(enabled: true))
        await harness.transport.emit(.message(.init(type: "dispatcher:changed", payload: .object([
            "enabled": .bool(true), "flagOn": .bool(true), "agentId": .string(dispatcherID)]))))
        try await harness.waitUntil { harness.host?.dispatcher?.isLoading == true }
        try await sendSnapshot(harness, dispatcher: dispatcherSnapshot())
        try await harness.waitUntil { harness.store.agent(for: dispatcherTarget) != nil }
    }
}
