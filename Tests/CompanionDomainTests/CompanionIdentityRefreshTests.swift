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
        let events = (1...2000).map { LiveServiceHarness.chatEvent("d", sequence: Int64($0 + 1), type: "agent_message", data: ["messageId": .string("m\($0)"), "text": .string("chat")]) }
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
        let keptChat = h.store.conversation(for: dispatcher).items == original.items
        #expect(keptChat)
        #expect(h.store.conversation(for: dispatcher).isLoaded)
        #expect(!h.store.canOperate(dispatcher))
        let clock = ContinuousClock()
        let started = clock.now
        await h.store.load(dispatcher)
        let returnDuration = clock.now - started
        let afterReads = await h.transport.readRoutes.filter { $0.name == "chat" }.count
        print("Dispatcher cached lookup: rows=\(original.items.count), extraFullHistoryReads=\(afterReads - reads), returnDuration=\(returnDuration)")
        #expect(afterReads == reads, "Returning to a cached chat must not reread its full history")
        observer.cancel()
        #expect(await observer.value == 0, "No host publication may claim the known Dispatcher disappeared")
        // ConversationView explicitly forces this resync on navigation/connection changes. Retaining
        // the cache avoids blanking, but does not eliminate that required full history read.
        #expect(h.store.conversation(for: dispatcher).requiresResync)
        await h.store.load(dispatcher, force: h.store.conversation(for: dispatcher).requiresResync)
        let uiReads = await h.transport.readRoutes.filter { $0.name == "chat" }.count - afterReads
        #expect(uiReads == 1)
        print("Dispatcher UI-required resync: fullHistoryReads=\(uiReads), retainedRows=\(h.store.conversation(for: dispatcher).items.count)")
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

    @Test(arguments: [AnnexJSON.object([:]), .object(["enabled": .bool(true), "flagOn": .bool(true)]), .object(["enabled": .bool(true), "agent": .null]), .string("invalid")])
    func incompleteDispatcherEntryKeepsKnownIdentity(value: AnnexJSON) async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["dispatcher": value]))
        await h.transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 1)))
        try await h.waitUntil { h.host?.connection == .reconnecting }
        #expect(h.store.agent(for: dispatcher) != nil)
    }

    @Test func explicitDispatcherOffObjectClearsIdentityAndChat() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(dispatcher)
        await h.transport.emit(h.snapshotEvent(["dispatcher": .object(["enabled": .bool(false), "flagOn": .bool(true)])]))
        try await h.waitUntil { h.host?.dispatcher?.enabled == false }
        #expect(!h.store.conversation(for: dispatcher).isLoaded)
    }

    @Test func completeSnapshotRemovesMissingAgentsAndProjects() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["agents": .object(["project": .array([])])]))
        try await h.waitUntil { h.store.agent(for: h.target) == nil }
        #expect(h.store.projectEntries.count == 1)
        await h.transport.emit(h.snapshotEvent(["projects": .array([]), "agents": .object([:])]))
        try await h.waitUntil { h.store.projectEntries.isEmpty }
    }

    @Test func quickCatalogOmissionKeepsIdentityAndExplicitEmptyRemovesIt() async throws {
        let h = try await start(); defer { h.stop() }
        let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "project", agentID: "quick")
        await h.transport.emit(h.snapshotEvent(["quickAgents": .object(["project": .array([.object(["id": .string("quick"), "kind": .string("quick")])])])]))
        try await h.waitUntil { h.store.agent(for: target) != nil }
        await h.transport.emit(h.snapshotEvent([:]))
        try await h.refreshCatalog()
        #expect(h.store.agent(for: target) != nil)
        await h.transport.emit(h.snapshotEvent(["quickAgents": .object([:])]))
        try await h.waitUntil { h.store.agent(for: target) == nil }
    }

    @Test(arguments: ["projects", "agents"]) func malformedRESTCatalogIsNotDeletion(route: String) async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead(route, .object([:]))
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { if case .failed = h.host?.connection { true } else { false } }
        #expect(h.store.agent(for: h.target) != nil)
        #expect(h.store.agent(for: dispatcher) != nil)
    }

    @Test func reconnectResyncAndConnectedShareOneCatalogRefresh() async throws {
        let h = try await start(); defer { h.stop() }
        let before = await h.transport.readRoutes.filter { $0.name == "capabilities" }.count
        await h.transport.pauseNextRead("capabilities")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("capabilities") }
        let publications = h.service.events()
        let connectedHandled = Task { @MainActor in
            var iterator = publications.makeAsyncIterator()
            _ = await iterator.next() // Initial synchronizing host.
            await h.transport.emit(.connection(.connected))
            _ = await iterator.next() // Connected has been handled while the first refresh is paused.
        }
        await connectedHandled.value
        await h.transport.resumeRead("capabilities")
        try await h.waitUntil { h.host?.connection == .connected }
        // Reads are in-memory actor calls; allow any erroneously queued follow-up to finish.
        try await Task.sleep(for: .milliseconds(50))
        let count = await h.transport.readRoutes.filter { $0.name == "capabilities" }.count - before
        #expect(count == 1, "Reconnect's resync + first snapshot connected are one synchronization")
    }

    @Test func completedReconnectCatalogIsNotRepeatedForItsFirstSnapshot() async throws {
        let h = try await start(); defer { h.stop() }
        let before = await h.transport.readRoutes.filter { $0.name == "capabilities" }.count
        try await h.refreshCatalog() // Resync's REST read can finish before the socket snapshot arrives.
        await h.transport.emit(.connection(.connected))
        try await Task.sleep(for: .milliseconds(50))
        let count = await h.transport.readRoutes.filter { $0.name == "capabilities" }.count - before
        #expect(count == 1)
        #expect(h.host?.connection == .connected)
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

    @Test func replacementDispatcherIdentityDiscardsOnlyTheOldChat() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(dispatcher)
        let replacement: AnnexJSON = .object(["enabled": .bool(true), "flagOn": .bool(true), "agent": .object(["id": .string("replacement"), "name": .string("Dispatcher")])])
        await h.transport.emit(h.snapshotEvent(["dispatcher": replacement]))
        let next = CompanionTarget(hostID: dispatcher.hostID, projectID: dispatcher.projectID, agentID: "replacement")
        try await h.waitUntil { h.store.agent(for: next) != nil }
        #expect(!h.store.conversation(for: dispatcher).isLoaded)
        #expect(h.store.agent(for: dispatcher) == nil)
    }

    @Test func explicitNullAndCapabilityFlagOffDiscardChat() async throws {
        let h = try await start(); defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot())
        await h.store.load(dispatcher)
        await h.transport.emit(h.snapshotEvent(["dispatcher": .null]))
        try await h.waitUntil { h.host?.dispatcher?.enabled == false }
        #expect(!h.store.conversation(for: dispatcher).isLoaded)
        await h.transport.emit(h.snapshotEvent(["dispatcher": entry]))
        try await h.waitUntil { h.store.agent(for: dispatcher) != nil }
        await h.store.load(dispatcher)
        await h.transport.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(false)]))
        try await h.refreshCatalog()
        #expect(h.store.agent(for: dispatcher) == nil)
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

@MainActor struct CompanionIdentityNavigationTests {
    @Test func unknownDestinationLoadsUntilCatalogCompletes() {
        let h = LiveServiceHarness.hostID
        let target = CompanionTarget(hostID: h, projectID: "p", agentID: "a")
        let store = CompanionStore(service: CompanionPreviewService())
        var host = CompanionHost(id: h, name: "Fixture", endpoint: "", connection: .connecting, projects: [])
        for state: CompanionConnection in [.connecting, .reconnecting, .synchronizing, .offline, .failed("network")] {
            host.connection = state; store.apply(.hosts([host]))
            #expect(store.isAgentLoading(target))
            #expect(!store.canOperate(target))
        }
        host.connection = .connected; store.apply(.hosts([host]))
        #expect(store.isAgentLoading(target), "Even a connected transport needs its first authoritative catalog")
        host.hasLoadedCatalog = true; store.apply(.hosts([host]))
        #expect(!store.isAgentLoading(target), "A completed catalog confirms absence")
        store.apply(.hosts([]))
        #expect(!store.isAgentLoading(target), "Forgetting a host is final")
    }
}
