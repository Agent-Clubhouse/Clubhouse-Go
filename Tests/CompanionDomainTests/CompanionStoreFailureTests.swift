import Foundation
import Testing
@testable import CompanionDomain

/// A service whose every optional command is scripted per test. Unscripted commands behave like a desktop that
/// accepts them. Required-only conformers (see `BareCompanionService`) exercise the protocol's defaults instead.
@MainActor private final class ScriptedCompanionService: CompanionService {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "Socket closed" } }

    var historyValue = CompanionHistory(items: [])
    var historyCalls = 0
    var sent: [CompanionSendRequest] = []
    var sendError: Error?
    var cancelled: [CompanionTarget] = []
    var cancelError: Error?
    var responses: [String] = []
    var respondError: Error?
    var answered: [String] = []
    var answerError: Error?
    var answerGate: CheckedContinuation<Void, Error>?
    var shouldSuspendAnswer = false
    var contentCalls: [CompanionContentReference] = []
    var contentResult: (CompanionContentReference) throws -> CompanionContent = { reference in
        .init(kind: "image", name: "image", mimeType: "image/png", bytes: Data(reference.id.utf8))
    }
    var created: [CompanionCreateRequest] = []
    var createError: Error?
    var createOptionsValue = CompanionCreateOptions(options: .init())
    var removeQueuedResult = true
    var reconnected: [String] = []
    var spawnError: Error?

    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { historyCalls += 1; return historyValue }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        sent.append(request)
        if let sendError { throw sendError }
        return .init(clientCommandID: request.clientCommandID)
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {
        cancelled.append(target)
        if let cancelError { throw cancelError }
    }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        responses.append(approvalID)
        if let respondError { throw respondError }
    }
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws {
        answered.append(questionID)
        if shouldSuspendAnswer { try await withCheckedThrowingContinuation { answerGate = $0 } }
        if let answerError { throw answerError }
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        if let spawnError { throw spawnError }
        return .init(clientCommandID: request.clientCommandID)
    }
    func reconnect(hostID: String) async { reconnected.append(hostID) }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        contentCalls.append(reference)
        return try contentResult(reference)
    }
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions { createOptionsValue }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt {
        created.append(request)
        if let createError { throw createError }
        return .init(target: .init(hostID: request.project.hostID, projectID: request.project.projectID, agentID: "new-agent"), isCreating: true)
    }
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool { removeQueuedResult }
}

