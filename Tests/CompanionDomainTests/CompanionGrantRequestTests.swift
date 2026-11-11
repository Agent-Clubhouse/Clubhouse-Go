import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Clubhouse grant requests (Go #337, desktop #3205): `grantRequests` in the snapshot, `grant_request:*` events and
// `grant.answer`, through the phone's decoder, live service and store.

@MainActor private final class GrantService: CompanionService {
    var answers: [(id: String, answer: CompanionGrantRequest.Answer, commandID: String)] = []
    var failures: [Error] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func answerGrantRequest(_ request: CompanionGrantRequest, answer: CompanionGrantRequest.Answer, clientCommandID: String) async throws {
        answers.append((request.id, answer, clientCommandID))
        if !failures.isEmpty { throw failures.removeFirst() }
    }
}

private let now = Date()

private func agent(_ id: String, project: String = "p1", _ status: CompanionAgentStatus = .idle) -> CompanionAgent {
    .init(id: .init(hostID: "mac", projectID: project, agentID: id), name: id.capitalized, subtitle: "", status: status)
}

private func call(_ id: String = "grant_call", agentID: String = "planner", project: String = "p1", at seconds: TimeInterval = 300,
                  expires: TimeInterval = 3600) -> CompanionGrantRequest {
    .init(id: id, hostID: "mac", projectID: project, kind: .call, agentID: agentID, agentName: agentID.capitalized, actionLabels: ["Manage devices"],
          whereLabel: "the app", toolName: "remove_device", summary: "Wants to run remove_device, which needs: Manage devices on the app.",
          detail: "Remove Phone.", arguments: "{\"id\": \"aa\"}", reason: "Lost.", allowEffect: "Allow runs this one call when it tries again.",
          requestedAt: now.addingTimeInterval(-seconds), expiresAt: now.addingTimeInterval(expires), answers: [.allowOnce, .decline])
}

private func ask(_ id: String = "grant_ask", at seconds: TimeInterval = 60) -> CompanionGrantRequest {
    .init(id: id, hostID: "mac", projectID: "p1", kind: .grant, agentID: "planner", agentName: "Planner", actionLabels: ["Change app settings"],
          summary: "Asks for Change app settings on the app.", requestedAt: now.addingTimeInterval(-seconds),
          expiresAt: now.addingTimeInterval(3600), answers: [.allowLasting, .decline])
}

@MainActor private func makeStore(_ requests: [CompanionGrantRequest], capable: Bool = true, connection: CompanionConnection = .connected,
                                  agents: [CompanionAgent] = [agent("planner")], dispatcher: CompanionAgent? = nil) -> (CompanionStore, GrantService) {
    let service = GrantService()
    let store = CompanionStore(service: service)
    var host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: connection, projects: [.init(id: "p1", name: "P1", agents: agents)])
    host.canAnswerGrantRequests = capable
    host.grantRequests = requests
    if let dispatcher { host.dispatcher = .init(enabled: true, flagOn: true, agent: dispatcher) }
    store.apply(.hosts([host]))
    return (store, service)
}

@MainActor struct CompanionGrantRequestTests {
    // MARK: Fixtures

    @Test func decodesTheDesktopSnapshotFixture() throws {
        let rows = CompanionLiveService.grantRequests(from: try ContractFixtures.json("snapshot-grant-requests.json")["value"] ?? .null, hostID: "mac")
        try #require(rows.count == 2)
        let call = rows[0], grant = rows[1]
        #expect(call.id == "grant_00000000-0000-4000-8000-000000000008" && call.kind == .call)
        #expect(call.agentTarget == .init(hostID: "mac", projectID: "__dispatcher__", agentID: "durable_dispatcher") && call.agentName == "Dispatcher")
        #expect(call.actionLabels == ["Manage devices"] && call.whereLabel == "the app" && call.toolName == "remove_device")
        #expect(call.summary == "Wants to run remove_device, which needs: Manage devices on the app.")
        #expect(call.detail?.hasPrefix("Remove Phone (phone, in this network).") == true)
        // Arguments are shown whole: Allow once covers exactly these.
        #expect(call.arguments == "{\n  \"id\": \"aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99\"\n}")
        #expect(call.reason == "You said the phone was lost." && call.allowEffect?.hasPrefix("Allow runs this one call") == true)
        #expect(call.answers == [.allowOnce, .decline] && call.allowAnswer == .allowOnce && call.canDecline)
        #expect(try #require(call.expiresAt).timeIntervalSince(try #require(call.requestedAt)) == 24 * 3600)

        #expect(grant.id == "grant_00000000-0000-4000-8000-000000000009" && grant.kind == .grant)
        #expect(grant.agentTarget == .init(hostID: "mac", projectID: "proj_app", agentID: "durable_chat") && grant.agentName == "planner")
        #expect(grant.toolName == nil && grant.detail == nil && grant.arguments == nil && grant.reason == "To set the cheap model for easy tasks.")
        #expect(grant.answers == [.allowLasting, .decline] && grant.allowAnswer == .allowLasting)
        #expect(grant.allowEffect == "Allow adds this to its Clubhouse permissions, where you can remove it later.")
    }

