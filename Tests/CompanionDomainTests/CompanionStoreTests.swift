import Foundation
import Testing
@testable import CompanionDomain

@MainActor private final class TestCompanionService: CompanionService {
    enum SendResult { case accepted, rejected, uncertain }
    var sendResult: SendResult = .accepted
    var sent: [CompanionSendRequest] = []
    var responses: [String] = []
    var cancelled: [CompanionTarget] = []
    var spawnCount = 0
    var spawnResult: SendResult = .accepted
    var spawned: [CompanionSpawnRequest] = []
    var removedMessages: [String] = []
    var removalIsUncertain = false
    var historyValue = CompanionHistory(items: [])
    var historyGate: CheckedContinuation<CompanionHistory, Error>?
    var shouldSuspendHistory = false
    var sendGate: CheckedContinuation<CompanionCommandReceipt, Error>?
    var shouldSuspendSend = false
    var nextHistory: CompanionHistory?
    var responseGate: CheckedContinuation<Void, Error>?
    var shouldSuspendResponse = false

    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        if shouldSuspendHistory { return try await withCheckedThrowingContinuation { historyGate = $0 } }
        return historyValue
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        sent.append(request)
        if shouldSuspendSend { return try await withCheckedThrowingContinuation { sendGate = $0 } }
        switch sendResult {
        case .accepted: return .init(clientCommandID: request.clientCommandID)
        case .rejected: throw CompanionServiceError.rejected("Desktop rejected command")
        case .uncertain: throw CompanionServiceError.uncertain("Connection ended before acknowledgement")
        }
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { cancelled.append(target) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        responses.append(approvalID)
        if shouldSuspendResponse { try await withCheckedThrowingContinuation { responseGate = $0 } }
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        spawnCount += 1
        spawned.append(request)
        if spawnResult == .uncertain { throw CompanionServiceError.uncertain("Reply lost") }
        if spawnResult == .rejected { throw CompanionServiceError.rejected("Not started") }
        return .init(clientCommandID: request.clientCommandID)
    }
    func reconnect(hostID: String) async {}
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool {
        removedMessages.append(messageID)
        if removalIsUncertain { throw CompanionServiceError.uncertain("Reply lost") }
        return true
    }
}

