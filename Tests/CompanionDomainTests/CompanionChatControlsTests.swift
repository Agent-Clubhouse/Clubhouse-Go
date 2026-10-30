import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// The composer's model, effort and level controls (#155), and full permission control from a paired phone.

private func json(_ text: String) -> AnnexJSON { try! JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }
private func event(_ type: String, _ seq: Int64, session: String = "s1", _ data: String) -> AnnexJSON {
    json(#"{"sessionId":"\#(session)","seq":\#(seq),"type":"\#(type)","data":\#(data)}"#)
}
private let snapshotControls = #"""
{"model":"opus","modelUnknown":false,"effort":"high","effortIsDefault":false,"effortReported":true,"level":"ask",
 "models":[{"id":"opus","label":"Opus","description":"Most capable","costHint":"1x"},{"id":"sonnet","label":"Sonnet"}],
 "efforts":["low","medium","high","xhigh"],"levelNames":{"ask":"default","plan":"plan","full_access":"bypassPermissions"},
 "liveLevels":["full_access","plan","ask","auto_edit"],"modelSwitch":"per_turn","effortSwitch":"live","effortDefault":true,
 "switchNote":"Model changes apply from the next message; effort changes now."}
"""#

struct CompanionChatControlsDecodingTests {
    @Test func snapshotDecodesEveryField() throws {
        let controls = try #require(CompanionChatControls(snapshot: json(snapshotControls)))
        #expect(controls.model == "opus" && !controls.modelUnknown)
        #expect(controls.effort == "high" && !controls.effortIsDefault && controls.effortReported)
        #expect(controls.level == .ask)
        #expect(controls.models == [.init(id: "opus", label: "Opus", description: "Most capable", costHint: "1x"), .init(id: "sonnet", label: "Sonnet")])
        #expect(controls.efforts == ["low", "medium", "high", "xhigh"])
        #expect(controls.levelNames == [.ask: "default", .plan: "plan", .fullAccess: "bypassPermissions"])
        // Ladder order, whatever order the desktop listed them in.
        #expect(controls.liveLevels == [.plan, .ask, .autoEdit, .fullAccess])
        #expect(controls.modelSwitch == .perTurn && controls.effortSwitch == .live && controls.effortDefault)
        // The phone's note matches the desktop's sentence.
        #expect(controls.switchNote == "Model changes apply from the next message; effort changes now.")
    }

    @Test func nullOrAbsentControlsMeanNoLiveSession() {
        #expect(CompanionChatControls(snapshot: nil) == nil)
        #expect(CompanionChatControls(snapshot: .null) == nil)
    }

    @Test func unknownValuesAreDroppedRatherThanGuessed() throws {
        let controls = try #require(CompanionChatControls(snapshot: json(#"""
            {"level":"bypass","liveLevels":["auto","yolo"],"levelNames":{"yolo":"x","auto":""},"modelSwitch":"teleport",
             "models":[{"id":"a"},{"id":"a","label":"dup"},{"label":"no id"}],"efforts":["low","low",""]}
            """#)))
        #expect(controls.level == nil && controls.currentLevel == .ask)
        #expect(controls.liveLevels == [.auto])
        #expect(controls.levelNames.isEmpty)
        #expect(controls.modelSwitch == .none)
        #expect(controls.models == [.init(id: "a", label: "a")])
        #expect(controls.efforts == ["low"])
    }
}

struct CompanionChatControlsFoldingTests {
    @Test func sessionEventsFoldLikeTheDesktopChatStore() {
        var projector = CompanionChatProjector()
        projector.apply(event("session_started", 1, #"{"model":"opus","level":"plan","capabilities":{"modelSwitch":"live","effortSwitch":"per_turn","effortDefault":true,"liveLevels":["plan","ask"]}}"#))
        #expect(projector.controls.model == "opus" && projector.controls.level == .plan)
        #expect(projector.controls.modelSwitch == .live && projector.controls.effortSwitch == .perTurn && projector.controls.effortDefault)
        #expect(projector.controls.liveLevels == [.plan, .ask])
        #expect(!projector.controls.effortReported)

        projector.apply(event("session_info", 2, #"{"models":[{"id":"opus","label":"Opus"},{"id":"haiku","label":"Haiku"}],"efforts":["low","high"],"levelNames":{"plan":"plan"}}"#))
        #expect(projector.controls.models.map(\.id) == ["opus", "haiku"])
        #expect(projector.controls.efforts == ["low", "high"])
        #expect(projector.controls.levelNames == [.plan: "plan"])
        #expect(projector.effortsSequence == 2)

        // Partial capabilities: only the keys present change.
        projector.apply(event("session_info", 3, #"{"capabilities":{"liveLevels":["plan","ask","full_access"]}}"#))
        #expect(projector.controls.liveLevels == [.plan, .ask, .fullAccess])
        #expect(projector.controls.modelSwitch == .live && projector.controls.effortSwitch == .perTurn)
        #expect(projector.controls.efforts == ["low", "high"], "An absent list is unchanged")

        projector.apply(event("model_changed", 4, #"{"modelId":"haiku","effort":"low","effortIsDefault":true}"#))
        #expect(projector.controls.model == "haiku" && projector.controls.effort == "low")
        #expect(projector.controls.effortIsDefault && projector.controls.effortReported)
        #expect(projector.model == "haiku", "The header model follows too")

        projector.apply(event("mode_changed", 5, #"{"level":"full_access","nativeMode":"bypassPermissions"}"#))
        #expect(projector.controls.level == .fullAccess)

        // An empty list clears it; model null is the provider's default, not yet named.
        projector.apply(event("session_info", 6, #"{"efforts":[],"model":null}"#))
        #expect(projector.controls.efforts.isEmpty)
        #expect(projector.controls.model == nil && projector.controls.modelUnknown)
        #expect(projector.controls.modelLabel == "Default model")
    }

    @Test func sessionStartedResetsTheListsAndANewSessionStartsClean() {
        var projector = CompanionChatProjector()
        projector.apply(event("session_info", 1, #"{"models":[{"id":"opus","label":"Opus"}],"efforts":["low"],"levelNames":{"ask":"default"}}"#))
        projector.apply(event("mode_changed", 2, #"{"level":"auto_edit"}"#))
        projector.apply(event("session_started", 3, #"{"model":"sonnet","capabilities":{}}"#))
        #expect(projector.controls.models.isEmpty && projector.controls.efforts.isEmpty && projector.controls.levelNames.isEmpty)
        #expect(projector.controls.level == .autoEdit, "A start without a level keeps the last one")
        #expect(projector.controls.model == "sonnet")

        projector.apply(event("mode_changed", 1, session: "s2", #"{"level":"plan"}"#))
        #expect(projector.controls.model == nil && projector.controls.level == .plan)
        #expect(projector.effortsSequence == 0)
    }

    @Test func snapshotCapabilitiesFeedTheControls() {
        var projector = CompanionChatProjector()
        projector.updateCapabilities(json(#"{"steer":true,"modelSwitch":"restart","effortSwitch":"none","liveLevels":["ask","auto"]}"#))
        #expect(projector.controls.modelSwitch == .restart && projector.controls.effortSwitch == .none)
        #expect(projector.controls.liveLevels == [.ask, .auto])
    }

    @Test func aNewModelsEffortsArriveWithItsSessionInfo() {
        var controls = CompanionChatControls(model: "opus", effort: "high", effortReported: true, models: [.init(id: "opus", label: "Opus")],
                                             efforts: ["low", "high"], modelSwitch: .live, effortSwitch: .live)
        controls.awaitingEfforts = true
        #expect(controls.offeredEfforts.isEmpty && !controls.showsEffortMenu && !controls.showsEffortChip)
        controls.apply(type: "model_changed", data: json(#"{"modelId":"sonnet"}"#))
        #expect(controls.awaitingEfforts, "The model alone doesn't say which efforts it takes")
        controls.apply(type: "session_info", data: json(#"{"efforts":["medium"]}"#))
        #expect(!controls.awaitingEfforts && controls.offeredEfforts == ["medium"] && controls.showsEffortMenu)
    }
}

struct CompanionChatControlsPresentationTests {
    @Test func levelsAreTheCurrentOnePlusLiveOnesInLadderOrder() {
        var controls = CompanionChatControls(level: .autoEdit, liveLevels: [.fullAccess, .plan])
        #expect(controls.levels == [.plan, .autoEdit, .fullAccess], "The current level stays listed even if it can't be re-entered")
        #expect(controls.canChangeLevel)
        controls.liveLevels = []
        #expect(controls.levels == [.autoEdit] && !controls.canChangeLevel)
        // A null level reads as Ask first.
        let unknown = CompanionChatControls(level: nil, liveLevels: [.ask, .auto])
        #expect(unknown.currentLevel == .ask && unknown.levels == [.ask, .auto])
    }

    @Test func raisingToAutoOrFullAccessIsConfirmed() {
        #expect(CompanionPermissionLevel.auto.needsConfirmation(from: .ask))
        #expect(CompanionPermissionLevel.fullAccess.needsConfirmation(from: .auto))
        #expect(CompanionPermissionLevel.fullAccess.needsConfirmation(from: .plan))
        #expect(!CompanionPermissionLevel.autoEdit.needsConfirmation(from: .ask))
        #expect(!CompanionPermissionLevel.auto.needsConfirmation(from: .fullAccess), "Lowering is never confirmed")
        #expect(!CompanionPermissionLevel.plan.needsConfirmation(from: .fullAccess))
        #expect(!CompanionPermissionLevel.auto.needsConfirmation(from: .auto))
    }

    @Test func levelLabelsMatchTheDesktop() {
        #expect(CompanionPermissionLevel.allCases.map(\.label) == ["Plan", "Ask first", "Auto-accept edits", "Auto", "Full access"])
        #expect(CompanionPermissionLevel.allCases.map(\.rawValue) == AnnexCommand.permissionLevels)
        #expect(CompanionPermissionLevel.allCases == CompanionPermissionLevel.allCases.sorted())
    }

    @Test func effortLabelsAreSentenceCase() {
        #expect(CompanionChatControls.effortWord("xhigh") == "Extra high")
        #expect(CompanionChatControls.effortWord("medium") == "Medium")
        #expect(CompanionChatControls(effort: "high", effortIsDefault: true).effortLabel == "High effort (default)")
        #expect(CompanionChatControls(effort: "xhigh").effortLabel == "Extra high effort")
        #expect(CompanionChatControls().effortLabel == "Default effort")
    }

    @Test func menusShowOnlyWhenTheSessionCanSwitch() {
        let models: [CompanionChatModel] = [.init(id: "opus", label: "Opus")]
        #expect(CompanionChatControls(model: "opus", models: models, modelSwitch: .live).showsModelMenu)
        #expect(!CompanionChatControls(model: "opus", models: models, modelSwitch: .none).showsModelMenu)
        #expect(!CompanionChatControls(model: "opus", models: [], modelSwitch: .live).showsModelMenu)
        #expect(CompanionChatControls(model: "opus", efforts: ["low"], effortSwitch: .perTurn).showsEffortMenu)
        #expect(!CompanionChatControls(model: "opus", efforts: ["low"], effortSwitch: .none).showsEffortMenu)
        #expect(!CompanionChatControls(model: "opus", efforts: [], effortSwitch: .live).showsEffortMenu)
    }

    @Test func effortChipWaitsForTheReportedEffort() {
        #expect(!CompanionChatControls(model: "opus", effortReported: false, efforts: ["low"]).showsEffortChip)
        #expect(CompanionChatControls(model: "opus", effortReported: true, efforts: ["low"]).showsEffortChip)
        #expect(!CompanionChatControls(model: "opus", effortReported: true, efforts: []).showsEffortChip, "A model without efforts has no chip")
    }

    @Test func modelLabelUsesTheListedNameThenTheID() {
        let models: [CompanionChatModel] = [.init(id: "opus", label: "Opus")]
        #expect(CompanionChatControls(model: "opus", models: models).modelLabel == "Opus")
        #expect(CompanionChatControls(model: "custom-1", models: models).modelLabel == "custom-1")
        #expect(CompanionChatControls(model: nil, modelUnknown: true).modelLabel == "Default model")
        #expect(CompanionChatControls(model: nil).modelLabel == nil)
    }

    @Test func defaultEffortRowAndKeptEffortFollowTheDesktopMenu() {
        // On the default with a Default row: Default is checked, no level is.
        let onDefault = CompanionChatControls(effort: "high", effortIsDefault: true, efforts: ["low", "high"], effortDefault: true)
        #expect(onDefault.isOnDefaultEffort && onDefault.chosenEffort == nil)
        // Without a Default row, the level the default resolved to is checked.
        let noDefaultRow = CompanionChatControls(effort: "high", effortIsDefault: true, efforts: ["low", "high"], effortDefault: false)
        #expect(noDefaultRow.chosenEffort == "high")
        // A model switch keeps a chosen effort the list offers; a default one follows the new model.
        #expect(CompanionChatControls(effort: "high", efforts: ["low", "high"]).keptEffort == .set("high"))
        #expect(onDefault.keptEffort == nil)
        #expect(CompanionChatControls(effort: "xhigh", efforts: ["low"]).keptEffort == nil)
    }

    @Test func switchNoteMatchesTheDesktopSentences() {
        typealias C = CompanionChatControls
        #expect(C.switchNote(model: .perTurn, effort: .perTurn) == "Applies from the next message.")
        #expect(C.switchNote(model: .restart, effort: .none) == "Applies the next time the agent starts.")
        #expect(C.switchNote(model: .none, effort: .perTurn) == "Effort applies from the next message.")
        #expect(C.switchNote(model: .live, effort: .restart) == "Model changes apply now; effort changes the next time the agent starts.")
        #expect(C.switchNote(model: .live, effort: .live) == nil)
        #expect(C.switchNote(model: .none, effort: .none) == nil)
    }

    @Test func refusalsBecomeSentences() {
        for code in ["model_switch_not_supported", "unknown_model", "effort_switch_not_supported", "effort_default_not_supported",
                     "unknown_effort", "level_not_live", "level_switch_not_supported", "persistent_approval_not_supported"] {
            let message = CompanionChatControlError.message(code: code)
            #expect(message != nil && message != code, "\(code)")
            // The receipt mapping finds them too.
            #expect(CompanionLiveService.rejectionMessage(.init(code: code, message: code)) == message)
        }
        #expect(CompanionChatControlError.message(code: "busy") == nil)
        #expect(CompanionAgentCommandError.message(code: "free_agent_mode_unavailable", message: nil) == CompanionFreeAgentMode.unsupported)
        #expect(CompanionLiveService.rejectionMessage(.init(code: "busy", message: "Try later")) == "Try later")
    }
}

struct CompanionChatControlsGatingTests {
    private func caps(_ commands: [String], _ extra: String) throws -> AnnexCapabilities {
        let list = commands.map { "\"\($0)\"" }.joined(separator: ",")
        return try json(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(list)],"idempotency":{"scope":"peer-and-epoch","maxEntries":1,"ttlMs":1}\#(extra)}"#)
            .decode(AnnexCapabilities.self)
    }
    private let controls = CompanionChatControls(model: "opus", level: .ask, models: [.init(id: "opus", label: "Opus")], efforts: ["low"],
                                                 liveLevels: [.plan, .ask, .fullAccess], modelSwitch: .live, effortSwitch: .live)

    @Test func olderDesktopsGetNoControls() throws {
        let older = try caps(["chat.send", "chat.permission"], "")
        #expect(CompanionLiveService.chatControls(controls, live: true, capabilities: older) == nil)
        #expect(CompanionLiveService.chatControls(controls, live: true, capabilities: nil) == nil)
    }

    @Test func currentDesktopsGetThemWhileTheSessionIsLive() throws {
        let current = try caps(["chat.send", "chat.setModel", "chat.setLevel"], #","chatControls":{"version":1}"#)
        #expect(CompanionLiveService.chatControls(controls, live: true, capabilities: current) == controls)
        #expect(CompanionLiveService.chatControls(controls, live: false, capabilities: current) == nil, "A sleeping agent has none")
    }

    @Test func eachMenuNeedsItsOwnCommand() throws {
        let levelOnly = try #require(CompanionLiveService.chatControls(controls, live: true,
                                     capabilities: try caps(["chat.setLevel"], #","chatControls":{"version":1}"#)))
        #expect(!levelOnly.showsModelMenu && !levelOnly.showsEffortMenu && levelOnly.canChangeLevel)
        let modelOnly = try #require(CompanionLiveService.chatControls(controls, live: true,
                                     capabilities: try caps(["chat.setModel"], #","chatControls":{"version":1}"#)))
        #expect(modelOnly.showsModelMenu && !modelOnly.canChangeLevel)
        #expect(modelOnly.levels == [.ask], "The current level still shows")
    }
}

struct CompanionFreeAgentModeTests {
    @Test func settingsReadTheEditableValueAndCreateOptionsTheAllowance() throws {
        let settings = try CompanionAgentSettings(json: json(#"{"state":"sleeping","sleeping":true,"settings":{"name":{"value":"a","editable":"sleeping"},"freeAgentMode":{"value":false,"editable":"sleeping"}}}"#))
        #expect(settings.freeAgentMode == .init(value: false, editable: .sleeping))
        #expect(settings.freeAgentMode.canEdit(sleeping: true))
        let awake = try CompanionAgentSettings(json: json(#"{"state":"running","sleeping":false,"settings":{"name":{"value":"a","editable":"sleeping"},"freeAgentMode":{"value":true,"editable":"sleeping"}}}"#))
        #expect(awake.freeAgentMode.isLocked(sleeping: false) && awake.hasLockedSettings)
        let unsupported = try CompanionAgentSettings(json: json(#"{"state":"sleeping","sleeping":true,"settings":{"name":{"value":"a","editable":"sleeping"},"freeAgentMode":{"value":false,"editable":"never"}}}"#))
        #expect(!unsupported.freeAgentMode.canEdit(sleeping: true))

        let allowed = try CompanionCreateOptions(json: json(#"{"orchestrators":[{"id":"cc","permissions":true}],"freeAgentMode":{"allowed":true}}"#))
        #expect(allowed.freeAgentModeAllowed)
        let older = try CompanionCreateOptions(json: json(#"{"orchestrators":[{"id":"cc"}],"freeAgentMode":{"allowed":false}}"#))
        #expect(!older.freeAgentModeAllowed)
    }

    @Test func settingsChangeCarriesFreeAgentMode() throws {
        let update = AnnexAgentUpdate(agentID: "a", change: .init(freeAgentMode: true))
        #expect(update.freeAgentMode == true && !update.isEmpty)
        #expect(!CompanionSettingsChange(freeAgentMode: false).isEmpty)
        let value = try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(epoch: "e", kind: .update(update)).encoded())
        #expect(value["freeAgentMode"] == .bool(true))
    }
}

/// The store's side: what it sends, and what it refuses before sending.
@MainActor private final class ControlsService: CompanionService {
    var models: [(String, CompanionEffortChoice?)] = []
    var levels: [CompanionPermissionLevel] = []
    var responses: [String] = []
    var historyLoads = 0
    var failure: CompanionServiceError?
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { historyLoads += 1; return .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { responses.append(optionID) }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws {
        if let failure { throw failure }
        models.append((model, effort))
    }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws {
        if let failure { throw failure }
        levels.append(level)
    }
}

@Suite @MainActor struct CompanionChatControlsStoreTests {
    private let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "a")
    private let controls = CompanionChatControls(model: "opus", effort: "high", effortReported: true, level: .ask,
                                                 models: [.init(id: "opus", label: "Opus"), .init(id: "sonnet", label: "Sonnet")],
                                                 efforts: ["low", "high"], liveLevels: [.plan, .ask, .fullAccess],
                                                 modelSwitch: .live, effortSwitch: .live, effortDefault: false)
    private func makeStore(_ service: ControlsService, controls: CompanionChatControls?, persistent: Bool = false) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts([.init(id: "h", name: "Desk", endpoint: "d", connection: .connected, projects: [
            .init(id: "p", name: "P", agents: [.init(id: target, name: "A", subtitle: "", status: .idle, capabilities: [.chat, .approve], chatControls: controls)])
        ], canAnswerPersistentApprovals: persistent)]))
        return store
    }

    @Test func levelAndModelChangesAreSent() async {
        let service = ControlsService()
        let store = makeStore(service, controls: controls)
        #expect(store.canChangeChatControls(target))
        await store.setLevel(.fullAccess, target: target)
        await store.setModel("sonnet", effort: controls.keptEffort, target: target)
        await store.setModel("opus", effort: .set("low"), target: target)
        #expect(service.levels == [.fullAccess])
        #expect(service.models.map(\.0) == ["sonnet", "opus"])
        #expect(service.models.map(\.1) == [.set("high"), .set("low")])
    }

    @Test func choicesTheSessionDoesNotOfferAreNotSent() async {
        let service = ControlsService()
        let store = makeStore(service, controls: controls)
        await store.setLevel(.ask, target: target)           // already current
        await store.setLevel(.auto, target: target)          // not live
        await store.setModel("gpt", effort: nil, target: target)                   // not listed
        await store.setModel("opus", effort: nil, target: target)                  // nothing changes
        await store.setModel("opus", effort: .providerDefault, target: target)     // no effortDefault
        #expect(service.levels.isEmpty && service.models.isEmpty)

        let none = makeStore(ControlsService(), controls: nil)
        #expect(!none.canChangeChatControls(target), "Older desktops and sleeping agents have no controls")
    }

    @Test func aRefusalSaysWhyAndRereadsTheConversation() async {
        let service = ControlsService()
        service.failure = .rejected(CompanionChatControlError.message(code: "level_not_live")!)
        let store = makeStore(service, controls: controls)
        await store.setLevel(.plan, target: target)
        #expect(store.operationErrors[target] == CompanionChatControlError.message(code: "level_not_live"))
        #expect(service.historyLoads == 1)
        #expect(!store.pendingCommands.contains(target))
    }

    @Test func persistentApprovalsAreSentOnlyToDesktopsThatTakeThem() async {
        let approval = CompanionApproval(id: "r1", toolName: "Bash", summary: "s", options: [
            .init(id: "once", label: "Allow once", kind: .allowOnce),
            .init(id: "always", label: "Always allow", kind: .allowAlways, scope: "npm test:*")
        ])
        let always = approval.options[1]

        let olderService = ControlsService()
        let older = makeStore(olderService, controls: nil, persistent: false)
        older.apply(.timeline(target, items: [.approval(approval)], sequence: 1, reset: true))
        await older.respond(approval, option: always, target: target)
        #expect(olderService.responses.isEmpty, "Older desktops refuse lasting options from a phone")

        let currentService = ControlsService()
        let current = makeStore(currentService, controls: nil, persistent: true)
        current.apply(.timeline(target, items: [.approval(approval)], sequence: 1, reset: true))
        await current.respond(approval, option: always, target: target)
        #expect(currentService.responses == ["always"])
        guard case .approval(let resolved)? = current.conversation(for: target).items.first else { Issue.record("expected approval"); return }
        #expect(resolved.resolution == .allowed)
        #expect(always.needsConfirmation && !approval.options[0].needsConfirmation)
    }
}

/// A desktop with or without chat controls, for the live service end to end.
private actor ControlsTransport: AnnexTransporting {
    let modern: Bool
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private(set) var commands: [AnnexJSON] = []
    var receiptResult = #"{"model":"sonnet","effort":null,"changed":true}"#
    init(modern: Bool) { self.modern = modern }
    func setReceiptResult(_ value: String) { receiptResult = value }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() {}
    func emit(_ event: AnnexJSON) {
        continuation?.yield(.message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]))))
    }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities:
            let commands = modern ? #"["chat.send","chat.permission","chat.setModel","chat.setLevel"]"# : #"["chat.send","chat.permission"]"#
            let extra = modern ? #","chatControls":{"version":1},"permissions":{"version":1,"persistentApprovals":true,"freeAgentMode":true}"# : ""
            return json(#"{"version":1,"epoch":"epoch","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":\#(commands),"idempotency":{"scope":"peer-and-epoch","maxEntries":64,"ttlMs":60000}\#(extra)}"#)
        case .projects: return json(#"[{"id":"project","name":"Project"}]"#)
        case .agents: return json(#"[{"id":"agent","name":"Agent","status":"running","executionMode":"chat"}]"#)
        case .chat:
            return json(#"""
                {"sessionId":"s1","state":"idle","capabilities":{"modelSwitch":"live","effortSwitch":"live","liveLevels":["plan","ask"]},
                 "events":[{"sessionId":"s1","seq":1,"type":"session_started","data":{"model":"opus","capabilities":{}}}],
                 "chatControls":\#(modern ? snapshotControls : "null")}
                """#)
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        commands.append(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()))
        return try json(#"{"version":1,"epoch":"epoch","commandId":"\#(command.commandID)","status":"completed","result":\#(receiptResult)}"#)
            .decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct CompanionChatControlsLiveTests {
    private let target = CompanionTarget(hostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef", projectID: "project", agentID: "agent")
    private func setup(_ transport: ControlsTransport) async throws -> (CompanionLiveService, CompanionStore) {
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: target.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Desk", transport: transport))
        try await waitUntil { store.hosts.first?.connection == .connected }
        await store.load(target)
        return (service, store)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for fixture condition")
        throw AnnexTransportError.disconnected
    }

    @Test func olderDesktopKeepsTheReadOnlyBehaviour() async throws {
        let transport = ControlsTransport(modern: false)
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.agent(for: target)?.capabilities.contains(.chat) == true }
        #expect(store.agent(for: target)?.chatControls == nil)
        #expect(!store.canAnswerPersistentApprovals(target))
        #expect(store.host(for: target)?.canSetFreeAgentMode == false)
    }

    @Test func snapshotEventsAndCommandsWorkEndToEnd() async throws {
        let transport = ControlsTransport(modern: true)
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.agent(for: target)?.chatControls != nil }
        #expect(store.canAnswerPersistentApprovals(target) && store.host(for: target)?.canSetFreeAgentMode == true)
        var controls = try #require(store.agent(for: target)?.chatControls)
        #expect(controls.model == "opus" && controls.currentLevel == .ask && controls.liveLevels == [.plan, .ask, .autoEdit, .fullAccess])

        // A change made on the desktop arrives as the session's own event.
        await transport.emit(event("mode_changed", 2, #"{"level":"plan"}"#))
        try await waitUntil { store.agent(for: target)?.chatControls?.level == .plan }

        await store.setLevel(.fullAccess, target: target)
        // Switching model: the efforts wait for the new model's list.
        await store.setModel("sonnet", effort: nil, target: target)
        let sent = await transport.commands
        #expect(sent.map { $0["type"]?.string } == ["chat.setLevel", "chat.setModel"])
        #expect(sent[0]["level"]?.string == "full_access" && sent[0]["sessionId"]?.string == "s1")
        #expect(sent[1]["model"]?.string == "sonnet" && sent[1]["effort"] == nil)
        // The service's hosts reach the store through its event stream, so they may land after setModel returns.
        try await waitUntil { store.agent(for: target)?.chatControls?.awaitingEfforts == true }
        controls = try #require(store.agent(for: target)?.chatControls)
        #expect(controls.awaitingEfforts && !controls.showsEffortMenu && controls.model == "opus")

        await transport.emit(event("model_changed", 3, #"{"modelId":"sonnet","effort":"medium","effortIsDefault":true}"#))
        await transport.emit(event("session_info", 4, #"{"efforts":["low","medium"]}"#))
        try await waitUntil { store.agent(for: target)?.chatControls?.awaitingEfforts == false }
        controls = try #require(store.agent(for: target)?.chatControls)
        #expect(controls.model == "sonnet" && controls.offeredEfforts == ["low", "medium"] && controls.effortLabel == "Medium effort (default)")

        // The session ending takes the controls away.
        await transport.emit(event("session_ended", 5, #"{"reason":"idle_timeout"}"#))
        try await waitUntil { store.agent(for: target)?.chatControls == nil }
    }

    @Test func anEffortOnlyChangeDoesNotWaitForAList() async throws {
        let transport = ControlsTransport(modern: true)
        await transport.setReceiptResult(#"{"model":"opus","effort":"low","changed":true}"#)
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.agent(for: target)?.chatControls != nil }
        await store.setModel("opus", effort: .providerDefault, target: target)
        let sent = await transport.commands
        #expect(sent.last?["effort"] == .null, "The provider's default is sent as null")
        #expect(store.agent(for: target)?.chatControls?.awaitingEfforts == false)
    }
}