    @Test func toleratesDamagedRows() {
        let good: [String: AnnexJSON] = ["requestId": .string("grant_1"), "kind": .string("grant"), "projectId": .string("p1"),
                                         "agent": .object(["agentId": .string("planner")])]
        var unknownKind = good; unknownKind["kind"] = .string("future")
        var noAgent = good; noAgent.removeValue(forKey: "agent")
        var noID = good; noID["requestId"] = .integer(3)
        var futureAnswer = good; futureAnswer["requestId"] = .string("grant_2"); futureAnswer["answers"] = .array([.string("allow_forever"), .string("decline")])
        let rows = CompanionLiveService.grantRequests(from: .array([.object(good), .object(unknownKind), .object(noAgent), .object(noID), .object(futureAnswer), .null]), hostID: "h")
        #expect(rows.map(\.id) == ["grant_1", "grant_2"])
        // No `answers`: its kind's. Unknown answers are never offered.
        #expect(rows[0].answers == [.allowLasting, .decline] && rows[0].agentName == "planner" && rows[0].summary == "Asks for a Clubhouse permission.")
        #expect(rows[1].answers == [.decline] && rows[1].allowAnswer == nil)
        #expect(CompanionLiveService.grantRequests(from: .string("x"), hostID: "h").isEmpty)
    }

