import Foundation
import Observation

@MainActor @Observable final class CompanionStore {
    var hosts: [CompanionHost] = []
    var selection: CompanionTarget?
    var drafts: [CompanionTarget: String] = [:] {
        didSet { draftPersistence?.save(drafts) }
    }
    private(set) var conversations: [CompanionTarget: CompanionConversation] = [:]
    private(set) var pendingCommands: Set<CompanionTarget> = []
    private(set) var operationErrors: [CompanionTarget: String] = [:]
    private(set) var spawnInProgress = false
    var spawnError: String?
    @ObservationIgnored private let service: any CompanionService
    @ObservationIgnored private let draftPersistence: (any CompanionDraftPersistence)?
    @ObservationIgnored private var listeningTask: Task<Void, Never>?
    @ObservationIgnored private var sendRequests: [String: CompanionSendRequest] = [:]
    @ObservationIgnored private var historyGenerations: [CompanionTarget: UUID] = [:]

    init(service: any CompanionService, draftPersistence: (any CompanionDraftPersistence)? = nil) {
        self.service = service
        self.draftPersistence = draftPersistence
        self.drafts = draftPersistence?.load() ?? [:]
    }

    func start() {
        guard listeningTask == nil else { return }
        let events = service.events()
        listeningTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.apply(event)
            }
        }
    }

    func stop() { listeningTask?.cancel(); listeningTask = nil }

    func host(for target: CompanionTarget) -> CompanionHost? { hosts.first { $0.id == target.hostID } }
    func agent(for target: CompanionTarget) -> CompanionAgent? {
        host(for: target)?.projects.first { $0.id == target.projectID }?.agents.first { $0.id == target }
    }
    func conversation(for target: CompanionTarget) -> CompanionConversation { conversations[target] ?? .init() }
    func canOperate(_ target: CompanionTarget) -> Bool {
        host(for: target)?.connection.canOperate == true && !conversation(for: target).requiresResync && !conversation(for: target).isLoading
    }
    func canSend(_ target: CompanionTarget) -> Bool {
        guard canOperate(target), !pendingCommands.contains(target), let agent = agent(for: target) else { return false }
        return agent.status == .working ? !agent.capabilities.intersection([.steer, .queue]).isEmpty : agent.capabilities.contains(.chat)
    }

    func load(_ target: CompanionTarget, force: Bool = false) async {
        guard force || (!conversation(for: target).isLoaded && !conversation(for: target).isLoading) else { return }
        let generation = UUID()
        historyGenerations[target] = generation
        conversations[target, default: .init()].isLoading = true
        conversations[target, default: .init()].error = nil
        do {
            let history = try await service.history(for: target)
            guard historyGenerations[target] == generation else { return }
            var current = conversation(for: target)
            // Preserve local messages whose command has not yet appeared in server history.
            let acknowledged = Set(history.items.compactMap { item -> String? in
                guard case .message(let message) = item else { return nil }
                return message.clientCommandID
            })
            let local = current.items.filter { item in
                guard case .message(let message) = item, let commandID = message.clientCommandID else { return false }
                return message.delivery != .confirmed && !acknowledged.contains(commandID)
            }
            // Do not overwrite events received while a history request was in flight.
            if history.sessionID == current.sessionID,
               let historySequence = history.lastSequence, let currentSequence = current.lastSequence,
               currentSequence > historySequence {
                let currentByID = Dictionary(current.items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                let historyIDs = Set(history.items.map(\.id))
                current.items = history.items.map { currentByID[$0.id] ?? $0 } + current.items.filter { !historyIDs.contains($0.id) }
                current.isLoading = false
                current.isLoaded = true
                current.hasEarlierMessages = history.hasEarlierMessages
                current.requiresResync = false
                current.error = nil
            } else {
                current = .init(items: history.items + local, isLoading: false, isLoaded: true,
                                hasEarlierMessages: history.hasEarlierMessages, lastSequence: history.lastSequence, sessionID: history.sessionID)
            }
            conversations[target] = current
        } catch {
            guard historyGenerations[target] == generation else { return }
            conversations[target, default: .init()].isLoading = false
            conversations[target, default: .init()].error = error.localizedDescription
            conversations[target, default: .init()].requiresResync = true
        }
    }

    func sendDraft(to target: CompanionTarget) async {
        let text = (drafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend(target) else { return }
        let commandID = UUID().uuidString
        let message = CompanionMessage(id: "local-\(commandID)", role: .user, text: text,
                                       timestamp: Date(), delivery: .sending, clientCommandID: commandID)
        conversations[target, default: .init()].items.append(.message(message))
        drafts[target] = ""
        await submit(message, to: target)
    }

    /// Retry is only offered for a definite rejection. Unknown delivery requires reconciliation first.
    func retry(messageID: String, target: CompanionTarget) async {
        guard canSend(target), let item = conversation(for: target).items.first(where: { $0.id == "message:\(messageID)" }),
              case .message(let message) = item, case .failed = message.delivery else { return }
        await submit(message, to: target)
    }

    private func submit(_ message: CompanionMessage, to target: CompanionTarget) async {
        guard let commandID = message.clientCommandID else { return }
        pendingCommands.insert(target)
        operationErrors[target] = nil
        updateDelivery(commandID, target: target, delivery: .sending)
        defer { pendingCommands.remove(target) }
        do {
            let request = sendRequests[commandID] ?? CompanionSendRequest(target: target, text: message.text, clientCommandID: commandID,
                                                                          isSteering: agent(for: target)?.status == .working && agent(for: target)?.capabilities.contains(.steer) == true,
                                                                          queueIfBusy: agent(for: target)?.status == .working && agent(for: target)?.capabilities.contains(.steer) != true)
            sendRequests[commandID] = request
            _ = try await service.send(request)
            updateDelivery(commandID, target: target, delivery: .accepted)
        } catch let error as CompanionServiceError {
            if case .uncertain(let detail) = error { updateDelivery(commandID, target: target, delivery: .uncertain(detail)) }
            else { updateDelivery(commandID, target: target, delivery: .failed(error.localizedDescription)) }
        } catch {
            updateDelivery(commandID, target: target, delivery: .uncertain(error.localizedDescription))
        }
    }

    func cancel(_ target: CompanionTarget) async {
        guard canOperate(target), !pendingCommands.contains(target), agent(for: target)?.capabilities.contains(.cancel) == true else { return }
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do { try await service.cancel(target, clientCommandID: UUID().uuidString) }
        catch { operationErrors[target] = error.localizedDescription }
    }

    func respond(_ approval: CompanionApproval, option: CompanionApprovalOption, target: CompanionTarget) async {
        guard canOperate(target), agent(for: target)?.capabilities.contains(.approve) == true,
              !pendingCommands.contains(target), !approval.isExpired(at: Date()), approval.resolution == .pending, approval.options.contains(option) else { return }
        var submitted = approval
        submitted.resolution = .submitting
        upsert(.approval(submitted), target: target)
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do {
            try await service.respond(to: approval.id, optionID: option.id, target: target, clientCommandID: UUID().uuidString)
            guard approvalIsSubmitting(approval.id, target: target) else { return }
            submitted.resolution = option.kind == .allowOnce ? .allowed : .denied
            upsert(.approval(submitted), target: target)
        } catch {
            guard approvalIsSubmitting(approval.id, target: target) else { return }
            if case CompanionServiceError.rejected = error {
                upsert(.approval(approval), target: target)
            } else {
                submitted.resolution = .uncertain
                upsert(.approval(submitted), target: target)
                conversations[target, default: .init()].requiresResync = true
            }
            operationErrors[target] = error.localizedDescription
        }
    }

    func answer(_ question: CompanionQuestion, answers: [String: CompanionAnswer], target: CompanionTarget) async {
        guard canOperate(target), !pendingCommands.contains(target), question.resolution == .pending,
              agent(for: target)?.capabilities.contains(.answer) == true,
              Self.validAnswers(answers, for: question) else { return }
        var submitted = question
        submitted.resolution = .submitting
        upsert(.question(submitted), target: target)
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do {
            try await service.answer(question.id, answers: answers, target: target, clientCommandID: UUID().uuidString)
            guard questionIsSubmitting(question.id, target: target) else { return }
            submitted.resolution = .answered
            upsert(.question(submitted), target: target)
        } catch {
            guard questionIsSubmitting(question.id, target: target) else { return }
            if case CompanionServiceError.rejected = error { submitted.resolution = .pending }
            else {
                submitted.resolution = .uncertain
                conversations[target, default: .init()].requiresResync = true
            }
            upsert(.question(submitted), target: target)
            operationErrors[target] = error.localizedDescription
        }
    }

    static func validAnswers(_ answers: [String: CompanionAnswer], for question: CompanionQuestion) -> Bool {
        guard Set(answers.keys) == Set(question.prompts.map(\.id)) else { return false }
        return question.prompts.allSatisfy { prompt in
            guard let answer = answers[prompt.id] else { return false }
            switch answer {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (prompt.allowsFreeText || prompt.options.contains { $0.id == text })
            case .choices(let choices):
                return !choices.isEmpty && (prompt.allowsMultiple || choices.count == 1) && Set(choices).count == choices.count && choices.allSatisfy { choice in prompt.options.contains { $0.id == choice } }
            }
        }
    }

    func spawn(project: CompanionProjectTarget, prompt: String, provider: String?, model: String?) async -> Bool {
        guard !spawnInProgress, let host = hosts.first(where: { $0.id == project.hostID }), host.connection.canOperate, host.canSpawn,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        spawnInProgress = true
        spawnError = nil
        defer { spawnInProgress = false }
        do {
            let receipt = try await service.spawn(.init(project: project, prompt: prompt, provider: provider,
                                                       model: model, clientCommandID: UUID().uuidString))
            if let target = receipt.agentTarget { selection = target }
            return true
        } catch { spawnError = error.localizedDescription; return false }
    }

    func reconnect(hostID: String) async { await service.reconnect(hostID: hostID) }
    func dismissError(for target: CompanionTarget) { operationErrors[target] = nil }

    func apply(_ event: CompanionEvent) {
        switch event {
        case .hosts(let hosts): self.hosts = hosts
        case .timeline(let target, let items, let sequence, let reset, let sessionID):
            if !reset, let previous = conversation(for: target).lastSequence, sequence < previous { return }
            let commandIDs = Set(items.compactMap { item -> String? in
                if case .message(let message) = item { return message.clientCommandID }; return nil
            })
            let local = conversation(for: target).items.filter { item in
                guard case .message(let message) = item, let commandID = message.clientCommandID else { return false }
                return message.delivery != .confirmed && !commandIDs.contains(commandID)
            }
            let previous = Dictionary(conversation(for: target).items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            let merged = items.map { item -> CompanionTimelineItem in
                guard let old = previous[item.id] else { return item }
                if case .approval(let incoming) = item, incoming.resolution == .pending,
                   case .approval(let existing) = old, existing.resolution != .pending { return old }
                if case .question(let incoming) = item, incoming.resolution == .pending,
                   case .question(let existing) = old, existing.resolution != .pending { return old }
                return item
            }
            conversations[target, default: .init()].items = merged + local
            conversations[target, default: .init()].lastSequence = sequence
            conversations[target, default: .init()].sessionID = sessionID
        case .resyncRequired(let hostID):
            for target in conversations.keys where target.hostID == hostID {
                conversations[target]?.requiresResync = true
            }
        case .upsert(let target, let item, let sequence):
            guard accept(sequence, for: target) else { return }
            upsert(item, target: target)
        case .textDelta(let target, let messageID, let text, let sequence):
            guard accept(sequence, for: target) else { return }
            var items = conversation(for: target).items
            if let index = items.firstIndex(where: { $0.id == "message:\(messageID)" }), case .message(var message) = items[index] {
                message.text += text
                message.isStreaming = true
                items[index] = .message(message)
            } else {
                items.append(.message(.init(id: messageID, role: .assistant, text: text, isStreaming: true)))
            }
            conversations[target, default: .init()].items = items
        case .streamFinished(let target, let messageID, let sequence):
            guard accept(sequence, for: target) else { return }
            var items = conversation(for: target).items
            if let index = items.firstIndex(where: { $0.id == "message:\(messageID)" }), case .message(var message) = items[index] {
                message.isStreaming = false
                items[index] = .message(message)
                conversations[target, default: .init()].items = items
            }
        }
    }

    private func approvalIsSubmitting(_ id: String, target: CompanionTarget) -> Bool {
        guard let item = conversation(for: target).items.first(where: { $0.id == "approval:\(id)" }), case .approval(let current) = item else { return false }
        return current.resolution == .submitting
    }
    private func questionIsSubmitting(_ id: String, target: CompanionTarget) -> Bool {
        guard let item = conversation(for: target).items.first(where: { $0.id == "question:\(id)" }), case .question(let current) = item else { return false }
        return current.resolution == .submitting
    }

    private func accept(_ sequence: Int?, for target: CompanionTarget) -> Bool {
        guard let sequence else { return true }
        if let previous = conversation(for: target).lastSequence, sequence <= previous { return false }
        conversations[target, default: .init()].lastSequence = sequence
        return true
    }

    private func upsert(_ item: CompanionTimelineItem, target: CompanionTarget) {
        var items = conversation(for: target).items
        // Reconcile optimistic sends using the server-echoed client command ID.
        if case .message(let incoming) = item, let commandID = incoming.clientCommandID {
            items.removeAll { item in
                guard case .message(let message) = item else { return false }
                return message.clientCommandID == commandID && message.id != incoming.id
            }
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        conversations[target, default: .init()].items = items
    }

    private func updateDelivery(_ commandID: String, target: CompanionTarget, delivery: CompanionMessage.Delivery) {
        var items = conversation(for: target).items
        for index in items.indices {
            if case .message(var message) = items[index], message.clientCommandID == commandID, message.delivery != .confirmed {
                message.delivery = delivery
                items[index] = .message(message)
            }
        }
        conversations[target, default: .init()].items = items
    }
}