@Suite @MainActor struct CompanionStoreFailureTests {
    private let target = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "agent")
    private var project: CompanionProjectTarget { .init(hostID: "host-a", projectID: "project") }

    private func host(capabilities: CompanionCapabilities = [.chat, .steer, .cancel, .approve, .answer],
                      status: CompanionAgentStatus = .working, configure: (inout CompanionHost) -> Void = { _ in }) -> CompanionHost {
        var value = CompanionHost(id: "host-a", name: "Desk", endpoint: "desktop.local", connection: .connected,
                                  projects: [.init(id: "project", name: "Project", agents: [
                                    .init(id: target, name: "Agent", subtitle: "Task", status: status, capabilities: capabilities)
                                  ])])
        configure(&value)
        return value
    }
    private func makeStore(_ service: ScriptedCompanionService, host: CompanionHost? = nil) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts([host ?? self.host()]))
        return store
    }
    private func onlyMessage(_ store: CompanionStore) -> CompanionMessage? {
        guard case .message(let message)? = store.conversation(for: target).items.first else { return nil }
        return message
    }

    // MARK: Sending

    @Test func unexpectedSendErrorLeavesDeliveryUncertainAndBlocksRetry() async throws {
        let service = ScriptedCompanionService()
        service.sendError = ScriptedCompanionService.Failure()
        let store = makeStore(service)
        store.drafts[target] = "Ship it"
        await store.sendDraft(to: target)
        let message = try #require(onlyMessage(store))
        #expect(message.delivery == .uncertain("Socket closed"))
        #expect(message.delivery.label == "Delivery unknown")
        #expect(!store.pendingCommands.contains(target))
        await store.retry(messageID: message.id, target: target)
        #expect(service.sent.count == 1, "An uncertain send keeps its identity until reconciled")
    }

    @Test func rejectedSendCanBeRetriedAndIsThenAccepted() async throws {
        let service = ScriptedCompanionService()
        service.sendError = CompanionServiceError.rejected("Busy")
        let store = makeStore(service)
        store.drafts[target] = "Again"
        await store.sendDraft(to: target)
        let failed = try #require(onlyMessage(store))
        #expect(failed.delivery == .failed("Busy"))
        #expect(failed.delivery.label == "Not sent")
        service.sendError = nil
        await store.retry(messageID: failed.id, target: target)
        let accepted = try #require(onlyMessage(store))
        #expect(accepted.delivery == .accepted)
        #expect(accepted.delivery.label == "Accepted by desktop")
        #expect(service.sent.count == 2)
        #expect(service.sent[0].clientCommandID != service.sent[1].clientCommandID)
        await store.retry(messageID: accepted.id, target: target)
        #expect(service.sent.count == 2, "Only failed messages retry")
        await store.retry(messageID: "missing", target: target)
        #expect(service.sent.count == 2)
    }

    @Test func imagesToAnAgentWithoutImageSupportAreRefusedBeforeSending() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        let image = CompanionImageAttachment(bytes: .init(Data([1, 2, 3])), mimeType: "image/png", width: 1, height: 1)
        store.drafts[target] = "Look"
        store.attachmentDrafts[target] = [image]
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        #expect(store.operationErrors[target] == CompanionAttachmentError.imagesNotSupported.localizedDescription)
        #expect(store.drafts[target] == "Look", "The draft stays so it can be sent as text")
        #expect(store.attachmentDrafts[target]?.count == 1)
    }

    @Test func retryOfAnImageWhoseBytesAreGoneFailsWithoutSending() async throws {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        let message = CompanionMessage(id: "m", role: .user, text: "See this", delivery: .failed("Not sent"), clientCommandID: "old",
                                       images: [.init(id: "img", mimeType: "image/png")])
        store.apply(.upsert(target, .message(message), sequence: 1))
        await store.retry(messageID: "m", target: target)
        #expect(service.sent.isEmpty)
        let final = try #require(onlyMessage(store))
        #expect(final.delivery == .failed("This image is no longer on your phone. Pick it again."))
    }

    @Test func historyKeepsUnconfirmedLocalMessagesItHasNotSeen() async throws {
        let service = ScriptedCompanionService()
        service.sendError = CompanionServiceError.rejected("Busy")
        let store = makeStore(service)
        store.drafts[target] = "Local only"
        await store.sendDraft(to: target)
        service.historyValue = .init(items: [.notice(id: "n", text: "Started")], lastSequence: 3)
        await store.load(target, force: true)
        let ids = store.conversation(for: target).items.map(\.id)
        #expect(ids.first == "notice:n")
        #expect(ids.count == 2)
        guard case .message(let kept) = store.conversation(for: target).items[1] else { Issue.record("Expected local message"); return }
        #expect(kept.text == "Local only")
        #expect(kept.delivery == .failed("Busy"))
    }

    @Test func attachmentProblemsAreReportedAndDismissed() {
        let store = makeStore(ScriptedCompanionService())
        store.reportAttachmentProblem("Too big", target: target)
        #expect(store.operationErrors[target] == "Too big")
        store.dismissError(for: target)
        #expect(store.operationErrors[target] == nil)
    }

    // MARK: Cancel

    @Test func cancelSendsOnceAndReportsFailure() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        await store.cancel(target)
        #expect(service.cancelled == [target])
        #expect(store.operationErrors[target] == nil)
        service.cancelError = CompanionServiceError.uncertain("No reply")
        await store.cancel(target)
        #expect(service.cancelled.count == 2)
        #expect(store.operationErrors[target] == "No reply")
        #expect(!store.pendingCommands.contains(target))
    }

    @Test func cancelNeedsTheCapabilityAndAConnection() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service, host: host(capabilities: [.chat]))
        await store.cancel(target)
        store.apply(.hosts([host { $0.connection = .reconnecting }]))
        await store.cancel(target)
        #expect(service.cancelled.isEmpty)
    }

    // MARK: Approvals

    private let allow = CompanionApprovalOption(id: "allow", label: "Allow once", kind: .allowOnce)
    private var approval: CompanionApproval { .init(id: "p", toolName: "Shell", summary: "rm -rf build", options: [allow]) }
    private func approvalResolution(_ store: CompanionStore) -> CompanionApproval.Resolution? {
        guard case .approval(let value)? = store.conversation(for: target).items.first else { return nil }
        return value.resolution
    }

    @Test func rejectedApprovalReopensItForAnotherAnswer() async {
        let service = ScriptedCompanionService()
        service.respondError = CompanionServiceError.rejected("Stale request")
        let store = makeStore(service)
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        await store.respond(approval, option: allow, target: target)
        #expect(approvalResolution(store) == .pending)
        #expect(store.operationErrors[target] == "Stale request")
        #expect(!store.conversation(for: target).requiresResync)
        #expect(store.canOperate(target))
    }

    @Test func uncertainApprovalNeedsResyncBeforeAnythingElse() async {
        let service = ScriptedCompanionService()
        service.respondError = CompanionServiceError.uncertain("Reply lost")
        let store = makeStore(service)
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        await store.respond(approval, option: allow, target: target)
        #expect(approvalResolution(store) == .uncertain)
        #expect(store.operationErrors[target] == "Reply lost")
        #expect(store.conversation(for: target).requiresResync)
        #expect(!store.canOperate(target))
        service.historyValue = .init(items: [.approval(.init(id: "p", toolName: "Shell", summary: "rm -rf build", resolution: .allowed))], lastSequence: 2)
        await store.load(target, force: true)
        #expect(approvalResolution(store) == .allowed)
        #expect(store.canOperate(target))
    }

    // MARK: Questions

    private var question: CompanionQuestion {
        .init(id: "q", prompts: [.init(id: "color", text: "Which?", options: [.init(id: "red", label: "Red"), .init(id: "blue", label: "Blue")],
                                       allowsMultiple: false, allowsFreeText: false)])
    }
    private func questionResolution(_ store: CompanionStore) -> CompanionQuestion.Resolution? {
        guard case .question(let value)? = store.conversation(for: target).items.first else { return nil }
        return value.resolution
    }

    @Test func answeredQuestionIsMarkedAnswered() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        store.apply(.upsert(target, .question(question), sequence: 1))
        await store.answer(question, answers: ["color": .choices(["red"])], target: target)
        #expect(service.answered == ["q"])
        #expect(questionResolution(store) == .answered)
        #expect(store.operationErrors[target] == nil)
    }

    @Test func rejectedAnswerReopensTheQuestion() async {
        let service = ScriptedCompanionService()
        service.answerError = CompanionServiceError.rejected("Expired")
        let store = makeStore(service)
        store.apply(.upsert(target, .question(question), sequence: 1))
        await store.answer(question, answers: ["color": .text("blue")], target: target)
        #expect(questionResolution(store) == .pending)
        #expect(store.operationErrors[target] == "Expired")
        #expect(!store.conversation(for: target).requiresResync)
    }

    @Test func uncertainAnswerRequiresResync() async {
        let service = ScriptedCompanionService()
        service.answerError = CompanionServiceError.uncertain("Reply lost")
        let store = makeStore(service)
        store.apply(.upsert(target, .question(question), sequence: 1))
        await store.answer(question, answers: ["color": .choices(["blue"])], target: target)
        #expect(questionResolution(store) == .uncertain)
        #expect(store.conversation(for: target).requiresResync)
        #expect(store.operationErrors[target] == "Reply lost")
    }

    @Test func authoritativeQuestionResolutionWinsOverLateReply() async {
        for failing in [false, true] {
            let service = ScriptedCompanionService()
            service.shouldSuspendAnswer = true
            if failing { service.answerError = CompanionServiceError.uncertain("Reply lost") }
            let store = makeStore(service)
            store.apply(.upsert(target, .question(question), sequence: 1))
            let task = Task { await store.answer(question, answers: ["color": .choices(["red"])], target: target) }
            while service.answerGate == nil { await Task.yield() }
            #expect(questionResolution(store) == .submitting)
            var cancelled = question
            cancelled.resolution = .cancelled
            store.apply(.upsert(target, .question(cancelled), sequence: 2))
            service.answerGate?.resume()
            await task.value
            #expect(questionResolution(store) == .cancelled)
            #expect(store.operationErrors[target] == nil)
            #expect(!store.conversation(for: target).requiresResync)
        }
    }

    @Test func answersAreOnlySentWhenValidAndAnswerable() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service, host: host(capabilities: [.chat]))
        store.apply(.upsert(target, .question(question), sequence: 1))
        await store.answer(question, answers: ["color": .choices(["red"])], target: target)
        store.apply(.hosts([host()]))
        await store.answer(question, answers: ["color": .choices(["green"])], target: target)
        var answered = question; answered.resolution = .answered
        await store.answer(answered, answers: ["color": .choices(["red"])], target: target)
        #expect(service.answered.isEmpty)
    }

    @Test func answerValidationFollowsEachPromptsRules() {
        let single = question
        var multiple = question; multiple.prompts[0].allowsMultiple = true
        var freeText = question; freeText.prompts[0].allowsFreeText = true
        #expect(CompanionStore.validAnswers(["color": .choices(["red"])], for: single))
        #expect(!CompanionStore.validAnswers(["color": .choices(["red", "blue"])], for: single))
        #expect(CompanionStore.validAnswers(["color": .choices(["red", "blue"])], for: multiple))
        #expect(!CompanionStore.validAnswers(["color": .choices(["red", "red"])], for: multiple))
        #expect(!CompanionStore.validAnswers(["color": .choices([])], for: multiple))
        #expect(!CompanionStore.validAnswers(["color": .choices(["green"])], for: multiple))
        #expect(!CompanionStore.validAnswers([:], for: single))
        #expect(!CompanionStore.validAnswers(["color": .text("red"), "extra": .text("x")], for: single))
        #expect(CompanionStore.validAnswers(["color": .text("red")], for: single))
        #expect(!CompanionStore.validAnswers(["color": .text("purple")], for: single))
        #expect(CompanionStore.validAnswers(["color": .text("purple")], for: freeText))
        #expect(!CompanionStore.validAnswers(["color": .text("   ")], for: freeText))
    }

    // MARK: Images and content

    @Test func messageImagesComeFromThePhoneOrTheDesktopCache() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service, host: host { $0.richContentAvailable = true })
        let local = CompanionMessageImage(id: "l", local: .init(Data([9])))
        #expect(await store.imageData(local, target: target) == Data([9]))
        #expect(await store.imageData(.init(id: "none"), target: target) == nil, "No local copy and no media reference")
        let remote = CompanionMessageImage(id: "r", mediaRef: "ref-0")
        #expect(await store.imageData(remote, target: target) == Data("image:ref-0".utf8))
        #expect(await store.imageData(remote, target: target) == Data("image:ref-0".utf8))
        #expect(service.contentCalls.count == 1, "The second read comes from the cache")
        // Fill the cache past its 24 entries: the oldest is evicted and fetched again.
        for index in 1...24 { _ = await store.imageData(.init(id: "r\(index)", mediaRef: "ref-\(index)"), target: target) }
        #expect(service.contentCalls.count == 25)
        _ = await store.imageData(remote, target: target)
        #expect(service.contentCalls.count == 26)
        _ = await store.imageData(.init(id: "r24", mediaRef: "ref-24"), target: target)
        #expect(service.contentCalls.count == 26, "Recent entries stay cached")
    }

    @Test func remoteImagesNeedRichContentAConnectionAndImageBytes() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        let remote = CompanionMessageImage(id: "r", mediaRef: "ref")
        #expect(await store.imageData(remote, target: target) == nil)
        store.apply(.hosts([host { $0.richContentAvailable = true; $0.connection = .offline }]))
        #expect(await store.imageData(remote, target: target) == nil)
        #expect(service.contentCalls.isEmpty)
        store.apply(.hosts([host { $0.richContentAvailable = true }]))
        service.contentResult = { _ in .init(kind: "file", name: "notes.txt", text: "hi") }
        #expect(await store.imageData(remote, target: target) == nil)
        service.contentResult = { _ in throw CompanionServiceError.unavailable("Gone") }
        #expect(await store.imageData(remote, target: target) == nil)
        service.contentResult = { _ in .init(kind: "image", name: "empty") }
        #expect(await store.imageData(remote, target: target) == nil)
        #expect(service.contentCalls.count == 3)
    }

    @Test func localImageContentWithoutTheImageIsUnavailable() async {
        let store = makeStore(ScriptedCompanionService())
        await #expect(throws: CompanionServiceError.self) { try await store.content(.localImage("missing"), target: target) }
    }

    // MARK: Spawn and create

    @Test func reviewedUncertainSpawnCanBeAcknowledged() async {
        let service = ScriptedCompanionService()
        service.spawnError = CompanionServiceError.uncertain("Reply lost")
        let store = makeStore(service, host: host { $0.canSpawn = true })
        #expect(await !store.spawn(project: project, prompt: "Task", provider: nil, model: nil))
        #expect(store.uncertainSpawnRequest != nil)
        #expect(store.spawnError == "Reply lost")
        store.acknowledgeReviewedSpawn()
        #expect(store.uncertainSpawnRequest == nil)
        #expect(store.spawnError == nil)
        service.spawnError = CompanionServiceError.rejected("No")
        #expect(await !store.spawn(project: project, prompt: "Task", provider: nil, model: nil))
        #expect(store.uncertainSpawnRequest == nil, "A rejection is final, not uncertain")
    }

    private func createRequest(name: String = "builder") -> CompanionCreateRequest {
        .init(project: project, name: name, color: "indigo", useWorktree: true, clientCommandID: "create-1")
    }

    @Test func uncertainCreateIsResentWithTheSameIdentity() async {
        let service = ScriptedCompanionService()
        service.createError = CompanionServiceError.uncertain("Reply lost")
        let store = makeStore(service, host: host { $0.canCreateDurable = true })
        #expect(await !store.create(createRequest()))
        #expect(store.uncertainCreateRequest == createRequest())
        #expect(store.createError == "Reply lost")
        #expect(await !store.create(createRequest(name: "other")), "No second create while one is unconfirmed")
        #expect(service.created.count == 1)
        service.createError = nil
        #expect(await store.checkCreateOutcome())
        #expect(service.created.map(\.clientCommandID) == ["create-1", "create-1"])
        let created = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "new-agent")
        #expect(store.selection == created)
        #expect(store.justCreated == created)
        #expect(store.uncertainCreateRequest == nil)
        #expect(await !store.checkCreateOutcome(), "Nothing left to check")
    }

    @Test func uncertainCreateWaitsForAConnectionAndCanBeAcknowledged() async {
        let service = ScriptedCompanionService()
        service.createError = CompanionServiceError.uncertain("Reply lost")
        let store = makeStore(service, host: host { $0.canCreateDurable = true })
        #expect(await !store.create(createRequest()))
        store.apply(.hosts([host { $0.canCreateDurable = true; $0.connection = .offline }]))
        #expect(await !store.checkCreateOutcome())
        #expect(service.created.count == 1)
        store.acknowledgeReviewedCreate()
        #expect(store.uncertainCreateRequest == nil)
        #expect(store.createError == nil)
    }

    @Test func rejectedCreateIsFinalAndInvalidNamesAreNotSent() async throws {
        let service = ScriptedCompanionService()
        service.createError = CompanionServiceError.rejected("Name taken")
        let store = makeStore(service, host: host { $0.canCreateDurable = true })
        #expect(await !store.create(createRequest(name: "")))
        #expect(await !store.create(createRequest(name: "has spaces/and..dots")))
        #expect(service.created.isEmpty)
        #expect(await !store.create(createRequest()))
        #expect(store.uncertainCreateRequest == nil)
        #expect(store.createError == "Name taken")
        service.createOptionsValue.suggestedName = "suggested"
        #expect(try await store.createOptions(for: project).suggestedName == "suggested")
    }

    // MARK: Settings, changes and reconnect

    @Test func settingsAndDiffsNeedAnEditableConnectedDesktop() async {
        let service = ScriptedCompanionService()
        let store = makeStore(service)
        await #expect(throws: CompanionServiceError.self) { try await store.updateSettings(.init(name: "New"), target: target) }
        store.apply(.hosts([host { $0.canEditSettings = true; $0.connection = .offline }]))
        await #expect(throws: CompanionServiceError.self) { try await store.updateSettings(.init(name: "New"), target: target) }
        let file = CompanionChangedFile(path: "a.swift", code: "M", staged: false)
        await #expect(throws: CompanionServiceError.self) { try await store.diff(of: file, in: project) }
        await store.reconnect(hostID: "host-a")
        #expect(service.reconnected == ["host-a"])
    }

    // MARK: Queue

    @Test func queuedMessageThatAlreadyLeftRefreshesTheChat() async {
        let service = ScriptedCompanionService()
        service.removeQueuedResult = false
        let store = makeStore(service, host: host(capabilities: [.chat, .queue, .removeQueued]))
        store.apply(.timeline(target, items: [.message(.init(id: "m", role: .user, text: "Later", queueState: .queued))], sequence: 1, reset: true))
        service.historyValue = .init(items: [.message(.init(id: "m", role: .user, text: "Later", queueState: .delivered))], lastSequence: 2)
        await store.removeQueuedMessage("m", target: target)
        #expect(store.operationErrors[target] == "This message has already left the desktop queue. Refreshing its status.")
        #expect(service.historyCalls == 1)
        guard case .message(let message)? = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        #expect(message.queueState == .delivered)
    }
}
