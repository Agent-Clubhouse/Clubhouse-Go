import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// The desktop's recorded Dispatcher messages (#2575) through the phone's decoders, live service and store.
@MainActor @Suite(.serialized) struct AnnexContractDispatcherTests {
    private let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_dispatcher")

    /// The capabilities fixture's `dispatcher` block, turned on as the snapshot fixture records it.
    private func start() async throws -> LiveServiceHarness {
        let block = try ContractFixtures.body("capabilities.json")["dispatcher"]
        guard case .object(var feature)? = block else { Issue.record("No dispatcher capability"); throw AnnexTransportError.malformedResponse }
        feature["enabled"] = .bool(true); feature["flagOn"] = .bool(true)
        let enabled = feature
        return try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", .object(enabled))
            await transport.addCommands(["dispatcher.setEnabled", "agent.update"])
        })
    }

    @Test func capabilitiesAdvertiseTheDispatcher() throws {
        let caps = try ContractFixtures.body("capabilities.json").decode(AnnexCapabilities.self)
        #expect(caps.supportsDispatcher && caps.supportsDispatcherToggle)
        #expect(caps.dispatcher?.projectID == CompanionDispatcher.defaultProjectID && caps.dispatcher?.newLayout == true)
        #expect(caps.dispatcher?.enabled == false, "The fixture desktop has it off")
        #expect(caps.dispatcher?.flagOn == true, "The flag graduated and the Clubhouse MCP always runs (Clubhouse #2901)")
        #expect(try ContractFixtures.json("snapshot.json")["frame"]?["payload"]?["dispatcher"] == .null, "Off: the snapshot's dispatcher is null")
    }

    @Test func theSnapshotsDispatcherShowsAsItsOwnRow() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let value = try #require(try ContractFixtures.json("snapshot-dispatcher.json")["value"])
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
        let agent = try #require(harness.store.agent(for: target))
        #expect(agent.isDispatcher && agent.name == "Dispatcher" && agent.status == .sleeping && agent.hasSession == true && agent.freeAgentMode)
        #expect(agent.orchestration == nil && agent.orchestrator == "claude-code")
        #expect(harness.host?.projects.contains { $0.id == "__dispatcher__" } == false)
        #expect(harness.store.isDispatcher(target))
    }

    @Test func dispatcherAppearanceSnapshotsApplyGoProfilePriorityAndInvalidateSender() async throws {
        let harness = try await start()
        defer { harness.stop() }
        var value = try #require(try ContractFixtures.json("snapshot-dispatcher.json")["value"])
        let original = value
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": original]))
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
        let sender = CompanionRoutedMessagePart.Sender(agentID: target.agentID, name: "Dispatcher")
        var previous = CompanionSenderResolver(agents: harness.host!.allAgents)
        let iconURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let iconVersion = "b1ff9c8ea3a780bad09b346c423d2d0e46815926879b18e841d928376a946640"
        #expect(CompanionIdentityColor.data(fromDataURL: iconURL).map(CompanionIconReference.digest) == iconVersion)
        // Synthetic appearance updates retain an emoji-only control, then exercise Go's explicit
        // profile-image priority for coexistence, image alone, and complete image removal.
        for (emoji, icon, expected): (String?, String?, CompanionAgentFace) in [
            (nil, nil, .initials("D")), ("🧭", nil, .emoji("🧭")), ("🧭", iconURL, .icon),
            (nil, iconURL, .icon), (nil, nil, .initials("D"))
        ] {
            guard case .object(var entry)? = original["agent"], case .object(var block) = original else {
                Issue.record("Missing Dispatcher fixture agent"); return
            }
            entry["color"] = .string("rose")
            entry["emoji"] = emoji.map(AnnexJSON.string) ?? .null
            entry["icon"] = icon == nil ? .null : .string("dispatcher.png")
            block["agent"] = .object(entry); value = .object(block)
            let icons: AnnexJSON = .object(icon.map { [target.agentID: .string($0)] } ?? [:])
            await harness.transport.emit(harness.snapshotEvent(["dispatcher": value, "agentIcons": icons]))
            try await harness.waitUntil {
                guard let agent = harness.store.agent(for: target) else { return false }
                return agent.color == "rose" && agent.emoji == emoji && agent.icon == CompanionIdentityColor.data(fromDataURL: icon).map { CompanionIconReference.inline(host: target.hostID, kind: .agent, id: target.agentID, data: $0) }
            }
            let row = try #require(harness.host?.dispatcher?.liveAgent)
            let resolver = CompanionSenderResolver(agents: harness.host!.allAgents)
            let identity = try #require(resolver.avatarIdentity(for: sender))
            #expect(resolver != previous, "A snapshot appearance change invalidates the identity-only resolver")
            #expect(identity == CompanionSenderIdentity(agent: row), "Pinned row and sender use the same live identity")
            #expect(identity.emoji == emoji)
            #expect(row.icon?.version == (icon == nil ? nil : iconVersion))
            #expect(identity.icon?.version == (icon == nil ? nil : iconVersion), "Expected image bytes come from the synthetic input, not the resolved face")
            #expect(identity.face == expected)
            #expect(CompanionIdentityColor.agentRGB(row.color) == CompanionRGB(hex: "#f43f5e"))
            try await harness.refreshCatalog()
            let refreshed = CompanionSenderResolver(agents: harness.host!.allAgents)
            #expect(refreshed.avatarIdentity(for: sender) == identity, "Catalog refresh must not resurrect a removed emoji or icon")
            previous = resolver
        }
    }

    @Test func dispatcherChangedFramesTurnItOffAndOn() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let value = try #require(try ContractFixtures.json("snapshot-dispatcher.json")["value"])
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        try await harness.waitUntil { harness.store.agent(for: target) != nil }

        let frames = (try ContractFixtures.json("dispatcher-changed.json")["frames"]).arrayValue
        #expect(frames.count == 2)
        let off = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frames[1]))
        await harness.transport.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(false), "flagOn": .bool(true)]))
        await harness.transport.emit(.message(off))
        try await harness.waitUntil { harness.host?.dispatcher?.enabled == false }
        #expect(harness.store.agent(for: target) == nil)

        let on = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frames[0]))
        await harness.transport.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true)]))
        await harness.transport.emit(.message(on))
        try await harness.waitUntil { harness.host?.dispatcher?.isLoading == true }
        await harness.transport.emit(harness.snapshotEvent(["dispatcher": value]))
        try await harness.waitUntil { harness.store.agent(for: target) != nil }
    }

    @Test func setEnabledReceiptsAndRefusals() async throws {
        let harness = try await start()
        defer { harness.stop() }
        for item in try ContractFixtures.cases("commands/dispatcher.setEnabled.json") {
            let body = try #require(item["response"]?["body"])
            let receipt = try body.decode(AnnexCommandReceipt.self)
            if let error = CompanionLiveService.receiptError(receipt) {
                let text = try #require((error as? LocalizedError)?.errorDescription)
                #expect(text.first?.isUppercase == true && !text.contains("_"), "\(item["name"]?.string ?? ""): \(text)")
            } else {
                #expect(receipt.result?["enabled"] != nil && receipt.result?["flagOn"] != nil, "\(item["name"]?.string ?? "")")
            }
        }
        #expect(CompanionAgentCommandError.message(code: "dispatcher_flag_off", message: nil) == CompanionDispatcher.flagOffNote)
    }

    /// Only older desktops send `dispatcher_flag_off`: current ones graduated the flag (Clubhouse #2901).
    @Test func legacyDispatcherFlagOffUsesTheDesktopsPlainMessage() {
        let message = "MCP is off. This session is still running."
        #expect(CompanionAgentCommandError.message(code: "dispatcher_flag_off", message: message) == message)
        #expect(CompanionAgentCommandError.message(code: "dispatcher_flag_off", message: nil) == CompanionDispatcher.flagOffNote)
        #expect(CompanionAgentCommandError.message(code: "dispatcher_flag_off", message: "") == CompanionDispatcher.flagOffNote)
    }

    @Test func dispatcherSettingsOfferOnlyWhatTheDesktopAllows() throws {
        let settings = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-dispatcher.json"))
        #expect(settings.name.editable == .never && settings.color.editable == .never && settings.emoji.editable == .never)
        #expect(settings.model.editable == .always && settings.orchestrator.editable == .always && settings.idleSleep.editable == .always)
        #expect(settings.orchestration == nil, "Its orchestration is locked")
        #expect(settings.freeAgentMode.editable == .always && !settings.hasLockedSettings, "Nothing waits for it to sleep")
        #expect(settings.workspace?.changes == nil && settings.workspace?.branch == nil)
    }

    @Test func orchestrationFixturesCarryTheNewFields() throws {
        let running = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-running.json"))
        let policy = try #require(running.orchestration)
        #expect(policy.sources["crossProjectHelpers"] != nil && policy.sources["connectToDispatcher"] != nil)
    }

    @Test func dispatcherRoutesWhileOffAreUnavailable() throws {
        let routes = try ContractFixtures.json("dispatcher-routes.json")
        #expect(routes["offChat"]?["response"]?["status"]?.integer == 404 && routes["offSettings"]?["response"]?["status"]?.integer == 404)
        #expect(CompanionLiveService.agentReadError(AnnexTransportError.rejected(status: 404, code: "agent_not_found")) == "This agent is no longer on the desktop.")
        #expect(routes["git"]?["response"]?["body"]?["error"]?.string == "not_git_repo")
    }

    /// Clubhouse #3146 filters on the desktop, not the phone. Chunks stay raw until the clean final reply replaces them.
    @Test func filteredGroupChatMatchesHistoryAndLiveWithoutHidingOrdinaryAgentActivity() throws {
        let fixture = try ContractFixtures.json("dispatcher-group-chat.json")
        let history = try #require(fixture["dispatcher"]?["history"]?["response"]?["body"])
        let events = history["events"].arrayValue
        #expect(events.compactMap { $0["seq"]?.integer } == [1, 2, 3, 8, 9, 10, 11])
        #expect(history["lastSeq"]?.integer == 12, "Hidden events still count in the desktop watermark")

        var live = CompanionChatProjector()
        for frame in try #require(fixture["dispatcher"]?["frames"]).arrayValue {
            let envelope = try frame.decode(AnnexEnvelope.self)
            #expect(envelope.type == "chat:event")
            let event = try #require(envelope.payload?["event"])
            live.apply(event)
            if event["type"]?.string == "agent_message_chunk" {
                guard case .message(let chunk)? = live.items.last else { Issue.record("Missing streamed reply"); return }
                #expect(chunk.text == "On it (task_id=t_1abcdef)." && chunk.isStreaming)
            }
            if event["type"]?.string == "turn_ended" {
                #expect(live.status == .idle && live.turnStartedAt == nil)
            }
        }
        var archived = CompanionChatProjector()
        for event in events { archived.apply(event) }
        #expect(live.items == archived.items)
        #expect(live.lastSequence == 11 && live.status == .idle)
        #expect(live.items.map(\.id) == ["message:msg_you", "message:amsg_1", "message:msg_news"],
                "No tool, thought, subagent, hand-off or turn-footer rows")
        let messages = try live.items.map { item -> CompanionMessage in
            guard case .message(let message) = item else { throw AnnexTransportError.malformedResponse }
            return message
        }
        try #require(messages.count == 3)
        #expect(messages[0].display == .you("Tell me when checkout is fixed."))
        #expect(messages[1].text == "On it." && !messages[1].isStreaming)
        #expect(messages[2].display == .others([
            .init(sender: .init(agentID: "durable_sleepy", name: "brave-otter"), text: "Checkout is fixed.")
        ]), "Display the cleaned routed part, not the raw task ids, routing tags or Clubhouse update")

        let ordinaryEvents = try #require(fixture["agent"]?["history"]?["response"]?["body"]?["events"]).arrayValue
        #expect(ordinaryEvents.count == 12)
        #expect(ordinaryEvents.contains { $0["type"]?.string == "agent_thought" })
        #expect(ordinaryEvents.contains { $0["type"]?.string == "tool_call" })
        var ordinary = CompanionChatProjector()
        for event in ordinaryEvents { ordinary.apply(event) }
        #expect(ordinary.items.contains { if case .tool = $0 { true } else { false } })
        #expect(ordinary.items != live.items, "The ordinary agent's stream remains unfiltered")
    }
}
