import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Real Store + LiveService admission, with capable scripted desktop replies. Every
/// denied path is paired with an unlocked dispatch control below, not an unsupported fixture.
@MainActor @Suite struct CompanionCrossEntryMutationTests {
    enum Provider: String, CaseIterable { case v1, v2 }
    enum Recovery: String, CaseIterable { case preparing, claimed, inFlight, unknown }
    private let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_term")

    private func replacing(_ value: AnnexJSON, _ key: String, _ replacement: AnnexJSON) throws -> AnnexJSON {
        guard case .object(var fields) = value else { throw AnnexTransportError.malformedResponse }
        fields[key] = replacement
        return .object(fields)
    }
    private func fixture(_ name: String) throws -> AnnexJSON {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ClubhouseTransportTests/Fixtures/ProviderControlV2")
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    private var agentSettings: AnnexJSON {
        .object(["state": .string("sleeping"), "sleeping": .bool(true), "settings": .object([
            "name": .object(["value": .string("Navi"), "editable": .string("sleeping")]),
            "model": .object(["value": .string("fixture-before"), "editable": .string("sleeping")]),
            "orchestrator": .object(["value": .string("claude-code"), "resolved": .string("claude-code"), "editable": .string("sleeping")])])])
    }
    private func dispatcherSettings() throws -> AnnexJSON {
        let original = try replacing(ContractFixtures.body("dispatcher-settings.json", "on"), "agentId", .string(target.agentID))
        // This capable synthetic desktop honors the generic model field under test.
        return try replacing(original, "notHonored", .array(original["notHonored"].arrayValue.filter { $0["setting"] != .string("model") }))
    }
    private func result(_ provider: Provider, _ key: String = "preview") throws -> AnnexJSON {
        if provider == .v2 { return try #require(fixture("provider-control-v2.json")[key]?["body"]?["result"]) }
        return try replacing(CompanionProviderFlowTests.result(), "agentId", .string(target.agentID))
    }
    private func start(_ provider: Provider) async throws -> LiveServiceHarness {
        guard case .object(var dispatcher)? = try ContractFixtures.body("capabilities.json")["dispatcher"] else { throw CancellationError() }
        dispatcher["enabled"] = .bool(true); dispatcher["flagOn"] = .bool(true)
        let dispatcherFeature = dispatcher, settings = try dispatcherSettings()
        let v2 = try #require(fixture("capabilities.json")["response"]?["body"])
        let apply = try #require(v2["providerControlV2"]), start = try #require(v2["providerStartV2"])
        let h = try await LiveServiceHarness.start { transport in
            await transport.setFeature("dispatcher", .object(dispatcherFeature))
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            await transport.setFeature("providerControl", CompanionProviderFlowTests.capability)
            if provider == .v2 {
                await transport.setFeature("providerControlV2", apply)
                await transport.setFeature("providerStartV2", start)
            }
            await transport.addCommands(["agent.update", "agent.stop", "agent.providerPreview", "agent.providerChange",
                                         "dispatcher.update", "dispatcher.setModels", "dispatcher.clearChat", "dispatcher.forgetEverything"])
            await transport.setRead("agentSettings", agentSettings)
            await transport.setRead("dispatcherSettings", settings)
            await transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["state": .string("sleeping")]))
        }
        await dispatcherSnapshot(h, enabled: true)
        try await h.waitUntil { h.store.agent(for: target)?.isSleepingOnDesktop == true }
        await h.store.load(target)
        #expect(h.store.canEditSettings(target) && h.store.canEditDispatcherSettings(hostID: target.hostID))
        let offered = try await h.store.settings(for: target)
        #expect(offered.model.canEdit(sleeping: true))
        #expect(try await !h.store.loadDispatcherSettings(hostID: target.hostID).notHonored.contains("model"))
        return h
    }
    private func dispatcherSnapshot(_ h: LiveServiceHarness, enabled: Bool) async {
        await h.transport.emit(h.snapshotEvent(["dispatcher": .object([
            "enabled": .bool(enabled), "flagOn": .bool(true), "projectId": .string(target.projectID),
            "agent": enabled ? .object(["id": .string(target.agentID), "name": .string("Navi"), "kind": .string("durable"),
                              "status": .string("sleeping"), "orchestrator": .string("claude-code"),
                              "projectId": .string(target.projectID), "isDispatcher": .bool(true)]) : .null])]))
    }
    private func select(_ provider: Provider, _ h: LiveServiceHarness) async throws {
        await h.transport.enqueue(.completed(try result(provider)))
        if provider == .v1 {
            let flow = h.store.providerFlow(for: target)
            await flow.select("codex-cli")
            #expect(flow.canSave)
        } else {
            let flow = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
            await flow.select("codex-cli")
            #expect(flow.canApply)
        }
    }
    private func retain(_ stage: String, _ h: LiveServiceHarness) async throws {
        let commands = try await h.transport.executed.map { try JSONDecoder().decode(AnnexJSON.self, from: $0.encoded()) }
        let data = try JSONEncoder().encode(AnnexJSON.object(["stage": .string(stage), "commands": .array(commands)]))
        print("CROSS_ENTRY_BOUNDARY " + String(decoding: data, as: UTF8.self))
    }
    private func save(_ provider: Provider, _ h: LiveServiceHarness) async {
        if provider == .v1 { await h.store.providerFlow(for: target).save() }
        else { await h.store.providerV2Flow(for: target, requestedRuntime: "terminal").apply() }
    }

