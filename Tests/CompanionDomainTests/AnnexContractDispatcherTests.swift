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
        #expect(caps.dispatcher?.enabled == false && caps.dispatcher?.flagOn == false, "The fixture desktop has it off")
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

    @Test func dispatcherSettingsOfferOnlyWhatTheDesktopAllows() throws {
        let settings = try CompanionAgentSettings(json: try ContractFixtures.body("agent-settings-dispatcher.json"))
        #expect(settings.name.editable == .never && settings.color.editable == .never && settings.emoji.editable == .never)
        #expect(settings.persona.editable == .never && settings.clubhouseMode.editable == .never)
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
}
