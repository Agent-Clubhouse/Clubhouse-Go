import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor @Suite(.serialized) struct CompanionIdentityRefreshTests {
    private let dispatcher = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "dispatcher")
    private var feature: AnnexJSON { .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true), "projectId": .string("__dispatcher__")]) }
    private var entry: AnnexJSON { .object(["enabled": .bool(true), "flagOn": .bool(true), "agent": .object(["id": .string("dispatcher"), "name": .string("Dispatcher")])]) }
    private func start() async throws -> LiveServiceHarness {
        let h = try await LiveServiceHarness.start { t in await t.setFeature("dispatcher", feature) }
        await h.transport.emit(h.snapshotEvent(["dispatcher": entry]))
        try await h.waitUntil { h.store.agent(for: dispatcher) != nil }
        return h
    }

    @Test func resumeAndRelocationKeepEveryPublishedIdentityAndLongChat() async throws {
        let h = try await start()
        defer { h.stop() }
        let events = (1...2000).map { LiveServiceHarness.chatEvent("d", sequence: Int64($0 + 1), type: "agent_message", data: ["messageId": .string("m\($0)"), "text": .string(String(repeating: "chat ", count: 40))]) }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "d", events: events))
        await h.store.load(dispatcher)
        let original = h.store.conversation(for: dispatcher)
        let reads = await h.transport.readRoutes.filter { $0.name == "chat" }.count
        await h.service.suspend()
        let stream = h.service.events()
        let observer = Task { @MainActor in
            var missing = 0
            for await event in stream {
                if case .hosts(let hosts) = event, hosts.first?.agent(for: dispatcher) == nil { missing += 1 }
                if Task.isCancelled { break }
            }
            return missing
        }
        h.service.prepareResume = {
            await h.transport.failNextConnect(.disconnected)
            await h.service.register(.init(host: try! LiveServiceHarness.trustedHost(), alias: "Relocated", transport: h.transport))
            return [LiveServiceHarness.hostID]
        }
        await h.service.resume()
        try await h.waitUntil { h.host?.name == "Relocated" }
        #expect(h.store.agent(for: dispatcher) != nil)
        #expect(h.store.agent(for: h.target) != nil)
        #expect(h.store.conversation(for: dispatcher).items == original.items)
        #expect(h.store.conversation(for: dispatcher).isLoaded)
        #expect(!h.store.canOperate(dispatcher))
        await h.store.load(dispatcher)
        #expect(await h.transport.readRoutes.filter { $0.name == "chat" }.count == reads, "Returning to a cached chat must not reread its full history")
        observer.cancel()
        #expect(await observer.value == 0, "No host publication may claim the known Dispatcher disappeared")
    }

    @Test func failedCapabilitiesReadKeepsDispatcherAndChat() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(dispatcher)
        await h.transport.failRead("capabilities", .disconnected)
        try await h.refreshCatalog()
        #expect(h.store.agent(for: dispatcher) != nil)
        #expect(h.store.conversation(for: dispatcher).isLoaded)
    }

    @Test func failedCatalogReadKeepsAllIdentities() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.failProjects(.disconnected)
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { if case .failed = h.host?.connection { true } else { false } }
        #expect(h.store.agent(for: dispatcher) != nil && h.store.agent(for: h.target) != nil)
        #expect(!h.store.canOperate(h.target))
    }

    @Test(arguments: [AnnexJSON.object([:]), .object(["projects": .array([])]), .object(["projects": .array([.object(["id": .string("project")])]), "agents": .object([:])])])
    func partialCatalogKeepsKnownAgents(payload: AnnexJSON) async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.emit(.message(.init(type: "snapshot", payload: payload)))
        // A later event serves as a processing barrier.
        await h.transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 1)))
        try await h.waitUntil { h.host?.connection == .reconnecting }
        #expect(h.store.agent(for: h.target) != nil)
        #expect(h.store.projectEntries.count == 1)
        #expect(h.store.allAgents.count == 2)
    }

    @Test func snapshotBeforeCapabilitiesArriveKeepsDispatcher() async throws {
        let h = try await LiveServiceHarness.start { t in await t.failRead("capabilities", .disconnected) }
        defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["dispatcher": entry]))
        await h.transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 1)))
        try await h.waitUntil { h.host?.connection == .reconnecting }
        #expect(h.store.agent(for: dispatcher) != nil, "Unknown capabilities do not mean Dispatcher is off")
    }

    @Test func missingDispatcherFieldKeepsIdentityButExplicitNullTurnsItOff() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.emit(h.snapshotEvent([:]))
        await h.transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 1)))
        try await h.waitUntil { h.host?.connection == .reconnecting }
        #expect(h.store.agent(for: dispatcher) != nil)
        await h.transport.emit(h.snapshotEvent(["dispatcher": .null]))
        try await h.waitUntil { h.store.agent(for: dispatcher) == nil }
        #expect(h.host?.dispatcher?.enabled == false)
    }

    @Test func completeSnapshotRemovesMissingAgentsAndProjects() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["agents": .object(["project": .array([])])]))
        try await h.waitUntil { h.store.agent(for: h.target) == nil }
        #expect(h.store.projectEntries.count == 1)
        await h.transport.emit(h.snapshotEvent(["projects": .array([]), "agents": .object([:])]))
        try await h.waitUntil { h.store.projectEntries.isEmpty }
    }

    @Test func authoritativeDeletionStillRemovesAgent() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setAgents(.array([]))
        try await h.refreshCatalog()
        #expect(h.store.agent(for: h.target) == nil)
        #expect(h.store.agent(for: dispatcher) != nil)
    }

    @Test(arguments: [false, true]) func dispatcherOffOrFlagOffClearsChat(flagOff: Bool) async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(dispatcher)
        await h.transport.emit(.message(.init(type: "dispatcher:changed", payload: .object(["enabled": .bool(flagOff), "flagOn": .bool(!flagOff)]))))
        try await h.waitUntil { h.store.agent(for: dispatcher) == nil }
        #expect(!h.store.conversation(for: dispatcher).isLoaded)
    }

    @Test func forgottenHostClearsChatAndIdentity() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(h.target)
        h.service.remove(hostID: LiveServiceHarness.hostID)
        try await h.waitUntil { h.store.hosts.isEmpty }
        #expect(h.store.agent(for: h.target) == nil)
        #expect(!h.store.conversation(for: h.target).isLoaded)
    }
}