    @Test func everyRecordedAnswerIsOneThePhoneBuilds() throws {
        for item in try ContractFixtures.cases("commands/grant.answer.json") {
            let request = try #require(item["request"])
            let answer = try #require(request["answer"]?.string.flatMap(CompanionGrantRequest.Answer.init(rawValue:)), "\(item["name"]?.string ?? "")")
            let wire = try #require(AnnexCommand.GrantAnswer(rawValue: answer.rawValue))
            let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string),
                                       kind: .answerGrant(requestID: try #require(request["requestId"]?.string), answer: wire,
                                                          updateMode: request["updateMode"]?.string.flatMap(AnnexUpdateMode.init(rawValue:))))
            #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == request)
        }
    }

    /// Each refusal the desktop recorded maps to what the phone does with the row and a sentence to show.
    @Test func everyRecordedRefusalMapsToARowOutcome() throws {
        var codes: Set<String> = []
        for item in try ContractFixtures.cases("commands/grant.answer.json") {
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            guard let failure = receipt.error else { continue }
            codes.insert(failure.code)
            #expect(receipt.status == .rejected)
            let text = CompanionGrantRequestError.message(code: failure.code, message: failure.message)
            #expect(text == failure.message && text.first?.isUppercase == true && !text.contains(failure.code))
        }
        #expect(codes == ["grant_request_not_found", "grant_answer_not_offered", "grant_answer_failed"])
        // Without the desktop's sentence, the phone has its own.
        for code in codes { #expect(!CompanionGrantRequestError.message(code: code, message: code).contains(code)) }
        #expect(CompanionGrantRequestError.message(code: "grant_request_not_found", message: nil) == CompanionGrantRequestError.goneMessage)
    }

    // MARK: Needs you

    @Test func needsYouListsThemApartFromHelperAndCLIRequestsAndCountsThem() {
        let (store, _) = makeStore([ask(at: 60), call(at: 300)], agents: [agent("planner"), agent("docs", .approval)])
        let items = store.attentionItems(now: now)
        #expect(items.compactMap(\.grantRequest).map(\.id) == ["grant_call", "grant_ask"], "Oldest first")
        #expect(items.filter { $0.grantRequest != nil }.allSatisfy { $0.helperRequest == nil && $0.id.hasPrefix("grant:") && $0.prompt == nil })
        #expect(items.first { $0.grantRequest?.id == "grant_ask" }?.detail == "Asks for Change app settings on the app.")
        #expect(items.count == 3, "The CLI approval stays its own item")
        #expect(store.needsYouCount == 3)
    }

    @Test func hiddenWithoutTheCapabilityOfflineExpiredOrForAnUnlistedAgent() {
        #expect(makeStore([call()], capable: false).0.attentionItems(now: now).isEmpty)
        #expect(makeStore([call()], capable: false).0.needsYouCount == 0)
        #expect(makeStore([call()], connection: .offline).0.needsYouCount == 0)
        let expired = call(expires: -1)
        let (store, _) = makeStore([expired, call("grant_other", agentID: "gone")])
        #expect(store.attentionItems(now: now).isEmpty && store.needsYouCount == 0)
        #expect(!store.canAnswer(expired))
    }

    @Test func theDispatchersRequestsShowOnItsAgentAndInItsCount() {
        let dispatcherAgent = CompanionAgent(id: .init(hostID: "mac", projectID: CompanionDispatcher.defaultProjectID, agentID: "durable_dispatcher"),
                                             name: "Dispatcher", subtitle: "", status: .idle)
        let request = call(agentID: "durable_dispatcher", project: CompanionDispatcher.defaultProjectID)
        let (store, _) = makeStore([request], dispatcher: dispatcherAgent)
        let item = store.attentionItems(now: now).first
        #expect(item?.grantRequest == request && item?.agent.id == dispatcherAgent.id && item?.projectName == CompanionDispatcher.name)
        #expect(store.dispatcherNeedsYouCount == 1 && store.needsYouCount == 1)
    }

    // MARK: Answering

    @Test func answersOnlyWhatTheRequestTakesAndDropsTheRow() async {
        let (store, service) = makeStore([call(), ask()])
        await store.answer(call(), with: .allowLasting)
        await store.answer(ask(), with: .allowOnce)
        #expect(service.answers.isEmpty, "An answer the request doesn't list is never sent")
        await store.answer(call(), with: .allowOnce)
        await store.answer(ask(), with: .decline)
        #expect(service.answers.map(\.id) == ["grant_call", "grant_ask"] && service.answers.map(\.answer) == [.allowOnce, .decline])
        #expect(store.hosts[0].grantRequests.isEmpty && store.needsYouCount == 0)
        await store.answer(call(), with: .allowOnce)
        #expect(service.answers.count == 2, "An answered request can't be answered again")
    }

    @Test func aLostReplyRetriesWithTheSameCommandID() async {
        let (store, service) = makeStore([ask()])
        service.failures = [CompanionServiceError.uncertain("The desktop may have received this command, but its reply was lost.")]
        await store.answer(ask(), with: .allowLasting)
        #expect(store.grantRequestErrors[ask().slot]?.contains("reply was lost") == true && store.hosts[0].grantRequests.count == 1)
        await store.answer(ask(), with: .allowLasting)
        #expect(service.answers.count == 2 && service.answers[0].commandID == service.answers[1].commandID, "The desktop replays its receipt")
        #expect(store.hosts[0].grantRequests.isEmpty && store.grantRequestErrors[ask().slot] == nil)
    }

    @Test func aDifferentAnswerOrADefinitiveRefusalGetsANewCommandID() async {
        let (store, service) = makeStore([ask()])
        service.failures = [CompanionServiceError.uncertain("lost"), CompanionGrantRequestError.refused("Couldn’t save the permissions. Try again.")]
        await store.answer(ask(), with: .allowLasting)
        await store.answer(ask(), with: .decline)
        await store.answer(ask(), with: .decline)
        #expect(Set(service.answers.map(\.commandID)).count == 3)
    }

    @Test func aRefusalKeepsTheRowAndSaysWhy() async {
        let (store, service) = makeStore([ask()])
        service.failures = [CompanionGrantRequestError.refused("Couldn’t save the permissions. Try again.")]
        await store.answer(ask(), with: .allowLasting)
        #expect(store.hosts[0].grantRequests.map(\.id) == ["grant_ask"] && store.canAnswer(ask()))
        #expect(store.grantRequestErrors[ask().slot] == "Couldn’t save the permissions. Try again." && store.grantRequestNotice == nil)
    }

    @Test func aRequestThatIsGoneDropsItsRowWithANotice() async {
        let (store, service) = makeStore([call()])
        service.failures = [CompanionGrantRequestError.gone(CompanionGrantRequestError.goneMessage)]
        await store.answer(call(), with: .decline)
        #expect(store.hosts[0].grantRequests.isEmpty && store.grantRequestNotice == CompanionGrantRequestError.goneMessage)
        #expect(store.grantRequestErrors.isEmpty)
    }
}

