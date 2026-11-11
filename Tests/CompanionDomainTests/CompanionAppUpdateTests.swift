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
    var holdCapabilities = false
    var capabilityGate: CheckedContinuation<Void, Never>?
    var includesSnapshotEpoch = true
    var holdReceipt = false
    var receiptGate: CheckedContinuation<Void, Never>?
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
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        switch route {
        case .capabilities:
            if holdCapabilities { await withCheckedContinuation { capabilityGate = $0 } }
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
        var envelope = AnnexEnvelope(type: "snapshot", payload: .object(payload), epoch: includesSnapshotEpoch ? epoch : nil)
        envelope.controlEpoch = epoch
        continuation?.yield(.message(envelope))
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
    func pauseCapabilities() { holdCapabilities = true }
    func releaseCapabilities() { holdCapabilities = false; capabilityGate?.resume(); capabilityGate = nil }
    var capabilitiesArePaused: Bool { capabilityGate != nil }
    func pauseReceipts() { holdReceipt = true }
    func releaseReceipt() { holdReceipt = false; receiptGate?.resume(); receiptGate = nil }
    var receiptIsPaused: Bool { receiptGate != nil }
    func omitSnapshotEpoch() { includesSnapshotEpoch = false }
    func setFailure(_ value: String?) { receiptFailure = value }
    func setBeforeReceipt(_ value: AnnexJSON) { beforeReceipt = value }
    func withdrawUpdateCapability() { supportsUpdate = false }
    func restart(version: String) {
        epoch = "new-epoch"
        update = .object(["state": .string("none"), "currentVersion": .string(version), "availableVersion": .null,
                          "downloadProgress": .integer(0), "reason": .null, "request": .null])
        rows = .array([])
    }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt {
        sent.append(command)
        if holdReceipt { await withCheckedContinuation { receiptGate = $0 } }
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
    private func connect(iconStore: CompanionIconStore = .shared) async throws -> (CompanionLiveService, CompanionStore, UpdateDesktop) {
        let desktop = try UpdateDesktop()
        let service = CompanionLiveService(iconStore: iconStore)
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
        for code in ["dispatcher_unavailable", "update_approval_capacity"] {
            try await wait { store.hosts.first?.connection == .connected }
            await desktop.setFailure(code)
            await store.requestAppUpdate(hostID: Self.id)
            let recorded = try #require(ContractFixtures.cases("commands/app.update.request.json").first {
                $0["response"]?["body"]?["error"]?["code"]?.string == code
            })
            #expect(store.appUpdateErrors[Self.id] == recorded["response"]?["body"]?["error"]?["message"]?.string)
        }
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
        let store = CompanionStore(service: service)
        store.apply(.hosts(pending))
        #expect(store.canAnswer(request))
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

    @Test func qaLostUpdateRequestReusesItsCommandID() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let ready = try #require(ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
            $0["state"]?.string == "ready" && $0["request"] == .null
        })
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await desktop.setLostReply(true)
        await store.requestAppUpdate(hostID: Self.id)
        await store.requestAppUpdate(hostID: Self.id)
        let sent = await desktop.sent
        try #require(sent.count == 2)
        #expect(sent[0].commandID == sent[1].commandID,
                "A lost reply must not turn a retry into a new request")
    }

    @Test(arguments: [false, true])
    func terminalShutdownClearsUnknownUpdatesAndRejectsLateReplies(cancel: Bool) async throws {
        let (service, store, desktop) = try await connect()
        defer { service.remove(hostID: Self.id) }
        let value = try #require(cancel
            ? ContractFixtures.json("snapshot-app-update-approval.json")["appUpdate"]
            : ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
                $0["state"]?.string == "ready" && $0["request"] == .null
            })
        let expected = try value.decode(AnnexAppUpdate.self)
        try await desktop.change(value)
        try await wait { store.hosts.first?.appUpdate == expected }
        let perform: @MainActor () async -> Void = {
            if cancel { await store.cancelAppUpdate(hostID: Self.id) }
            else { await store.requestAppUpdate(hostID: Self.id) }
        }
        await desktop.setLostReply(true)
        await perform()
        #expect(store.appUpdateErrors[Self.id] != nil)
        await desktop.pauseReceipts()
        let retry = Task { await perform() }
        try await wait { await desktop.receiptIsPaused }
        let prior = store.hosts
        store.shutdown()
        #expect(store.appUpdateInFlight.isEmpty && store.appUpdateErrors.isEmpty)
        await service.shutdown()
        await desktop.releaseReceipt()
        await retry.value
        #expect(store.appUpdateErrors.isEmpty)
        #expect(store.hosts.first?.appUpdate == nil)
        store.start()
        store.apply(.hosts(prior))
        await perform()
        #expect(await desktop.sent.count == 2, "Shutdown must neither replay nor admit a fresh update")
        #expect(store.hosts.first?.appUpdate == nil)
        #expect(service.registeredHostIDs.isEmpty)
        var events = service.events().makeAsyncIterator()
        guard case .hosts(let stopped) = await events.next() else { Issue.record("Missing shutdown hosts"); return }
        #expect(stopped.first?.appUpdate == nil && stopped.first?.controlEpoch == nil)
        #expect(stopped.first?.canUpdateApp == false)
    }

    @Test(arguments: [false, true])
    func terminalShutdownClearsApprovalAttemptsAndRejectsALateAnswer(lostReply: Bool) async throws {
        let (service, store, desktop) = try await connect()
        defer { service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let request = try #require(store.hosts.first?.grantRequests.first)
        await desktop.setLostReply(true)
        await store.answer(request, with: .allowOnce, updateMode: .whenIdle)
        #expect(store.grantRequestErrors[request.slot] != nil)
        await desktop.pauseReceipts()
        let retry = Task { await store.answer(request, with: .allowOnce, updateMode: .whenIdle) }
        try await wait { await desktop.receiptIsPaused }
        store.shutdown()
        await service.shutdown()
        await desktop.setLostReply(lostReply)
        await desktop.releaseReceipt()
        await retry.value
        #expect(store.grantRequestsInFlight.isEmpty && store.grantRequestErrors.isEmpty)
        #expect(store.grantRequestNotice == nil)
        #expect(store.hosts.first?.grantRequests.isEmpty == true)
        #expect(!store.canAnswer(request))
        await store.answer(request, with: .allowOnce, updateMode: .now)
        #expect(await desktop.sent.count == 2)
    }

    @Test func qaNewEpochCannotPublishThePreviousEpochsApprovalWhileSnapshotWaitsForIcons() async throws {
        let icons = CompanionIconStore()
        let (service, store, desktop) = try await connect(iconStore: icons)
        defer { store.stop(); service.remove(hostID: Self.id) }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let oldRequest = try #require(store.hosts.first?.grantRequests.first)
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await icons.qaHoldActor(entered: enteredContinuation, release: release) }
        for await _ in entered { break }
        defer { release.signal() }
        await desktop.restart(version: "1.1.0")
        await desktop.pauseCapabilities()
        await service.reconnect(hostID: Self.id)
        try await wait { await desktop.capabilitiesArePaused }
        try await Task.sleep(for: .milliseconds(100))
        await desktop.releaseCapabilities()
        try await wait { store.hosts.first?.controlEpoch == "new-epoch" && store.hosts.first?.connection == .connected }
        #expect(store.hosts.first?.grantRequests.isEmpty == true,
                "Publishing the new epoch must retire old approvals before awaiting icon work")
        #expect(!store.canAnswer(oldRequest))
        release.signal()
        await blocker.value
    }

    @Test(arguments: [false, true])
    func lostUpdateRepliesRequireExplicitRetriesAndDoNotSurviveANewEpoch(cancel: Bool) async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let value = try #require(cancel
            ? ContractFixtures.json("snapshot-app-update-approval.json")["appUpdate"]
            : ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
                $0["state"]?.string == "ready" && $0["request"] == .null
            })
        let expected = try value.decode(AnnexAppUpdate.self)
        try await desktop.change(value)
        try await wait { store.hosts.first?.appUpdate == expected }
        let perform: @MainActor () async -> Void = {
            if cancel { await store.cancelAppUpdate(hostID: Self.id) }
            else { await store.requestAppUpdate(hostID: Self.id) }
        }
        await desktop.setLostReply(true)
        await perform()
        #expect(store.appUpdateErrors[Self.id]?.contains("reply was lost") == true)
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.connection == .connected && store.hosts.first?.appUpdate == expected }
        #expect(await desktop.sent.count == 1, "Reconnect never retries an unknown outcome")
        await desktop.setLostReply(false)
        await perform()
        let recovered = await desktop.sent
        try #require(recovered.count == 2)
        #expect(recovered[0] == recovered[1], "An explicit retry recovers the original command's receipt")
        #expect(store.appUpdateErrors[Self.id] == nil)
        await desktop.setLostReply(true)
        await perform()
        let previousAttempt = try #require(await desktop.sent.last)
        #expect(previousAttempt.commandID != recovered[1].commandID, "A completed attempt is not reused")
        await desktop.restart(version: "1.1.0")
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.connection == .connected && store.hosts.first?.controlEpoch == "new-epoch" }
        #expect(await desktop.sent.count == 3, "A new epoch never replays old attempts")
        #expect(store.appUpdateErrors[Self.id] == nil)
        try await desktop.change(value)
        try await wait { store.hosts.first?.appUpdate == expected }
        await perform()
        let currentAttempt = try #require(await desktop.sent.last)
        #expect(await desktop.sent.count == 4)
        #expect(currentAttempt.commandID != previousAttempt.commandID)
        #expect(currentAttempt.epoch == "new-epoch")
    }

    @Test func anUncertainRequestAndCancellationKeepIndependentRetryIDsUntilResolved() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        await desktop.setLostReply(true)
        let pending = try #require(ContractFixtures.json("snapshot-app-update-approval.json")["appUpdate"])
        let ready = try #require(ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
            $0["state"]?.string == "ready" && $0["request"] == .null
        })
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await store.requestAppUpdate(hostID: Self.id)
        try await desktop.change(pending)
        try await wait { store.hosts.first?.appUpdate?.request?.canCancel == true }
        await store.cancelAppUpdate(hostID: Self.id)
        await store.cancelAppUpdate(hostID: Self.id)
        let unresolved = await desktop.sent
        try #require(unresolved.count == 3)
        #expect(unresolved[0].commandID != unresolved[1].commandID)
        #expect(unresolved[1] == unresolved[2])
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await store.requestAppUpdate(hostID: Self.id)
        let sent = await desktop.sent
        try #require(sent.count == 4)
        #expect(sent[0].commandID != sent[3].commandID, "Authoritative disappearance resolved the earlier request")
    }

    @Test func anOldApprovalCannotAnswerAnIdenticalRequestIDInTheNewEpoch() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        await desktop.omitSnapshotEpoch()
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let oldRequest = try #require(store.hosts.first?.grantRequests.first)
        await desktop.restart(version: "1.1.0")
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.controlEpoch == "new-epoch" && store.hosts.first?.connection == .connected }
        try await desktop.openApproval()
        try await wait { store.hosts.first?.grantRequests.count == 1 }
        let currentRequest = try #require(store.hosts.first?.grantRequests.first)
        #expect(oldRequest.id == currentRequest.id)
        #expect(!store.canAnswer(oldRequest) && store.canAnswer(currentRequest))
        await store.answer(oldRequest, with: .allowOnce, updateMode: .now)
        await #expect(throws: CompanionServiceError.self) {
            try await service.answerGrantRequest(oldRequest, answer: .allowOnce, updateMode: .now, clientCommandID: "fresh-id-for-stale-row")
        }
        #expect(await desktop.sent.isEmpty)
        await store.answer(currentRequest, with: .decline)
        #expect(await desktop.sent.count == 1)
    }

    @Test func qaReconciledCancelledRequestAllowsAFreshExplicitRequest() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let values = try ContractFixtures.json("app-update-statuses.json")["values"].arrayValue
        let ready = try #require(values.first { $0["state"]?.string == "ready" && $0["request"] == .null })
        let pending = try #require(values.first { $0["request"]?["state"]?.string == "pending_approval" })
        let cancelled = try #require(values.first { $0["request"]?["state"]?.string == "cancelled" })
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await desktop.setLostReply(true)
        await store.requestAppUpdate(hostID: Self.id)
        try await desktop.change(pending)
        try await wait { store.hosts.first?.appUpdate?.request?.state == .pendingApproval }
        try await desktop.change(cancelled)
        try await wait { store.hosts.first?.appUpdate?.request?.state == .cancelled }
        await desktop.setLostReply(false)
        await store.requestAppUpdate(hostID: Self.id)
        let sent = await desktop.sent
        try #require(sent.count == 2)
        #expect(sent[0].commandID != sent[1].commandID,
                "A new request after authoritative cancellation is not a retry of the old request")
    }

    @Test(arguments: [false, true])
    func authoritativeTerminalStatesResolveUnknownRequestAndCancelOutcomes(cancel: Bool) async throws {
        let values = try ContractFixtures.json("app-update-statuses.json")["values"].arrayValue
        let ready = try #require(values.first { $0["state"]?.string == "ready" && $0["request"] == .null })
        let pending = try #require(values.first { $0["request"]?["state"]?.string == "pending_approval" })
        for value in values where ["cancelled", "failed"].contains(value["request"]?["state"]?.string ?? "") {
            let (service, store, desktop) = try await connect()
            defer { store.stop(); service.remove(hostID: Self.id) }
            if !cancel {
                try await desktop.change(ready)
                try await wait { store.hosts.first?.appUpdate?.canRequest == true }
            }
            await desktop.setLostReply(true)
            if cancel { await store.cancelAppUpdate(hostID: Self.id) }
            else { await store.requestAppUpdate(hostID: Self.id) }
            #expect(store.appUpdateErrors[Self.id] != nil)
            try await desktop.change(pending)
            try await wait { store.hosts.first?.appUpdate?.request?.state == .pendingApproval }
            let expected = try value.decode(AnnexAppUpdate.self)
            try await desktop.change(value)
            try await wait { store.hosts.first?.appUpdate == expected }
            #expect(store.appUpdateErrors[Self.id] == nil, "Authoritative outcomes resolve the lost receipt")
            #expect(await desktop.sent.count == 1, "Reconciliation must never dispatch another command")
            if !cancel {
                await desktop.setLostReply(false)
                await store.requestAppUpdate(hostID: Self.id)
                let sent = await desktop.sent
                try #require(sent.count == 2)
                #expect(sent[0].commandID != sent[1].commandID)
            }
        }
    }

    @Test func aPreexistingTerminalRowDoesNotResolveANewUnknownRequest() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let cancelled = try #require(ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
            $0["request"]?["state"]?.string == "cancelled"
        })
        try await desktop.change(cancelled)
        try await wait { store.hosts.first?.appUpdate?.request?.state == .cancelled }
        await desktop.setLostReply(true)
        await store.requestAppUpdate(hostID: Self.id)
        await service.reconnect(hostID: Self.id)
        try await wait { store.hosts.first?.connection == .connected }
        #expect(store.appUpdateErrors[Self.id] != nil)
        await desktop.setLostReply(false)
        await store.requestAppUpdate(hostID: Self.id)
        let sent = await desktop.sent
        try #require(sent.count == 2)
        #expect(sent[0] == sent[1], "The old terminal row must not invent a fresh request id for an unresolved attempt")
    }

    @Test func anInstalledVersionResolvesALostRequestWithoutAnIntermediateApprovalSnapshot() async throws {
        let (service, store, desktop) = try await connect()
        defer { store.stop(); service.remove(hostID: Self.id) }
        let ready = try #require(ContractFixtures.json("app-update-statuses.json")["values"].arrayValue.first {
            $0["state"]?.string == "ready" && $0["request"] == .null
        })
        let version = try #require(ready["availableVersion"]?.string)
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await desktop.setLostReply(true)
        await store.requestAppUpdate(hostID: Self.id)
        try await desktop.change(.object(["state": .string("none"), "currentVersion": .string(version), "downloadProgress": .integer(0)]))
        try await wait { store.hosts.first?.appUpdate?.currentVersion == version }
        #expect(store.appUpdateErrors[Self.id] == nil)
        #expect(await desktop.sent.count == 1)
        try await desktop.change(ready)
        try await wait { store.hosts.first?.appUpdate?.canRequest == true }
        await desktop.setLostReply(false)
        await store.requestAppUpdate(hostID: Self.id)
        let sent = await desktop.sent
        try #require(sent.count == 2)
        #expect(sent[0].commandID != sent[1].commandID)
    }
}

private extension CompanionIconStore {
    func qaHoldActor(entered: AsyncStream<Void>.Continuation, release: DispatchSemaphore) {
        entered.yield(())
        release.wait()
    }
}
