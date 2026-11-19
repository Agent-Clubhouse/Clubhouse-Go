import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Original c4cdbacc fixtures stay frozen. These scenario replies echo ONLY dynamic
/// request IDs/epoch, and Start's already-reviewed expected state; no real network.
private func providerV2Fixtures() throws -> AnnexJSON {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ClubhouseTransportTests/Fixtures/ProviderControlV2/provider-control-v2.json")
    return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: path))
}
private func providerV2Caps(_ epoch: String = "00000000-0000-4000-8000-000000000001") throws -> AnnexJSON {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ClubhouseTransportTests/Fixtures/ProviderControlV2/capabilities.json")
    let original = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: path))
    let body = try #require(original["response"]?["body"])
    let keys = ["version", "controlAuth", "controlAvailable", "commands", "idempotency", "providerControl", "providerControlV2", "providerStartV2", "agentSettings"]
    var fields = Dictionary(uniqueKeysWithValues: keys.compactMap { key in body[key].map { (key, $0) } })
    fields["epoch"] = .string(epoch)
    return .object(fields)
}
private func changed(_ value: AnnexJSON, _ key: String, _ replacement: AnnexJSON) throws -> AnnexJSON {
    guard case .object(var object) = value else { throw AnnexTransportError.malformedResponse }
    object[key] = replacement; return .object(object)
}

