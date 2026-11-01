import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// The desktop's canonical fixtures (`Tests/Fixtures/AnnexContract/`, see scripts/sync-annex-fixtures.sh), through
/// the phone's real decoders, live service and store: what the user would see from the desktop's actual messages.
enum ContractFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/AnnexContract", directoryHint: .isDirectory)
    static func json(_ name: String) throws -> AnnexJSON {
        try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: directory.appending(path: name)))
    }
    static func body(_ name: String, _ key: String? = nil) throws -> AnnexJSON {
        let value = try json(name)
        let exchange = key.map { value[$0] } ?? value
        return exchange?["response"]?["body"] ?? .null
    }
    static func cases(_ name: String) throws -> [AnnexJSON] { (try json(name)["cases"]).arrayValue }
    static func files() throws -> [String] { (try json("index.json")["files"]).arrayValue.compactMap(\.string) }
    /// Event types repeat (five user_message fixtures). Pick the intended delivery by its stable message id.
    static func chatEvent(_ messageID: String) throws -> AnnexJSON {
        let events = try json("chat-events.json")["frames"].arrayValue.compactMap { $0["payload"]?["event"] }
            .filter { $0["data"]?["messageId"]?.string == messageID }
        #expect(events.count == 1, "Expected one fixture delivery for \(messageID)")
        return try #require(events.first)
    }
}