// MARK: - Through the live service

/// A desktop from the fixtures whose `grant.answer` replies are scripted by recorded case name.
private final class GrantTransport: AnnexTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private var scripted: [String] = []
    private var sentCommands: [AnnexJSON] = []
    var sent: [AnnexJSON] { lock.withLock { sentCommands } }
    func script(_ names: String...) { lock.withLock { scripted += names } }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        lock.withLock { continuation = pair.continuation }
        return pair.stream
    }
    private var stream: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation? { lock.withLock { continuation } }
    func connect() { stream?.yield(.connection(.connected)) }
    func disconnect() {}
    func drop() { stream?.yield(.connection(.disconnected)) }
    func emit(_ frame: AnnexJSON) throws {
        var envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(frame))
        if envelope.type == "snapshot" { envelope.controlEpoch = try ContractFixtures.body("capabilities.json")["epoch"]?.string }
        stream?.yield(.message(envelope))
    }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities: return try ContractFixtures.body("capabilities.json")
        case .projects: return try ContractFixtures.body("rest-catalog.json", "projects")
        case .agents(let project): return project == "proj_app" ? try ContractFixtures.body("rest-catalog.json", "agents") : .array([])
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        let body = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
        let name: String? = lock.withLock {
            sentCommands.append(body)
            return scripted.isEmpty ? nil : scripted.removeFirst()
        }
        guard let name, case .object(var receipt)? = try ContractFixtures.cases("commands/grant.answer.json")
            .first(where: { $0["name"]?.string == name })?["response"]?["body"] else { throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID) }
        receipt["commandId"] = .string(command.commandID)
        return try AnnexJSON.object(receipt).decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct CompanionGrantRequestLiveTests {
    static let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    static let callID = "grant_00000000-0000-4000-8000-000000000008"
    static let askID = "grant_00000000-0000-4000-8000-000000000009"

    private func snapshot(_ rows: AnnexJSON? = nil) throws -> AnnexJSON {
        guard case .object(var frame)? = try ContractFixtures.json("snapshot.json")["frame"], case .object(var payload)? = frame["payload"] else {
            throw AnnexTransportError.malformedResponse
        }
        payload["grantRequests"] = try rows ?? ContractFixtures.json("snapshot-grant-requests.json")["value"]
        frame["payload"] = .object(payload)
        return .object(frame)
    }
    private func rows(_ ids: [String]) throws -> AnnexJSON {
        .array((try ContractFixtures.json("snapshot-grant-requests.json")["value"]).arrayValue.filter { ids.contains($0["requestId"]?.string ?? "") })
    }
    private func event(_ index: Int) throws -> AnnexJSON { try #require((try ContractFixtures.json("grant-request-events.json")["frames"]).arrayValue[safe: index]) }

    private func connect() async throws -> (CompanionLiveService, CompanionStore, GrantTransport) {
        let transport = GrantTransport()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: Self.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Studio Mac", transport: transport))
        try await waitUntil { store.hosts.first?.connection == .connected && store.hosts.first?.canAnswerGrantRequests == true }
        try transport.emit(try snapshot())
        try await waitUntil { store.hosts.first?.grantRequests.count == 2 }
        return (service, store, transport)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the fixture desktop")
        throw AnnexTransportError.disconnected
    }
    private func ids(_ store: CompanionStore) -> [String] { store.hosts.first?.grantRequests.map(\.id) ?? [] }

    @Test func theSnapshotListsRowsAndNeedsYouShowsTheListedAgents() async throws {
        let (service, store, _) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        #expect(ids(store) == [Self.callID, Self.askID])
        // This snapshot has no Dispatcher, so its row has no agent to show on; the planner's does.
        let items = store.attentionItems().compactMap(\.grantRequest)
        #expect(items.map(\.id) == [Self.askID] && items.first?.agentTarget.agentID == "durable_chat")
    }

    @Test func answersGoOutAsGrantAnswerAndDropTheRow() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let ask = try #require(store.hosts.first?.grantRequests.first { $0.id == Self.askID })
        transport.script("accepted allow_lasting")
        await store.answer(ask, with: .allowLasting)
        #expect(transport.sent.last?["type"]?.string == "grant.answer" && transport.sent.last?["answer"]?.string == "allow_lasting")
        #expect(transport.sent.last?["requestId"]?.string == Self.askID)
        #expect(ids(store) == [Self.callID])
        // A snapshot broadcast before the answer landed can't bring it back.
        try transport.emit(try snapshot())
        try await waitUntil { store.hosts.first?.grantRequests.count == 2 || ids(store) == [Self.callID] }
        try await Task.sleep(for: .milliseconds(30))
        #expect(ids(store) == [Self.callID])
    }

    @Test func refusalsFollowTheContract() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let ask = try #require(store.hosts.first?.grantRequests.first { $0.id == Self.askID })
        // A lasting Allow that couldn't be saved: nothing changed, the request still waits.
        transport.script("grant_answer_failed (the request still waits)")
        await store.answer(ask, with: .allowLasting)
        #expect(ids(store).contains(Self.askID) && store.grantRequestErrors[ask.slot] == "Couldn’t save the permissions. Try again.")
        // Not offered (a phone that showed the wrong answer): the request still waits.
        transport.script("grant_answer_not_offered (allow_once on a grant)")
        await #expect(throws: CompanionGrantRequestError.refused("This request adds a lasting permission. Allow or decline it.")) {
            try await service.answerGrantRequest(ask, answer: .allowOnce, clientCommandID: "not-offered")
        }
        #expect(ids(store).contains(Self.askID))
        // Expired, answered elsewhere, or about this device itself: drop the row.
        transport.script("grant_request_not_found (names this device)")
        await store.answer(ask, with: .decline)
        #expect(!ids(store).contains(Self.askID) && store.grantRequestNotice == "This request has expired or was already answered.")
    }

    @Test func aLostReplyIsRetriedUnderTheSameCommandID() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        let ask = try #require(store.hosts.first?.grantRequests.first { $0.id == Self.askID })
        await store.answer(ask, with: .decline)   // Nothing scripted: the reply is lost.
        #expect(store.grantRequestErrors[ask.slot] != nil && ids(store).contains(Self.askID))
        transport.script("accepted decline")
        await store.answer(ask, with: .decline)
        let sent = transport.sent
        try #require(sent.count == 2)
        #expect(sent[0] == sent[1], "Same command id and body: the desktop answers once and replays its receipt")
        #expect(!ids(store).contains(Self.askID))
    }

    @Test func eventsResolveRowsAndAReopenedRequestComesBack() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        // Answered anywhere: the row goes at once, before the snapshot that follows.
        try transport.emit(try event(1))
        try await waitUntil { ids(store) == [Self.askID] }
        // A snapshot from before the answer still lists it: it stays gone.
        try transport.emit(try snapshot())
        try await Task.sleep(for: .milliseconds(30))
        #expect(ids(store) == [Self.askID])
        // Its lasting Allow couldn't be saved: `opened` with the same id, then a snapshot with the row.
        try transport.emit(try event(0))
        try transport.emit(try snapshot())
        try await waitUntil { ids(store) == [Self.callID, Self.askID] }
        // Expired and withdrawn ids this phone never saw are tolerated.
        try transport.emit(try event(2))
        try transport.emit(try event(3))
        try transport.emit(try snapshot(try rows([Self.askID])))
        try await waitUntil { ids(store) == [Self.askID] }
    }

    @Test func anOpenedIDTheSnapshotDoesntListIsIgnored() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        // A Manage devices call that names this device: announced, but every snapshot to this device leaves it out.
        try transport.emit(.object(["type": .string("grant_request:opened"), "seq": .integer(1001),
                                    "payload": .object(["agentId": .string("durable_chat"), "requestId": .string("grant_about_this_phone"),
                                                        "kind": .string("call"), "projectId": .string("proj_app")])]))
        try transport.emit(try snapshot())
        try await Task.sleep(for: .milliseconds(30))
        #expect(ids(store) == [Self.callID, Self.askID])
        #expect(store.attentionItems().compactMap(\.grantRequest).allSatisfy { $0.id != "grant_about_this_phone" })
    }

    @Test func aReconnectTrustsTheNextWholeSnapshot() async throws {
        let (service, store, transport) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.hostID) }
        try transport.emit(try event(1))
        try await waitUntil { ids(store) == [Self.askID] }
        transport.drop()
        transport.connect()
        try transport.emit(try snapshot())
        try await waitUntil { ids(store) == [Self.callID, Self.askID] }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
