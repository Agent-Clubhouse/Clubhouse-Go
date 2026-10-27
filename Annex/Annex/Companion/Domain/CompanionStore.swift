import Foundation
import Observation

@MainActor @Observable final class CompanionStore {
    var hosts: [CompanionHost] = []
    var selection: CompanionTarget?
    var drafts: [CompanionTarget: String] = [:] {
        didSet { draftPersistence?.save(drafts) }
    }
    /// Images picked for each agent's next message. Kept for this session only, not across launches.
    var attachmentDrafts: [CompanionTarget: [CompanionImageAttachment]] = [:]
    private(set) var conversations: [CompanionTarget: CompanionConversation] = [:]
    private(set) var pendingCommands: Set<CompanionTarget> = []
    private(set) var operationErrors: [CompanionTarget: String] = [:]
    private(set) var spawnInProgress = false
    var spawnError: String?
    private(set) var uncertainSpawnRequest: CompanionSpawnRequest?
    private(set) var createInProgress = false
    var createError: String?
    private(set) var uncertainCreateRequest: CompanionCreateRequest?
    /// The durable agent just created from this phone, so its chat can offer "Wake with a message".
    var justCreated: CompanionTarget?
    @ObservationIgnored private let service: any CompanionService
    @ObservationIgnored private let draftPersistence: (any CompanionDraftPersistence)?
    @ObservationIgnored private var listeningTask: Task<Void, Never>?
    @ObservationIgnored private var sendRequests: [String: CompanionSendRequest] = [:]
    @ObservationIgnored private var historyGenerations: [CompanionTarget: UUID] = [:]
    /// Desktop ids of uploaded images, by `CompanionMessageImage.id`, so a retry doesn't upload them again.
    @ObservationIgnored private var uploadedAttachmentIDs: [String: String] = [:]
    /// Sessions that refused images (`images_not_supported`), by agent. A new session may take them.
    private var imagesRefused: [CompanionTarget: String] = [:]
    /// Each agent's content roots, from its latest chat snapshot.
    private var contentRoots: [CompanionTarget: CompanionContentRoots] = [:]
    @ObservationIgnored private var remoteImages: [String: CompanionImageBytes] = [:]
    @ObservationIgnored private var remoteImageOrder: [String] = []

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

    func sessions(for target: CompanionTarget) async throws -> [CompanionSessionSummary] { try await service.sessions(for: target) }
    func archive(for target: CompanionTarget, sessionID: String) throws -> CompanionArchiveTranscript {
        CompanionArchiveTranscript(reader: try service.archive(for: target, sessionID: sessionID))
    }