@Suite @MainActor struct CompanionStoreTests {
    private let target = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "agent")

    private func makeStore(service: TestCompanionService) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(id: "host-a"), host(id: "host-b")]))
        return store
    }
    private func host(id: String) -> CompanionHost {
        .init(id: id, name: id, endpoint: "desktop.local", connection: .connected,
              projects: [.init(id: "project", name: "Project", agents: [
                .init(id: .init(hostID: id, projectID: "project", agentID: "agent"), name: "Agent", subtitle: "Task", status: .working, capabilities: [.chat, .steer, .cancel, .approve])
              ])])
    }

    @Test func hostIdentityAndDraftsStayIsolated() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let other = CompanionTarget(hostID: "host-b", projectID: "project", agentID: "agent")
        store.drafts[target] = "Send to A"
        store.drafts[other] = "Keep B"
        await store.sendDraft(to: target)
        #expect(service.sent.count == 1)
        #expect(service.sent[0].target == target)
        #expect(service.sent[0].isSteering)
        #expect(store.drafts[other] == "Keep B")
        #expect(store.conversation(for: other).items.isEmpty)
    }

    @Test func replayDoesNotAppendTextTwice() {
        let store = makeStore(service: TestCompanionService())
        store.apply(.textDelta(target, messageID: "reply", text: "Hello", sequence: 20))
        store.apply(.textDelta(target, messageID: "reply", text: "Hello", sequence: 20))
        store.apply(.textDelta(target, messageID: "reply", text: " world", sequence: 22))
        store.apply(.streamFinished(target, messageID: "reply", sequence: 23))
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        #expect(message.text == "Hello world")
        #expect(!message.isStreaming)
    }

    @Test func disconnectAndResyncDisableCommandsWithoutLosingDraft() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.drafts[target] = "Do this later"
        store.apply(.textDelta(target, messageID: "reply", text: "Partial", sequence: 2))
        store.apply(.resyncRequired(hostID: target.hostID))
        #expect(!store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        #expect(store.drafts[target] == "Do this later")
        service.historyValue = .init(items: [.message(.init(id: "reply", role: .assistant, text: "Complete"))], lastSequence: 4)
        await store.load(target, force: true)
        #expect(store.canSend(target))
        var disconnected = host(id: "host-a")
        disconnected.connection = .offline
        store.apply(.hosts([disconnected]))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
    }

    @Test func uncertainDeliveryCannotBeRetriedAsDefiniteFailure() async {
        let service = TestCompanionService()
        service.sendResult = .uncertain
        let store = makeStore(service: service)
        store.drafts[target] = "Potentially expensive action"
        await store.sendDraft(to: target)
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        guard case .uncertain = message.delivery else { Issue.record("Expected uncertain delivery"); return }
        await store.retry(messageID: message.id, target: target)
        #expect(service.sent.count == 1)
    }

    @Test func retryKeepsIdempotencyKeyAndEchoReconcilesLocalMessage() async {
        let service = TestCompanionService()
        service.sendResult = .rejected
        let store = makeStore(service: service)
        store.drafts[target] = "Hello"
        await store.sendDraft(to: target)
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        service.sendResult = .accepted
        await store.retry(messageID: message.id, target: target)
        #expect(service.sent.count == 2)
        #expect(service.sent[0].clientCommandID == service.sent[1].clientCommandID)
        store.apply(.upsert(target, .message(.init(id: "server-id", role: .user, text: "Hello", clientCommandID: service.sent[0].clientCommandID)), sequence: 8))
        #expect(store.conversation(for: target).items.count == 1)
        #expect(store.conversation(for: target).items[0].id == "message:server-id")
    }

    @Test func expiredPermissionCannotBeApproved() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let approval = CompanionApproval(id: "permission", toolName: "Shell", summary: "run command", deadline: Date(timeIntervalSince1970: 1), options: [.init(id: "allow", label: "Allow once", kind: .allowOnce)])
        await store.respond(approval, option: .init(id: "allow", label: "Allow once", kind: .allowOnce), target: target)
        #expect(service.responses.isEmpty)
    }

    @Test func liveEventsAreNotOverwrittenByStaleHistory() async {
        let service = TestCompanionService()
        service.shouldSuspendHistory = true
        let store = makeStore(service: service)
        let task = Task { await store.load(target) }
        while service.historyGate == nil { await Task.yield() }
        store.apply(.textDelta(target, messageID: "live", text: "Newest", sequence: 11))
        service.historyGate?.resume(returning: .init(items: [.message(.init(id: "old", role: .user, text: "Earlier message"))], lastSequence: 10))
        await task.value
        #expect(store.conversation(for: target).items.count == 2)
        #expect(store.conversation(for: target).items.first?.id == "message:old")
        #expect(store.conversation(for: target).lastSequence == 11)
    }

    @Test func lateReceiptDoesNotDowngradeConfirmedMessage() async {
        let service = TestCompanionService()
        service.shouldSuspendSend = true
        let store = makeStore(service: service)
        store.drafts[target] = "Hi"
        let task = Task { await store.sendDraft(to: target) }
        while service.sendGate == nil { await Task.yield() }
        let commandID = service.sent[0].clientCommandID
        store.apply(.upsert(target, .message(.init(id: "confirmed", role: .user, text: "Hi", clientCommandID: commandID)), sequence: 1))
        service.sendGate?.resume(returning: .init(clientCommandID: commandID))
        await task.value
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        #expect(message.delivery == .confirmed)
    }
    @Test func authoritativeApprovalResolutionWinsLateReceipt() async {
        let service = TestCompanionService()
        service.shouldSuspendResponse = true
        let store = makeStore(service: service)
        let option = CompanionApprovalOption(id: "allow", label: "Allow once", kind: .allowOnce)
        let approval = CompanionApproval(id: "p", toolName: "Command", summary: "Task", options: [option])
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        let task = Task { await store.respond(approval, option: option, target: target) }
        while service.responseGate == nil { await Task.yield() }
        var resolved = approval
        resolved.resolution = .denied
        store.apply(.upsert(target, .approval(resolved), sequence: 2))
        service.responseGate?.resume()
        await task.value
        guard case .approval(let final) = store.conversation(for: target).items[0] else { Issue.record("Expected approval"); return }
        #expect(final.resolution == .denied)
    }

    @Test func unrelatedTimelineDoesNotReopenAcknowledgedApproval() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let option = CompanionApprovalOption(id: "allow", label: "Allow once", kind: .allowOnce)
        let approval = CompanionApproval(id: "p", toolName: "Command", summary: "Task", options: [option])
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        await store.respond(approval, option: option, target: target)
        store.apply(.timeline(target, items: [.approval(approval), .notice(id: "other", text: "Working")], sequence: 2, reset: false))
        guard case .approval(let final) = store.conversation(for: target).items[0] else { Issue.record("Expected approval"); return }
        #expect(final.resolution == .allowed)
    }

    @Test func draftPersistenceRestoresAndClearsSentDraft() async {
        let persistence = TestDraftPersistence()
        persistence.values[target] = "Saved across launch"
        let service = TestCompanionService()
        let store = CompanionStore(service: service, draftPersistence: persistence)
        store.apply(.hosts([host(id: "host-a")]))
        #expect(store.drafts[target] == "Saved across launch")
        store.drafts[target] = "Updated draft"
        #expect(persistence.values[target] == "Updated draft")
        await store.sendDraft(to: target)
        #expect(persistence.values[target] == "")
    }

    @Test func queuedFollowUpWorksWithoutSteeringCapability() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a")
        value.projects[0].agents[0].capabilities = [.chat, .queue]
        store.apply(.hosts([value]))
        store.drafts[target] = "Next, review the tests"
        #expect(store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.first?.isSteering == false)
        #expect(service.sent.first?.queueIfBusy == true)
    }

    @Test func spawningRequiresAdvertisedHostCapability() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let project = CompanionProjectTarget(hostID: "host-a", projectID: "project")
        let unsupported = await store.spawn(project: project, prompt: "Task", provider: nil, model: nil)
        #expect(!unsupported)
        #expect(service.spawnCount == 0)
        var value = host(id: "host-a")
        value.canSpawn = true
        store.apply(.hosts([value]))
        let supported = await store.spawn(project: project, prompt: "Task", provider: nil, model: nil)
        #expect(supported)
        #expect(service.spawnCount == 1)
    }

    @Test func failedRefreshKeepsCommandsBlockedUntilReconciled() async {
        let service = TestCompanionService()
        service.shouldSuspendHistory = true
        let store = makeStore(service: service)
        store.drafts[target] = "Keep this direction"
        let task = Task { await store.load(target, force: true) }
        while service.historyGate == nil { await Task.yield() }
        #expect(!store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        service.historyGate?.resume(throwing: CompanionServiceError.unavailable("Offline"))
        await task.value
        #expect(!store.canSend(target))
        #expect(store.drafts[target] == "Keep this direction")
        service.shouldSuspendHistory = false
        await store.load(target, force: true)
        #expect(store.canSend(target))
    }

    @Test func uncertainSpawnCannotCreateAnotherTaskOnRetry() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.canSpawn = true
        store.apply(.hosts([value]))
        let project = CompanionProjectTarget(hostID: "host-a", projectID: "project")
        service.spawnResult = .uncertain
        #expect(await !store.spawn(project: project, prompt: "Original task", provider: "provider", model: "model"))
        #expect(store.uncertainSpawnRequest != nil)
        #expect(await !store.spawn(project: project, prompt: "Duplicate", provider: nil, model: nil))
        #expect(service.spawnCount == 1)
        service.spawnResult = .accepted
        #expect(await store.checkSpawnOutcome())
        #expect(service.spawnCount == 2)
        #expect(service.spawned[0].clientCommandID == service.spawned[1].clientCommandID)
        #expect(service.spawned[1].prompt == "Original task")
        #expect(service.spawned[1].model == "model")
        #expect(store.uncertainSpawnRequest == nil)
    }

    @Test func acknowledgedQueueRemovalCannotBeReopenedByUnrelatedTimeline() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.projects[0].agents[0].capabilities.insert(.removeQueued)
        store.apply(.hosts([value]))
        let queued = CompanionTimelineItem.message(.init(id: "m", role: .user, text: "Next task", queueState: .queued))
        store.apply(.timeline(target, items: [queued], sequence: 1, reset: true))
        await store.removeQueuedMessage("m", target: target)
        store.apply(.timeline(target, items: [queued, .notice(id: "other", text: "Activity")], sequence: 2, reset: false))
        await store.removeQueuedMessage("m", target: target)
        #expect(service.removedMessages == ["m"])
        guard case .message(let message) = store.conversation(for: target).items[0] else { Issue.record("Expected message"); return }
        #expect(message.queueState == .removed)
    }

    @Test func uncertainQueueRemovalRequiresReconciliation() async {
        let service = TestCompanionService(); service.removalIsUncertain = true
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.projects[0].agents[0].capabilities.insert(.removeQueued)
        store.apply(.hosts([value]))
        store.apply(.timeline(target, items: [.message(.init(id: "m", role: .user, text: "Task", queueState: .queued))], sequence: 1, reset: true))
        await store.removeQueuedMessage("m", target: target)
        await store.removeQueuedMessage("m", target: target)
        #expect(service.removedMessages == ["m"])
        #expect(store.conversation(for: target).requiresResync)
    }

    @Test func restartedSessionHistoryReplacesOlderHighSequence() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.apply(.timeline(target, items: [.notice(id: "old", text: "Previous session")], sequence: 100,
                              reset: true, sessionID: "old-session"))
        store.apply(.resyncRequired(hostID: target.hostID))
        service.historyValue = .init(items: [.notice(id: "new", text: "Restarted session")],
                                     lastSequence: 2, sessionID: "new-session")
        await store.load(target, force: true)
        #expect(store.conversation(for: target).items.map(\.id) == ["notice:new"])
        #expect(store.conversation(for: target).sessionID == "new-session")
        #expect(!store.conversation(for: target).requiresResync)
    }

    @Test func successfulHistoryWithNewerLiveEventsClearsResync() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.apply(.timeline(target, items: [.notice(id: "live", text: "Live update")], sequence: 12,
                              reset: true, sessionID: "session"))
        store.apply(.resyncRequired(hostID: target.hostID))
        service.historyValue = .init(items: [.notice(id: "past", text: "Earlier update")],
                                     lastSequence: 10, sessionID: "session")
        await store.load(target, force: true)
        #expect(store.conversation(for: target).items.count == 2)
        #expect(!store.conversation(for: target).requiresResync)
        #expect(store.canOperate(target))
    }

}

@MainActor private final class TestDraftPersistence: CompanionDraftPersistence {
    var values: [CompanionTarget: String] = [:]
    func load() -> [CompanionTarget: String] { values }
    func save(_ drafts: [CompanionTarget: String]) { values = drafts }
}
