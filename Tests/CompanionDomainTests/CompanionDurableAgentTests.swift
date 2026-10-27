import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Durable agents from the phone: create (#131) and settings (#132).

private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }

private let optionsJSON = #"""
{"version":1,"epoch":"e","projectId":"p1",
 "orchestrators":[
  {"id":"claude-code","displayName":"Claude Code","shortName":"CC","available":true,"permissions":true,"chat":true,"models":[{"id":"default","label":"Default"},{"id":"opus","label":"Opus"}]},
  {"id":"codex","displayName":"Codex","shortName":"CX","badge":"Beta","available":false,"unavailableReason":"codex not found on PATH","permissions":false,"chat":false,"models":[]}],
 "personas":[{"id":"qa","name":"QA","source":"builtin"}],
 "colors":[{"id":"indigo","label":"Indigo","hex":"#6366f1"},{"id":"teal","label":"Teal","hex":"#14b8a6"}],
 "mcp":{"catalog":[{"id":"ado","name":"Azure DevOps","description":"Work items"},{"id":"gh","name":"GitHub"}],"defaults":["ado"]},
 "isGitRepo":true,"suggestedName":"brave-otter",
 "defaults":{"orchestrator":"claude-code","color":"indigo","model":"default","useWorktree":true},
 "freeAgentMode":{"allowed":false}}
