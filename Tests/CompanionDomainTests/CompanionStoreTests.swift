import Foundation
import Testing
@testable import CompanionDomain

@MainActor private final class TestCompanionService: CompanionService {
    enum SendResult { case accepted, rejected, uncertain }
    var sendResult: SendResult = .accepted
    var sent: [CompanionSendRequest] = []
    var responses: [String] = []
    var cancelled: [CompanionTarget] = []
    var historyValue = CompanionHistory(items: [])
    var historyGate: CheckedContinuation<CompanionHistory, Error>?
    var shouldSuspendHistory = false
    var sendGate: CheckedContinuation<CompanionCommandReceipt, Error>?
    var shouldSuspendSend = false
    var nextHistory: CompanionHistory?

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
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { responses.append(approvalID) }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
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
}
