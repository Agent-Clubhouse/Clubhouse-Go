import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Settings > Dispatcher (Clubhouse #3206, Go #338): the recorded route and commands through the phone's decoders,
/// live service and store, and the confirmation flow for its two resets.
@MainActor @Suite(.serialized) struct AnnexContractDispatcherSettingsTests {
    private static let commands = ["dispatcher.setEnabled", "agent.update", "dispatcher.update", "dispatcher.setModels",
                                   "dispatcher.clearChat", "dispatcher.forgetEverything"]

    /// The capabilities fixture's `dispatcher` block, on, with its settings route.
    private func start(settings: Bool = true) async throws -> LiveServiceHarness {
        guard case .object(var feature)? = try ContractFixtures.body("capabilities.json")["dispatcher"] else {
            Issue.record("No dispatcher capability"); throw AnnexTransportError.malformedResponse
        }
        feature["enabled"] = .bool(true); feature["flagOn"] = .bool(true)
        if !settings { feature["settings"] = nil }
        let enabled = feature
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", .object(enabled))
            await transport.addCommands(Self.commands)
            await transport.setRead("dispatcherSettings", try! ContractFixtures.body("dispatcher-settings.json", "on"))
        })
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == true }
        return harness
    }
    private func settingsReads(_ harness: LiveServiceHarness) async -> Int {
        await harness.transport.readRoutes.filter { $0.name == "dispatcherSettings" }.count
    }
    private func result(_ file: String, _ name: String) throws -> AnnexJSON {
        let item = try #require(try ContractFixtures.cases(file).first { $0["name"]?.string == name })
        return try #require(item["response"]?["body"]?["result"])
    }
    private func withTokens(_ body: AnnexJSON, clear: String, forget: String, clearApplies: String? = nil) -> AnnexJSON {
        guard case .object(var value) = body, case .object(var clearChat)? = value["clearChat"] else { return body }
        clearChat["expectedState"] = .string(clear)
        if let clearApplies { clearChat["applies"] = .string(clearApplies) }
        value["clearChat"] = .object(clearChat)
        value["forgetEverything"] = .object(["expectedState": .string(forget)])
        return .object(value)
    }

    // MARK: Decoding

    @Test func capabilitiesGateTheSettingsOnTheRouteAndItsFourCommands() throws {
        let caps = try ContractFixtures.body("capabilities.json").decode(AnnexCapabilities.self)
        #expect(caps.supportsDispatcherSettings)
        #expect(caps.dispatcher?.settings == .init(version: 1, path: "/api/v1/mobile/dispatcher/settings"))
        var raw = try ContractFixtures.body("capabilities.json")
        if case .object(var document) = raw { document["commands"] = .array(caps.commands.filter { $0 != "dispatcher.forgetEverything" }.map(AnnexJSON.string)); raw = .object(document) }
        #expect(try raw.decode(AnnexCapabilities.self).supportsDispatcherSettings == false, "Every command is needed")
    }

    @Test func theRouteDecodesOnAndWithModelsChosenByHand() throws {
        let on = try CompanionDispatcherSettings(json: try ContractFixtures.body("dispatcher-settings.json", "on"))
        #expect(on.agentID == "durable_dispatcher")
        #expect(on.behavior.value == "standard" && on.behavior.setsModels && on.behavior.editable && on.behavior.note == nil)
        #expect(on.behavior.choices.map(\.id) == ["light", "standard", "thorough"] && on.behavior.choices.map(\.label) == ["Light", "Standard", "Thorough"])
        #expect(on.behavior.selected?.description == "Balanced models. Checks in on your agents occasionally.")
        #expect(!on.models.byHand && on.models.roles.map(\.id) == ["chat", "work"] && on.models.roles.allSatisfy { $0.pick == nil })
        #expect(on.models.roles.first?.label == "Talking with you")
        #expect(on.identity.name == "Dispatcher" && on.identity.color == "indigo" && on.identity.emoji == nil && on.identity.maxNameLength == 40 && !on.identity.hasImageIcon)
        let personality = try #require(on.personality)
        #expect(personality.maxLength == 2000 && personality.presets.map(\.id) == ["friendly", "concise", "detailed", "custom"])
        #expect(personality.presets.last?.text == nil, "Custom has no text of its own")
        let usage = try #require(on.usage)
        #expect(usage.day != nil && usage.conversations != nil && usage.background != nil)
        #expect(on.notHonored == ["model", "contextWindow", "runtime", "freeAgentMode", "access"])
        #expect(on.clearChat.expectedState?.isEmpty == false && on.clearChat.applies == "next_start")
        #expect(on.forgetEverything.expectedState?.isEmpty == false && on.forgetEverything.expectedState != on.clearChat.expectedState)

        let byHand = try CompanionDispatcherSettings(json: try ContractFixtures.body("dispatcher-settings.json", "byHand"))
        #expect(byHand.models.byHand && !byHand.behavior.setsModels && byHand.behavior.note?.isEmpty == false)
        #expect(byHand.models.roles.last?.pick == .init(provider: "claude-code", model: "opus", effort: "high", contextWindow: nil))
        #expect(byHand.identity.name == "Robin" && byHand.identity.emoji == "🦉")
        #expect(byHand.personality?.preset == "custom" && byHand.personality?.text == "Talk like a ship's captain.")
        let conversations = try #require(byHand.usage?.conversations)
        #expect(conversations.turns == 4 && conversations.input == 182_000 && conversations.output == 6400 && conversations.costUSD == 0.42 && conversations.costIsEstimate)
        #expect(byHand.usage?.background?.turnsWithoutUsage == 1)
        #expect(byHand.notHonored == ["runtime", "freeAgentMode", "access"], "Models chosen by hand are offered")
    }

    @Test func everyAcceptedCommandResultDecodesAsTheSettings() throws {
        var checked = 0
        for file in ["commands/dispatcher.update.json", "commands/dispatcher.setModels.json"] {
            for item in try ContractFixtures.cases(file) where item["response"]?["body"]?["status"]?.string == "completed" {
                let result = try #require(item["response"]?["body"]?["result"])
                #expect(throws: Never.self, "\(file) \(item["name"]?.string ?? "")") { _ = try CompanionDispatcherSettings(json: result) }
                checked += 1
            }
        }
        #expect(checked >= 5)
        #expect(CompanionDispatcherResetOutcome(.clearChat, result: try result("commands/dispatcher.clearChat.json", "accepted")) == .chatCleared(now: false))
        #expect(CompanionDispatcherResetOutcome(.forgetEverything, result: try result("commands/dispatcher.forgetEverything.json", "accepted")) == .forgot(removed: 1, heldNews: 0))
        #expect(CompanionDispatcherResetOutcome(.clearChat, result: .object(["cleared": .string("later")])) == nil)
    }

    @Test func theRawAgentSettingsHideWhatSettingsDispatcherDoesntOffer() throws {
        let settings = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-dispatcher.json"))
        #expect(settings.notHonored == ["model", "contextWindow", "runtime", "freeAgentMode", "access"])
        let byHand = try ContractFixtures.json("dispatcher-settings.json")["byHandAgentSettingsNotHonored"].arrayValue.compactMap { $0["setting"]?.string }
        #expect(!byHand.isEmpty)
    }

    @Test func theDesktopsWordsForEachReset() throws {
        let settings = try CompanionDispatcherSettings(json: try ContractFixtures.body("dispatcher-settings.json", "byHand"))
        let clear = try #require(CompanionDispatcherResetPrompt(.clearChat, settings: settings, hostID: "h"))
        #expect(clear.title == "Clear chat?" && clear.expectedState == settings.clearChat.expectedState)
        #expect(clear.message.hasPrefix("The conversation starts over. Robin still remembers what you decided"))
        #expect(clear.message.hasSuffix("It starts over the next time it wakes."))
        let forget = try #require(CompanionDispatcherResetPrompt(.forgetEverything, settings: settings, hostID: "h"))
        #expect(forget.title == "Forget everything?" && forget.expectedState == settings.forgetEverything.expectedState)
        #expect(forget.message.contains("Robin forgets its notes on your agents and your work") && forget.message.contains("This can’t be undone."))
        #expect(forget.id != clear.id, "Each reset has its own confirmation")
        var unconfirmable = settings
        unconfirmable.clearChat.expectedState = nil
        #expect(CompanionDispatcherResetPrompt(.clearChat, settings: unconfirmable, hostID: "h") == nil, "A client without the pinned certificate can't confirm")
    }

    // MARK: Commands

    @Test func commandsEncodeAsTheDesktopRecordedThem() throws {
        let update = AnnexCommand(commandID: "c", epoch: "e", kind: .updateDispatcher(.init(behavior: "thorough")))
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: update.encoded())["behavior"] == .string("thorough"))
        for invalid: AnnexCommand.Kind in [.updateDispatcher(.init()), .updateDispatcher(.init(personality: .init())),
                                           .setDispatcherModels(.pick(role: "work")), .setDispatcherModels(.pick(role: "boss", model: "opus")),
                                           .clearDispatcherChat(expectedState: ""), .forgetDispatcherEverything(expectedState: "")] {
            #expect(throws: AnnexTransportError.malformedResponse) { try AnnexCommand(commandID: "c", epoch: "e", kind: invalid).encoded() }
        }
    }

    @Test func behaviorAndModelChangesUseTheResultWithoutReadingAgain() async throws {
        let harness = try await start()
        defer { harness.stop() }
        #expect(harness.store.canEditDispatcherSettings(hostID: LiveServiceHarness.hostID))
        _ = try await harness.store.loadDispatcherSettings(hostID: LiveServiceHarness.hostID)
        let reads = await settingsReads(harness)

        await harness.transport.enqueue(.completed(try result("commands/dispatcher.update.json", "accepted")))
        let updated = try await harness.store.updateDispatcher(.init(behavior: "thorough"), hostID: LiveServiceHarness.hostID)
        #expect(updated.behavior.value == "thorough")
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: LiveServiceHarness.hostID)?.behavior.value == "thorough" }

        await harness.transport.enqueue(.completed(try result("commands/dispatcher.setModels.json", "accepted pick")))
        let models = try await harness.store.setDispatcherModels(.pick(role: "work", model: "opus", effort: .set("high")), hostID: LiveServiceHarness.hostID)
        #expect(models.models.byHand && models.models.roles.last?.pick?.model == "opus")
        #expect(await settingsReads(harness) == reads, "A result is already fresh")
        let sent = await harness.transport.executed.map(\.type)
        #expect(sent == ["dispatcher.update", "dispatcher.setModels"])
    }

    @Test func refusalsReachThePersonAsSentences() async throws {
        let harness = try await start()
        defer { harness.stop() }
        await harness.transport.enqueue(.rejected(code: "models_refused", message: "Turn on Choose models yourself first."))
        await #expect { _ = try await harness.store.setDispatcherModels(.pick(role: "work", model: "opus"), hostID: LiveServiceHarness.hostID) } throws: {
            $0.localizedDescription == "Turn on Choose models yourself first."
        }
        await harness.transport.enqueue(.rejected(code: "invalid_behavior", message: "turbo isn't a Behavior."))
        await #expect { _ = try await harness.store.updateDispatcher(.init(behavior: "turbo"), hostID: LiveServiceHarness.hostID) } throws: {
            $0.localizedDescription.hasPrefix("That Behavior isn't one the desktop offers.")
        }
    }

    @Test func theOffRouteMeansTurnedOff() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let off = try ContractFixtures.json("dispatcher-settings.json")["off"]?["response"]
        #expect(off?["status"]?.integer == 404 && off?["body"]?["error"]?.string == "dispatcher_off")
        await harness.transport.failRead("dispatcherSettings", .rejected(status: 404, code: "dispatcher_off"))
        await #expect { _ = try await harness.store.loadDispatcherSettings(hostID: LiveServiceHarness.hostID) } throws: {
            $0.localizedDescription == "The Dispatcher is turned off on the desktop. Turn it on first."
        }
        #expect(harness.store.dispatcherSettings(hostID: LiveServiceHarness.hostID) == nil)
    }

    @Test func olderDesktopsWithoutTheRouteOfferNoSettings() async throws {
        let harness = try await start(settings: false)
        defer { harness.stop() }
        #expect(!harness.store.canEditDispatcherSettings(hostID: LiveServiceHarness.hostID))
        await #expect(throws: CompanionServiceError.self) { _ = try await harness.store.loadDispatcherSettings(hostID: LiveServiceHarness.hostID) }
        #expect(await settingsReads(harness) == 0)
    }

    // MARK: Confirmations

    /// The confirmation is read right before asking, sent once, and on `stale_state` the person is asked again with
    /// what changed. A reset is never sent again by itself.
    @Test func aStaleClearChatAsksAgainWithWhatChangedAndIsNeverRetried() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let on = try ContractFixtures.body("dispatcher-settings.json", "on")
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-1"))
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        let first = try #require(harness.store.dispatcherResetPrompt)
        #expect(first.reset == .clearChat && first.expectedState == "clear-1" && first.changed == nil)

        // Its chat woke while the person read the question.
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-2", forget: "forget-2", clearApplies: "now"))
        await harness.transport.enqueue(.rejected(code: "stale_state", message: "This changed since you were asked. Check again and confirm."))
        await harness.store.confirmDispatcherReset(first)
        let again = try #require(harness.store.dispatcherResetPrompt)
        #expect(again.expectedState == "clear-2" && again.reset == .clearChat)
        #expect(again.changed?.contains("Its chat woke up, so it would start over at once.") == true)
        #expect(again.message.hasPrefix("This changed since you were asked."))
        var sent = await harness.transport.executed
        #expect(sent.count == 1, "A stale reset is never retried")
        #expect(harness.store.dispatcherResetNotices[hostID] == nil)

        await harness.transport.enqueue(.completed(.object(["cleared": .string("now")])))
        await harness.store.confirmDispatcherReset(again)
        sent = await harness.transport.executed
        #expect(sent.map(\.kind) == [.clearDispatcherChat(expectedState: "clear-1"), .clearDispatcherChat(expectedState: "clear-2")])
        #expect(Set(sent.map(\.commandID)).count == 2, "The second confirmation is a new command")
        #expect(harness.store.dispatcherResetPrompt == nil)
        #expect(harness.store.dispatcherResetNotices[hostID] == "Its conversation started over.")
    }

    @Test func forgetEverythingSendsItsOwnConfirmationAndCancelSendsNothing() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let on = try ContractFixtures.body("dispatcher-settings.json", "on")
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-1"))

        await harness.store.askDispatcherReset(.forgetEverything, hostID: hostID)
        #expect(harness.store.dispatcherResetPrompt?.expectedState == "forget-1")
        harness.store.cancelDispatcherReset()
        #expect(harness.store.dispatcherResetPrompt == nil)
        #expect(await harness.transport.executed.isEmpty)

        await harness.store.askDispatcherReset(.forgetEverything, hostID: hostID)
        let prompt = try #require(harness.store.dispatcherResetPrompt)
        await harness.transport.enqueue(.completed(try result("commands/dispatcher.forgetEverything.json", "accepted")))
        await harness.store.confirmDispatcherReset(prompt)
        #expect(await harness.transport.executed.map(\.kind) == [.forgetDispatcherEverything(expectedState: "forget-1")])
        #expect(harness.store.dispatcherResetNotices[hostID] == "Its memory was cleared.")
    }

    @Test func aStaleForgetEverythingSaysItsMemoryChanged() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let on = try ContractFixtures.body("dispatcher-settings.json", "on")
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-1"))
        await harness.store.askDispatcherReset(.forgetEverything, hostID: hostID)
        let first = try #require(harness.store.dispatcherResetPrompt)
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-2"))
        await harness.transport.enqueue(.rejected(code: "stale_state", message: "This changed since you were asked. Check again and confirm."))
        await harness.store.confirmDispatcherReset(first)
        let again = try #require(harness.store.dispatcherResetPrompt)
        #expect(again.reset == .forgetEverything && again.expectedState == "forget-2")
        #expect(again.changed?.contains("Its memory changed since you were asked") == true)
        #expect(await harness.transport.executed.count == 1)
    }

    @Test func aRefusedClearSaysWhyAndDoesntAskAgain() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        let prompt = try #require(harness.store.dispatcherResetPrompt)
        await harness.transport.enqueue(.rejected(code: "dispatcher_off", message: "The Dispatcher is turned off."))
        await harness.store.confirmDispatcherReset(prompt)
        #expect(harness.store.dispatcherResetPrompt == nil, "Only a stale confirmation asks again")
        #expect(harness.store.dispatcherResetNotices[hostID] == "The Dispatcher is turned off on the desktop. Turn it on first.")
        #expect(await harness.transport.executed.count == 1)
    }

    // MARK: Live changes

    @Test func dispatcherChangedKeepsTheSettingsCurrentAndDropsThemWhenOff() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.behavior.value == "standard" }

        // Changed on the desktop: the next read has it.
        await harness.transport.setRead("dispatcherSettings", try ContractFixtures.body("dispatcher-settings.json", "byHand"))
        let frames = (try ContractFixtures.json("dispatcher-changed.json")["frames"]).arrayValue
        let on = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frames[0]))
        await harness.transport.emit(.message(on))
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.behavior.value == "thorough" }
        #expect(harness.store.dispatcherSettings(hostID: hostID)?.identity.name == "Robin")

        let off = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frames[1]))
        await harness.transport.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(false), "flagOn": .bool(true)]))
        await harness.transport.emit(.message(off))
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID) == nil }
        #expect(!harness.store.canEditDispatcherSettings(hostID: hostID))
    }

    @Test func aSnapshotWithAChangedDispatcherRereadsLoadedSettings() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let value = try #require(try ContractFixtures.json("snapshot-dispatcher.json")["value"])
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        let reads = await settingsReads(harness)

        // The same Dispatcher again: nothing to read.
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        #expect(await settingsReads(harness) == reads)

        // Renamed on the desktop.
        guard case .object(var block) = value, case .object(var agent)? = block["agent"] else { Issue.record("No agent"); return }
        agent["name"] = .string("Robin"); block["agent"] = .object(agent)
        await harness.transport.setRead("dispatcherSettings", try ContractFixtures.body("dispatcher-settings.json", "byHand"))
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": .object(block)]))
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.identity.name == "Robin" }
    }
}
