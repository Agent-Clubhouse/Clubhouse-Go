import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private actor LiveTestTransport: AnnexTransporting {
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private(set) var subscriptionCount = 0
    private(set) var connectCount = 0
    private var eventsGate: CheckedContinuation<Void, Never>?
    private var holdEvents = false
    private(set) var eventsWaiting = false
    private var projectGate: CheckedContinuation<AnnexJSON, Never>?
    private(set) var projectsWaiting = false
    private var historyGate: CheckedContinuation<AnnexJSON, Never>?
    private(set) var historyWaiting = false
    private var holdProjects = false
    private var holdHistory = false
    private var historyResponse: AnnexJSON = .object([:])
    private var commands: [String: AnnexCommandReceipt] = [:]
    private(set) var executedIDs: [String] = []
    private var startedHistory: AnnexJSON?
    func setStartedHistory(_ value: AnnexJSON) { startedHistory = value }
    private var rejectNext = true
    private(set) var executedKinds: [String] = []
    func acceptCommands() { rejectNext = false }

    func delaySubscription() { holdEvents = true }
    func releaseSubscription() { holdEvents = false; eventsWaiting = false; eventsGate?.resume(); eventsGate = nil }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        if holdEvents {
            eventsWaiting = true
            await withCheckedContinuation { eventsGate = $0 }
        }
        subscriptionCount += 1
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        continuation = pair.continuation
        continuation?.yield(.connection(.disconnected))
        return pair.stream
    }
    func connect() { connectCount += 1; emit(.connection(.connected)) }
    func disconnect() { emit(.connection(.disconnected)) }
    func emit(_ event: AnnexTransportEvent) {
        if case .dropped = continuation?.yield(event) {
            continuation?.finish(throwing: AnnexTransportError.queueOverflow)
        }
    }
    func overflow() { for _ in 0..<100 { emit(.message(.init(type: "ignored"))) } }
    func holdCatalog() { holdProjects = true }
    func releaseCatalog() {
        holdProjects = false; projectsWaiting = false
        projectGate?.resume(returning: projects); projectGate = nil
    }
    func setHistory(_ value: AnnexJSON, hold: Bool = false) { historyResponse = value; holdHistory = hold }
    func releaseHistory() {
        holdHistory = false; historyWaiting = false
        historyGate?.resume(returning: historyResponse); historyGate = nil
    }
    private var projects: AnnexJSON { .array([.object(["id": .string("project"), "name": .string("Project")])]) }
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        switch route {
        case .capabilities:
            return .object(["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"),
                            "controlAvailable": .bool(true), "idempotency": .object(["scope": .string("client"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]), "commands": .array([.string("chat.send"), .string("agent.start")])])
        case .projects:
            if holdProjects {
                projectsWaiting = true
                return await withCheckedContinuation { projectGate = $0 }
            }
            return projects
        case .agents:
            return .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])
        case .chat:
            if holdHistory {
                historyWaiting = true
                return await withCheckedContinuation { historyGate = $0 }
            }
            return historyResponse
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        executedIDs.append(command.commandID)
        executedKinds.append(command.type)
        if command.type == "agent.start", let startedHistory { historyResponse = startedHistory }
        if let receipt = commands[command.commandID] { return receipt }
        let status = rejectNext ? "rejected" : "completed"
        rejectNext = false
        let value: AnnexJSON = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": .string(command.commandID),
            "status": .string(status), "error": status == "rejected" ? .object(["code": .string("busy"), "message": .string("Try later")]) : .null])
        let receipt = try value.decode(AnnexCommandReceipt.self)
        commands[command.commandID] = receipt
        return receipt
    }
}

