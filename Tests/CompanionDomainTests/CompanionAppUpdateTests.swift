import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private actor UpdateDesktop: AnnexTransporting {
    var epoch = "old-epoch"
    var update: AnnexJSON
    var lostReply = false
    var receiptFailure: String?
    var beforeReceipt: AnnexJSON?
    var supportsUpdate = true
    var sent: [AnnexCommand] = []
    var capabilityReads = 0
    var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    var rows: AnnexJSON = .array([])
    init() throws {
        update = try #require(ContractFixtures.json("snapshot-app-update-approval.json")["appUpdate"])
    }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() throws {
        continuation?.yield(.connection(.connecting))
        continuation?.yield(.connection(.connected))
        try snapshot()
    }
    func disconnect() { continuation?.yield(.connection(.disconnected)) }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities:
            capabilityReads += 1
            guard case .object(var value) = try ContractFixtures.body("capabilities.json") else { throw AnnexTransportError.malformedResponse }
            value["epoch"] = .string(epoch)
            if !supportsUpdate { value["appUpdate"] = nil }
            return .object(value)
        case .projects: return .array([])
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func snapshot() throws {
        guard case .object(var payload)? = try ContractFixtures.json("snapshot.json")["frame"]?["payload"] else {
            throw AnnexTransportError.malformedResponse
        }
        payload["appUpdate"] = update
        payload["grantRequests"] = rows
        payload["dispatcher"] = try ContractFixtures.json("snapshot-dispatcher.json")["value"]
            ?? ContractFixtures.json("snapshot-dispatcher.json")["frame"]?["payload"]?["dispatcher"]
        continuation?.yield(.message(.init(type: "snapshot", payload: .object(payload), epoch: epoch)))
    }
    func openApproval() throws {
        rows = .array([try #require(ContractFixtures.json("snapshot-app-update-approval.json")["grantRequest"])])
        try snapshot()
    }
    func change(_ value: AnnexJSON) throws {
        update = value
        continuation?.yield(.message(.init(type: "app_update:changed", payload: value)))
    }
    func setLostReply(_ value: Bool) { lostReply = value }
    func setFailure(_ value: String?) { receiptFailure = value }
    func setBeforeReceipt(_ value: AnnexJSON) { beforeReceipt = value }
    func withdrawUpdateCapability() { supportsUpdate = false }
    func restart(version: String) {
        epoch = "new-epoch"
        update = .object(["state": .string("none"), "currentVersion": .string(version), "availableVersion": .null,
                          "downloadProgress": .integer(0), "reason": .null, "request": .null])
        rows = .array([])
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        sent.append(command)
        if lostReply { throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID) }
        if let receiptFailure {
            guard let item = try ContractFixtures.cases("commands/app.update.request.json").first(where: { $0["response"]?["body"]?["error"]?["code"]?.string == receiptFailure }),
                  case .object(var receipt)? = item["response"]?["body"] else { throw AnnexTransportError.malformedResponse }
            receipt["commandId"] = .string(command.commandID)
            receipt["epoch"] = .string(epoch)
            return try AnnexJSON.object(receipt).decode(AnnexCommandReceipt.self)
        }
        if let beforeReceipt { try change(beforeReceipt) }
        let result: AnnexJSON
        switch command.kind {
        case .requestAppUpdate:
            result = try #require(ContractFixtures.json("snapshot-app-update-approval.json")["appUpdate"]?["request"])
        case .cancelAppUpdate:
            result = try #require(ContractFixtures.cases("commands/app.update.cancel.json").first?["response"]?["body"]?["result"])
        case .answerGrant(let id, let answer, _):
            result = .object(["requestId": .string(id), "kind": .string("call"), "answer": .string(answer.rawValue)])
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
        return try AnnexJSON.object(["version": .integer(1), "commandId": .string(command.commandID), "epoch": .string(epoch),
                                     "status": .string("completed"), "result": result]).decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct CompanionAppUpdateTests {
    static let id = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AnnexTransportError.disconnected
    }
    private func connect() async throws -> (CompanionLiveService, CompanionStore, UpdateDesktop) {
        let desktop = try UpdateDesktop()
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: Self.id,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        await service.register(.init(host: host, alias: "Studio Mac", transport: desktop))
        try await wait { store.hosts.first?.canUpdateApp == true && store.hosts.first?.appUpdate != nil }
        return (service, store, desktop)
    }

    @Test func snapshotAndWholeEventsDriveStatusCancellationAndErrors() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        for value in (try ContractFixtures.json("app-update-statuses.json")["values"]).arrayValue {
            let expected = try value.decode(AnnexAppUpdate.self)
            try await desktop.change(value)
            try await wait { store.hosts.first?.appUpdate == expected }
            #expect(CompanionAppUpdateText.indicator(expected, desktop: "Studio Mac").contains("Studio Mac"))
            if let request = expected.request {
                #expect(!CompanionAppUpdateText.requestState(request).isEmpty)
                let before = await desktop.sent.count
                await store.cancelAppUpdate(hostID: Self.id)
                #expect(await desktop.sent.count == before + (request.canCancel ? 1 : 0))
            }
        }
        try await desktop.change(.object(["state": .string("future")]))
        try await wait { store.hosts.first?.appUpdateError != nil }
        #expect(store.hosts.first?.appUpdate == nil)
    }

    @Test func approvalRequiresModeAndNonUpdateAnswersStillUseTheOldShape() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let request = try #require(store.hosts.first?.grantRequests.first)
        #expect(request.update?.workingAgents.first?.name == "planner")
        await store.answer(request, with: .allowOnce)
        #expect(await desktop.sent.isEmpty)
        #expect(store.grantRequestErrors[request.slot]?.contains("Choose") == true)
        await desktop.setLostReply(true)
        await store.answer(request, with: .allowOnce, updateMode: .whenIdle)
        await store.answer(request, with: .allowOnce, updateMode: .whenIdle)
        let sent = await desktop.sent
        #expect(sent.count == 2 && sent[0] == sent[1])
        #expect(sent[0].kind == .answerGrant(requestID: request.id, answer: .allowOnce, updateMode: .whenIdle))
        await desktop.setLostReply(false)
        await store.answer(request, with: .decline)
        #expect(await desktop.sent.last?.kind == .answerGrant(requestID: request.id, answer: .decline))
    }

    @Test func newEpochRefetchesCapabilitiesDropsOldApprovalsAndNeverReplaysTheLostAnswer() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let request = try #require(store.hosts.first?.grantRequests.first)
        await desktop.setLostReply(true)
        await #expect(throws: CompanionServiceError.self) {
            try await service.answerGrantRequest(request, answer: .allowOnce, updateMode: .now, clientCommandID: "lost-approval")
        }
        let reads = await desktop.capabilityReads
        await desktop.restart(version: "1.1.0")
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.controlEpoch == "new-epoch" && store.hosts.first?.appUpdate?.request == nil }
        #expect(await desktop.capabilityReads > reads)
        #expect(store.hosts.first?.appUpdateOutcome == "Updated to 1.1.0.")
        #expect(store.hosts.first?.grantRequests.isEmpty == true)
        await store.answer(request, with: .allowOnce, updateMode: .now)
        await #expect(throws: CompanionServiceError.self) {
            try await service.answerGrantRequest(request, answer: .allowOnce, updateMode: .now, clientCommandID: "lost-approval")
        }
        #expect(await desktop.sent.count == 1)
    }

    @Test func requestsOnlyReadyUpdatesAndShowsTheDesktopRefusal() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let values = (try ContractFixtures.json("app-update-statuses.json")["values"]).arrayValue
        for value in values {
            let update = try value.decode(AnnexAppUpdate.self)
            try await desktop.change(value)
            try await wait { store.hosts.first?.appUpdate == update }
            let before = await desktop.sent.count
            await store.requestAppUpdate(hostID: Self.id)
            #expect(await desktop.sent.count == before + (update.canRequest ? 1 : 0))
        }
        try await desktop.change(values[5])
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await desktop.setFailure("dispatcher_unavailable")
        await store.requestAppUpdate(hostID: Self.id)
        #expect(store.appUpdateErrors[Self.id]?.contains("desktop banner") == true)
    }

    @Test(arguments: AnnexUpdateMode.allCases) func previewUsesOnlySyntheticStateForEveryUpdateChoice(_ mode: AnnexUpdateMode) async throws {
        let service = CompanionPreviewService()
        service.showsAppUpdate = true
        var events = service.events().makeAsyncIterator()
        guard case .hosts(let initial) = await events.next() else { Issue.record("Missing preview hosts"); return }
        let host = try #require(initial.first)
        #expect(host.canUpdateApp && host.appUpdate?.canRequest == true)
        try await service.requestAppUpdate(hostID: host.id, clientCommandID: "preview-request")
        guard case .hosts(let pending) = await events.next() else { Issue.record("Missing preview approval"); return }
        let request = try #require(pending.first?.grantRequests.first)
        #expect(request.isAppUpdate && request.update?.workingAgents.first?.name == "River")
        await #expect(throws: CompanionServiceError.self) {
            try await service.answerGrantRequest(request, answer: .allowOnce, updateMode: nil, clientCommandID: "no-choice")
        }
        try await service.answerGrantRequest(request, answer: .allowOnce, updateMode: mode, clientCommandID: "preview-answer")
        guard case .hosts(let approved) = await events.next() else { Issue.record("Missing preview result"); return }
        #expect(approved.first?.grantRequests.isEmpty == true)
        #expect(approved.first?.appUpdate?.request?.state == (mode == .now ? .restarting : .waitingForIdle))
        if mode == .whenIdle {
            try await service.cancelAppUpdate(hostID: host.id, requestID: request.id, clientCommandID: "preview-cancel")
            guard case .hosts(let cancelled) = await events.next() else { Issue.record("Missing preview cancellation"); return }
            #expect(cancelled.first?.appUpdate?.request?.state == .cancelled)
            try await service.requestAppUpdate(hostID: host.id, clientCommandID: "preview-request-again")
            _ = await events.next()
            try await service.answerGrantRequest(request, answer: .decline, updateMode: nil, clientCommandID: "preview-decline")
            guard case .hosts(let declined) = await events.next() else { Issue.record("Missing preview decline"); return }
            #expect(declined.first?.appUpdate?.request?.state == .cancelled)
        }
    }

    @Test func anUnchangedVersionAfterRestartIsUnconfirmedNotAnAutomaticRetry() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let request = try #require(store.hosts.first?.grantRequests.first)
        try await service.answerGrantRequest(request, answer: .allowOnce, updateMode: .whenIdle, clientCommandID: "approve")
        await desktop.restart(version: "0.0.0-test")
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.appUpdateOutcome != nil }
        #expect(store.hosts.first?.appUpdateOutcome?.contains("unconfirmed") == true)
        #expect(await desktop.sent.count == 1)
    }

    @Test func anEventBeforeTheReceiptIsNotReplacedByThatReceiptsOlderResult() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let statuses = (try ContractFixtures.json("app-update-statuses.json")["values"]).arrayValue
        let waiting = try #require(statuses.first { $0["request"]?["state"]?.string == "waiting_for_idle" })
        await desktop.setBeforeReceipt(waiting)
        try await service.requestAppUpdate(hostID: Self.id, clientCommandID: "request")
        try await wait { store.hosts.first?.appUpdate?.request?.state == .waitingForIdle }
        #expect(store.hosts.first?.appUpdate?.request?.version == "1.1.0")
    }

    @Test func withdrawingTheCapabilityHidesUpdateApprovalsAndBlocksCommands() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let request = try #require(store.hosts.first?.grantRequests.first)
        await desktop.withdrawUpdateCapability()
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.canUpdateApp == false }
        #expect(store.attentionItems().compactMap(\.grantRequest).isEmpty)
        #expect(!store.canAnswer(request))
        await store.answer(request, with: .allowOnce, updateMode: .now)
        await store.requestAppUpdate(hostID: Self.id)
        #expect(await desktop.sent.isEmpty)
    }
}
