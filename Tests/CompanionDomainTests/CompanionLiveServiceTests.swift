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
    private var catalogAgents: [AnnexJSON] = [.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])]
    func setCatalogAgent(_ value: AnnexJSON) { catalogAgents = [value] }
    func setCatalogAgents(_ values: [AnnexJSON]) { catalogAgents = values }
    /// The bulk `agentState` read; nil leaves it out of the capabilities, as an older desktop does.
    private var agentState: AnnexJSON?
    func setAgentState(_ value: AnnexJSON?) { agentState = value }
    private(set) var agentStateReads = 0
    private var failAgentState = false
    private var holdState = false
    private var stateGate: CheckedContinuation<Void, Never>?
    private(set) var agentStateWaiting = false
    func holdAgentState() { holdState = true }
    func releaseAgentState() { holdState = false; agentStateWaiting = false; stateGate?.resume(); stateGate = nil }
    func setAgentStateFails(_ fails: Bool) { failAgentState = fails }
    /// One-event chat pages by agent, for desktops without the bulk read.
    private var chatPages: [String: AnnexJSON] = [:]
    func setChatPage(_ agentID: String, _ value: AnnexJSON) { chatPages[agentID] = value }
    private(set) var chatPageReads: [String] = []
    private var rejectNext = true
    private(set) var executedKinds: [String] = []
    private(set) var executedCommands: [AnnexCommand] = []
    func acceptCommands() { rejectNext = false }
    private var helperRequests = false
    func enableHelperRequests() { helperRequests = true }
    private var finishedQuick = false
    func enableFinishedQuick() { finishedQuick = true }
    /// The `result` of the next command that succeeds.
    private var nextResult: AnnexJSON?
    func setNextResult(_ value: AnnexJSON) { nextResult = value }

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
                            "controlAvailable": .bool(true), "idempotency": .object(["scope": .string("client"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
                            "commands": .array([.string("chat.send"), .string("agent.start")] + (helperRequests ? [.string("helper.approve"), .string("helper.decline")] : [])
                                               + (finishedQuick ? [.string("quick.dismiss"), .string("quick.clear")] : [])),
                            "helperRequests": helperRequests ? .object(["version": .integer(1), "snapshotField": .string("helperRequests")]) : .null,
                            "finishedQuickAgents": finishedQuick ? .object(["version": .integer(1)]) : .null,
                            "agentState": agentState != nil ? .object(["version": .integer(1), "path": .string("/api/v1/mobile/agents/state")]) : .null])
        case .projects:
            if holdProjects {
                projectsWaiting = true
                return await withCheckedContinuation { projectGate = $0 }
            }
            return projects
        case .agents:
            return .array(catalogAgents)
        case .agentState:
            agentStateReads += 1
            if holdState {
                agentStateWaiting = true
                await withCheckedContinuation { stateGate = $0 }
            }
            if failAgentState { throw AnnexTransportError.malformedResponse }
            guard let agentState else { throw AnnexTransportError.unsupportedCapability("agentState") }
            return agentState
        case .chatHistory(let agentID, nil, nil, 1):
            chatPageReads.append(agentID)
            guard let page = chatPages[agentID] else { throw AnnexTransportError.unsupportedCapability("chat page") }
            return page
        case .chat:
            if holdHistory {
                historyWaiting = true
                return await withCheckedContinuation { historyGate = $0 }
            }
            return historyResponse
        case .gitStatus(let project):
            return .object(["hasGit": .bool(true), "branch": .string("main-\(project)"),
                            "status": .array([.object(["path": .string("gone.txt"), "status": .string("D"), "staged": .bool(true)])])])
        case .gitDiff(_, let file, let staged):
            diffReads.append("\(file):\(staged)")
            return .object(["original": .string("a\nb\n"), "modified": .string("")])
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    private(set) var diffReads: [String] = []
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        executedIDs.append(command.commandID)
        executedKinds.append(command.type)
        executedCommands.append(command)
        if command.type == "agent.start", let startedHistory { historyResponse = startedHistory }
        if let receipt = commands[command.commandID] { return receipt }
        let status = rejectNext ? "rejected" : "completed"
        rejectNext = false
        let value: AnnexJSON = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": .string(command.commandID),
            "status": .string(status), "error": status == "rejected" ? .object(["code": .string("busy"), "message": .string("Try later")]) : .null,
            "result": status == "completed" ? (nextResult ?? .null) : .null])
        if status == "completed" { nextResult = nil }
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
    private func chat(_ event: AnnexJSON, agent: String = "agent") -> AnnexTransportEvent {
        .message(.init(type: "chat:event", payload: .object(["agentId": .string(agent), "event": event])))
    }


    /// Helper requests come in the WebSocket snapshot, survive a REST refresh, and are answered with helper.approve.
    @Test func theDesktopsFinishedListComesFromTheSnapshotAndDismissSendsQuickDismiss() async throws {
        let transport = LiveTestTransport()
        await transport.enableFinishedQuick()
        await transport.acceptCommands()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        let project = CompanionProjectTarget(hostID: target.hostID, projectID: "project")
        func entry(_ id: String, at ms: Int64) -> AnnexJSON {
            .object(["agentId": .string(id), "name": .string(id), "prompt": .string("Task \(id)"), "summary": .null,
                     "exitCode": .integer(0), "finishedAt": .integer(ms)])
        }
        func snapshot(_ list: [AnnexJSON]?) -> AnnexTransportEvent {
            var payload: [String: AnnexJSON] = ["projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
                                                "agents": .object(["project": .array([])])]
            if let list { payload["finishedQuickAgents"] = .object(["project": .array(list)]) }
            return .message(.init(type: "snapshot", payload: .object(payload)))
        }
        // Not migrated yet: the field is absent, so the phone keeps its own list.
        await transport.emit(snapshot(nil))
        try await waitUntil { store.hosts.first?.canSyncFinishedQuick == true && store.hosts.first?.projects.isEmpty == false }
        #expect(!store.sharesFinished(project))

        await transport.emit(snapshot([entry("q2", at: 1_800_000_060_000), entry("q1", at: 1_800_000_000_000)]))
        try await waitUntil { store.sharesFinished(project) }
        #expect(store.finished(in: project).map(\.target.agentID) == ["q2", "q1"])

        await transport.setNextResult(.object(["projectId": .string("project"), "finishedQuickAgents": .array([entry("q1", at: 1_800_000_000_000)])]))
        await store.dismissFinished(.init(hostID: target.hostID, projectID: "project", agentID: "q2"))
        let sent = await transport.executedCommands.last
        #expect(sent?.kind == .dismissFinishedQuick(projectID: "project", agentID: "q2"))
        #expect(store.finished(in: project).map(\.target.agentID) == ["q1"], "The desktop's reply is the list until the next snapshot")
        #expect(store.finishedError == nil)
    }

    @Test func helperRequestsFromTheSnapshotAreAnswered() async throws {
        let transport = LiveTestTransport()
        await transport.enableHelperRequests()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.hosts.first?.canAnswerHelperRequests == true)
        let request: AnnexJSON = .object(["requestId": .string("hdispose_1"), "kind": .string("dispose"), "projectId": .string("project"),
            "requester": .object(["agentId": .string("agent"), "name": .string("Agent")]), "helper": .object(["agentId": .string("agent"), "name": .string("Agent")]),
            "requestedAt": .string("2026-10-26T10:00:00.000Z"), "summary": .string("Agent asked to dispose this helper. 1 uncommitted file."),
            "dispose": .object(["uncommittedFiles": .integer(1), "unpushedCommits": .integer(0), "workAtRisk": .bool(true), "canDispose": .bool(true)])])
        await transport.emit(.message(.init(type: "snapshot", payload: .object([
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
            "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])]),
            "helperRequests": .array([request])]))))
        try await waitUntil { store.attentionItems().contains { $0.helperRequest != nil } }
        let pending = try #require(store.attentionItems().compactMap(\.helperRequest).first)
        #expect(pending.summary == "Agent asked to dispose this helper. 1 uncommitted file.")

        // The fixture rejects the first command, as a desktop refusal; the request stays and says why.
        await store.answer(pending, approve: true)
        #expect(store.helperRequestErrors[pending.slot] == "Try later")
        #expect(store.hosts.first?.helperRequests.count == 1)
        await transport.acceptCommands()
        await store.answer(pending, approve: true)
        let sent = try #require(await transport.executedCommands.last)
        #expect(sent.kind == .helperApprove(requestID: "hdispose_1", force: true))
        try await waitUntil { store.hosts.first?.helperRequests.isEmpty == true }
        #expect(store.needsYouCount == 0)
    }

    @Test(arguments: ["waiting_input", "waiting_permission"])
    func coarseRunningStatusCannotHidePendingInteraction(state: String) async throws {
        let transport = LiveTestTransport()
        await transport.setHistory(.object(["sessionId": .string("session"), "state": .string(state),
            "events": .array([event("session", sequence: 1, text: "before")]),
            "capabilities": .object(["chat": .bool(true)])]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await store.load(target)
        let expected: CompanionAgentStatus = state == "waiting_input" ? .waiting : .approval
        try await waitUntil { store.agent(for: target)?.status == expected }
        #expect(store.agent(for: target)?.status == expected)
        await transport.emit(.message(.init(type: "agent:status", payload: .object(["id": .string("agent"), "status": .string("running")]))))
        await transport.emit(chat(event("session", sequence: 2, text: "after-status")))
        try await waitUntil { store.conversation(for: target).items.contains(where: { $0.id == "message:after-status" }) == true }
        #expect(store.agent(for: target)?.status == expected)
        await transport.emit(chat(.object(["sessionId": .string("session"), "seq": .integer(3), "type": .string("session_state"), "data": .object(["state": .string("running")])])))
        try await waitUntil { store.agent(for: target)?.status == .working }
    }

    /// An agent awake when the phone last connected sleeps while it is away. The desktop drops the agent's chat
    /// events from replay when it exits, and the reconnect resumes from the snapshot, so its session's end never
    /// arrives: the catalog's "sleeping" must win over the chat projection's last Working or Done.
    @Test(arguments: ["running", "idle"])
    func anAgentThatSleptWhileThePhoneWasAwayShowsAsleepAfterReconnect(lastState: String) async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running"), "hasSession": .bool(true)]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(chat(.object(["sessionId": .string("session"), "seq": .integer(1), "type": .string("session_started"),
                                           "data": .object(["capabilities": .object(["chat": .bool(true)])])])))
        await transport.emit(chat(.object(["sessionId": .string("session"), "seq": .integer(2), "type": .string("session_state"),
                                           "data": .object(["state": .string(lastState)])])))
        let awake: CompanionAgentStatus = lastState == "running" ? .working : .idle
        try await waitUntil { store.agent(for: target)?.status == awake }

        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping"),
                                                 "detailedStatus": .null, "hasSession": .bool(true)]))
        await transport.connect()
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.agent(for: target)?.status == .sleeping)
        #expect(store.agent(for: target)?.capabilities.contains(.chat) != true)

        // A snapshot on the socket says the same; a later event from the same stale session can't wake it.
        await transport.emit(.message(.init(type: "snapshot", payload: .object([
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
            "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping")])])])]))))
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.agent(for: target)?.status == .sleeping)

        // Woken again: the new session's events drive the status as before.
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running")]))
        await transport.emit(chat(.object(["sessionId": .string("session-2"), "seq": .integer(1), "type": .string("session_state"),
                                           "data": .object(["state": .string("running")])])))
        try await waitUntil { store.agent(for: target)?.status == .working }
    }

    // MARK: Catch-up after a reconnect

    private func catalogEntry(_ id: String, _ status: String) -> AnnexJSON {
        .object(["id": .string(id), "name": .string(id.capitalized), "status": .string(status), "hasSession": .bool(true)])
    }
    private func liveState(_ id: String, _ status: String, _ sessionState: String?, permission: Bool = false, question: Bool = false) -> AnnexJSON {
        .object(["agentId": .string(id), "projectId": .string("project"), "kind": .string("durable"), "status": .string(status),
                 "sessionId": sessionState == nil ? .null : .string("session-\(id)"), "sessionState": sessionState.map(AnnexJSON.string) ?? .null,
                 "hasSession": .bool(true), "detailedStatus": .null, "pendingPermission": .bool(permission), "pendingQuestion": .bool(question)])
    }
    private func state(_ agent: String, _ state: String, seq: Int64) -> AnnexTransportEvent {
        chat(.object(["sessionId": .string("session-\(agent)"), "seq": .integer(seq), "type": .string("session_state"), "data": .object(["state": .string(state)])]), agent: agent)
    }
    private func agentTarget(_ id: String) -> CompanionTarget { .init(hostID: target.hostID, projectID: "project", agentID: id) }

    /// Three agents the phone saw awake; while it was away one slept, one started a turn, and one had its approval
    /// answered. None of that reaches it as events. One bulk read on reconnect puts every one right, open or not.
    @Test func aReconnectCatchesUpEveryCachedAgentFromOneBulkRead() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgents([catalogEntry("sleeper", "running"), catalogEntry("worker", "running"), catalogEntry("asker", "running")])
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([])]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(state("sleeper", "running", seq: 1))
        await transport.emit(state("worker", "idle", seq: 1))
        await transport.emit(state("asker", "waiting_permission", seq: 1))
        try await waitUntil {
            store.agent(for: agentTarget("sleeper"))?.status == .working && store.agent(for: agentTarget("worker"))?.status == .idle
                && store.agent(for: agentTarget("asker"))?.status == .approval
        }
        let readsBefore = await transport.agentStateReads

        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        // The catalog alone can't tell: two of the three still say running.
        await transport.setCatalogAgents([catalogEntry("sleeper", "sleeping"), catalogEntry("worker", "running"), catalogEntry("asker", "running")])
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([
            liveState("sleeper", "sleeping", nil), liveState("worker", "running", "running"), liveState("asker", "running", "idle")])]))
        await transport.connect()
        try await waitUntil { store.hosts.first?.connection == .connected }

        #expect(store.agent(for: agentTarget("sleeper"))?.status == .sleeping)
        #expect(store.agent(for: agentTarget("worker"))?.status == .working)
        #expect(store.agent(for: agentTarget("asker"))?.status == .idle)
        #expect(!store.attentionItems().contains { $0.agent.id == agentTarget("asker") })
        #expect(await transport.agentStateReads == readsBefore + 1)
        #expect(await transport.chatPageReads.isEmpty)
    }

    /// A question asked while the phone was away shows as Needs you after the reconnect.
    @Test func aCatchUpShowsARequestMadeWhileAway() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgents([catalogEntry("asker", "running")])
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([])]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(state("asker", "running", seq: 1))
        try await waitUntil { store.agent(for: agentTarget("asker"))?.status == .working }
        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([liveState("asker", "running", "running", question: true)])]))
        await transport.connect()
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.agent(for: agentTarget("asker"))?.status == .waiting)
    }

    /// An older desktop has no bulk read: the phone reads a one-event chat page for each agent still showing awake.
    @Test func withoutTheBulkReadACatchUpReadsOneEventPagesForAwakeAgentsOnly() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgents([catalogEntry("sleeper", "running"), catalogEntry("worker", "running"), catalogEntry("stopped", "running")])
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(state("sleeper", "running", seq: 1))
        await transport.emit(state("worker", "waiting_input", seq: 1))
        await transport.emit(chat(.object(["sessionId": .string("session-stopped"), "seq": .integer(1), "type": .string("session_ended"),
                                           "data": .object(["reason": .string("killed")])]), agent: "stopped"))
        try await waitUntil { store.agent(for: agentTarget("stopped"))?.status == .stopped && store.agent(for: agentTarget("worker"))?.status == .waiting }

        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        // The desktop still says running for both (it lags, or the agent is between sessions): only the pages know.
        await transport.setChatPage("sleeper", .object(["sessionId": .string("session-sleeper"), "readOnly": .bool(true), "state": .string("sleeping"),
                                                        "events": .array([]), "pendingPermissions": .array([]), "pendingQuestions": .array([])]))
        await transport.setChatPage("worker", .object(["sessionId": .string("session-worker"), "readOnly": .bool(false), "state": .string("idle"),
                                                       "events": .array([]), "pendingPermissions": .array([]), "pendingQuestions": .array([])]))
        await transport.connect()
        try await waitUntil { store.hosts.first?.connection == .connected }

        #expect(store.agent(for: agentTarget("sleeper"))?.status == .sleeping)
        #expect(store.agent(for: agentTarget("worker"))?.status == .idle)
        #expect(store.agent(for: agentTarget("stopped"))?.status == .stopped)
        #expect(await Set(transport.chatPageReads) == ["sleeper", "worker"])
    }

    /// A chat event that arrives while the catch-up read is in flight is newer than the read and keeps its status.
    @Test func aChatEventDuringTheCatchUpReadWins() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgents([catalogEntry("worker", "running")])
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([])]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(state("worker", "running", seq: 1))
        try await waitUntil { store.agent(for: agentTarget("worker"))?.status == .working }
        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        // Read before the turn ended: it still says running.
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([liveState("worker", "running", "running")])]))
        await transport.holdAgentState()
        await transport.connect()
        try await waitUntil { await transport.agentStateWaiting }
        await transport.emit(state("worker", "idle", seq: 2))
        try await waitUntil { store.agent(for: agentTarget("worker"))?.status == .idle }
        await transport.releaseAgentState()
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.agent(for: agentTarget("worker"))?.status == .idle)
    }

    /// A catch-up that fails leaves the host catching up on its next refresh rather than calling it done.
    @Test func aFailedCatchUpIsRetriedOnTheNextRefresh() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgents([catalogEntry("sleeper", "running")])
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([])]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(state("sleeper", "running", seq: 1))
        try await waitUntil { store.agent(for: agentTarget("sleeper"))?.status == .working }
        await transport.disconnect()
        try await waitUntil { store.hosts.first?.connection == .offline }
        // Advertised but failing: the host still connects, on the catalog's statuses.
        await transport.setAgentStateFails(true)
        let reads = await transport.agentStateReads
        await transport.connect()
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(await transport.agentStateReads == reads + 1)
        #expect(store.agent(for: agentTarget("sleeper"))?.status == .working)
        // The next refresh, for any reason, catches up.
        await transport.setAgentStateFails(false)
        await transport.setAgentState(.object(["version": .integer(1), "agents": .array([liveState("sleeper", "sleeping", nil)])]))
        await transport.emit(.message(.init(type: "agent:deleted", payload: .object([:]))))
        try await waitUntil { store.agent(for: agentTarget("sleeper"))?.status == .sleeping }
        #expect(store.hosts.first?.connection == .connected)
    }

    /// The desktop says `agent:status` "sleeping" when a durable agent's process exits, terminal or chat.
    @Test func agentStatusSleepingPutsALiveChatToSleep() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running")]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(chat(.object(["sessionId": .string("session"), "seq": .integer(1), "type": .string("turn_started"), "data": .object([:])])))
        try await waitUntil { store.agent(for: target)?.status == .working }
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping")]))
        await transport.emit(.message(.init(type: "agent:status", payload: .object([
            "id": .string("agent"), "agentId": .string("agent"), "kind": .string("durable"), "status": .string("sleeping"), "detailedStatus": .null]))))
        try await waitUntil { store.agent(for: target)?.status == .sleeping }
        #expect(store.agent(for: target)?.turnStartedAt == nil)
    }

    /// A chat that ended as stopped keeps that, rather than taking the coarser "sleeping" from the exit after it.
    @Test func agentStatusSleepingKeepsAChatsOwnEnd() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running")]))
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(chat(.object(["sessionId": .string("session"), "seq": .integer(1), "type": .string("session_ended"),
                                           "data": .object(["reason": .string("killed"), "exitCode": .integer(0)])])))
        try await waitUntil { store.agent(for: target)?.status == .stopped }
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping")]))
        await transport.emit(.message(.init(type: "agent:status", payload: .object(["id": .string("agent"), "kind": .string("durable"), "status": .string("sleeping")]))))
        await transport.emit(chat(event("session", sequence: 2, text: "marker")))
        try await waitUntil { store.conversation(for: target).items.contains(where: { $0.id == "message:marker" }) }
        #expect(store.agent(for: target)?.status == .stopped)
    }

    @Test func contentRootsComeFromEachChatSnapshotAndTheHostsPlatform() async throws {
        let transport = LiveTestTransport()
        var history = snapshot("session", text: "Hi")
        if case .object(var fields) = history { fields["contentRoots"] = .array([.string("C:\\Proj")]); history = .object(fields) }
        await transport.setHistory(history)
        let (_, store) = try await setup(transport)
        try await waitUntil { store.hosts.first?.connection == .connected }
        await transport.emit(.message(.init(type: "snapshot", payload: .object([
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
            "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])]),
            "ptyHost": .object(["platform": .string("win32")])
        ]))))
        // The snapshot frame is handled asynchronously; reload until it has been seen.
        try await waitUntil { await store.load(target, force: true); return store.contentRoots(for: target).windows }
        #expect(store.contentRoots(for: target) == .init(paths: ["C:\\Proj"], windows: true))
        #expect(store.contentRoots(for: target).covers("c:/proj/a.txt"))
        // An older desktop omits the field: relative paths only.
        await transport.setHistory(snapshot("session", text: "Hi"))
        await store.load(target, force: true)
        #expect(store.contentRoots(for: target).paths.isEmpty)
        store.stop()
    }

    @Test func aQuickAgentsExitIsKeptForTheFinishedList() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        let project = CompanionProjectTarget(hostID: target.hostID, projectID: "project")
        let quick: AnnexJSON = .object(["id": .string("quick-1"), "kind": .string("quick"), "name": .string("brave-otter"), "prompt": .string("Fix the build"),
                                        "status": .string("running"), "projectId": .string("project")])
        await transport.emit(.message(.init(type: "snapshot", payload: .object([
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
            "agents": .object(["project": .array([])]), "quickAgents": .object(["project": .array([quick])])
        ]))))
        try await waitUntil { store.hosts.first?.projects.first?.agents.contains { $0.id.agentID == "quick-1" } == true }
        #expect(store.finished(in: project).isEmpty)
        await transport.emit(.message(.init(type: "agent:completed", payload: .object([
            "id": .string("quick-1"), "kind": .string("quick"), "status": .string("failed"), "exitCode": .integer(2), "projectId": .string("project")
        ]))))
        try await waitUntil { store.finished(in: project).first?.exitCode == 2 }
        let run = try #require(store.finished(in: project).first)
        #expect(run.title == "Fix the build" && run.detail == "Exited with code 2")
        // The catalog refresh that follows keeps the exit, so the agent still reads as exited.
        try await waitUntil { store.hosts.first?.connection == .connected }
        let agent = store.hosts.first?.projects.first?.agents.first { $0.id.agentID == "quick-1" }
        #expect(agent?.hasExited == true && agent?.exitCode == 2)
    }

    @Test func changesReadTheProjectRootAndDiffADeletedFileAgainstNothing() async throws {
        let transport = LiveTestTransport()
        let (service, store) = try await setup(transport)
        defer { store.stop(); service.remove(hostID: target.hostID) }
        try await waitUntil { store.hosts.first?.connection == .connected }
        let project = CompanionProjectTarget(hostID: target.hostID, projectID: "project")
        let changes = try await store.changes(for: project)
        #expect(changes.branch == "main-project")
        let file = try #require(changes.files.first)
        #expect(file.status == .deleted && file.diffsStaged)
        let diff = try await store.diff(of: file, in: project)
        #expect(diff.isDeleted && diff.removed == 2 && diff.added == 0)
        #expect(await transport.diffReads == ["gone.txt:true"])
    }

    @Test func sleepingDurableCanWakeOnlyAfterAuthoritativeSnapshot() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(true)]))
        let (_, store) = try await setup(transport)
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(!store.canWake(target))
        await store.load(target)
        // Wake comes with the snapshot; its status follows in the service's next hosts update.
        try await waitUntil { store.canWake(target) && store.agent(for: target)?.status == .sleeping }
        await store.wake(target)
        #expect(await transport.executedKinds == ["agent.start"])
        store.stop()
    }
    /// Wake & Resume sends `resume: true`; Start New Session sends `resume: false`.
    @Test(arguments: [(CompanionWakeChoice.resume, true), (.newSession, false), (.wake, true)])
    func wakeChoiceSetsResume(choice: CompanionWakeChoice, resume: Bool) async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping"), "hasSession": .bool(true)]))
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(true)]))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        // The catalog refresh can land just after the connection under load; wait for the agent itself.
        try await waitUntil { store.hosts.first?.connection == .connected && store.agent(for: target)?.hasSession == true }
        #expect(store.wakeChoices(for: target) == [.resume, .newSession])
        // From a row's menu the chat isn't read yet: waking reads it first.
        #expect(store.mayWake(target))
        await store.wake(target, choice)
        let commands = await transport.executedCommands
        #expect(commands.map(\.kind) == [.start(agentID: "agent", resume: resume)])
        let body = try JSONSerialization.jsonObject(with: try #require(commands.first).encoded()) as? [String: Any]
        #expect(body?["resume"] as? Bool == resume)
    }
    @Test func messageToAnAgentWithoutASessionStartsFresh() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping"), "hasSession": .bool(false)]))
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(true)]))
        let (service, store) = try await setup(transport)
        defer { store.stop() }
        try await waitUntil { store.hosts.first?.connection == .connected }
        #expect(store.wakeChoices(for: target) == [.newSession])
        _ = try await service.history(for: target)
        _ = try await service.send(.init(target: target, text: "hello", clientCommandID: "fresh", isSteering: false))
        #expect(await transport.executedCommands.map(\.kind) == [.start(agentID: "agent", message: "hello", resume: false)])
    }
    @Test func catalogDetailedStatusReachesTheAgent() async throws {
        let transport = LiveTestTransport()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running"),
            "detailedStatus": .object(["state": .string("needs_permission"), "message": .string("Needs permission"),
                                       "toolName": .string("mcp__clubhouse__message_parent"), "timestamp": .integer(1_700_000_000_000)])]))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        try await waitUntil { store.hosts.first?.connection == .connected && store.agent(for: target) != nil }
        let agent = try #require(store.agent(for: target))
        #expect(agent.status == .approval)
        #expect(agent.detail == .init(state: "needs_permission", message: "Needs permission", toolName: "mcp__clubhouse__message_parent",
                                      since: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(agent.hasSession == nil)
        #expect(store.attentionItems().map(\.detail) == ["Needs permission to use message_parent"])
    }
    @Test func snapshotAndChatSessionFeedAgentDetails() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running"), "executionMode": .string("chat"),
                                                 "branch": .string("agent/standby"), "orchestrator": .string("claude-code"), "freeAgentMode": .bool(true)]))
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(false)]))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        try await waitUntil { store.hosts.first?.connection == .connected }
        let agent = try #require(store.agent(for: target))
        #expect(agent.branch == "agent/standby")
        #expect(agent.orchestrator == "claude-code")
        #expect(agent.freeAgentMode)
        await transport.emit(chat(.object(["sessionId": .string("live"), "seq": .integer(1), "type": .string("session_started"),
                                           "data": .object(["cliVersion": .string("2.1.4"), "level": .string("plan"),
                                                            "capabilities": .object([:])])])))
        try await waitUntil { store.agent(for: target)?.session?.cliVersion == "2.1.4" }
        #expect(store.agent(for: target)?.session?.level == "plan")
    }
    @Test func newAgentBecomesSendableWhenItsChatStartsAfterHistoryLoaded() async throws {
        let transport = LiveTestTransport()
        await transport.acceptCommands()
        await transport.setCatalogAgent(.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running"), "executionMode": .string("chat")]))
        await transport.setHistory(.object(["sessionId": .null, "state": .string("sleeping"), "readOnly": .bool(true), "canStart": .bool(false)]))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        try await waitUntil { store.hosts.first?.connection == .connected }
        await store.load(target)
        #expect(!store.canSend(target))
        // session_started (and its capabilities) went out before the agent was listed; only later events arrive.
        await transport.setHistory(snapshot("new", text: "ready"))
        await transport.emit(chat(event("new", sequence: 2, text: "ready")))
        await transport.emit(chat(.object(["sessionId": .string("new"), "seq": .integer(3), "type": .string("turn_ended"),
                                           "data": .object(["stopReason": .string("end_turn")])])))
        try await waitUntil { store.canSend(target) }
        #expect(store.agent(for: target)?.status == .idle)
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