    func host(for target: CompanionTarget) -> CompanionHost? { hosts.first { $0.id == target.hostID } }
    func agent(for target: CompanionTarget) -> CompanionAgent? {
        host(for: target)?.projects.first { $0.id == target.projectID }?.agents.first { $0.id == target }
    }
    func conversation(for target: CompanionTarget) -> CompanionConversation { conversations[target] ?? .init() }
    func canOperate(_ target: CompanionTarget) -> Bool {
        host(for: target)?.connection.canOperate == true && !conversation(for: target).requiresResync && !conversation(for: target).isLoading
    }
    func canWake(_ target: CompanionTarget) -> Bool {
        canOperate(target) && !pendingCommands.contains(target) && agent(for: target)?.capabilities.contains(.wake) == true
    }
    func wake(_ target: CompanionTarget) async {
        guard canWake(target) else { return }
        pendingCommands.insert(target); operationErrors.removeValue(forKey: target)
        defer { pendingCommands.remove(target) }
        do { try await service.wake(target, clientCommandID: UUID().uuidString); await load(target, force: true) }
        catch { operationErrors[target] = error.localizedDescription; await load(target, force: true) }
    }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        if case .localImage(let id) = reference {
            // The phone's own copy of an image it sent: no desktop setting or connection needed.
            guard let image = messageImage(id: id, target: target), let local = image.local else {
                throw CompanionServiceError.unavailable("This image is no longer on your phone.")
            }
            return .init(kind: "image", name: image.name ?? "Image", mimeType: image.mimeType, bytes: local.data)
        }
        guard let host = host(for: target), host.connection.canOperate else { throw CompanionServiceError.unavailable("Reconnect to your desktop to view this content.") }
        guard host.richContentAvailable else {
            throw CompanionServiceError.unavailable("Rich chat content is off on \(host.name). Turn it on in the desktop's Experimental settings to preview images and files.")
        }
        if !reference.isOffered(roots: contentRoots(for: target)) {
            throw CompanionServiceError.unavailable("This file is outside the agent's folders, so \(host.name) won't share it.")
        }
        return try await service.content(reference, target: target)
    }
    func richContentAvailable(for target: CompanionTarget) -> Bool { host(for: target)?.richContentAvailable == true }
    func contentRoots(for target: CompanionTarget) -> CompanionContentRoots { contentRoots[target] ?? .init() }
    func canSend(_ target: CompanionTarget) -> Bool {
        guard canOperate(target), !pendingCommands.contains(target), let agent = agent(for: target) else { return false }
        return agent.status == .working ? !agent.capabilities.intersection([.steer, .queue]).isEmpty : agent.capabilities.contains(.chat)
    }

    /// Limits for the attach button. It shows only when the desktop takes uploads and the agent's live session takes images.
    func attachmentLimits(for target: CompanionTarget) -> CompanionAttachmentLimits? {
        guard let limits = host(for: target)?.attachments, agent(for: target)?.capabilities.contains(.images) == true,
              imagesRefused[target] != (conversation(for: target).sessionID ?? "") else { return nil }
        return limits
    }
    func addAttachments(_ images: [CompanionImageAttachment], to target: CompanionTarget) {
        guard let limits = attachmentLimits(for: target), !images.isEmpty else { return }
        let current = attachmentDrafts[target] ?? []
        attachmentDrafts[target] = current + images.prefix(max(0, limits.maxCount - current.count))
    }
    func removeAttachment(_ id: String, from target: CompanionTarget) {
        attachmentDrafts[target]?.removeAll { $0.id == id }
    }
    func reportAttachmentProblem(_ text: String, target: CompanionTarget) { operationErrors[target] = text }

    /// The bytes behind a message image: the phone's own copy, or the desktop's when its Rich chat content is on.
    func imageData(_ image: CompanionMessageImage, target: CompanionTarget) async -> Data? {
        if let local = image.local { return local.data }
        guard let reference = image.mediaRef, richContentAvailable(for: target), host(for: target)?.connection.canOperate == true else { return nil }
        if let cached = remoteImages[reference] { return cached.data }
        guard let content = try? await service.content(.image(reference), target: target), content.kind == "image",
              let data = content.bytes else { return nil }
        remoteImages[reference] = .init(data)
        remoteImageOrder.removeAll { $0 == reference }
        remoteImageOrder.append(reference)
        while remoteImageOrder.count > 24 { remoteImages.removeValue(forKey: remoteImageOrder.removeFirst()) }
        return data
    }

    private func messageImage(id: String, target: CompanionTarget) -> CompanionMessageImage? {
        for case .message(let message) in conversation(for: target).items {
            if let image = message.images.first(where: { $0.id == id }) { return image }
        }
        return nil
    }

    func load(_ target: CompanionTarget, force: Bool = false) async {
        guard force || (!conversation(for: target).isLoaded && !conversation(for: target).isLoading) else { return }
        let generation = UUID()
        historyGenerations[target] = generation
        conversations[target, default: .init()].isLoading = true
        conversations[target, default: .init()].error = nil
        do {
            var history = try await service.history(for: target)
            guard historyGenerations[target] == generation else { return }
            var current = conversation(for: target)
            contentRoots[target] = history.contentRoots
            history.items = Self.carryingLocalImages(history.items, from: current.items)
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
        let attachments = attachmentDrafts[target] ?? []
        guard !text.isEmpty || !attachments.isEmpty, canSend(target) else { return }
        guard attachments.isEmpty || attachmentLimits(for: target) != nil else {
            operationErrors[target] = CompanionAttachmentError.imagesNotSupported.localizedDescription
            return
        }
        let commandID = UUID().uuidString
        let message = CompanionMessage(id: "local-\(commandID)", role: .user, text: text,
                                       timestamp: Date(), delivery: .sending, clientCommandID: commandID,
                                       images: attachments.map { .init(id: $0.id, mimeType: $0.mimeType, width: $0.width, height: $0.height, local: $0.bytes) })
        conversations[target, default: .init()].items.append(.message(message))
        drafts[target] = ""
        attachmentDrafts[target] = nil
        await submit(message, to: target)
    }

    /// Retry is only offered for a definite rejection. Unknown delivery requires reconciliation first.
    func retry(messageID: String, target: CompanionTarget) async {
        guard canSend(target), let item = conversation(for: target).items.first(where: { $0.id == "message:\(messageID)" }),
              case .message(var message) = item, case .failed = message.delivery else { return }
        // A definitive rejection is cached by both transport and desktop. A
        // deliberate retry is a new logical command; uncertain outcomes never
        // enter this path and retain their original identity for reconciliation.
        if let previousID = message.clientCommandID { sendRequests.removeValue(forKey: previousID) }
        message.clientCommandID = UUID().uuidString
        message.delivery = .sending
        upsert(.message(message), target: target)
        await submit(message, to: target)
    }

    private func submit(_ message: CompanionMessage, to target: CompanionTarget) async {
        guard var commandID = message.clientCommandID else { return }
        pendingCommands.insert(target)
        operationErrors[target] = nil
        updateDelivery(commandID, target: target, delivery: .sending)
        defer { pendingCommands.remove(target) }
        do {
            var request = sendRequests[commandID] ?? CompanionSendRequest(target: target, text: message.text, clientCommandID: commandID,
                                                                          isSteering: agent(for: target)?.status == .working && agent(for: target)?.capabilities.contains(.steer) == true,
                                                                          queueIfBusy: agent(for: target)?.status == .working && agent(for: target)?.capabilities.contains(.steer) != true)
            // Every image goes up first; then one send names them all.
            if !message.images.isEmpty && request.attachmentIDs.isEmpty {
                request.attachmentIDs = try await upload(message.images, commandID: commandID, target: target)
                updateDelivery(commandID, target: target, delivery: .sending)
            }
            sendRequests[commandID] = request
            do { _ = try await service.send(request) }
            catch CompanionAttachmentError.attachmentUnavailable where !message.images.isEmpty {
                // The ids expired or the desktop restarted. The old command id is fingerprinted with the old ids,
                // so upload again and send as a new command.
                for image in message.images { uploadedAttachmentIDs.removeValue(forKey: image.id) }
                sendRequests.removeValue(forKey: commandID)
                let renewed = UUID().uuidString
                renameCommand(commandID, to: renewed, target: target)
                commandID = renewed
                request.clientCommandID = renewed
                request.attachmentIDs = try await upload(message.images, commandID: renewed, target: target)
                updateDelivery(renewed, target: target, delivery: .sending)
                sendRequests[renewed] = request
                _ = try await service.send(request)
            }
            updateDelivery(commandID, target: target, delivery: .accepted)
        } catch let error as CompanionAttachmentError {
            if error == .imagesNotSupported { imagesRefused[target] = conversation(for: target).sessionID ?? "" }
            updateDelivery(commandID, target: target, delivery: .failed(error.localizedDescription))
        } catch let error as CompanionServiceError {
            if case .uncertain(let detail) = error { updateDelivery(commandID, target: target, delivery: .uncertain(detail)) }
            else { updateDelivery(commandID, target: target, delivery: .failed(error.localizedDescription)) }
        } catch {
            updateDelivery(commandID, target: target, delivery: .uncertain(error.localizedDescription))
        }
    }

    /// Uploads in order, reusing ids from an earlier try. Waits out a short `Retry-After` up to twice.
    private func upload(_ images: [CompanionMessageImage], commandID: String, target: CompanionTarget) async throws -> [String] {
        var ids: [String] = []
        for (index, image) in images.enumerated() {
            updateDelivery(commandID, target: target, delivery: .uploading(completed: index, total: images.count))
            if let id = uploadedAttachmentIDs[image.id] { ids.append(id); continue }
            guard let bytes = image.local, let mimeType = image.mimeType else {
                throw CompanionServiceError.rejected("This image is no longer on your phone. Pick it again.")
            }
            let attachment = CompanionImageAttachment(id: image.id, bytes: bytes, mimeType: mimeType, width: image.width ?? 0, height: image.height ?? 0)
            var waits = 0
            while true {
                do {
                    let id = try await service.upload(attachment, target: target)
                    uploadedAttachmentIDs[image.id] = id
                    ids.append(id)
                    break
                } catch CompanionAttachmentError.rateLimited(let seconds) where waits < 2 && (seconds ?? 5) <= 30 {
                    waits += 1
                    try await Task.sleep(for: .seconds(max(1, seconds ?? 5)))
                }
            }
        }
        return ids
    }

    private func renameCommand(_ old: String, to new: String, target: CompanionTarget) {
        var items = conversation(for: target).items
        for index in items.indices {
            if case .message(var message) = items[index], message.clientCommandID == old {
                message.clientCommandID = new
                items[index] = .message(message)
            }
        }
        conversations[target, default: .init()].items = items
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
              !pendingCommands.contains(target), !approval.isExpired(at: Date()), approval.resolution == .pending, approval.options.contains(option),
              option.isAnswerableHere else { return } // The desktop refuses persistent options from a phone.
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
        guard !spawnInProgress, uncertainSpawnRequest == nil, let host = hosts.first(where: { $0.id == project.hostID }), host.connection.canOperate, host.canSpawn,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await dispatchSpawn(.init(project: project, prompt: prompt, provider: provider,
                                         model: model, clientCommandID: UUID().uuidString))
    }

    /// Explicitly checks/re-dispatches the same idempotent request. The transport
    /// refuses expired or cross-epoch retries; a second task is never invented.
    func checkSpawnOutcome() async -> Bool {
        guard !spawnInProgress, let request = uncertainSpawnRequest,
              hosts.first(where: { $0.id == request.project.hostID })?.connection.canOperate == true else { return false }
        return await dispatchSpawn(request)
    }

    func acknowledgeReviewedSpawn() {
        guard !spawnInProgress else { return }
        uncertainSpawnRequest = nil; spawnError = nil
    }

    private func dispatchSpawn(_ request: CompanionSpawnRequest) async -> Bool {
        spawnInProgress = true
        spawnError = nil
        defer { spawnInProgress = false }
        do {
            let receipt = try await service.spawn(request)
            uncertainSpawnRequest = nil
            if let target = receipt.agentTarget { selection = target }
            return true
        } catch {
            if case CompanionServiceError.rejected = error { uncertainSpawnRequest = nil }
            else { uncertainSpawnRequest = request }
            spawnError = error.localizedDescription
            return false
        }
    }

    // MARK: Durable agents (#131, #132)

    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        try await service.createOptions(for: project)
    }

    /// Creates a durable agent and opens it. Its worktree is still being made when this returns.
    func create(_ request: CompanionCreateRequest) async -> Bool {
        guard !createInProgress, uncertainCreateRequest == nil, let host = hosts.first(where: { $0.id == request.project.hostID }),
              host.connection.canOperate, host.canCreateDurable,
              !request.name.isEmpty, request.useWorktree != true || CompanionAgentName.problem(request.name) == nil else { return false }
        return await dispatchCreate(request)
    }

    /// Re-sends the same idempotent create, so an unconfirmed one never becomes two agents.
    func checkCreateOutcome() async -> Bool {
        guard !createInProgress, let request = uncertainCreateRequest,
              hosts.first(where: { $0.id == request.project.hostID })?.connection.canOperate == true else { return false }
        return await dispatchCreate(request)
    }

    func acknowledgeReviewedCreate() {
        guard !createInProgress else { return }
        uncertainCreateRequest = nil; createError = nil
    }

    private func dispatchCreate(_ request: CompanionCreateRequest) async -> Bool {
        createInProgress = true
        createError = nil
        defer { createInProgress = false }
        do {
            let receipt = try await service.create(request)
            uncertainCreateRequest = nil
            justCreated = receipt.target
            selection = receipt.target
            return true
        } catch {
            if case CompanionServiceError.rejected = error { uncertainCreateRequest = nil }
            else { uncertainCreateRequest = request }
            createError = error.localizedDescription
            return false
        }
    }

    /// Settings are offered for durable agents on desktops that support them.
    func canEditSettings(_ target: CompanionTarget) -> Bool {
        host(for: target)?.canEditSettings == true && agent(for: target).map { !$0.isQuick } == true
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        guard canEditSettings(target) else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.") }
        return try await service.settings(for: target)
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget) async throws -> CompanionAgentSettings {
        guard canEditSettings(target), host(for: target)?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to your desktop to change this agent's settings.")
        }
        return try await service.updateSettings(change, target: target, clientCommandID: UUID().uuidString)
    }

    func reconnect(hostID: String) async { await service.reconnect(hostID: hostID) }

    func removeQueuedMessage(_ messageID: String, target: CompanionTarget) async {
        guard canOperate(target), !pendingCommands.contains(target), agent(for: target)?.capabilities.contains(.removeQueued) == true,
              conversation(for: target).items.contains(where: {
                  if case .message(let message) = $0 { return message.id == messageID && message.queueState == .queued }; return false
              }) else { return }
        pendingCommands.insert(target)
        defer { pendingCommands.remove(target) }
        do {
            let removed = try await service.removeQueued(messageID, target: target, clientCommandID: UUID().uuidString)
            if removed {
                var items = conversation(for: target).items
                for index in items.indices {
                    if case .message(var message) = items[index], message.id == messageID, message.queueState == .queued {
                        message.queueState = .removed; items[index] = .message(message)
                    }
                }
                conversations[target, default: .init()].items = items
            } else {
                operationErrors[target] = "This message has already left the desktop queue. Refreshing its status."
                await load(target, force: true)
            }
        } catch {
            operationErrors[target] = error.localizedDescription
            if case CompanionServiceError.rejected = error {} else {
                conversations[target, default: .init()].requiresResync = true
            }
        }
    }
    func dismissError(for target: CompanionTarget) { operationErrors[target] = nil }

    func apply(_ event: CompanionEvent) {
        switch event {
        case .hosts(let hosts): self.hosts = hosts
        case .timeline(let target, let incoming, let sequence, let reset, let sessionID):
            if !reset, let previous = conversation(for: target).lastSequence, sequence < previous { return }
            let items = Self.carryingLocalImages(incoming, from: conversation(for: target).items)
            let commandIDs = Set(items.compactMap { item -> String? in
                if case .message(let message) = item { return message.clientCommandID }; return nil
            })
            let local = conversation(for: target).items.filter { item in
                guard case .message(let message) = item, let commandID = message.clientCommandID else { return false }
                return message.delivery != .confirmed && !commandIDs.contains(commandID) && !Self.echoes(message, in: items)
            }
            let previous = Dictionary(conversation(for: target).items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            let merged = items.map { item -> CompanionTimelineItem in
                guard let old = previous[item.id] else { return item }
                if case .approval(let incoming) = item, incoming.resolution == .pending,
                   case .approval(let existing) = old, existing.resolution != .pending { return old }
                if case .question(let incoming) = item, incoming.resolution == .pending,
                   case .question(let existing) = old, existing.resolution != .pending { return old }
                if case .message(var incoming) = item, incoming.queueState == .queued,
                   case .message(let existing) = old, existing.queueState == .removed, !reset {
                    incoming.queueState = .removed
                    return .message(incoming)
                }
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

    /// A message that wakes a sleeping agent starts its session, and the desktop's copy of it carries no
    /// client command id. That copy, same text and no id, stands in for the phone's unconfirmed one.
    static func echoes(_ local: CompanionMessage, in items: [CompanionTimelineItem]) -> Bool {
        local.role == .user && items.contains { item in
            guard case .message(let incoming) = item else { return false }
            return incoming.role == .user && incoming.clientCommandID == nil && incoming.id != local.id && incoming.text == local.text
                && incoming.images.count == local.images.count
        }
    }

    /// The desktop's echo replaces the phone's bubble. Each image keeps the phone's copy, so it still shows
    /// when the desktop's Rich chat content is off, and without a fetch when it's on. Matched by command id, then message id.
    static func carryingLocalImages(_ items: [CompanionTimelineItem], from previous: [CompanionTimelineItem]) -> [CompanionTimelineItem] {
        var byCommand: [String: [CompanionMessageImage]] = [:]
        var byMessage: [String: [CompanionMessageImage]] = [:]
        for case .message(let message) in previous where message.images.contains(where: { $0.local != nil }) {
            if let commandID = message.clientCommandID { byCommand[commandID] = message.images }
            byMessage[message.id] = message.images
        }
        guard !byMessage.isEmpty else { return items }
        return items.map { item in
            guard case .message(var message) = item, message.role == .user, !message.images.isEmpty,
                  let local = message.clientCommandID.flatMap({ byCommand[$0] }) ?? byMessage[message.id] else { return item }
            for index in message.images.indices where message.images[index].local == nil && index < local.count {
                message.images[index].local = local[index].local
                message.images[index].mimeType = message.images[index].mimeType ?? local[index].mimeType
            }
            return .message(message)
        }
    }

    private func upsert(_ incoming: CompanionTimelineItem, target: CompanionTarget) {
        var items = conversation(for: target).items
        let item = Self.carryingLocalImages([incoming], from: items)[0]
        if case .message(let incoming) = item, incoming.role == .user, incoming.clientCommandID == nil {
            items.removeAll { existing in
                guard case .message(let local) = existing, local.clientCommandID != nil, local.delivery != .confirmed else { return false }
                return Self.echoes(local, in: [item])
            }
        }
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