private actor ProviderV2IO: AnnexIO {
    let fixtures: AnnexJSON
    var caps: AnnexJSON
    let lost: String?
    private(set) var posts: [AnnexJSON] = []
    private(set) var saved = false
    private var overrides: [String: AnnexJSON] = [:]
    init(lost: String?) throws { self.lost = lost; fixtures = try providerV2Fixtures(); caps = try providerV2Caps() }
    func setEpoch(_ epoch: String) throws { caps = try providerV2Caps(epoch) }
    func override(_ kind: String, body: AnnexJSON) { overrides[kind] = body }
    func setCapabilities(_ value: AnnexJSON) { caps = value }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        guard request.httpMethod == "POST" else { return .init(status: 200, data: try JSONEncoder().encode(caps)) }
        let command = try JSONDecoder().decode(AnnexJSON.self, from: try #require(request.httpBody))
        posts.append(command)
        let type = try #require(command["type"]?.string)
        let key: String
        switch type {
        case "agent.providerPreview": key = saved ? "savedDefaultsPreview" : "preview"
        case "agent.providerChange": saved = true; key = "applied"
        case "agent.start": key = "started"
        default: throw AnnexTransportError.malformedResponse
        }
        if type == lost { throw URLError(.networkConnectionLost) }
        var body = try #require(overrides[type] ?? fixtures[key]?["body"])
        body = try changed(changed(body, "commandId", try #require(command["commandId"])), "epoch", try #require(command["epoch"]))
        if type == "agent.start" {
            let result = try #require(body["result"]), contract = try #require(result["contract"])
            var target = try #require(contract["target"])
            target = try changed(changed(target, "commandId", try #require(command["commandId"])), "hostEpoch", try #require(command["epoch"]))
            let echoed = try changed(changed(contract, "configured", try #require(command["expectedNextWake"])), "target", target)
            body = try changed(body, "result", changed(result, "contract", echoed))
        }
        return .init(status: body["status"] == .string("completed") ? 200 : 409, data: try JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
    func mutations() -> [AnnexJSON] { posts.filter { ["agent.providerChange", "agent.start"].contains($0["type"]?.string ?? "") } }
}

private actor ProviderV2Transport: AnnexTransporting {
    let catalog: ScriptedAnnexTransport
    var commands: AnnexTransport
    init(catalog: ScriptedAnnexTransport, commands: AnnexTransport) { self.catalog = catalog; self.commands = commands }
    func replaceCommands(_ commands: AnnexTransport) { self.commands = commands }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> { await catalog.events() }
    func connect() async throws { _ = try await commands.read(.capabilities); try await catalog.connect() }
    func disconnect() async { await commands.disconnect(); await catalog.disconnect() }
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON { try await catalog.read(route) }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt { try await commands.execute(command) }
}

@Suite @MainActor struct CompanionProviderV2TransportTests {
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Provider fixture did not reach its expected state"); throw AnnexTransportError.disconnected
    }
    private func commands(host: TrustedAnnexHost, io: ProviderV2IO) async throws -> AnnexTransport {
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "synthetic-only"), for: host.hostID)
        return AnnexTransport(host: host, credentials: credentials, io: io)
    }
    private func setup(lost: String?) async throws -> (CompanionStore, CompanionLiveService, ProviderV2IO, ProviderV2Transport, ScriptedAnnexTransport, CompanionTarget) {
        let io = try ProviderV2IO(lost: lost), catalog = await ScriptedAnnexTransport()
        await catalog.setRead("capabilities", try providerV2Caps())
        await catalog.setAgents(.array([.object(["id": .string("durable_term"), "name": .string("Synthetic"), "status": .string("sleeping"), "orchestrator": .string("claude-code")])]))
        let host = try LiveServiceHarness.trustedHost()
        let transport = ProviderV2Transport(catalog: catalog, commands: try await commands(host: host, io: io))
        let service = CompanionLiveService(), store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Synthetic", transport: transport))
        let target = CompanionTarget(hostID: host.hostID, projectID: "project", agentID: "durable_term")
        try await wait { store.host(for: target)?.connection == .connected }
        return (store, service, io, transport, catalog, target)
    }

    @Test(arguments: ["agent.providerChange", "agent.start"], [false, true])
    func lostMutationNeverRedispatchesAfterReopenReplacementReconnectOrEqualRead(lost: String, changedEpoch: Bool) async throws {
        let (store, service, io, transport, catalog, target) = try await setup(lost: lost)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli")
        #expect(flow.canApply && !flow.canStart)
        await flow.apply()
        if lost == "agent.start" {
            #expect(flow.canStart && flow.lastApply?.value.contract.saved.model.source == .providerDefault)
            await flow.startNew()
        }
        #expect(flow.blocksMutations && !flow.canApply && !flow.canStart && !store.mayWake(target))
        let before = await io.mutations()
        #expect(before.count == (lost == "agent.start" ? 2 : 1))
        let reopened = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        #expect(reopened === flow)
        let originalHeld = flow.lastApply
        await flow.refresh()
        #expect(flow.reportedSaved?.provider == "codex-cli" && flow.blocksMutations, "Equal fresh state is not a receipt")
        // Replace the actual production transport: its command cache starts EMPTY.
        if changedEpoch {
            let epoch = "00000000-0000-4000-8000-000000000002"
            try await io.setEpoch(epoch); await catalog.setRead("capabilities", try providerV2Caps(epoch))
        }
        await transport.replaceCommands(try await commands(host: LiveServiceHarness.trustedHost(), io: io))
        await service.reconnect(hostID: target.hostID)
        let expectedEpoch = changedEpoch ? "00000000-0000-4000-8000-000000000002" : "00000000-0000-4000-8000-000000000001"
        try await wait { store.host(for: target)?.connection == .connected && store.host(for: target)?.controlEpoch == expectedEpoch }
        await reopened.refresh()
        #expect(reopened.reportedSaved?.provider == "codex-cli" && reopened.blocksMutations)
        reopened.reviewHeldResult(); await reopened.select("claude-code"); await reopened.apply(); await reopened.startNew()
        #expect(await io.mutations() == before, "No extra mutation request, regardless of server/transport cache state")
        let witness = try await service.providerPreviewV2(target, provider: "codex-cli")
        do { _ = try await service.applyProviderV2(target, preview: witness, clientCommandID: "new-id-is-not-recovery"); Issue.record("Unresolved target must stay locked") } catch {}
        if let applied = originalHeld {
            do { _ = try await service.startProviderV2(target, applied: applied, witness: witness, clientCommandID: "another-start-is-not-recovery"); Issue.record("Unknown Start must stay locked") } catch {}
        }
        #expect(await io.mutations() == before && reopened.blocksMutations)
        #expect(before.allSatisfy { $0["contractVersion"] == .integer(2) && $0["model"] == nil && $0["effort"] == nil })
        #expect(Set(before.compactMap { $0["commandId"]?.string }).count == before.count)
    }

    @Test func successfulApplyAndSeparateStartKeepFullStateAndHistoricalCreation() async throws {
        let (store, service, io, _, _, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli"); await flow.apply()
        #expect(flow.lastApply != nil && flow.lastStart == nil && flow.canStart)
        let apply = try #require(await io.mutations().first)
        #expect(apply["expectedState"] == .string("000000000000000000000000000000000000000000000000000000000000000b"))
        await flow.startNew()
        let mutations = await io.mutations(), start = try #require(mutations.last)
        #expect(mutations.count == 2 && start["type"] == .string("agent.start"))
        #expect(start["commandId"] != apply["commandId"] && start["resume"] == .bool(false))
        #expect(start["expectedState"] == .string("000000000000000000000000000000000000000000000000000000000000000a"))
        #expect(start["expectedNextWake"] == (try flow.lastApply?.value.contract.saved.json))
        #expect(flow.lastStart?.start.wasObserved == true && !flow.canStart && !flow.blocksMutations)
        #expect(flow.lastStart?.running.model == nil && flow.lastStart?.running.effort == nil)
    }
    @Test func changedWitnessTokenBlocksStartEvenWithEqualSavedValues() async throws {
        let (store, service, io, _, _, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli"); await flow.apply()
        let fixture = try providerV2Fixtures(), body = try #require(fixture["savedDefaultsPreview"]?["body"])
        let result = try changed(#require(body["result"]), "expectedState", .string("a-new-token-is-not-the-Apply-token"))
        await io.override("agent.providerPreview", body: try changed(body, "result", result))
        await flow.startNew()
        #expect(await io.mutations().count == 1 && flow.lastStart == nil && !flow.canStart)
        #expect(flow.reportedSaved == flow.lastApply?.value.contract.saved)
    }

    @Test(arguments: ["target", "saved", "selection"])
    func contradictoryApplyReceiptStaysUnknownAndCannotAuthorizeStart(field: String) async throws {
        let (store, service, io, _, _, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli")
        let fixture = try providerV2Fixtures(), body = try #require(fixture["applied"]?["body"])
        let result = try #require(body["result"]), contract = try #require(result["contract"])
        let wrong: AnnexJSON
        switch field {
        case "target": wrong = .object(["agentId": .string("different-agent")])
        case "selection": wrong = .object(["contractVersion": .integer(2), "effort": .null])
        default: wrong = try #require(fixture["preview"]?["body"]?["result"]?["contract"]?["current"])
        }
        let altered = try changed(result, "contract", changed(contract, field, wrong))
        await io.override("agent.providerChange", body: try changed(body, "result", altered))
        await flow.apply(); await flow.startNew()
        #expect(flow.blocksMutations && flow.lastApply == nil && flow.lastStart == nil)
        #expect(await io.mutations().count == 1)
    }

    @Test func advertisedMalformedV2CannotDowngradeToV1OrGenericSettings() async throws {
        let (store, service, io, _, catalog, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let malformed = try changed(providerV2Caps(), "providerControlV2", .string("unrecognized"))
        await catalog.setRead("capabilities", malformed); await io.setCapabilities(malformed)
        await service.reconnect(hostID: target.hostID)
        try await wait { store.host(for: target)?.connection == .connected && store.host(for: target)?.providerApplyV2 == nil }
        #expect(store.host(for: target)?.providerV2Advertised == true)
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli"); await flow.apply(); await flow.startNew()
        do { _ = try await service.providerPreview(target, provider: "codex-cli"); Issue.record("No V1 downgrade") } catch {}
        #expect(await io.posts.isEmpty && !flow.canApply && !flow.canStart)
    }

    @Test func separateMissingStartCapabilityAllowsApplyButNeverStart() async throws {
        let (store, service, io, _, catalog, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        guard case .object(var fields) = try providerV2Caps() else { throw AnnexTransportError.malformedResponse }
        fields["providerStartV2"] = nil
        await catalog.setRead("capabilities", .object(fields)); await io.setCapabilities(.object(fields))
        await service.reconnect(hostID: target.hostID)
        try await wait { store.host(for: target)?.connection == .connected && store.host(for: target)?.providerStartV2 == nil }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli"); await flow.apply(); await flow.startNew()
        #expect(flow.lastApply != nil && !flow.canStart && flow.lastStart == nil)
        #expect(await io.mutations().count == 1)
    }

    @Test(arguments: ["refused", "changed-token", "contradictory-saved"])
    func applyReceiptCannotEnableStartBeforeAFreshMatchingWitness(failure: String) async throws {
        let (store, service, io, _, _, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli")
        let fixture = try providerV2Fixtures()
        var body = try #require(fixture["savedDefaultsPreview"]?["body"])
        if failure == "refused" {
            body = .object(["version": .integer(1), "status": .string("rejected"), "error": .object(["code": .string("stale_state"), "message": .string("synthetic read refusal")])])
        } else {
            var result = try #require(body["result"])
            if failure == "changed-token" {
                result = try changed(result, "expectedState", .string("different-from-Apply-token"))
            } else {
                let contract = try #require(result["contract"])
                let old = try #require(fixture["preview"]?["body"]?["result"]?["contract"]?["current"])
                result = try changed(result, "contract", changed(contract, "saved", old))
            }
            body = try changed(body, "result", result)
        }
        await io.override("agent.providerPreview", body: body)
        await flow.apply()
        #expect(flow.lastApply != nil && !flow.canStart && !flow.blocksMutations)
        await flow.startNew()
        #expect(await io.mutations().count == 1 && flow.lastStart == nil)
    }

    @Test(arguments: [false, true])
    func reconnectCannotRestoreStartReadinessWithoutANewMatchingWitness(changedEpoch: Bool) async throws {
        let (store, service, io, _, catalog, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli"); await flow.apply()
        #expect(flow.canStart)
        let nextEpoch = changedEpoch ? "00000000-0000-4000-8000-000000000002" : "00000000-0000-4000-8000-000000000001"
        try await io.setEpoch(nextEpoch); await catalog.setRead("capabilities", try providerV2Caps(nextEpoch))
        await service.reconnect(hostID: target.hostID)
        try await wait { store.host(for: target)?.connection == .connected && store.host(for: target)?.controlEpoch == nextEpoch }
        #expect(!flow.canStart, "A witness from the previous connection cannot enable Start")
        await flow.refresh()
        #expect(flow.canStart == !changedEpoch, "Only a new matching witness and the original Apply epoch may restore readiness")
        #expect(await io.mutations().count == 1)
    }

    @Test(arguments: [false, true], ["unsupported", "malformed", "missing"])
    func sameEpochCapabilityChangeInvalidatesManagedAuthorityWithoutReconnect(afterApply: Bool, platform: String) async throws {
        let (store, service, io, _, catalog, target) = try await setup(lost: nil)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let flow = store.providerV2Flow(for: target, requestedRuntime: "terminal")
        await flow.select("codex-cli")
        let originalWitness = try #require(flow.preview)
        #expect(originalWitness.value.preview.outcome.instructionScope == "managed_composition")
        #expect(originalWitness.value.delivery?.isAdmittedUnloaded == true)
        if afterApply {
            await flow.apply()
            #expect(flow.lastApply?.value.outcome.instructionScope == "managed_composition" && flow.canStart)
        }
        else { #expect(flow.canApply) }
        let before = await io.mutations(), originalCaps = try providerV2Caps()
        guard case .object(var applyCap) = originalCaps["providerControlV2"] else { throw AnnexTransportError.malformedResponse }
        switch platform {
        case "missing": applyCap["managedPlatform"] = nil
        case "malformed": applyCap["managedPlatform"] = .string("unsupported-shape")
        default:
            applyCap["managedPlatform"] = .object(["current": .string("win32"), "supported": .bool(false), "supportedPlatforms": .array([.string("darwin"), .string("linux")]), "refusalCode": .string("managed_platform_unsupported")])
        }
        let unsupported = try changed(originalCaps, "providerControlV2", .object(applyCap))
        await catalog.setRead("capabilities", unsupported); await io.setCapabilities(unsupported)
        // Direct read refresh, no reconnect/resync; review generation must stay the SAME.
        try await service.refreshSleepState(target)
        try await wait { store.host(for: target)?.providerApplyV2?.managedPlatform?.permitsManaged != true }
        #expect(store.host(for: target)?.providerStartV2?.isSupported == true)
        #expect(!flow.canStart && !flow.canApply)
        #expect(!service.providerV2WitnessIsCurrent(originalWitness, starting: false))
        let freshUnsupported = try await service.providerPreviewV2(target, provider: "codex-cli")
        #expect(freshUnsupported.generation == originalWitness.generation && freshUnsupported.epoch == originalWitness.epoch)
        #expect(!freshUnsupported.value.permitsApply(capability: freshUnsupported.capability))
        await flow.startNew(); await flow.apply()
        #expect(await io.mutations() == before)
        await catalog.setRead("capabilities", originalCaps); await io.setCapabilities(originalCaps)
        try await service.refreshSleepState(target)
        await flow.refresh()
        #expect(afterApply ? flow.canStart : flow.canApply, "Only a fresh matching valid witness restores this known operation")
        #expect(await io.mutations() == before)
        // With managed support absent, a FRESH independently valid native preview still permits editing.
        await catalog.setRead("capabilities", unsupported); await io.setCapabilities(unsupported)
        try await service.refreshSleepState(target)
        let fixture = try providerV2Fixtures()
        await io.override("agent.providerPreview", body: try #require(fixture["inheritedPreview"]?["body"]))
        await flow.select("claude-code")
        #expect(flow.preview?.value.preview.outcome.instructionScope == "native_primary_only" && flow.canApply)
        #expect(await io.mutations() == before)
    }

}