@Suite @MainActor struct CompanionLiveServiceTests {
    private let target = CompanionTarget(hostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef", projectID: "project", agentID: "agent")
    private func setup(_ transport: LiveTestTransport) async throws -> (CompanionLiveService, CompanionStore) {
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: target.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        return (service, store)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for fixture condition")
        throw AnnexTransportError.disconnected
    }
    private func event(_ session: String, sequence: Int64, text: String) -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(sequence), "type": .string("agent_message"),
                 "data": .object(["messageId": .string(text), "text": .string(text)])])
    }
    private func snapshot(_ session: String, text: String) -> AnnexJSON {
        .object(["sessionId": .string(session), "state": .string("idle"), "events": .array([event(session, sequence: 1, text: text)]),
                 "capabilities": .object(["chat": .bool(true)])])
    }
    private func chat(_ event: AnnexJSON) -> AnnexTransportEvent {
        .message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event])))
    }


    @Test func sleepingDurableCanWakeOnlyAfterAuthoritativeSnapshot() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(true)]))
        let (_, store) = try await setup(transport)
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(!store.canWake(target))
        await store.load(target)
        try await waitUntil { store.canWake(target) }
        #expect(store.canWake(target))
        #expect(store.agent(for: target)?.status == .sleeping)
        await store.wake(target)
        #expect(await transport.executedKinds == ["agent.start"])
        store.stop()
    }
    @Test func messageWakesThenNextMessageUsesTheLiveSession() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(true)]))
        await transport.setStartedHistory(snapshot("new-session", text: "hello"))
        let (service, store) = try await setup(transport)
        try await waitUntil { store.hosts.first?.connection == .connected }
        _ = try await service.history(for: target)
        _ = try await service.send(.init(target: target, text: "wake message", clientCommandID: "wake-message", isSteering: false))
        _ = try await service.send(.init(target: target, text: "follow up", clientCommandID: "follow-up", isSteering: false))
        #expect(await transport.executedKinds == ["agent.start", "chat.send"])
        store.stop()
    }
    @Test func historicalOrTerminalSessionCannotOfferWakeWithoutDesktopAuthority() async throws {
        let transport = LiveTestTransport()
        await transport.setHistory(.object(["sessionId": .string("old"), "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(false)]))
        let (_, store) = try await setup(transport)
        try await waitUntil { store.hosts.first?.connection == .connected }
        await store.load(target)
        #expect(!store.canWake(target))
        #expect(!store.canSend(target))
        await store.wake(target)
        #expect(await transport.executedKinds.isEmpty)
        store.stop()
    }

    @Test func staleDelayedSubscriptionCannotConnectRemovedOrReplacedHost() async throws {
        let old = LiveTestTransport()
        await old.delaySubscription()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: target.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop(); service.remove(hostID: target.hostID) }
        let registering = Task { await service.register(.init(host: host, alias: "Old", transport: old)) }
        try await waitUntil { await old.eventsWaiting }
        service.remove(hostID: target.hostID)
        let replacement = LiveTestTransport()
        await service.register(.init(host: host, alias: "Replacement", transport: replacement))
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await old.releaseSubscription()
        await registering.value
        #expect(await old.connectCount == 0)
        #expect(await replacement.connectCount == 1)
        #expect(store.host(for: target)?.name == "Replacement")
        #expect(store.host(for: target)?.connection == .connected)
    }

    @Test func reconnectResubscribesAfterBoundedStreamOverflows() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.overflow()
        try await waitUntil { if case .failed = store.host(for: target)?.connection { return true }; return false }
        await service.reconnect(hostID: target.hostID)
        try await waitUntil { store.host(for: target)?.connection == .connected }
        #expect(await transport.subscriptionCount == 2)
        await transport.emit(chat(event("session", sequence: 2, text: "After reconnect")))
        try await waitUntil { store.conversation(for: target).items.contains { $0.id == "message:After reconnect" } }
    }

    @Test func catalogReadDoesNotBlockChatStreamAndCannotReconnectAfterSuspend() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.holdCatalog()
        await transport.emit(.resyncRequired(.reconnected))
        try await waitUntil { await transport.projectsWaiting }
        await transport.emit(chat(event("session", sequence: 2, text: "During catalog read")))
        try await waitUntil { store.conversation(for: target).items.contains { $0.id == "message:During catalog read" } }
        await service.suspend()
        await transport.releaseCatalog()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.host(for: target)?.connection == .offline)
    }

    @Test func automaticDisconnectCancelsCatalogBeforeNextConnection() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.holdCatalog()
        await transport.emit(.resyncRequired(.reconnected))
        try await waitUntil { await transport.projectsWaiting }
        await transport.emit(.connection(.disconnected))
        try await waitUntil { store.host(for: target)?.connection == .offline }
        await transport.releaseCatalog()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.host(for: target)?.connection == .offline)
        await transport.emit(.connection(.connected))
        try await waitUntil { store.host(for: target)?.connection == .connected }
        #expect(await transport.subscriptionCount == 1)
    }

    @Test func oldSessionBufferedDuringHistoryCannotReplaceAuthoritativeNewSession() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.setHistory(snapshot("old", text: "Old"))
        _ = try await service.history(for: target)
        await transport.setHistory(snapshot("new", text: "New"), hold: true)
        let loading = Task { try await service.history(for: target) }
        try await waitUntil { await transport.historyWaiting }
        await transport.emit(chat(event("old", sequence: 100, text: "Stale old")))
        // A following marker guarantees that the preceding event was consumed.
        await transport.emit(.connection(.connecting))
        try await waitUntil { store.host(for: target)?.connection == .connecting }
        await transport.releaseHistory()
        let history = try await loading.value
        #expect(history.sessionID == "new")
        #expect(history.items.map(\.id) == ["message:New"])
    }

    @Test func ambiguousNewSessionDuringHistoryRequiresAnotherSnapshot() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.setHistory(snapshot("old", text: "Old"))
        _ = try await service.history(for: target)
        await transport.setHistory(snapshot("old", text: "Old"), hold: true)
        let loading = Task { try await service.history(for: target) }
        try await waitUntil { await transport.historyWaiting }
        await transport.emit(chat(event("new", sequence: 1, text: "New")))
        await transport.emit(.connection(.connecting))
        try await waitUntil { store.host(for: target)?.connection == .connecting }
        await transport.releaseHistory()
        await #expect(throws: CompanionServiceError.self) { try await loading.value }
    }

    @Test func retryAfterCachedRejectionUsesNewLogicalCommandThroughLiveService() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.host(for: target)?.connection == .connected }
        await transport.setHistory(snapshot("session", text: "Existing"))
        await store.load(target)
        try await waitUntil { store.canSend(target) }
        store.drafts[target] = "Please continue"
        await store.sendDraft(to: target)
        let firstIDs = await transport.executedIDs
        #expect(firstIDs.count == 1)
        let rejected = try #require(store.conversation(for: target).items.compactMap { item -> CompanionMessage? in
            guard case .message(let message) = item, case .failed = message.delivery else { return nil }
            return message
        }.first)
        await store.retry(messageID: rejected.id, target: target)
        let ids = await transport.executedIDs
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
        #expect(store.conversation(for: target).items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.clientCommandID == ids[1] && message.delivery == .accepted
        })
    }
}