"""#

private func settingsJSON(sleeping: Bool, state: String? = nil, idle: String = "\"inherit\"", runtimeEditable: String = "sleeping", options: Bool = true) -> String {
    let optionsField = options ? ##","options":{"orchestrators":[{"id":"claude-code","displayName":"Claude Code","shortName":"CC","available":true,"permissions":true,"chat":true,"models":[{"id":"default","label":"Default"},{"id":"opus","label":"Opus"}]}],"personas":[{"id":"qa","name":"QA","source":"builtin"}],"colors":[{"id":"indigo","label":"Indigo","hex":"#6366f1"}],"idleSleep":{"minutes":[15,30,60,240],"appMinutes":30}}"## : ""
    return #"""
    {"agentId":"durable_1","projectId":"p1","state":"\#(state ?? (sleeping ? "sleeping" : "running"))","sleeping":\#(sleeping),
     "settings":{
      "name":{"value":"brave-otter","editable":"sleeping"},
      "color":{"value":"indigo","editable":"sleeping"},
      "emoji":{"value":null,"editable":"sleeping"},
      "hasImageIcon":false,
      "orchestrator":{"value":null,"resolved":"claude-code","editable":"sleeping"},
      "model":{"value":"opus","editable":"sleeping"},
      "runtime":{"value":"default","resolved":"chat","editable":"\#(runtimeEditable)"},
      "persona":{"value":"qa","editable":"sleeping"},
      "clubhouseMode":{"value":null,"projectEnabled":false,"editable":"never"},
      "freeAgentMode":{"value":true,"editable":"never"},
      "idleSleep":{"value":\#(idle),"minutes":30,"source":"app","applies":true,"editable":"always"}}\#(optionsField)}
    """#
}

@Suite struct CompanionDurableAgentDecodingTests {
    @Test func createOptionsDecodeTheNewAgentForm() throws {
        let options = try CompanionCreateOptions(json: json(optionsJSON))
        #expect(options.options.orchestrators.map(\.id) == ["claude-code", "codex"])
        let codex = try #require(options.options.orchestrator("codex"))
        #expect(!codex.available && codex.badge == "Beta" && !codex.chat)
        #expect(codex.warning == "codex not found on PATH")
        #expect(options.options.orchestrator("claude-code")?.warning == nil)
        // A CLI with no model list still offers the provider default.
        #expect(options.options.models(for: "codex").map(\.id) == ["default"])
        #expect(options.options.models(for: "claude-code", keeping: "my-model").map(\.id) == ["default", "opus", "my-model"])
        #expect(options.options.personas == [.init(id: "qa", name: "QA", source: "builtin")])
        #expect(options.options.colors.first?.rgb == CompanionRGB(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xf1 / 255.0))
        #expect(options.mcpCatalog.map(\.id) == ["ado", "gh"] && options.mcpDefaults == ["ado"])
        #expect(options.isGitRepo && options.suggestedName == "brave-otter")
        #expect(options.defaultOrchestrator == "claude-code" && options.defaultColor == "indigo" && options.defaultModel == "default" && options.defaultUseWorktree)
    }

    @Test func createOptionsWithoutAFormAreRefused() throws {
        #expect(throws: AnnexTransportError.malformedResponse) { try CompanionCreateOptions(json: json(#"{"error":"nope"}"#)) }
    }

    @Test func settingsDecodeValuesEditabilityAndOptions() throws {
        let settings = try CompanionAgentSettings(json: json(settingsJSON(sleeping: true)))
        #expect(settings.state == "sleeping" && settings.sleeping)
        #expect(settings.name == .init(value: "brave-otter", editable: .sleeping))
        #expect(settings.emoji.value == nil && settings.orchestrator.value == nil && settings.resolvedOrchestrator == "claude-code")
        #expect(settings.orchestratorName == "Claude Code" && settings.modelLabel == "Opus" && settings.personaName == "QA")
        #expect(settings.runtime.value == "default" && settings.resolvedRuntime == "chat")
        #expect(settings.clubhouseMode == .init(value: nil, editable: .never) && !settings.clubhouseModeProjectEnabled)
        #expect(settings.freeAgentMode == .init(value: true, editable: .never))
        #expect(settings.idleSleep == .init(value: .inherit, editable: .always))
        #expect(settings.idleSleepMinutes == [15, 30, 60, 240] && settings.appIdleMinutes == 30)
        #expect(settings.autoSleepSummary == "Sleeps after 30 min")
    }

    @Test func idleSleepValuesDecodeAsTheDesktopNormalizesThem() throws {
        #expect(try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, idle: "\"never\""))).idleSleep.value == .never)
        #expect(try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, idle: "240"))).idleSleep.value == .minutes(240))
        #expect(try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, idle: "-5"))).idleSleep.value == .inherit)
        #expect(try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, idle: "\"soon\""))).idleSleep.value == .inherit)
    }

    @Test func updateResultKeepsTheOptionsOnScreen() throws {
        let shown = try CompanionAgentSettings(json: json(settingsJSON(sleeping: true)))
        let result = try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, idle: "60", options: false)))
        #expect(result.options.orchestrators.isEmpty)
        let merged = result.keepingOptions(of: shown)
        #expect(merged.options == shown.options && merged.idleSleep.value == .minutes(60))
    }

    @Test func settingsWithoutANameAreRefused() throws {
        #expect(throws: AnnexTransportError.malformedResponse) { try CompanionAgentSettings(json: json(#"{"state":"sleeping","settings":{}}"#)) }
    }

    @Test func missingEditabilityReadsAsNever() throws {
        let settings = try CompanionAgentSettings(json: json(#"{"state":"sleeping","sleeping":true,"settings":{"name":{"value":"n"}}}"#))
        #expect(settings.name.editable == .never && !settings.name.canEdit(sleeping: true))
        #expect(settings.freeAgentMode.editable == .never)
    }
}

@Suite struct CompanionDurableAgentRulesTests {
    @Test func lockedOnlyWhenSleepingOnlyAndAwake() {
        let always = CompanionSetting(value: 1, editable: .always)
        let sleeping = CompanionSetting(value: 1, editable: .sleeping)
        let never = CompanionSetting(value: 1, editable: .never)
        #expect(!always.isLocked(sleeping: false) && always.canEdit(sleeping: false) && always.canEdit(sleeping: true))
        #expect(sleeping.isLocked(sleeping: false) && !sleeping.canEdit(sleeping: false))
        #expect(!sleeping.isLocked(sleeping: true) && sleeping.canEdit(sleeping: true))
        #expect(!never.isLocked(sleeping: false) && !never.canEdit(sleeping: true))
    }

    @Test func awakeAgentShowsTheLockedHintAndKeepsAutoSleepEditable() throws {
        let awake = try CompanionAgentSettings(json: json(settingsJSON(sleeping: false)))
        #expect(awake.hasLockedSettings)
        #expect(awake.model.isLocked(sleeping: awake.sleeping))
        #expect(awake.idleSleep.canEdit(sleeping: awake.sleeping))
        #expect(!awake.freeAgentMode.canEdit(sleeping: awake.sleeping))
        let asleep = try CompanionAgentSettings(json: json(settingsJSON(sleeping: true)))
        #expect(!asleep.hasLockedSettings)
        // A failed agent can change its spawn settings too.
        let failed = try CompanionAgentSettings(json: json(settingsJSON(sleeping: true, state: "failed")))
        #expect(failed.model.canEdit(sleeping: failed.sleeping))
    }

    @Test func autoSleepUsesTheDesktopsWords() {
        #expect(CompanionIdleSleep.format(30) == "30 min" && CompanionIdleSleep.format(240) == "4 h" && CompanionIdleSleep.format(90) == "90 min")
        #expect(CompanionIdleSleep.format(0) == "Never")
        #expect(CompanionIdleSleep.minutes(30).summary(appMinutes: 15) == "Sleeps after 30 min")
        #expect(CompanionIdleSleep.never.summary(appMinutes: 15) == "Never sleeps")
        #expect(CompanionIdleSleep.inherit.summary(appMinutes: 60) == "Sleeps after 1 h")
        #expect(CompanionIdleSleep.inherit.summary(appMinutes: 0) == "Never sleeps")
        #expect(CompanionIdleSleep.inherit.label(appMinutes: 30) == "App default (30 min)")
        #expect(CompanionIdleSleep.minutes(60).label(appMinutes: 30) == "After 1 h idle")
        #expect(CompanionIdleSleep.never.label(appMinutes: 30) == "Never")
        #expect(CompanionIdleSleep.inherit.source(appMinutes: 30) == "App default: 30 min")
        #expect(CompanionIdleSleep.never.source(appMinutes: 30) == "Set for this agent. App default: 30 min")
        #expect(CompanionIdleSleep.choices(minutes: [15, 30, 60, 240], current: .minutes(45))
                == [.inherit, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(240), .never])
    }

    @Test(arguments: [
        ("brave-otter", nil),
        ("agent_2", nil),
        ("", "Enter a name for the agent."),
        ("-otter", "Start the agent name with a letter, digit or _."),
        (".otter", "Start the agent name with a letter, digit or _."),
        ("a..b", "Remove the \"..\" from the agent name."),
        ("brave otter", "Use only letters, digits, - and _ in the agent name."),
        ("brave/otter", "Use only letters, digits, - and _ in the agent name."),
        ("otterß", "Use only letters, digits, - and _ in the agent name."),
        ("CON", "\"CON\" is reserved on Windows, so choose another agent name."),
        ("lpt1", "\"lpt1\" is reserved on Windows, so choose another agent name."),
        (String(repeating: "a", count: 65), "Keep the agent name to 64 characters or fewer."),
    ] as [(String, String?)])
    func namesAreCheckedAsTheDesktopDoes(name: String, problem: String?) {
        #expect(CompanionAgentName.problem(name) == problem)
    }

    @Test func randomNamesAreValid() {
        for _ in 0..<50 {
            let name = CompanionAgentName.random()
            #expect(CompanionAgentName.problem(name) == nil && name.contains("-"))
        }
    }

    @Test func refusalsBranchOnCode() {
        #expect(CompanionAgentCommandError.message(code: "invalid_name", message: "Use only letters, digits, - and _ in the agent name.") == "Use only letters, digits, - and _ in the agent name.")
        #expect(CompanionAgentCommandError.message(code: "create_refused", message: "Branch brave-otter/standby already exists") == "Branch brave-otter/standby already exists")
        #expect(CompanionAgentCommandError.message(code: "agent_running", message: "Sleep the agent to change these") == "Sleep the agent to change these")
        // Without a sentence the message is just the code; never show that.
        #expect(CompanionAgentCommandError.message(code: "invalid_color", message: "invalid_color") == "Choose one of the colours offered.")
        #expect(CompanionAgentCommandError.message(code: "invalid_branch_name", message: "invalid_branch_name") == "The desktop couldn't accept these settings.")
        #expect(CompanionAgentCommandError.message(code: "agent_running", message: "agent_running") == "Sleep the agent to change these")
        #expect(CompanionAgentCommandError.message(code: "free_agent_mode_not_allowed", message: "anything") == "Free Agent Mode can only be changed on the desktop.")
        #expect(CompanionAgentCommandError.message(code: "agent_creating", message: "agent_creating")?.contains("still being set up") == true)
        #expect(CompanionAgentCommandError.message(code: "busy", message: "Try later") == nil)
    }

    @Test func liveRejectionsKeepOtherMessagesAsBefore() {
        #expect(CompanionLiveService.rejectionMessage(.init(code: "busy", message: "Try later")) == "Try later")
        #expect(CompanionLiveService.rejectionMessage(.init(code: "invalid_color", message: "invalid_color")) == "Choose one of the colours offered.")
        #expect(CompanionLiveService.rejectionMessage(nil) == "The desktop rejected this command.")
    }

    @Test func settingsChangeConvertsToAnUpdate() {
        let update = AnnexAgentUpdate(agentID: "a", change: .init(emoji: .clear, model: "default", runtime: "terminal", persona: .set("qa"), idleSleep: .minutes(15)))
        #expect(update == AnnexAgentUpdate(agentID: "a", emoji: .clear, model: "default", runtime: .terminal, persona: .set("qa"), idleSleep: .minutes(15)))
        #expect(CompanionSettingsChange().isEmpty && !CompanionSettingsChange(clubhouseMode: false).isEmpty)
    }
}

// MARK: - Live service

private actor DurableTransport: AnnexTransporting {
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    let commands: [String]
    let durable: Bool
    private(set) var executed: [AnnexCommand] = []
    private(set) var reads: [String] = []
    var receipt: AnnexJSON = .null
    init(durable: Bool) {
        self.durable = durable
        commands = durable ? ["agent.spawn", "agent.start", "agent.create", "agent.update"] : ["agent.spawn", "agent.start"]
    }
    func setReceipt(_ value: AnnexJSON) { receipt = value }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() {}
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        switch route {
        case .capabilities:
            var caps: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true),
                                             "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
                                             "commands": .array(commands.map(AnnexJSON.string))]
            if durable {
                caps["createOptions"] = .object(["version": .integer(1), "path": .string("/api/v1/mobile/projects/{projectId}/create-options")])
                caps["agentSettings"] = .object(["version": .integer(1), "path": .string("/api/v1/mobile/agents/{agentId}/settings")])
            }
            return .object(caps)
        case .projects: return .array([.object(["id": .string("p1"), "name": .string("Project")])])
        case .agents:
            return .array([.object(["id": .string("durable_1"), "name": .string("brave-otter"), "kind": .string("durable"), "status": .string("sleeping")])])
        case .createOptions(let project): reads.append("options:\(project)"); return try json(optionsJSON)
        case .agentSettings(let agent): reads.append("settings:\(agent)"); return try json(settingsJSON(sleeping: true))
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        executed.append(command)
        return try receipt.decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct CompanionDurableAgentLiveTests {
    private let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    private var project: CompanionProjectTarget { .init(hostID: hostID, projectID: "p1") }
    private var agent: CompanionTarget { .init(hostID: hostID, projectID: "p1", agentID: "durable_1") }

    private func setup(_ transport: DurableTransport) async throws -> (CompanionLiveService, CompanionStore) {
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        for _ in 0..<200 where store.hosts.first?.connection != .connected { try await Task.sleep(for: .milliseconds(5)) }
        try #require(store.hosts.first?.connection == .connected)
        return (service, store)
    }

    @Test func olderDesktopsOfferQuickAgentsOnly() async throws {
        let (service, store) = try await setup(DurableTransport(durable: false))
        defer { store.stop() }
        let host = try #require(store.hosts.first)
        #expect(host.canSpawn && !host.canCreateDurable && !host.canEditSettings)
        #expect(!store.canEditSettings(agent))
        await #expect(throws: CompanionServiceError.self) { try await service.createOptions(for: project) }
        let created = await store.create(.init(project: project, name: "brave-otter", color: "indigo", clientCommandID: "c1"))
        #expect(!created)
    }

    @Test func currentDesktopsOfferDurableCreateAndSettings() async throws {
        let transport = DurableTransport(durable: true)
        let (service, store) = try await setup(transport)
        defer { store.stop() }
        let host = try #require(store.hosts.first)
        #expect(host.canCreateDurable && host.canEditSettings)
        #expect(store.agent(for: agent)?.isQuick == false && store.canEditSettings(agent))
        let options = try await service.createOptions(for: project)
        #expect(options.suggestedName == "brave-otter")
        let settings = try await store.settings(for: agent)
        #expect(settings.name.value == "brave-otter")
        #expect(await transport.reads == ["options:p1", "settings:durable_1"])
    }

    @Test func createOpensTheNewAgent() async throws {
        let transport = DurableTransport(durable: true)
        await transport.setReceipt(try json(#"{"version":1,"commandId":"c1","epoch":"epoch","status":"completed","result":{"agentId":"durable_1","projectId":"p1","name":"brave-otter","branch":"brave-otter/standby","worktreePath":"/w","state":"creating"}}"#))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        let created = await store.create(.init(project: project, name: "brave-otter", color: "teal", orchestrator: "claude-code", useWorktree: true, mcpIDs: ["ado"], clientCommandID: "c1"))
        #expect(created)
        #expect(store.selection == agent && store.justCreated == agent)
        let command = try #require(await transport.executed.first)
        #expect(command.type == "agent.create" && command.commandID == "c1")
        guard case .create(let sent) = command.kind else { Issue.record("Expected agent.create"); return }
        #expect(sent == AnnexAgentCreate(projectID: "p1", name: "brave-otter", color: "teal", orchestrator: "claude-code", useWorktree: true, mcpIDs: ["ado"]))
    }

    @Test func createRefusesAnInvalidWorktreeNameWithoutSending() async throws {
        let transport = DurableTransport(durable: true)
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        #expect(!(await store.create(.init(project: project, name: "brave otter", color: "indigo", useWorktree: true, clientCommandID: "c1"))))
        #expect(await transport.executed.isEmpty)
    }

    @Test func refusedCreateShowsTheDesktopsReason() async throws {
        let transport = DurableTransport(durable: true)
        await transport.setReceipt(try json(#"{"version":1,"commandId":"c1","epoch":"epoch","status":"rejected","error":{"code":"create_refused","message":"Branch brave-otter/standby already exists"}}"#))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        #expect(!(await store.create(.init(project: project, name: "brave-otter", color: "indigo", clientCommandID: "c1"))))
        #expect(store.createError == "Branch brave-otter/standby already exists")
        #expect(store.uncertainCreateRequest == nil && store.justCreated == nil)
    }

    @Test func updateSendsOnlyTheChangeAndReturnsSavedSettings() async throws {
        let transport = DurableTransport(durable: true)
        let result = try json(settingsJSON(sleeping: true, idle: "60", options: false))
        await transport.setReceipt(.object(["version": .integer(1), "commandId": .string("x"), "epoch": .string("epoch"), "status": .string("completed"), "result": result]))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        let saved = try await store.updateSettings(.init(idleSleep: .minutes(60)), target: agent)
        #expect(saved.idleSleep.value == .minutes(60))
        let command = try #require(await transport.executed.first)
        guard case .update(let sent) = command.kind else { Issue.record("Expected agent.update"); return }
        #expect(sent == AnnexAgentUpdate(agentID: "durable_1", idleSleep: .minutes(60)))
    }

    @Test func runningAgentRefusalSaysToSleepIt() async throws {
        let transport = DurableTransport(durable: true)
        await transport.setReceipt(try json(#"{"version":1,"epoch":"epoch","status":"rejected","error":{"code":"agent_running","message":"Sleep the agent to change these"}}"#))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        do {
            _ = try await store.updateSettings(.init(model: "opus"), target: agent)
            Issue.record("Expected a refusal")
        } catch {
            guard case CompanionServiceError.rejected(let message) = error else { Issue.record("Expected a rejection, got \(error)"); return }
            #expect(message == "Sleep the agent to change these")
        }
    }
}