/// A desktop that answers from the fixtures. Commands must be accepted-shaped: within the desktop's field list and
/// equal to one of its recorded accepted requests. Each is answered with that request's recorded receipt.
/// A lock-guarded class rather than an actor: the compiler refuses this actor's synthesized initializer
/// ("'nonisolated' on an actor's synchronous initializer is invalid") in clean builds of this target.
final class ContractTransport: AnnexTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private var matchedCommands: [String] = []
    private var recordedProblems: [String] = []
    var matched: [String] { lock.withLock { matchedCommands } }
    var problems: [String] { lock.withLock { recordedProblems } }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        lock.withLock { continuation = pair.continuation }
        return pair.stream
    }
    private var stream: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation? { lock.withLock { continuation } }
    func connect() { stream?.yield(.connection(.connected)) }
    /// The socket drops and comes back, as after the phone was in the background.
    func reconnect() { stream?.yield(.connection(.disconnected)); stream?.yield(.connection(.connected)) }
    func disconnect() {}
    func emit(_ frame: AnnexJSON) throws {
        stream?.yield(.message(try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frame))))
    }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities: return try ContractFixtures.body("capabilities.json")
        case .projects: return try ContractFixtures.body("rest-catalog.json", "projects")
        case .agents(let project): return project == "proj_app" ? try ContractFixtures.body("rest-catalog.json", "agents") : .array([])
        case .chat(let agent):
            switch agent {
            case "durable_chat": return try ContractFixtures.body("chat-snapshot.json")
            case "durable_sleepy": return try ContractFixtures.body("chat-snapshot-sleeping.json")
            default: throw AnnexTransportError.rejected(status: 404, code: "agent_not_found")
            }
        case .chatSessions: return try ContractFixtures.body("chat-sessions.json")
        case .agentState: return try ContractFixtures.body("agent-state.json")
        case .createOptions(let project):
            guard project == "proj_app" else { throw AnnexTransportError.rejected(status: 404, code: "project_not_found") }
            return try ContractFixtures.body("create-options.json")
        case .agentSettings(let agent):
            switch agent {
            case "durable_sleepy": return try ContractFixtures.body("agent-settings.json")
            case "durable_chat": return try ContractFixtures.body("agent-settings-running.json")
            case "durable_docs": return try ContractFixtures.body("agent-settings-helper.json")
            default: throw AnnexTransportError.rejected(status: 404, code: "agent_not_found")
            }
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        let sent = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
        let schema = try ContractFixtures.json("commands/_fields.json")
        let allowed = Set((schema["base"]).arrayValue.compactMap(\.string) + (schema["commands"]?[command.type]?["fields"]).arrayValue.compactMap(\.string))
        guard case .object(let fields) = sent else { throw AnnexTransportError.malformedResponse }
        let unknown = Set(fields.keys).subtracting(allowed)
        if !unknown.isEmpty { lock.withLock { recordedProblems.append("\(command.type) sends \(unknown.sorted()), which the desktop refuses") } }
        func content(_ value: AnnexJSON?) -> AnnexJSON? {
            guard case .object(var values)? = value else { return nil }
            values.removeValue(forKey: "commandId"); values.removeValue(forKey: "epoch")
            return .object(values)
        }
        let cases = try ContractFixtures.cases("commands/\(command.type).json")
        guard let match = cases.first(where: { $0["name"]?.string?.hasPrefix("accepted") == true && content($0["request"]) == content(sent) }),
              case .object(var receipt)? = match["response"]?["body"] else {
            let text = String(data: try command.encoded(), encoding: .utf8) ?? ""
            lock.withLock { recordedProblems.append("No accepted \(command.type) request matches \(text)") }
            throw AnnexTransportError.rejected(status: 400, code: "invalid_command")
        }
        lock.withLock { matchedCommands.append("\(command.type): \(match["name"]?.string ?? "")") }
        receipt["commandId"] = .string(command.commandID)
        return try AnnexJSON.object(receipt).decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct AnnexContractDomainTests {
    static let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    let chat = CompanionTarget(hostID: hostID, projectID: "proj_app", agentID: "durable_chat")
    let sleepy = CompanionTarget(hostID: hostID, projectID: "proj_app", agentID: "durable_sleepy")
    var project: CompanionProjectTarget { .init(hostID: Self.hostID, projectID: "proj_app") }

    private func connect() async throws -> (CompanionLiveService, CompanionStore, ContractTransport) {
        let transport = ContractTransport()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: Self.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Studio Mac", transport: transport))
        try await waitUntil { store.hosts.first?.connection == .connected }
        // The recorded snapshot, with the helper requests the desktop listed in its second one.
        guard case .object(var frame)? = try ContractFixtures.json("snapshot.json")["frame"], case .object(var payload)? = frame["payload"] else {
            throw AnnexTransportError.malformedResponse
        }
        payload["helperRequests"] = try ContractFixtures.json("snapshot-helper-requests.json")["value"]
        frame["payload"] = .object(payload)
        try transport.emit(.object(frame))
        try await waitUntil { store.hosts.first?.helperRequests.isEmpty == false || store.hosts.first?.projectState != nil }
        return (service, store, transport)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the fixture desktop")
        throw AnnexTransportError.disconnected
    }

    // MARK: Snapshot and catalog

    @Test func helperParentCanBeOutsideTheCatalogAndDisappearsOnHandoff() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let target = CompanionTarget(hostID: Self.hostID, projectID: "proj_app", agentID: "durable_docs")
        guard case .object(var frame)? = try ContractFixtures.json("snapshot.json")["frame"],
              case .object(var payload)? = frame["payload"], case .object(var agents)? = payload["agents"],
              case .array(var app)? = agents["proj_app"],
              let index = app.firstIndex(where: { $0["id"]?.string == "durable_docs" }),
              case .object(var helper) = app[index] else { throw AnnexTransportError.malformedResponse }
        helper["parentAgentId"] = .string("parent_in_another_project")
        app[index] = .object(helper); agents["proj_app"] = .array(app); payload["agents"] = .object(agents); frame["payload"] = .object(payload)
        try transport.emit(.object(frame))
        try await waitUntil { store.agent(for: target)?.parentAgentID == "parent_in_another_project" }
        helper.removeValue(forKey: "parentAgentId")
        app[index] = .object(helper); agents["proj_app"] = .array(app); payload["agents"] = .object(agents); frame["payload"] = .object(payload)
        try transport.emit(.object(frame))
        try await waitUntil { store.agent(for: target)?.parentAgentID == nil }
    }

    @Test func snapshotBecomesTheHostTheUserSees() async throws {
        let (service, store, _) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let host = try #require(store.hosts.first)
        #expect(host.projects.map(\.name) == ["App", "docs"])
        let app = try #require(host.projects.first)
        #expect(app.color == "indigo" && app.iconData != nil)
        let planner = try #require(app.agents.first { $0.id.agentID == "durable_chat" })
        #expect(planner.name == "planner" && planner.emoji == "🦊" && planner.color == "indigo" && planner.iconData != nil)
        #expect(planner.hasSession == true && planner.branch == "planner/standby" && planner.orchestrator == "claude-code" && !planner.isQuick)
        #expect(planner.detail?.state == "needs_permission")
        #expect(planner.orchestration?.orchestrate == true && planner.orchestration?.maxHelpers == 3 && planner.orchestration?.sources["maxHelpers"] == .agent)
        let quick = try #require(app.agents.first { $0.id.agentID == "quick_1" })
        #expect(quick.isQuick && quick.color == "gray" && quick.subtitle == "Fix the flaky test" && quick.status == .working)
        #expect(quick.parentAgentID == nil, "Quick-agent parent metadata is a different payload, not durable helper identity")
        let helper = try #require(app.agents.first { $0.id.agentID == "durable_docs" })
        #expect(helper.parentAgentID == "durable_chat")
        #expect(planner.parentAgentID == nil)
        #expect(try await service.settings(for: helper.id).parentAgentID == "durable_chat")
        #expect(app.agents.first { $0.id.agentID == "durable_term" }?.runsInTerminal == true)

        // Capability-gated features, from the desktop's capabilities.
        #expect(host.canSpawn && host.canCreateDurable && host.canEditSettings && host.canAnswerHelperRequests)
        #expect(host.canSyncProjectState && host.canSyncFinishedQuick && host.canRevokeSession && host.canAnswerPersistentApprovals && host.canSetFreeAgentMode)
        #expect(host.richContentAvailable && host.attachments?.maxCount == 10 && host.terminal != nil && host.canOrchestrate)

        // Helper requests, both kinds.
        #expect(host.helperRequests.map(\.kind) == [.start, .dispose])
        let start = host.helperRequests[0], dispose = host.helperRequests[1]
        #expect(start.helperID == nil && start.helperName == "impl-ipc" && start.requesterName == "planner" && start.task == "Wire the IPC")
        #expect(start.expiresAt != nil && start.requestedAt != nil && start.summary.contains("impl-ipc"))
        #expect(dispose.helperID == "durable_docs" && dispose.expiresAt == nil)
        #expect(dispose.dispose == .init(uncommittedFiles: 2, unpushedCommits: 1, unmergedCommits: 0, checkError: nil, forceRequested: true, workAtRisk: true, canDispose: true))

        // Project state, idle days and the finished list.
        #expect(host.projectState?["proj_app"]?.pinned == true && host.projectState?["proj_docs"]?.idle == true && host.idleDays == 7)
        #expect(host.projectState?["proj_app"]?.lastActivity != nil)
        let finished = try #require(host.finishedQuickAgents?["proj_app"])
        #expect(finished.map(\.status) == [.completed, .stopped])
        #expect(finished[0].mission == "Write the release notes" && finished[0].summary == "Wrote docs/release.md" && finished[0].completedAt.timeIntervalSince1970 > 0)
        #expect(host.finishedQuickAgents?["proj_docs"] == [])

        #expect(host.theme != nil)
        #expect(host.providers.map(\.name) == ["Claude Code", "Codex"])
    }

    @Test func liveChatSnapshotBecomesTheConversation() async throws {
        let (service, store, _) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let history = try await service.history(for: chat)
        #expect(history.sessionID == "sess_live" && history.lastSequence == 12)
        #expect(history.contentRoots.paths == ["/work/app/.clubhouse/agents/planner", "/work/app"])
        guard case .message(let user)? = history.items.first(where: { $0.id == "message:msg_1" }) else { Issue.record("no user message"); return }
        #expect(user.role == .user && user.clientCommandID == "cmd_photo" && user.text == "What is on this screen?")
        #expect(user.images.map(\.mediaRef) == [String(repeating: "ab", count: 32) + ".png"])
        #expect(user.images.first?.name == "shot.png" && user.images.first?.width == 1179)
        guard case .approval(let approval)? = history.items.first(where: { $0.id == "approval:perm_1" }) else { Issue.record("no approval"); return }
        #expect(approval.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce] && approval.options[1].scope == "npm test:*")
        guard case .question(let question)? = history.items.first(where: { $0.id == "question:q_1" }) else { Issue.record("no question"); return }
        #expect(question.prompts.first?.options.map(\.id) == ["main", "dev"] && question.prompts.first?.allowsFreeText == true)
        #expect(history.items.contains { $0.id == "tool:tool_1" } && history.items.contains { $0.id == "message:amsg_1" })

        try await waitUntil { store.agent(for: chat)?.chatControls != nil }
        let agent = try #require(store.agent(for: chat))
        #expect(agent.capabilities.isSuperset(of: [.chat, .approve, .answer, .steer, .cancel, .images, .removeQueued]))
        let controls = try #require(agent.chatControls)
        #expect(controls.model == "opus" && controls.effort == "high" && controls.currentLevel == .ask && controls.effortReported)
        #expect(controls.models.map(\.id) == ["opus", "sonnet"] && controls.efforts == ["low", "medium", "high"])
        #expect(controls.liveLevels == [.plan, .ask, .autoEdit, .fullAccess] && controls.levelNames[.ask] == "default")
        #expect(agent.contextUsage?.size == 200_000 && agent.model == "opus")
        // The composer's / menu: the desktop's bounded list, with the CLI's own commands marked start-only.
        let slash = try #require(agent.slashCommands)
        #expect(slash.map(\.name) == ["compact", "review", "frontend-design"])
        #expect(slash[0].startOnly && slash[0].inputHint == "<optional custom summarization instructions>" && slash[0].description != nil)
        #expect(!slash[1].startOnly && slash[1].inputHint == "<pr>")
    }

    @Test func sleepingChatSnapshotIsReadOnlyAndOffersAWake() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let history = try await service.history(for: sleepy)
        #expect(history.sessionID == "sess_old" && history.items.count == 2)
        // The store hears of the snapshot's Wake through the service's next hosts update.
        try await waitUntil { store.agent(for: sleepy)?.capabilities.contains(.wake) == true }
        #expect(store.agent(for: sleepy)?.slashCommands == nil, "No / menu while asleep")
        try await service.wake(sleepy, resume: true, clientCommandID: "wake-1")
        #expect(transport.matched == ["agent.start: accepted wake"])
        let problems = transport.problems
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: Agents that sleep while the phone is away

    /// The phone saw brave-otter working; it slept while the phone was in the background. The reconnect's one
    /// bulk read (the desktop's recorded `agent-state.json`) puts it to sleep, without opening its chat.
    @Test func aReconnectCatchesUpFromTheDesktopsAgentState() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        try transport.emit(.object(["type": .string("chat:event"), "seq": .integer(900), "payload": .object(["agentId": .string("durable_sleepy"),
            "event": .object(["v": .integer(2), "agentId": .string("durable_sleepy"), "sessionId": .string("sess_old"), "seq": .integer(4),
                              "type": .string("session_state"), "data": .object(["state": .string("running")])])])]))
        try await waitUntil { store.agent(for: sleepy)?.status == .working }
        transport.reconnect()
        try await waitUntil { store.agent(for: sleepy)?.status == .sleeping }
        #expect(store.hosts.first?.connection == .connected)
    }

    /// The desktop's recorded frames when a durable agent goes to sleep: `pty:exit` (the terminal's) and `agent:status`.
    @Test func theDesktopsSleepFramesPutALiveChatToSleep() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        _ = try await service.history(for: chat)
        try await waitUntil { store.agent(for: chat)?.status.dot != .sleeping }
        for frame in (try ContractFixtures.json("agent-sleep.json")["frames"]).arrayValue { try transport.emit(frame) }
        try await waitUntil { store.agent(for: chat)?.status == .sleeping }
        #expect(store.agent(for: chat)?.capabilities.contains(.chat) != true)
    }

    // MARK: Commands, end to end

    /// The user's actions produce the requests the desktop recorded as accepted, and its receipts read back.
    @Test func userActionsSendAcceptedCommandsAndReadTheirReceipts() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        _ = try await service.history(for: chat)
        _ = try await service.send(.init(target: chat, text: "Run the tests", clientCommandID: "c1", isSteering: false))
        _ = try await service.send(.init(target: chat, text: "Then the linter", clientCommandID: "c2", isSteering: false, queueIfBusy: true))
        try await service.cancel(chat, clientCommandID: "c3")
        #expect(try await service.removeQueued("msg_q", target: chat, clientCommandID: "c4"))
        try await service.respond(to: "perm_1", optionID: "allow", target: chat, clientCommandID: "c5")
        try await service.respond(to: "perm_1", optionID: "always", target: chat, clientCommandID: "c6")
        try await service.answer("q_1", answers: ["which": .text("main")], target: chat, clientCommandID: "c7")
        try await service.answer("q_1", answers: ["which": .choices(["main", "dev"])], target: chat, clientCommandID: "c8")
        try await service.setModel("sonnet", effort: nil, target: chat, clientCommandID: "c9")
        try await service.setLevel(.fullAccess, target: chat, clientCommandID: "c10")
        let spawned = try await service.spawn(.init(project: project, prompt: "Fix the flaky test", provider: "claude-code", model: "sonnet", clientCommandID: "c11"))
        #expect(spawned.agentTarget?.agentID == "quick_new")
        let created = try await service.create(.init(project: project, name: "quiet-wren", color: "emerald", orchestrator: nil, model: nil, persona: nil,
                                                     useWorktree: nil, mcpIDs: nil, clientCommandID: "c12"))
        #expect(created.target.agentID == "durable_created" && created.isCreating)
        let saved = try await service.updateSettings(.init(idleSleep: .never), target: chat, clientCommandID: "c13")
        #expect(saved.name.value == "planner")
        let pinned = try await service.setProject(.init(hostID: Self.hostID, projectID: "proj_docs"), pinned: true, clientCommandID: "c14")
        #expect(pinned.pinned && !pinned.idle)
        let marked = try await service.setProject(.init(hostID: Self.hostID, projectID: "proj_docs"), inactive: true, clientCommandID: "c15")
        #expect(marked.inactive && marked.idle)
        let left = try await service.dismissFinishedQuick(.init(hostID: Self.hostID, projectID: "proj_app", agentID: "quick_done"), clientCommandID: "c16")
        #expect(left.map(\.target.agentID) == ["quick_stopped"])
        #expect(try await service.clearFinishedQuick(project, clientCommandID: "c17").isEmpty)
        let requests = try #require(store.hosts.first?.helperRequests)
        try #require(requests.count == 2)
        // Snapshot request ids are the desktop's of that moment; any accepted approve/decline shape will do.
        try? await service.answerHelperRequest(requests[1], approve: true, force: true, clientCommandID: "c18")
        try? await service.answerHelperRequest(requests[0], approve: false, force: false, clientCommandID: "c19")

        let problems = transport.problems
        #expect(problems.filter { !$0.contains("helper.") } == [])
        let matched = transport.matched
        for expected in ["chat.send: accepted", "chat.send: accepted queued", "chat.interrupt: accepted", "chat.queue.remove: accepted",
                         "chat.permission: accepted", "chat.permission: accepted persistent option", "chat.question: accepted",
                         "chat.question: accepted multiple choices", "chat.setModel: accepted switch", "chat.setLevel: accepted", "agent.spawn: accepted",
                         "agent.create: accepted minimal", "agent.update: accepted while running (idleSleep)", "project.setPinned: accepted",
                         "project.setInactive: accepted", "quick.dismiss: accepted", "quick.clear: accepted"] {
            #expect(matched.contains(expected), "\(expected)")
        }
    }

    // MARK: Decoders

    @Test func createOptionsDecode() throws {
        let options = try CompanionCreateOptions(json: try ContractFixtures.body("create-options.json"))
        #expect(options.options.orchestrators.map(\.id) == ["claude-code", "codex-cli"])
        let claude = options.options.orchestrators[0], codex = options.options.orchestrators[1]
        #expect(claude.badge == "Beta" && claude.available && claude.permissions && claude.chat && claude.models.map(\.id) == ["default", "opus", "sonnet"])
        #expect(!codex.available && codex.unavailableReason == "Codex CLI not found" && !codex.permissions && !codex.chat)
        #expect(options.options.personas.map(\.id) == ["qa", "architect"] && options.options.colors.count == 8)
        #expect(options.mcpCatalog.map(\.id) == ["github", "ado"] && options.mcpDefaults == ["github"])
        #expect(options.isGitRepo && options.suggestedName == "brave-otter" && options.defaultOrchestrator == "claude-code")
        #expect(options.defaultColor == "indigo" && options.defaultModel == "default" && options.defaultUseWorktree && options.freeAgentModeAllowed)
    }

    @Test func agentSettingsDecode() throws {
        let settings = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings.json"))
        #expect(settings.state == "sleeping" && settings.sleeping && settings.name.value == "brave-otter" && settings.name.editable == .sleeping)
        #expect(settings.idleSleep.value == .minutes(60) && settings.idleSleep.editable == .always && settings.idleSleepApplies)
        #expect(settings.resolvedOrchestrator == "claude-code" && settings.resolvedRuntime == "chat")
        #expect(settings.clubhouseMode.value == nil && settings.clubhouseMode.editable == .never)
        #expect(settings.freeAgentMode.editable == .sleeping && settings.idleSleepMinutes == [15, 30, 60, 240] && settings.appIdleMinutes == 30)
        #expect(settings.options.orchestrators.count == 2)
        let workspace = try #require(settings.workspace)
        #expect(workspace.branch == "brave-otter/standby" && workspace.worktree == ".clubhouse/agents/brave-otter")
        #expect(workspace.changes?.files == 2 && workspace.changes?.additions == 94 && workspace.changes?.deletions == 51 && workspace.changes?.ahead == 2)

        #expect(settings.orchestration == CompanionOrchestration(sources: ["orchestrate": .default, "access": .default, "control": .default, "maxHelpers": .default,
                                                                          "crossProjectHelpers": .default, "connectToDispatcher": .default]))

        let running = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-running.json"))
        #expect(running.state == "running" && !running.sleeping && running.hasLockedSettings)
        #expect(running.orchestration?.orchestrate == true && running.orchestration?.maxHelpers == 3 && running.orchestration?.maxHelpersCap == 20)
        // The agent.update receipt's result is the settings without options.
        for item in try ContractFixtures.cases("commands/agent.update.json") where item["response"]?["body"]?["status"]?.string == "completed" {
            let result = try #require(item["response"]?["body"]?["result"])
            #expect(throws: Never.self, "\(item["name"]?.string ?? "")") { _ = try CompanionAgentSettings(json: result) }
        }
        let updated = try CompanionAgentSettings(json: try #require(try ContractFixtures.cases("commands/agent.update.json").first?["response"]?["body"]?["result"]))
        #expect(updated.name.value == "bright-otter" && updated.emoji.value == "🦦" && updated.idleSleep.value == .minutes(30))
        let orchestrated = try #require(try ContractFixtures.cases("commands/agent.update.json").first { $0["name"]?.string == "accepted orchestration" })
        let policy = try CompanionAgentSettings(json: try #require(orchestrated["response"]?["body"]?["result"])).orchestration
        #expect(policy?.access == "auto" && policy?.control == "ask-everything" && policy?.maxHelpers == 20 && policy?.sources["access"] == .agent)
    }

    @Test func readErrorsBecomeUserMessages() throws {
        for (file, key) in [("create-options-errors.json", "projectNotFound"), ("agent-settings-errors.json", "agentNotFound")] {
            let response = try #require(try ContractFixtures.json(file)[key]?["response"])
            let error = AnnexTransportError.rejected(status: Int(response["status"]?.integer ?? 0), code: response["body"]?["error"]?.string)
            #expect(!CompanionLiveService.agentReadError(error).contains("_"), "\(file)")
        }
    }

    /// Every chat event type the desktop sends folds into the conversation without losing what it says.
    @Test func everyChatEventTypeProjects() throws {
        var projection = CompanionChatProjector()
        let frames = (try ContractFixtures.json("chat-events.json")["frames"]).arrayValue
        for frame in frames { projection.apply(try #require(frame["payload"]?["event"])) }
        #expect(projection.sessionID == "sess_live" && projection.lastSequence == 134)
        #expect(frames.filter { $0["payload"]?["event"]?["type"]?.string == "user_message" }.count == 5)
        guard case .message(let user)? = projection.items.first(where: { $0.id == "message:msg_10" }) else { Issue.record("no user message"); return }
        #expect(user.isSteered && user.images.count == 1 && user.images[0].name == "p.jpg" && user.text.contains("Like this?"))
        guard case .tool(let tool)? = projection.items.first(where: { $0.id == "tool:tool_2" }) else { Issue.record("no tool"); return }
        #expect(tool.state == .completed && tool.hasChanges && tool.location == "src/main.ts")
        #expect(tool.images == [.image(String(repeating: "ef", count: 32) + ".png")])
        guard case .approval(let approval)? = projection.items.first(where: { $0.id == "approval:perm_2" }) else { Issue.record("no approval"); return }
        #expect(approval.resolution == .allowed && approval.detail?.isEmpty == false)
        guard case .question(let question)? = projection.items.first(where: { $0.id == "question:q_2" }) else { Issue.record("no question"); return }
        #expect(question.resolution == .answered)
        #expect(projection.items.contains { $0.id.hasPrefix("message:plan-") })
        #expect(projection.items.contains { $0.id == "message:plan-document-plan_1" })
        #expect(projection.items.contains { if case .notice(_, let text) = $0 { text == "Explore · completed" } else { false } })
        #expect(projection.items.contains { if case .notice(_, let text) = $0 { text == "Rate limited" } else { false } })
        #expect(projection.contextUsage?.size == 400_000)
        #expect(projection.model == "sonnet" && projection.session.level == "auto_edit" && projection.session.effortIsDefault)
        #expect(projection.controls.effortReported && projection.controls.effort == "medium" && projection.controls.currentLevel == .autoEdit)
        #expect(projection.session.mcpServers?.first?.status == .needsAuth && projection.session.cliVersion == "2.1.0")
        // The question (answered later, which doesn't change status) is the last event that sets one.
        #expect(projection.status == .waiting)
    }

    // MARK: Errors the user reads

    /// Every refusal the desktop recorded, for every command, reaches the user as a sentence, never a code.
    @Test func everyRecordedRefusalHasAUserMessage() throws {
        var seen: Set<String> = []
        for file in try ContractFixtures.files() where file.hasPrefix("commands/") && file != "commands/_fields.json" {
            for item in try ContractFixtures.cases(file) {
                guard let body = item["response"]?["body"], body["status"]?.string != "completed", body["status"] != nil else { continue }
                let receipt = try body.decode(AnnexCommandReceipt.self)
                let code = try #require(receipt.error?.code)
                seen.insert(code)
                let error = try #require(CompanionLiveService.receiptError(receipt))
                let text = try #require((error as? LocalizedError)?.errorDescription)
                #expect(!text.isEmpty && !text.contains(code) && text.first?.isUppercase == true, "\(file) \(code): \(text)")
                if receipt.status == .failed { #expect(error is CompanionServiceError, "\(code)") }
            }
        }
        #expect(seen.count >= 45)
    }

    @Test(arguments: [
        ("session_mismatch", "This conversation moved to a new session. Refresh it and try again."),
        ("pending_request_not_found", "This request was already answered or has expired."),
        ("agent_running", "Sleep the agent to change these"),
        ("not_git_repo", "This project isn't a git repository, so the agent can't have its own worktree."),
        ("model_switch_not_supported", "This agent can't change model mid-session."),
        ("level_not_live", "This agent can't switch to that permission level mid-session."),
        ("project_pinned", "Unpin this project before marking it inactive."),
        ("epoch_mismatch", "The desktop restarted. Refresh and try again."),
        ("client_certificate_required", "Pair this desktop again to control it from your phone."),
        ("command_capacity", "The desktop is busy. Try again in a moment."),
    ]) func refusalMessages(_ code: String, _ expected: String) throws {
        var found = false
        for file in try ContractFixtures.files() where file.hasPrefix("commands/") && file != "commands/_fields.json" {
            for item in try ContractFixtures.cases(file) where item["response"]?["body"]?["error"]?["code"]?.string == code {
                let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
                #expect((CompanionLiveService.receiptError(receipt) as? LocalizedError)?.errorDescription?.hasPrefix(expected) == true, "\(file)")
                found = true
            }
        }
        #expect(found, "No fixture refuses with \(code)")
    }

    @Test func imageRefusalsKeepTheirRecovery() throws {
        let cases = try ContractFixtures.cases("commands/chat.send.json")
        func receipt(_ code: String) throws -> AnnexCommandReceipt {
            try #require(cases.first { $0["response"]?["body"]?["error"]?["code"]?.string == code }?["response"]?["body"]).decode(AnnexCommandReceipt.self)
        }
        #expect(CompanionLiveService.receiptError(try receipt("attachment_unavailable")) as? CompanionAttachmentError == .attachmentUnavailable)
        #expect(CompanionLiveService.receiptError(try receipt("images_not_supported")) as? CompanionAttachmentError == .imagesNotSupported)
        #expect((CompanionLiveService.receiptError(try receipt("not_chat"), attachmentCount: 1) as? LocalizedError)?.errorDescription == CompanionLiveService.notChatMessage)
    }

    /// Every upload answer reaches the user as the right recovery or sentence.
    @Test func everyRecordedUploadErrorHasAUserMessage() throws {
        for item in try ContractFixtures.cases("attachments.json") {
            let status = Int(item["response"]?["status"]?.integer ?? 0)
            guard status != 200 else { continue }
            let code = item["response"]?["body"]?["error"]?.string
            // As AnnexTransport reads an HTTP refusal.
            let transport: AnnexTransportError = switch status {
            case 401: .unauthorized
            case 403: .forbidden
            case 429: .rateLimited(code: code, retryAfterSeconds: 30)
            default: .rejected(status: status, code: code)
            }
            let error = CompanionLiveService.uploadError(transport)
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(!text.isEmpty && !(code.map(text.contains) ?? false), "\(item["name"]?.string ?? ""): \(text)")
            switch code {
            case "images_not_supported": #expect(error as? CompanionAttachmentError == .imagesNotSupported)
            case "rate_limited": #expect(error as? CompanionAttachmentError == .rateLimited(retryAfter: 30))
            case "not_chat": #expect(text == CompanionLiveService.notChatMessage)
            case "too_large": #expect(text == "This image is too large for the desktop.")
            case "unsupported_image", "unsupported_media_type": #expect(text == "The desktop can't read this image.")
            case "agent_not_found": #expect(text == "This agent is no longer on your desktop.")
            default: break
            }
        }
    }
}