    @Test(arguments: Provider.allCases, Recovery.allCases)
    func recoveryBlocksGenericAndProviderWritesButKeepsReadsAndOtherTargets(provider: Provider, recovery: Recovery) async throws {
        let h = try await start(provider); defer { h.stop() }
        try await select(provider, h) // A real, applicable proposal exists BEFORE recovery takes ownership.
        var task: Task<Void, Never>?
        if recovery == .preparing {
            await h.transport.pauseNextRead("dispatcherSettings")
            task = Task { await h.store.askDispatcherRecoveryNewChat(target) }
            try await h.waitUntil { await h.transport.isReadPaused("dispatcherSettings") }
        } else {
            await h.store.askDispatcherRecoveryNewChat(target)
            let prompt = try #require(h.store.dispatcherResetPrompt)
            let claim = try #require(h.store.claimDispatcherRecoveryNewChat(prompt, target: target))
            if recovery == .inFlight {
                await h.transport.enqueue(.heldCompleted(.object(["cleared": .string("now")])))
                let count = await h.transport.executed.count
                task = Task { await h.store.confirmDispatcherRecoveryNewChat(claim) }
                try await h.waitUntil { await h.transport.executed.count == count + 1 }
            } else if recovery == .unknown {
                await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost-reset")))
                await h.store.confirmDispatcherRecoveryNewChat(claim)
                #expect(h.store.dispatcherRecoveryUnknown.contains(target))
            }
        }
        let before = await h.transport.executed.map(\.commandID)
        try await retain("recovery/\(provider)/\(recovery)/before", h)
        let notice = h.store.dispatcherResetNotices[target.hostID]
        let held = h.store.dispatcherResetPrompt
        let error = await serviceErrorKind { _ = try await h.store.updateSettings(.init(model: "default"), target: target) }
        #expect(error != .none)
        await save(provider, h)
        try await retain("recovery/\(provider)/\(recovery)/after", h)
        if provider == .v1 { #expect(!h.store.providerFlow(for: target).canChoose) }
        else { #expect(!h.store.providerV2Flow(for: target, requestedRuntime: "terminal").canChoose) }
        #expect(await h.transport.executed.map(\.commandID) == before, "Blocked paths create no additional command IDs")
        _ = try await h.store.settings(for: target)
        #expect(await serviceErrorKind { _ = try await h.store.loadDispatcherSettings(hostID: target.hostID) } == .none)
        #expect(h.store.dispatcherResetNotices[target.hostID] == notice && h.store.dispatcherResetPrompt == held)
        // The same host's unrelated agent is not locked by this Dispatcher's action.
        _ = try await h.store.updateSettings(.init(model: "default"), target: h.target)
        #expect(await h.transport.executed.last?.type == "agent.update")
        #expect(await h.transport.executed.count == before.count + 1)
        try await retain("recovery/\(provider)/\(recovery)/other-target-control", h)
        if recovery == .preparing { await h.transport.resumeRead("dispatcherSettings") }
        if recovery == .inFlight { await h.transport.releaseCommand() }
        await task?.value
    }

    @Test(arguments: ["v1-save", "v2-apply", "v2-start", "v2-in-flight"])
    func providerOwnershipBlocksBothLegacyResetsAndSettingsWithoutDiscardingEvidence(scenario: String) async throws {
        let provider: Provider = scenario == "v1-save" ? .v1 : .v2
        let h = try await start(provider); defer { h.stop() }
        // Both prompts were genuinely read/asked while unlocked; test confirm's own guard too.
        await h.store.askDispatcherReset(.clearChat, hostID: target.hostID)
        let clear = try #require(h.store.dispatcherResetPrompt)
        await h.store.askDispatcherReset(.forgetEverything, hostID: target.hostID)
        let forget = try #require(h.store.dispatcherResetPrompt)
        h.store.cancelDispatcherReset()
        try await select(provider, h)
        var task: Task<Void, Never>?
        if scenario == "v2-start" {
            await h.transport.enqueue(.completed(try result(.v2, "applied")))
            await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
            await save(.v2, h)
            let flow = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
            #expect(flow.canStart && flow.lastApply != nil)
            await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
            await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost-start")))
            await flow.startNew()
        } else if scenario == "v2-in-flight" {
            await h.transport.enqueue(.heldCompleted(try result(.v2, "applied")))
            let count = await h.transport.executed.count
            task = Task { await save(provider, h) }
            try await h.waitUntil { await h.transport.executed.count == count + 1 }
        } else {
            await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost-provider")))
            await save(provider, h)
        }
        #expect(h.store.hasPendingProviderAction(target))
        let flow = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
        let heldApply = flow.lastApply, heldStart = flow.lastStart, heldConflict = flow.conflict
        let before = await h.transport.executed.map(\.commandID)
        let beforeMutations = await h.transport.executed.filter { $0.type != "agent.providerPreview" }.map(\.commandID)
        try await retain("provider/\(scenario)/before", h)
        await h.store.confirmDispatcherReset(clear)
        await h.store.confirmDispatcherReset(forget)
        await h.store.askDispatcherReset(.clearChat, hostID: target.hostID)
        await h.store.askDispatcherReset(.forgetEverything, hostID: target.hostID)
        #expect(h.store.dispatcherResetPrompt == nil)
        #expect(await serviceErrorKind { _ = try await h.store.updateSettings(.init(model: "default"), target: target) } != .none)
        #expect(await serviceErrorKind { _ = try await h.store.updateDispatcher(.init(behavior: "light"), hostID: target.hostID) } != .none)
        #expect(await serviceErrorKind { _ = try await h.store.setDispatcherModels(.byHand(true), hostID: target.hostID) } != .none)
        try await retain("provider/\(scenario)/after", h)
        #expect(await h.transport.executed.map(\.commandID) == before)
        _ = try await h.store.settings(for: target)
        #expect(await serviceErrorKind { _ = try await h.store.loadDispatcherSettings(hostID: target.hostID) } == .none)
        #expect(flow.lastApply == heldApply && flow.lastStart == heldStart && flow.conflict == heldConflict)
        #expect(h.store.hasPendingProviderAction(target))
        if provider == .v2 && task == nil {
            await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
            await flow.refresh() // Its OWN read-only continuation must not self-lock.
            #expect(flow.reportedSaved?.provider == "codex-cli" && flow.blocksMutations)
            #expect(flow.lastApply == heldApply && flow.lastStart == heldStart && flow.conflict == heldConflict)
            #expect(await h.transport.executed.filter { $0.type != "agent.providerPreview" }.map(\.commandID)
                    == beforeMutations)
        }
        if task != nil {
            await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
            await h.transport.releaseCommand()
            await task?.value
            #expect(!flow.blocksMutations && flow.canStart)
        }
    }

    @Test(arguments: Provider.allCases)
    func unlockedCapableControlsReallyDispatch(provider: Provider) async throws {
        let h = try await start(provider); defer { h.stop() }
        _ = try await h.store.updateSettings(.init(model: "default"), target: target)
        let settings = try dispatcherSettings()
        await h.transport.enqueue(.completed(settings))
        _ = try await h.store.updateDispatcher(.init(behavior: "light"), hostID: target.hostID)
        await h.transport.enqueue(.completed(settings))
        _ = try await h.store.setDispatcherModels(.byHand(true), hostID: target.hostID)
        for reset in [CompanionDispatcherReset.clearChat, .forgetEverything] {
            await h.store.askDispatcherReset(reset, hostID: target.hostID)
            let prompt = try #require(h.store.dispatcherResetPrompt)
            let outcome: AnnexJSON = reset == .clearChat ? .object(["cleared": .string("now")])
                : .object(["removed": .integer(2), "heldNews": .integer(0)])
            await h.transport.enqueue(.completed(outcome))
            await h.store.confirmDispatcherReset(prompt)
            #expect(h.store.dispatcherResetNotices[target.hostID] == (reset == .clearChat ? "Its conversation started over." : "Its memory was cleared."))
        }
        #expect(await h.transport.executed.map(\.type) == ["agent.update", "dispatcher.update", "dispatcher.setModels", "dispatcher.clearChat", "dispatcher.forgetEverything"])
        try await select(provider, h)
        await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "control-write-reached")))
        await save(provider, h)
        #expect(await h.transport.executed.last?.type == "agent.providerChange")
        #expect(h.store.hasPendingProviderAction(target))
        try await retain("unlocked/\(provider)", h)
    }

    @Test(arguments: [false, true])
    func startRechecksRecoveryAdmissionAfterItsFreshPreview(preparing: Bool) async throws {
        let h = try await start(.v2); defer { h.stop() }
        try await select(.v2, h)
        await h.transport.enqueue(.completed(try result(.v2, "applied")))
        await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
        await save(.v2, h)
        let flow = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
        #expect(flow.canStart)
        let heldApply = try #require(flow.lastApply)
        await h.transport.enqueue(.heldCompleted(try result(.v2, "savedDefaultsPreview")))
        let count = await h.transport.executed.count
        let starting = Task { await flow.startNew() }
        try await h.waitUntil { await h.transport.executed.count == count + 1 }
        #expect(await h.transport.executed.last?.type == "agent.providerPreview")
        var recoveryRead: Task<Void, Never>?
        if preparing {
            await h.transport.pauseNextRead("dispatcherSettings")
            recoveryRead = Task { await h.store.askDispatcherRecoveryNewChat(target) }
            try await h.waitUntil { await h.transport.isReadPaused("dispatcherSettings") }
            #expect(h.store.dispatcherRecoveryPreparing.contains(target))
        } else {
            await h.store.askDispatcherRecoveryNewChat(target)
            let prompt = try #require(h.store.dispatcherResetPrompt)
            #expect(h.store.claimDispatcherRecoveryNewChat(prompt, target: target) != nil)
            #expect(h.store.pendingCommands.contains(target))
        }
        let before = await h.transport.executed.map(\.commandID)
        try await retain("start-recheck/\(preparing)/before", h)
        await h.transport.releaseCommand()
        await starting.value
        try await retain("start-recheck/\(preparing)/after", h)
        #expect(await h.transport.executed.map(\.commandID) == before)
        #expect(await h.transport.executed.allSatisfy { $0.type != "agent.start" })
        #expect(flow.lastApply == heldApply && flow.lastStart == nil && !flow.canStart)
        if preparing { await h.transport.resumeRead("dispatcherSettings") }
        await recoveryRead?.value
    }

    @Test(arguments: [false, true])
    func settingsReadRetainsItsOwnReservationAndRejectsASecondWriter(dispatcher: Bool) async throws {
        let h = try await start(.v1); defer { h.stop() }
        let writingTarget = dispatcher ? target : h.target
        await h.transport.pauseNextRead("agentSettings")
        let saving = Task { await serviceErrorKind {
            _ = try await h.store.updateSettings(.init(orchestrator: "claude-code", model: "default"), target: writingTarget)
        } }
        try await h.waitUntil { await h.transport.isReadPaused("agentSettings") }
        #expect(h.store.pendingCommands.contains(writingTarget))
        #expect(await serviceErrorKind { _ = try await h.store.updateSettings(.init(model: "default"), target: writingTarget) } != .none)
        #expect(h.store.pendingCommands.contains(writingTarget), "A refused second writer cannot remove the first writer's reservation")
        #expect(await h.transport.executed.isEmpty)
        if dispatcher {
            await h.store.askDispatcherRecoveryNewChat(target)
            #expect(h.store.dispatcherResetPrompt == nil)
            #expect(h.store.dispatcherRecovery(for: target)?.canStartNewChat == false)
            _ = try await h.store.updateSettings(.init(model: "default"), target: h.target)
            #expect(await h.transport.executed.count == 1, "The other target retains its mutation authority")
        }
        try await retain("settings-reservation/\(dispatcher)/before-resume", h)
        await h.transport.resumeRead("agentSettings")
        #expect(await saving.value == .none)
        #expect(!h.store.pendingCommands.contains(writingTarget))
        #expect(await h.transport.executed.count == (dispatcher ? 2 : 1))
        #expect(await h.transport.executed.last?.type == "agent.update")
        try await retain("settings-reservation/\(dispatcher)/after-resume", h)
    }

    @Test(arguments: [false, true])
    func dispatcherSettingsWritesReserveOnlyTheirDispatcherTarget(models: Bool) async throws {
        let h = try await start(.v2); defer { h.stop() }
        try await select(.v2, h)
        await h.transport.enqueue(.heldCompleted(try dispatcherSettings()))
        let saving = Task { await serviceErrorKind {
            if models { _ = try await h.store.setDispatcherModels(.byHand(true), hostID: target.hostID) }
            else { _ = try await h.store.updateDispatcher(.init(behavior: "light"), hostID: target.hostID) }
        } }
        try await h.waitUntil { await h.transport.executed.count == 2 }
        #expect(h.store.pendingCommands.contains(target))
        await h.store.askDispatcherRecoveryNewChat(target)
        #expect(h.store.dispatcherResetPrompt == nil)
        let before = await h.transport.executed.map(\.commandID)
        await save(.v2, h)
        #expect(await h.transport.executed.map(\.commandID) == before)
        _ = try await h.store.updateSettings(.init(model: "default"), target: h.target)
        #expect(h.store.pendingCommands.contains(target) && !h.store.pendingCommands.contains(h.target))
        await h.transport.releaseCommand()
        #expect(await saving.value == .none)
        #expect(!h.store.pendingCommands.contains(target))
        try await retain("dispatcher-settings-reservation/\(models)", h)
    }

    private func settingsWrite(_ kind: String, _ h: LiveServiceHarness) async -> ServiceErrorKind {
        await serviceErrorKind {
            switch kind {
            case "dispatcher": _ = try await h.store.updateDispatcher(.init(behavior: "light"), hostID: target.hostID)
            case "models": _ = try await h.store.setDispatcherModels(.byHand(true), hostID: target.hostID)
            default: _ = try await h.store.updateSettings(.init(model: "default"), target: target)
            }
        }
    }
    private func disableAndReenable(_ h: LiveServiceHarness) async throws {
        await dispatcherSnapshot(h, enabled: false)
        try await h.waitUntil { h.host?.dispatcher?.enabled == false && h.store.agent(for: target) == nil }
        #expect(!h.store.pendingCommands.contains(target), "Existing target cleanup remains effective")
        await dispatcherSnapshot(h, enabled: true)
        try await h.waitUntil { h.store.agent(for: target)?.isSleepingOnDesktop == true }
    }

    @Test(arguments: ["generic", "dispatcher", "models"])
    func oldWriterCannotReleaseANewerReservationAfterDispatcherReplacement(kind: String) async throws {
        let h = try await start(.v1); defer { h.stop() }
        let receipt = kind == "generic" ? agentSettings : try dispatcherSettings()
        await h.transport.enqueue(.heldCompleted(receipt))
        let a = Task { await settingsWrite(kind, h) }
        try await h.waitUntil { await h.transport.executed.count == 1 }
        let aID = try #require(await h.transport.executed.first?.commandID)
        try await disableAndReenable(h)
        await h.transport.enqueue(.heldCompleted(receipt))
        let b = Task { await settingsWrite(kind, h) }
        try await h.waitUntil { await h.transport.executed.count == 2 }
        let bID = try #require(await h.transport.executed.last?.commandID)
        #expect(aID != bID && h.store.pendingCommands.contains(target))
        await h.transport.releaseCommand(commandID: aID)
        _ = await a.value
        #expect(h.store.pendingCommands.contains(target), "A cannot release B's reservation")
        #expect(await settingsWrite("generic", h) != .none)
        #expect(await h.transport.executed.count == 2)
        try await retain("replacement/\(kind)/B-still-held", h)
        await h.transport.releaseCommand(commandID: bID)
        #expect(await b.value == .none)
        #expect(!h.store.pendingCommands.contains(target))
        #expect(await settingsWrite("generic", h) == .none)
        #expect(await h.transport.executed.count == 3)
        try await retain("replacement/\(kind)/after-B-and-unlocked", h)
    }

    @Test func invalidatedSameProviderReadCannotForwardAWriteIntoANewerReservation() async throws {
        let h = try await start(.v1); defer { h.stop() }
        await h.transport.pauseNextRead("agentSettings")
        let a = Task { await serviceErrorKind {
            _ = try await h.store.updateSettings(.init(orchestrator: "claude-code", model: "default"), target: target)
        } }
        try await h.waitUntil { await h.transport.isReadPaused("agentSettings") }
        try await disableAndReenable(h)
        await h.transport.enqueue(.heldCompleted(agentSettings))
        let b = Task { await settingsWrite("generic", h) }
        try await h.waitUntil { await h.transport.executed.count == 1 }
        let bID = try #require(await h.transport.executed.first?.commandID)
        await h.transport.resumeRead("agentSettings")
        #expect(await a.value != .none)
        #expect(await h.transport.executed.map(\.commandID) == [bID], "A's invalidated read must forward zero writes")
        #expect(h.store.pendingCommands.contains(target))
        #expect(await settingsWrite("generic", h) != .none)
        #expect(await h.transport.executed.map(\.commandID) == [bID])
        try await retain("invalidated-read/B-still-held", h)
        await h.transport.releaseCommand(commandID: bID)
        #expect(await b.value == .none)
        #expect(await settingsWrite("generic", h) == .none)
        #expect(await h.transport.executed.count == 2)
        try await retain("invalidated-read/after-B-and-unlocked", h)
    }

    @Test(arguments: ["same-only", "mixed", "different"])
    func storeRetainsSameProviderNoOpAndExplicitSwitchRefusal(kind: String) async throws {
        let h = try await start(.v1); defer { h.stop() }
        if kind == "same-only" {
            let saved = try await h.store.updateSettings(.init(orchestrator: "claude-code"), target: target)
            #expect(saved.name.value == "Navi" && saved.model.value == "fixture-before")
            #expect(await h.transport.executed.isEmpty)
        } else if kind == "mixed" {
            _ = try await h.store.updateSettings(.init(orchestrator: "claude-code", model: "default"), target: target)
            let command = try #require(await h.transport.executed.first)
            let payload = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
            #expect(await h.transport.executed.count == 1)
            #expect(payload["type"] == .string("agent.update") && payload["model"] == .string("default") && payload["orchestrator"] == nil)
        } else {
            #expect(await serviceErrorText { _ = try await h.store.updateSettings(.init(orchestrator: "codex-cli"), target: target) }
                    == CompanionProviderReason.message("provider_change_requires_preview"))
            #expect(await h.transport.executed.isEmpty)
        }
        #expect(!h.store.pendingCommands.contains(target))
        try await retain("provider-no-op/\(kind)", h)
    }

    @Test(arguments: [false, true])
    func changingRuntimeRequiresNewIntentAndCannotUnlockHeldProviderEvidence(lostStart: Bool) async throws {
        let h = try await start(.v2); defer { h.stop() }
        try await select(.v2, h)
        await h.transport.enqueue(.completed(try result(.v2, "applied")))
        await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
        await save(.v2, h)
        let flow = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
        #expect(flow.canStart)
        if lostStart {
            await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
            await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "held-runtime-change")))
            await flow.startNew()
        }
        let held = try #require(flow.lastApply)
        let mutations = await h.transport.executed.filter { $0.type != "agent.providerPreview" }.map(\.commandID)
        #expect(h.store.hasPendingProviderV2Action(target) == lostStart)
        #expect(!h.store.hasPendingLegacyProviderAction(target))
        #expect(h.store.providerV2Flow(for: target, requestedRuntime: "chat") === flow)
        #expect(flow.preview == nil && !flow.canApply && !flow.canStart && flow.lastApply == held)
        _ = h.store.providerV2Flow(for: target, requestedRuntime: "terminal")
        #expect(!flow.canStart, "Returning to an old runtime does not restore its old Start intent")
        await h.transport.enqueue(.completed(try result(.v2, "savedDefaultsPreview")))
        await flow.refresh()
        #expect(flow.lastApply == held && !flow.canStart)
        #expect(flow.canApply == !lostStart && flow.blocksMutations == lostStart)
        #expect(await h.transport.executed.filter { $0.type != "agent.providerPreview" }.map(\.commandID) == mutations)
        try await retain("coverage/runtime-intent/\(lostStart)", h)
    }

    @Test(arguments: ["different-agent", "missing-token"])
    func changedRecoveryReadCannotCreateAConfirmationOrMutation(change: String) async throws {
        let h = try await start(.v1); defer { h.stop() }
        await h.transport.pauseNextRead("dispatcherSettings")
        let asking = Task { await h.store.askDispatcherRecoveryNewChat(target) }
        try await h.waitUntil { await h.transport.isReadPaused("dispatcherSettings") }
        let changed = try change == "different-agent"
            ? replacing(dispatcherSettings(), "agentId", .string("replacement-dispatcher"))
            : replacing(dispatcherSettings(), "clearChat", .object(["applies": .string("now")]))
        await h.transport.setRead("dispatcherSettings", changed)
        await h.transport.resumeRead("dispatcherSettings")
        await asking.value
        #expect(h.store.dispatcherResetPrompt == nil)
        #expect(h.store.dispatcherResetNotices[target.hostID] == "This Dispatcher changed. Reopen its recovery controls and review it again.")
        #expect(!h.store.dispatcherRecoveryPreparing.contains(target) && !h.store.pendingCommands.contains(target))
        #expect(await h.transport.executed.isEmpty)
        await h.transport.setRead("dispatcherSettings", try dispatcherSettings())
        await h.store.askDispatcherRecoveryNewChat(target)
        let fresh = try #require(h.store.dispatcherResetPrompt)
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(fresh, target: target))
        #expect(await h.transport.executed.isEmpty)
        await h.transport.enqueue(.completed(.object(["cleared": .string("now")])))
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.count == 1)
        try await retain("coverage/changed-recovery-read/\(change)", h)
    }

    @Test(arguments: [CompanionDispatcherReset.clearChat, .forgetEverything])
    func aMissingDesktopConfirmationTokenNeverAuthorizesALegacyReset(reset: CompanionDispatcherReset) async throws {
        let h = try await start(.v1); defer { h.stop() }
        let missing = try replacing(dispatcherSettings(), reset.rawValue, .object([:]))
        await h.transport.setRead("dispatcherSettings", missing)
        await h.store.askDispatcherReset(reset, hostID: target.hostID)
        #expect(h.store.dispatcherResetPrompt == nil)
        #expect(h.store.dispatcherResetNotices[target.hostID] == "This desktop didn't offer a confirmation for \(reset.action). Try again.")
        #expect(await h.transport.executed.isEmpty)
        await h.transport.setRead("dispatcherSettings", try dispatcherSettings())
        await h.store.askDispatcherReset(reset, hostID: target.hostID)
        let cancelled = try #require(h.store.dispatcherResetPrompt)
        #expect(cancelled.reset == reset)
        h.store.cancelDispatcherReset()
        #expect(await h.transport.executed.isEmpty)
        await h.store.askDispatcherReset(reset, hostID: target.hostID)
        let confirmed = try #require(h.store.dispatcherResetPrompt)
        let outcome: AnnexJSON = reset == .clearChat ? .object(["cleared": .string("now")]) : .object(["removed": .integer(1)])
        await h.transport.enqueue(.completed(outcome))
        await h.store.confirmDispatcherReset(confirmed)
        #expect(await h.transport.executed.count == 1)
        #expect(await h.transport.executed.first?.type == (reset == .clearChat ? "dispatcher.clearChat" : "dispatcher.forgetEverything"))
        try await retain("coverage/missing-reset-token/\(reset)", h)
    }

    @Test func disconnectRefusesPreviouslyCapableDispatcherWritesWithoutClaimingThem() async throws {
        let h = try await start(.v1); defer { h.stop() }
        await h.transport.enqueue(.completed(try dispatcherSettings()))
        _ = try await h.store.updateDispatcher(.init(behavior: "light"), hostID: target.hostID)
        let sent = await h.transport.executed.map(\.commandID)
        #expect(sent.count == 1)
        await h.transport.emit(.connection(.disconnected))
        try await h.waitUntil { h.host?.connection.canOperate == false }
        #expect(await serviceErrorText { _ = try await h.store.updateDispatcher(.init(behavior: "thorough"), hostID: target.hostID) }
                == "Reconnect to your desktop to change the Dispatcher.")
        #expect(await serviceErrorText { _ = try await h.store.setDispatcherModels(.byHand(true), hostID: target.hostID) }
                == "Reconnect to your desktop to change the Dispatcher.")
        #expect(!h.store.pendingCommands.contains(target))
        #expect(await h.transport.executed.map(\.commandID) == sent)
        try await retain("coverage/disconnected-dispatcher", h)
    }

    @Test func revokedSettingsCapabilityCannotReuseAPreviouslyValidReset() async throws {
        let h = try await start(.v1); defer { h.stop() }
        await h.store.askDispatcherReset(.clearChat, hostID: target.hostID)
        let held = try #require(h.store.dispatcherResetPrompt)
        await h.transport.enqueue(.completed(try dispatcherSettings()))
        _ = try await h.service.updateDispatcher(.init(behavior: "light"), hostID: target.hostID, clientCommandID: "capable-before-revocation")
        let sent = await h.transport.executed.map(\.commandID)
        #expect(sent.count == 1)
        guard case .object(var feature)? = try ContractFixtures.body("capabilities.json")["dispatcher"] else { throw CancellationError() }
        feature["enabled"] = .bool(true); feature["flagOn"] = .bool(true)
        feature.removeValue(forKey: "settings")
        await h.transport.setFeature("dispatcher", .object(feature))
        try await h.refreshCatalog()
        #expect(h.host?.canEditDispatcherSettings == false)
        #expect(await serviceErrorText { _ = try await h.service.dispatcherSettings(hostID: target.hostID) } == CompanionDispatcherSettings.updateDesktop)
        #expect(await serviceErrorText { _ = try await h.service.updateDispatcher(.init(behavior: "thorough"), hostID: target.hostID, clientCommandID: "blocked-update") } == CompanionDispatcherSettings.updateDesktop)
        #expect(await serviceErrorText { _ = try await h.service.setDispatcherModels(.byHand(true), hostID: target.hostID, clientCommandID: "blocked-models") } == CompanionDispatcherSettings.updateDesktop)
        #expect(await serviceErrorText { _ = try await h.service.resetDispatcher(held, clientCommandID: "blocked-reset") } == CompanionDispatcherSettings.updateDesktop)
        await h.store.confirmDispatcherReset(held)
        #expect(h.store.dispatcherResetNotices[target.hostID] == CompanionDispatcherSettings.updateDesktop)
        #expect(!h.store.dispatcherResetting.contains(target.hostID) && !h.store.pendingCommands.contains(target))
        #expect(await h.transport.executed.map(\.commandID) == sent)
        try await retain("coverage/revoked-settings-capability", h)
    }
}
