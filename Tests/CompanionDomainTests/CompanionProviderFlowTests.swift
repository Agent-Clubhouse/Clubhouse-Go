import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Synthetic workflow edge cases supplement the complete canonical fixtures pinned in SOURCE.json.
@Suite @MainActor struct CompanionProviderFlowTests {
    static let capability: AnnexJSON = .object(["version": .integer(1), "preview": .string("agent.providerPreview"), "change": .string("agent.providerChange"), "stoppedAcknowledgment": .bool(true), "strictStart": .bool(true)])
    static func catalog(_ status: String) -> AnnexJSON { .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string(status), "orchestrator": .string("claude-code")])]) }
    static func result(provider: String = "codex-cli", saved: String = "claude-code", status: String? = nil, blocked: String? = nil) -> AnnexJSON {
        var value: [String: AnnexJSON] = [
            "agentId": .string("agent"), "savedProvider": .string(saved), "activeProvider": .null,
            "provider": .string(provider), "state": .string("sleeping"), "available": .bool(true), "availabilityMeaning": .string("local_cli_only"),
            "instructions": .string("equivalent"), "instructionScope": .string("native_primary_only"), "targetRuntime": .string("chat"),
            "blocked": blocked.map(AnnexJSON.string) ?? .null, "canSave": .bool(blocked == nil), "historyRetained": .bool(true), "contextTransferred": .bool(false),
            "nextStart": .string(status == "changed" || provider != saved ? "new_session" : "resume_requires_validation"), "settingsReset": .array([]),
        ]
        if status != "changed" { value["expectedState"] = .string("opaque-\(saved)") }
        if let status { value["status"] = .string(status) }
        return .object(value)
    }
    func harness(status: String = "sleeping", supported: Bool = true) async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start { transport in
            await transport.setAgents(Self.catalog(status))
            await transport.addCommands(["agent.stop", "agent.update", "agent.providerPreview", "agent.providerChange"])
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            if supported { await transport.setFeature("providerControl", Self.capability) }
        }
    }
    func select(_ flow: CompanionProviderFlow, _ harness: LiveServiceHarness, provider: String = "codex-cli") async {
        await harness.transport.enqueue(.completed(Self.result(provider: provider)))
        await flow.select(provider)
        #expect(flow.canSave && !flow.canStart)
    }

    @Test(arguments: ["codex-cli", "claude-code"])
    func openingAndSelectingNeverSaveOrStartAndStartNewIsSeparate(_ provider: String) async throws {
        let harness = try await harness(); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        #expect(await harness.transport.executed.isEmpty)
        await select(flow, harness, provider: provider)
        #expect(await harness.transport.executed.map(\.type) == ["agent.providerPreview"])
        await harness.transport.enqueue(.completed(Self.result(provider: provider, saved: provider, status: provider == "claude-code" ? "already_selected" : "changed")))
        await harness.transport.enqueue(.completed(Self.result(provider: provider, saved: provider)))
        await flow.save()
        try await harness.waitUntil { harness.host?.connection == .connected }
        if flow.preview == nil { await flow.refresh() }
        #expect(flow.savedProvider == provider && flow.canStart && !flow.blocksMutations)
        #expect(await harness.transport.executed.map(\.type) == ["agent.providerPreview", "agent.providerChange", "agent.providerPreview"])
        #expect(!flow.startRequested)
        await harness.transport.enqueue(.completed(.object(["agentId": .string("agent"), "started": .bool(true)])))
        await flow.startNew()
        #expect(flow.startRequested && !flow.canStart)
        let start = try #require(await harness.transport.executed.last)
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: start.encoded())
        #expect(payload["type"]?.string == "agent.start" && payload["expectedProvider"]?.string == provider && payload["resume"] == .bool(false))
        #expect(payload["expectedSessionId"] == nil && payload["message"] == nil)
    }

    @Test func staleAndUnknownRefusalsClearPreviewWithoutStarting() async throws {
        let harness = try await harness(); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        for code in ["stale_state", "future_reason"] {
            await select(flow, harness)
            await harness.transport.enqueue(.rejected(code: code, message: "opaque material must never be displayed"))
            await flow.save()
            #expect(!flow.blocksMutations && flow.preview == nil && !flow.canStart && !flow.canSave)
            #expect(flow.error == CompanionProviderReason.message(code))
        }
        #expect(await harness.transport.executed.allSatisfy { $0.type != "agent.start" })
    }

    @Test func lostSaveRetainsLockAcrossReopeningAndReplaysSameCommand() async throws {
        let harness = try await harness(); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        await select(flow, harness)
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost")))
        await flow.save()
        #expect(flow.blocksMutations && !harness.store.canOperate(harness.target) && !harness.store.mayWake(harness.target))
        #expect(harness.store.providerFlow(for: harness.target) === flow)
        await flow.select("claude-code"); await flow.startNew(); await flow.save()
        #expect(await harness.transport.executed.count == 2)
        await harness.transport.enqueue(.completed(Self.result(saved: "codex-cli", status: "changed")))
        await harness.transport.enqueue(.completed(Self.result(saved: "codex-cli")))
        await flow.checkPreviousResult()
        let commands = await harness.transport.executed
        #expect(commands[1].commandID == commands[2].commandID)
        #expect(try commands[1].encoded() == commands[2].encoded())
        #expect(!flow.blocksMutations && flow.savedProvider == "codex-cli")
    }

    @Test(arguments: [false, true]) func unknownWriteNeverReplaysAcrossRestartOrExpiredWindow(expired: Bool) async throws {
        let harness = try await harness(); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        await select(flow, harness)
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost"))); await flow.save()
        if expired {
            await harness.transport.setCapability("idempotency", .object(["scope": .string("client"), "maxEntries": .integer(256), "ttlMs": .integer(0)]))
        } else { await harness.transport.setEpoch("restarted") }
        try await harness.refreshCatalog()
        await flow.checkPreviousResult()
        #expect(await harness.transport.executed.count == 2)
        #expect(flow.blocksMutations && !flow.canStart)
        #expect(flow.error?.contains("outcome is still unknown") == true)
    }

    @Test func lostStartReplaysOnlyItsOriginalExplicitStart() async throws {
        let harness = try await harness(); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        await select(flow, harness)
        await harness.transport.enqueue(.completed(Self.result(saved: "codex-cli", status: "changed")))
        await harness.transport.enqueue(.completed(Self.result(saved: "codex-cli")))
        await flow.save()
        try await harness.waitUntil { harness.host?.connection == .connected }
        if flow.preview == nil { await flow.refresh() }
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "lost-start")))
        await flow.startNew()
        #expect(flow.blocksMutations && !flow.startRequested)
        await flow.startNew(); await flow.save()
        await harness.transport.enqueue(.completed(.object(["agentId": .string("agent"), "started": .bool(true)])))
        await flow.checkPreviousResult()
        let starts = await harness.transport.executed.filter { $0.type == "agent.start" }
        #expect(starts.count == 2 && starts[0].commandID == starts[1].commandID)
        #expect(try starts[0].encoded() == starts[1].encoded())
        #expect(flow.startRequested && !flow.blocksMutations)
    }

    @Test func strictStopRequestedAloneStaysPendingAndReplaysForAcknowledgment() async throws {
        let harness = try await harness(status: "running"); defer { harness.stop() }
        await harness.transport.enqueue(.completed(.object(["agentId": .string("agent"), "stopRequested": .bool(true)])))
        await harness.store.sleepAgent(harness.target)
        await harness.transport.setAgents(Self.catalog("sleeping")); try await harness.refreshCatalog()
        #expect(harness.store.sleepRequests.contains(harness.target))
        await harness.transport.enqueue(.completed(.object(["agentId": .string("agent"), "stopRequested": .bool(true), "stopped": .bool(true), "state": .string("sleeping")])))
        await harness.store.refreshSleepState(harness.target)
        let commands = await harness.transport.executed
        #expect(commands.count == 2 && commands[0].commandID == commands[1].commandID)
        #expect(!harness.store.sleepRequests.contains(harness.target))
    }

    @Test func strictSleepWaitsForAcknowledgmentEvenWhenCatalogIsAlreadySleeping() async throws {
        let harness = try await harness(status: "running"); defer { harness.stop() }
        let receipt = try AnnexJSON.object(["version": .integer(1), "epoch": .string("epoch"), "status": .string("completed"),
            "result": .object(["agentId": .string("agent"), "stopRequested": .bool(true), "stopped": .bool(true), "state": .string("sleeping")])]).decode(AnnexCommandReceipt.self)
        await harness.transport.enqueue(.heldReceipt(receipt))
        let task = Task { await harness.store.sleepAgent(harness.target) }
        try await harness.waitUntil { await harness.transport.executed.count == 1 }
        await harness.transport.setAgents(Self.catalog("sleeping")); try await harness.refreshCatalog()
        #expect(harness.store.sleepRequests.contains(harness.target) && !harness.store.canOperate(harness.target))
        await harness.transport.releaseCommand(); await task.value
        #expect(!harness.store.sleepRequests.contains(harness.target))
        let command = try #require(await harness.transport.executed.first)
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())["waitForStopped"] == .bool(true))
    }

    @Test func unsupportedDesktopCannotSendGuidedCommands() async throws {
        let harness = try await harness(supported: false); defer { harness.stop() }
        let flow = harness.store.providerFlow(for: harness.target)
        await flow.select("codex-cli")
        do { _ = try await harness.service.providerPreview(harness.target, provider: "codex-cli"); Issue.record("Must refuse") } catch {}
        #expect(await harness.transport.executed.isEmpty)
    }
}
