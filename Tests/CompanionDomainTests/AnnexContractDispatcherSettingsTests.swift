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

    @Test(arguments: [("Dispatcher controller", "Dispatcher controller"), ("Navi", "Navi"), (" \n\t", "Dispatcher")])
    func settingsNameUsesTheChatDisplayRole(name: String, expected: String) throws {
        guard case .object(var value) = try ContractFixtures.body("dispatcher-settings.json", "on"),
              case .object(var identity)? = value["identity"], case .object(var field)? = identity["name"] else {
            Issue.record("Missing settings identity"); return
        }
        field["value"] = .string(name)
        identity["name"] = .object(field)
        value["identity"] = .object(identity)
        let settings = try CompanionDispatcherSettings(json: .object(value))
        #expect(settings.identity.name == expected)
        #expect(CompanionDispatcherResetPrompt(.clearChat, settings: settings, hostID: "host")?.name == expected)
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

    @Test func rawDispatcherAgentSettingsAlsoPreserveTheSavedChatName() throws {
        guard case .object(var value) = try ContractFixtures.body("agent-settings-dispatcher.json"),
              case .object(var settings)? = value["settings"], case .object(var name)? = settings["name"] else {
            Issue.record("Missing raw agent settings name"); return
        }
        name["value"] = .string("Dispatcher controller")
        settings["name"] = .object(name)
        value["settings"] = .object(settings)
        #expect(try CompanionAgentSettings(json: .object(value)).name.value == "Dispatcher controller")
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

    @Test func canonicalEquivalentDraftAcknowledgementsReachTheStoreWithTheirExactBytes() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let original = try ContractFixtures.body("dispatcher-settings.json", "on")
        for field in ["name", "emoji", "personality"] {
            for value in ["\u{e9}", "e\u{301}", "Next desktop value"] {
                let raw = try withDraftText(original, field: field, value: value)
                await harness.transport.setRead("dispatcherSettings", raw)
                _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
                func bytes() -> [UInt8]? {
                    guard let settings = harness.store.dispatcherSettings(hostID: hostID) else { return nil }
                    switch field {
                    case "name": return Array(settings.identity.name.utf8)
                    case "emoji": return settings.identity.emoji.map { Array($0.utf8) }
                    default: return settings.personality.map { Array($0.text.utf8) }
                    }
                }
                try await harness.waitUntil { bytes() == Array(value.utf8) }
                #expect(bytes() == Array(value.utf8))
            }
        }
    }

    @Test func anOlderCommandReceiptDoesNotPublishOverANewerSettingsRead() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID) != nil }
        let original = try ContractFixtures.body("dispatcher-settings.json", "on")
        let saved = try withDraftText(original, field: "name", value: "Saved name")
        let newer = try withDraftText(saved, field: "emoji", value: "New remote emoji")
        let receipt = try AnnexJSON.object([
            "version": .integer(1), "epoch": .string("epoch"), "commandId": .string("held"),
            "status": .string("completed"), "result": saved
        ]).decode(AnnexCommandReceipt.self)
        await harness.transport.enqueue(.heldReceipt(receipt))
        let save = Task {
            try await harness.service.updateDispatcher(.init(name: "Saved name"), hostID: hostID, clientCommandID: "held")
        }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        await harness.transport.setRead("dispatcherSettings", newer)
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.identity.emoji == "New remote emoji" }
        let events = harness.service.events()
        let observed = Task {
            var emojiValues: [String?] = []
            for await event in events {
                guard case .hosts(let hosts) = event, let host = hosts.first(where: { $0.id == hostID }) else { continue }
                emojiValues.append(host.dispatcherSettings?.identity.emoji)
                if host.dispatcherSettings?.identity.color == "teal" { return emojiValues }
            }
            return emojiValues
        }
        defer { observed.cancel() }
        let readsBeforeReceipt = await settingsReads(harness)
        await harness.transport.releaseCommand()
        let result = try await save.value
        #expect(result.identity.name == "Saved name", "The caller receives the reconciled snapshot, which also includes the saved name")
        #expect(await settingsReads(harness) == readsBeforeReceipt + 1, "Conflicting receipt evidence is resolved by one authoritative read, never by publishing the older snapshot")
        // A distinct final read is a barrier after any incorrectly emitted receipt snapshot.
        await harness.transport.setRead("dispatcherSettings", try withDraftText(newer, field: "color", value: "teal"))
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.identity.color == "teal" }
        let emojiValues = await observed.value
        #expect(!emojiValues.isEmpty)
        #expect(emojiValues.allSatisfy { $0 == "New remote emoji" })
    }

    @Test func legitimateBehaviorReceiptSurvivesAnInterveningConfirmationRefresh() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID) != nil }
        let original = try ContractFixtures.body("dispatcher-settings.json", "on")
        let newer = withTokens(original, clear: "new-clear", forget: "new-forget")
        guard case .object(var saved) = newer,
              case .object(var behavior)? = saved["behavior"] else {
            Issue.record("Missing fixture behavior")
            return
        }
        behavior["value"] = .string("thorough")
        saved["behavior"] = .object(behavior)
        let receipt = try AnnexJSON.object([
            "version": .integer(1), "epoch": .string("epoch"), "commandId": .string("held"),
            "status": .string("completed"), "result": .object(saved)
        ]).decode(AnnexCommandReceipt.self)
        await harness.transport.enqueue(.heldReceipt(receipt))
        let save = Task {
            try await harness.store.updateDispatcher(.init(behavior: "thorough"), hostID: hostID)
        }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        await harness.transport.setRead("dispatcherSettings", newer)
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil {
            harness.store.dispatcherSettings(hostID: hostID)?.clearChat.expectedState == "new-clear"
        }
        let readsBeforeReceipt = await settingsReads(harness)
        await harness.transport.releaseCommand()
        let acknowledged = try await save.value
        #expect(acknowledged.behavior.value == "thorough")
        #expect(acknowledged.clearChat.expectedState == "new-clear")
        let events = harness.service.events()
        var iterator = events.makeAsyncIterator()
        guard case .hosts(let hosts)? = await iterator.next() else {
            Issue.record("Missing current service snapshot")
            return
        }
        let visible = hosts.first { $0.id == hostID }?.dispatcherSettings
        #expect(visible?.behavior.value == "thorough", "A later receipt containing every intervening change must not leave the saved Behavior unshown")
        #expect(visible?.clearChat.expectedState == "new-clear")
        #expect(visible?.forgetEverything.expectedState == "new-forget")
        #expect(await settingsReads(harness) == readsBeforeReceipt, "A receipt including all observed changes needs no extra read")
    }

    @Test func sameFieldConflictUsesOneAuthoritativeRead() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let original = try ContractFixtures.body("dispatcher-settings.json", "on")
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID) != nil }
        let saved = try withDraftText(original, field: "name", value: "Submitted name")
        let newer = try withDraftText(original, field: "name", value: "Newer desktop name")
        let receipt = try AnnexJSON.object([
            "version": .integer(1), "epoch": .string("epoch"), "commandId": .string("held"),
            "status": .string("completed"), "result": saved
        ]).decode(AnnexCommandReceipt.self)
        await harness.transport.enqueue(.heldReceipt(receipt))
        let save = Task {
            try await harness.store.updateDispatcher(.init(name: "Submitted name"), hostID: hostID)
        }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        await harness.transport.setRead("dispatcherSettings", newer)
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.dispatcherSettings(hostID: hostID)?.identity.name == "Newer desktop name" }
        let before = await settingsReads(harness)
        await harness.transport.releaseCommand()
        let returned = try await save.value
        #expect(Array(returned.identity.name.utf8) == Array("Newer desktop name".utf8),
                "The submitted-field acknowledgement must use the authoritative read, not the superseded receipt")
        #expect(await settingsReads(harness) == before + 1)
        #expect(harness.store.dispatcherSettings(hostID: hostID)?.identity.name == "Newer desktop name")
        #expect(await harness.transport.executed.count == 1)
    }

    private func withDraftText(_ body: AnnexJSON, field: String, value: String) throws -> AnnexJSON {
        guard case .object(var document) = body else { throw AnnexTransportError.malformedResponse }
        if field == "personality" {
            guard case .object(var personality)? = document["personality"],
                  case .object(var text)? = personality["value"] else { throw AnnexTransportError.malformedResponse }
            text["text"] = .string(value)
            personality["value"] = .object(text)
            document["personality"] = .object(personality)
        } else {
            guard case .object(var identity)? = document["identity"],
                  case .object(var text)? = identity[field] else { throw AnnexTransportError.malformedResponse }
            text["value"] = .string(value)
            identity[field] = .object(text)
            document["identity"] = .object(identity)
        }
        return .object(document)
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

    /// Go #626: the visible chat is kept unless the person confirms; asking again always starts from a fresh read.
    @Test func cancellingClearChatSendsNothingAndAskingAgainReadsAFreshConfirmation() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let on = try ContractFixtures.body("dispatcher-settings.json", "on")
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-1"))
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        #expect(harness.store.dispatcherResetPrompt?.reset == .clearChat)
        harness.store.cancelDispatcherReset()
        #expect(harness.store.dispatcherResetPrompt == nil)
        #expect(await harness.transport.executed.isEmpty, "Cancel never clears the chat")
        #expect(harness.store.dispatcherResetNotices[hostID] == nil)

        let reads = await settingsReads(harness)
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-2", forget: "forget-2"))
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        #expect(await settingsReads(harness) == reads + 1, "Each question reads the desktop's current confirmation")
        #expect(harness.store.dispatcherResetPrompt?.expectedState == "clear-2")
        #expect(await harness.transport.executed.isEmpty)
    }

    /// Go #626: a lost reply is not a result. The reset is sent once, never resent, and nothing claims the chat was cleared.
    @Test func anUncertainClearIsSentOnceNeverRetriedAndClaimsNothing() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        let on = try ContractFixtures.body("dispatcher-settings.json", "on")
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-1", forget: "forget-1"))
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        let prompt = try #require(harness.store.dispatcherResetPrompt)
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost-reply")))
        await harness.store.confirmDispatcherReset(prompt)

        #expect(await harness.transport.executed.map(\.kind) == [.clearDispatcherChat(expectedState: "clear-1")])
        #expect(harness.store.dispatcherResetPrompt == nil, "An uncertain reply doesn't re-ask with the spent confirmation")
        let notice = try #require(harness.store.dispatcherResetNotices[hostID])
        #expect(notice == "The desktop may have received this command, but its reply was lost.")
        #expect(!notice.contains("started over") && !notice.lowercased().contains("cleared"), "No outcome is claimed: \(notice)")
        #expect(harness.store.dispatcherResetting.isEmpty)

        // Nothing is resent later on its own, and the next question starts from the desktop's current state.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.executed.count == 1)
        let reads = await settingsReads(harness)
        await harness.transport.setRead("dispatcherSettings", withTokens(on, clear: "clear-2", forget: "forget-2"))
        await harness.store.askDispatcherReset(.clearChat, hostID: hostID)
        #expect(await settingsReads(harness) == reads + 1)
        #expect(harness.store.dispatcherResetPrompt?.expectedState == "clear-2")
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

    @Test func settingsReadsAndUpdateResultsProjectTheChosenChatNameOntoTheCatalog() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let hostID = LiveServiceHarness.hostID
        guard case .object(var value)? = try ContractFixtures.json("snapshot-dispatcher.json")["value"],
              case .object(var agent)? = value["agent"] else { Issue.record("No Dispatcher agent"); return }
        agent["name"] = .string("Dispatcher controller")
        value["agent"] = .object(agent)
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": .object(value)]))
        try await harness.waitUntil { harness.host?.dispatcher?.agent != nil }
        let target = try #require(harness.host?.dispatcher?.agent?.id)
        #expect(harness.store.agent(for: target)?.name == "Dispatcher controller", "The snapshot name is already authoritative before settings load")
        await harness.transport.setRead("dispatcherSettings", try ContractFixtures.body("dispatcher-settings.json", "byHand"))
        _ = try await harness.store.loadDispatcherSettings(hostID: hostID)
        try await harness.waitUntil { harness.store.agent(for: target)?.name == "Robin" }
        #expect(harness.host?.dispatcherDisplayName == "Robin")

        let result = try self.result("commands/dispatcher.update.json", "accepted")
        await harness.transport.enqueue(.completed(result))
        let settings = try await harness.store.updateDispatcher(.init(behavior: "thorough"), hostID: hostID)
        try await harness.waitUntil { harness.store.agent(for: target)?.name == settings.identity.name }
        #expect(harness.host?.dispatcherAgent?.id == target, "Name updates never change the chat id")
    }

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
