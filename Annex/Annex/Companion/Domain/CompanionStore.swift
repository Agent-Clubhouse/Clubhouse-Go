import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif
import Observation

@MainActor @Observable final class CompanionStore {
    // Concrete service/persistence ownership is reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    var hosts: [CompanionHost] = []
    var selection: CompanionTarget?
    var drafts: [CompanionTarget: String] = [:] {
        didSet { draftPersistence?.save(drafts) }
    }
    /// Images picked for each agent's next message. Kept for this session only, not across launches.
    var attachmentDrafts: [CompanionTarget: [CompanionImageAttachment]] = [:]
    private(set) var conversations: [CompanionTarget: CompanionConversation] = [:]
    private(set) var pendingCommands: Set<CompanionTarget> = []
    /// A stop receipt only acknowledges the request. Keep mutations blocked until the desktop confirms sleep.
    private(set) var sleepRequests: Set<CompanionTarget> = []
    private(set) var sleepRefreshes: Set<CompanionTarget> = []
    private var confirmedSleepCommands: [CompanionTarget: String] = [:]
    private var providerFlows: [CompanionTarget: CompanionProviderFlow] = [:]
    private(set) var operationErrors: [CompanionTarget: String] = [:]
    /// The `wrong_machine` refusal behind a chat's error, while it shows.
    private(set) var wrongMachines: [CompanionTarget: CompanionWrongMachine] = [:]
    /// Helper requests being answered, and why an answer failed, by `CompanionHelperRequest.slot`.
    private(set) var helperRequestsInFlight: Set<String> = []
    var helperRequestNotice: String?
    var helperStartWarning: CompanionHelperStartWarning?
    private var consumedHelperRequests: Set<String> = []
    private(set) var helperRequestErrors: [String: String] = [:]
    /// Grant requests being answered, and why an answer didn't go through, by `CompanionGrantRequest.slot`.
    private(set) var grantRequestsInFlight: Set<String> = []
    private(set) var grantRequestErrors: [String: String] = [:]
    /// Why a request left before its answer landed (expired, answered elsewhere): shown once.
    var grantRequestNotice: String?
    /// An answer whose outcome is unknown, by slot. Sending the same answer again reuses its command id, so the desktop
    /// replays its receipt instead of answering twice.
    private var grantAnswerAttempts: [String: (answer: CompanionGrantRequest.Answer, mode: AnnexUpdateMode?, commandID: String)] = [:]
    private(set) var appUpdateInFlight: Set<String> = []
    private(set) var appUpdateErrors: [String: String] = [:]
    private struct AppUpdateAttemptKey: Hashable {
        var hostID: String
        var epoch: String?
        var requestID: String?
    }
    private var appUpdateAttempts: [AppUpdateAttemptKey: String] = [:]
    private(set) var spawnInProgress = false
    var spawnError: String?
    private(set) var uncertainSpawnRequest: CompanionSpawnRequest?
    private(set) var createInProgress = false
    var createError: String?
    private(set) var uncertainCreateRequest: CompanionCreateRequest?
    /// The durable agent just created from this phone, so its chat can offer "Wake with a message".
    var justCreated: CompanionTarget?
    /// Quick agents that exited, until dismissed: each project's "Finished, waiting on you".
    private(set) var finishedRuns = CompanionFinishedRuns() {
        didSet { finishedPersistence?.save(finishedRuns) }
    }
    /// Pin and inactive changes sent to a desktop, shown until it confirms them.
    private(set) var pendingProjectStates: [CompanionProjectTarget: CompanionProjectState] = [:]
    /// Why the last pin or inactive change didn't reach the desktop.
    var projectStateError: String?
    /// Finished runs dismissed or cleared on a desktop, hidden until it confirms.
    private(set) var pendingFinishedRemovals: Set<CompanionTarget> = []
    /// Why the last Dismiss or Clear all didn't reach the desktop.
    var finishedError: String?
    private var fetchedReviews: [CompanionTarget: [String: CompanionFullReview]] = [:]
    var fullReviews: [CompanionTarget: [String: CompanionFullReview]] = [:]
    private var fullFetchFailures: [CompanionTarget: [String: String]] = [:]
    var fullReviewFailures: [CompanionTarget: [String: String]] = [:]
    @ObservationIgnored private let service: any CompanionService
    @ObservationIgnored private let draftPersistence: (any CompanionDraftPersistence)?
    @ObservationIgnored private let finishedPersistence: (any CompanionFinishedPersistence)?
    @ObservationIgnored private var listeningTask: Task<Void, Never>?
    @ObservationIgnored private var sendRequests: [String: CompanionSendRequest] = [:]
    @ObservationIgnored private var historyGenerations: [CompanionTarget: UUID] = [:]
    /// Desktop ids of uploaded images, by `CompanionMessageImage.id`, so a retry doesn't upload them again.
    @ObservationIgnored private var uploadedAttachmentIDs: [String: String] = [:]
    /// Sessions that refused images (`images_not_supported`), by agent. A new session may take them.
    private var imagesRefused: [CompanionTarget: String] = [:]
    /// Each agent's current conversation content hints, from its latest chat snapshot. Archives own theirs.
    private var contentRoots: [CompanionTarget: CompanionContentRoots] = [:]
    @ObservationIgnored private let clock: AnnexClock
    @ObservationIgnored private var remoteImages: [String: CompanionImageBytes] = [:]
    @ObservationIgnored private var remoteImageOrder: [String] = []

    init(service: any CompanionService, draftPersistence: (any CompanionDraftPersistence)? = nil,
         finishedPersistence: (any CompanionFinishedPersistence)? = nil, clock: AnnexClock = .live) {
        self.service = service
        self.clock = clock
        self.draftPersistence = draftPersistence
        self.finishedPersistence = finishedPersistence
        self.drafts = draftPersistence?.load() ?? [:]
        self.finishedRuns = finishedPersistence?.load() ?? .init()
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

    /// Whether a terminal entry point shows, and whether it can open now (`terminal` v1).
    func terminalAvailability(_ scope: CompanionTerminalScope) -> CompanionTerminalAvailability {
        .of(scope, host: hosts.first { $0.id == scope.hostID })
    }
    /// A terminal on the desktop, not yet started.
    func makeTerminal(_ scope: CompanionTerminalScope) throws -> CompanionTerminalSession {
        let host = hosts.first { $0.id == scope.hostID }
        return CompanionTerminalSession(scope: scope, title: CompanionTerminalSession.title(for: scope, host: host), channel: try service.terminal(scope))
    }
    func agent(for target: CompanionTarget) -> CompanionAgent? { host(for: target)?.agent(for: target) }
    /// Navigation must not call an unknown target unavailable while its desktop is still synchronizing.
    func isAgentLoading(_ target: CompanionTarget) -> Bool {
        guard let host = host(for: target) else { return false }
        guard agent(for: target) == nil else { return false }
        if host.isDispatcher(target), host.dispatcher?.enabled == false { return false }
        return !host.hasLoadedCatalog || !host.connection.canOperate || (host.isDispatcher(target) && host.dispatcher?.isLoading == true)
    }
    /// The target is its desktop's Dispatcher, by the project id the desktop gives it.
    func isDispatcher(_ target: CompanionTarget) -> Bool { host(for: target)?.isDispatcher(target) == true }
    @ObservationIgnored private var timelineProjections: [CompanionTarget: CompanionTimelineProjection] = [:]
    func timelineProjection(for target: CompanionTarget) -> CompanionTimelineProjection {
        if let projection = timelineProjections[target] { return projection }
        let projection = CompanionTimelineProjection(); timelineProjections[target] = projection; return projection
    }
    func timelineRows(for target: CompanionTarget) -> [CompanionTimelineRow] {
        timelineProjection(for: target).rows(for: conversation(for: target))
    }

    @ObservationIgnored private var readingBookmarks: [CompanionTarget: CompanionReadingBookmark] = [:]
    func readingBookmark(for target: CompanionTarget) -> CompanionReadingBookmark {
        if let bookmark = readingBookmarks[target] { return bookmark }
        let bookmark = CompanionReadingBookmark(); readingBookmarks[target] = bookmark; return bookmark
    }

    private struct TranscriptKey: Hashable { var target: CompanionTarget; var sessionID: String? }
    @ObservationIgnored private var transcriptExpansions: [TranscriptKey: CompanionTranscriptExpansion] = [:]
    func transcriptExpansion(for target: CompanionTarget, sessionID: String? = nil) -> CompanionTranscriptExpansion {
        let key = TranscriptKey(target: target, sessionID: sessionID)
        if let expansion = transcriptExpansions[key] { return expansion }
        let expansion = CompanionTranscriptExpansion(); transcriptExpansions[key] = expansion; return expansion
    }

    func conversation(for target: CompanionTarget) -> CompanionConversation { conversations[target] ?? .init() }
    func canOperate(_ target: CompanionTarget) -> Bool {
        !sleepRequests.contains(target) && providerFlows[target]?.blocksMutations != true && host(for: target)?.connection.canOperate == true && !conversation(for: target).requiresResync && !conversation(for: target).isLoading
    }
    func canWake(_ target: CompanionTarget) -> Bool {
        if isDispatcher(target), host(for: target)?.dispatcher?.mcpOff != nil { return false }
        return canOperate(target) && !pendingCommands.contains(target) && agent(for: target)?.capabilities.contains(.wake) == true
    }
    /// The ways to wake this agent: Wake & Resume only when it has a session to resume, and Start New Session.
    func wakeChoices(for target: CompanionTarget) -> [CompanionWakeChoice] {
        CompanionWakeChoice.choices(hasSession: agent(for: target)?.hasSession)
    }
    /// A sleeping durable agent on a connected desktop, which a long-press can offer to wake before its chat is read.
    func mayWake(_ target: CompanionTarget) -> Bool {
        guard !sleepRequests.contains(target), providerFlows[target]?.blocksMutations != true else { return false }
        if isDispatcher(target), host(for: target)?.dispatcher?.mcpOff != nil { return false }
        guard let agent = agent(for: target), !agent.isQuick, agent.status == .sleeping || agent.status == .stopped else { return false }
        return host(for: target)?.connection.canOperate == true && !pendingCommands.contains(target)
            && (!conversation(for: target).isLoaded || agent.capabilities.contains(.wake))
    }
    func wake(_ target: CompanionTarget, _ choice: CompanionWakeChoice = .wake) async {
        // From a row's menu the chat may not be read yet, and only its snapshot says whether waking is allowed.
        if !conversation(for: target).isLoaded { await load(target) }
        guard canWake(target) else { return }
        pendingCommands.insert(target); operationErrors.removeValue(forKey: target)
        defer { pendingCommands.remove(target) }
        do { try await service.wake(target, resume: choice.resume, clientCommandID: UUID().uuidString); await load(target, force: true) }
        catch { fail(error, for: target); await load(target, force: true) }
    }
    /// An archive supplies its own snapshot hints; it never updates or inherits the live conversation's policy.
    func content(_ reference: CompanionContentReference, target: CompanionTarget, contentRoots archiveRoots: CompanionContentRoots? = nil) async throws -> CompanionContent {
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
        if !reference.isOffered(roots: archiveRoots ?? contentRoots(for: target)) {
            throw CompanionServiceError.unavailable("This conversation can't preview that file. Refresh the conversation or open it on \(host.name).")
        }
        switch reference {
        case .link(let href): return try await linkContent(href, target: target)
        // A code-span path resolves like a link, so a folder lists and a missing file says so. A desktop
        // without the route still reads files through `/content`, as before.
        case .file(let path) where host.canResolveLinks: return try await linkContent(path, target: target)
        default: return try await service.content(reference, target: target)
        }
    }
    /// A chat link, a code-span path, or an entry of a folder the desktop listed, resolved on the desktop first (`chatLinks` v1).
    /// Entries skip the conversation's path hints: the desktop listed them and still authorizes every read.
    func linkContent(_ href: String, target: CompanionTarget) async throws -> CompanionContent {
        guard let host = host(for: target), host.connection.canOperate else { throw CompanionServiceError.unavailable("Reconnect to your desktop to view this content.") }
        guard host.richContentAvailable else {
            throw CompanionServiceError.unavailable("Rich chat content is off on \(host.name). Turn it on in the desktop's Experimental settings to preview images and files.")
        }
        guard host.canResolveLinks else { throw CompanionServiceError.unavailable(CompanionContentReference.linksNeedUpdate) }
        return try await CompanionContentReference.open(link: href, hostName: host.name, resolve: { try await service.resolveLink($0, target: target) },
                                                        load: { try await service.content($0, target: target) })
    }
    func richContentAvailable(for target: CompanionTarget) -> Bool { host(for: target)?.richContentAvailable == true }
    func contentRoots(for target: CompanionTarget) -> CompanionContentRoots {
        // A removed conversation cannot leave its old hints active when the host or agent returns.
        guard conversations[target]?.isLoaded == true else { return .init() }
        return contentRoots[target] ?? .init()
    }
    func canSend(_ target: CompanionTarget) -> Bool {
        if isDispatcher(target), let off = host(for: target)?.dispatcher?.mcpOff, !off.allows("chat.send") { return false }
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
            if current.sessionID != history.sessionID { clearFullReviews(target) }
            contentRoots[target] = history.contentRoots
            if let capabilities = history.capabilities { setCapabilities(capabilities, for: target) }
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
            current.historyRevision = UUID()
            conversations[target] = current
        } catch {
            guard historyGenerations[target] == generation else { return }
            conversations[target, default: .init()].isLoading = false
            conversations[target, default: .init()].error = error.localizedDescription
            conversations[target, default: .init()].requiresResync = true
        }
    }

    private func setCapabilities(_ capabilities: CompanionCapabilities, for target: CompanionTarget) {
        guard let host = hosts.firstIndex(where: { $0.id == target.hostID }) else { return }
        if hosts[host].dispatcher?.agent?.id == target { hosts[host].dispatcher?.agent?.capabilities = capabilities; return }
        guard let project = hosts[host].projects.firstIndex(where: { $0.id == target.projectID }),
              let agent = hosts[host].projects[project].agents.firstIndex(where: { $0.id == target }) else { return }
        hosts[host].projects[project].agents[agent].capabilities = capabilities
    }

    func sendDraft(to target: CompanionTarget) async {
        let draft = drafts[target] ?? ""
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let dispatcher = isDispatcher(target)
        if let refusal = await submit(message, to: target), dispatcher {
            // A session can end after the button was enabled, including while a send is in flight.
            // Keep newer typing; a definitive refusal restores the submitted draft for editing.
            if (drafts[target] ?? "").isEmpty { drafts[target] = draft }
            let current = attachmentDrafts[target] ?? []
            let restored = Set(attachments.map(\.id))
            attachmentDrafts[target] = attachments + current.filter { !restored.contains($0.id) }
            operationErrors[target] = refusal
        }
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
        _ = await submit(message, to: target)
    }

    /// A definite refusal can restore a draft. Unknown delivery must first be reconciled.
    private func submit(_ message: CompanionMessage, to target: CompanionTarget) async -> String? {
        guard var commandID = message.clientCommandID else { return nil }
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
            return error.localizedDescription
        } catch let error as CompanionServiceError {
            if case .uncertain(let detail) = error { updateDelivery(commandID, target: target, delivery: .uncertain(detail)) }
            else {
                if case .wrongMachine = error { fail(error, for: target) }
                updateDelivery(commandID, target: target, delivery: .failed(error.localizedDescription))
                return error.localizedDescription
            }
        } catch {
            updateDelivery(commandID, target: target, delivery: .uncertain(error.localizedDescription))
        }
        return nil
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
                    try await clock.sleep(.seconds(max(1, seconds ?? 5)))
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

    func canSleepDispatcher(_ target: CompanionTarget) -> Bool {
        isDispatcher(target) && canOperate(target) && !pendingCommands.contains(target)
            && host(for: target)?.dispatcher?.mcpOff?.allows("agent.stop") == true
    }
    func sleepDispatcher(_ target: CompanionTarget) async {
        guard canSleepDispatcher(target) else { return }
        await sleepAgent(target)
    }
    func canSleep(_ target: CompanionTarget) -> Bool {
        if isDispatcher(target), host(for: target)?.dispatcher?.mcpOff != nil { return canSleepDispatcher(target) }
        return canOperate(target) && !pendingCommands.contains(target) && host(for: target)?.canStopAgents == true
            && agent(for: target).map { !$0.isQuick && $0.isSleepingOnDesktop == false } == true
    }
    func sleepAgent(_ target: CompanionTarget) async {
        guard canSleep(target) else { return }
        sleepRequests.insert(target)
        pendingCommands.insert(target); operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do {
            if isDispatcher(target), host(for: target)?.dispatcher?.mcpOff != nil {
                try await service.sleepDispatcher(target, clientCommandID: UUID().uuidString)
            } else if host(for: target)?.canControlProvider == true {
                let id = UUID().uuidString
                confirmedSleepCommands[target] = id
                try await service.sleepAndWait(target, clientCommandID: id)
                confirmedSleepCommands[target] = nil; sleepRequests.remove(target)
            } else {
                try await service.sleepAgent(target, clientCommandID: UUID().uuidString)
            }
            await refreshSleepState(target)
        } catch {
            // A lost reply is not a refusal and must not unlock provider changes or a new start.
            if case CompanionServiceError.rejected = error { sleepRequests.remove(target); confirmedSleepCommands[target] = nil }
            if case CompanionServiceError.unavailable = error { sleepRequests.remove(target); confirmedSleepCommands[target] = nil }
            fail(error, for: target)
        }
    }
    func refreshSleepState(_ target: CompanionTarget) async {
        guard !sleepRefreshes.contains(target), host(for: target)?.connection.canOperate == true else { return }
        sleepRefreshes.insert(target)
        defer { sleepRefreshes.remove(target) }
        do {
            if let id = confirmedSleepCommands[target] {
                try await service.sleepAndWait(target, clientCommandID: id)
                confirmedSleepCommands[target] = nil; sleepRequests.remove(target); operationErrors[target] = nil
            }
            try await service.refreshSleepState(target)
        }
        catch { fail(error, for: target) }
    }

    func cancel(_ target: CompanionTarget) async {
        guard canOperate(target), !pendingCommands.contains(target), agent(for: target)?.capabilities.contains(.cancel) == true else { return }
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do { try await service.cancel(target, clientCommandID: UUID().uuidString) }
        catch { fail(error, for: target) }
    }

    func respond(_ approval: CompanionApproval, option: CompanionApprovalOption, target: CompanionTarget) async {
        guard canOperate(target), agent(for: target)?.capabilities.contains(.approve) == true,
              !pendingCommands.contains(target), !approval.isExpired(at: Date()), approval.resolution == .pending, approval.options.contains(option),
              (!option.allows || canApprove(approval, target: target)),
              option.isAnswerable(persistentApprovals: canAnswerPersistentApprovals(target)) else { return }
        var submitted = approval
        submitted.resolution = .submitting
        upsert(.approval(submitted), target: target)
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do {
            try await service.respond(to: approval.id, optionID: option.id, reviewedDigest: option.allows && fullReviews[target]?[approval.id]?.reference == approval.eventReference ? fullReviews[target]?[approval.id]?.digest : nil, target: target, clientCommandID: UUID().uuidString)
            guard approvalIsSubmitting(approval.id, target: target) else { return }
            submitted.resolution = option.allows ? .allowed : .denied
            upsert(.approval(submitted), target: target)
        } catch {
            fullReviews[target]?[approval.id] = nil
            if option.allows, case CompanionServiceError.incompleteRepresentation = error {
                fullReviewFailures[target, default: [:]][approval.id] = "Review the full request before allowing it, or review it on the desktop."
            }
            guard approvalIsSubmitting(approval.id, target: target) else { return }
            if case CompanionServiceError.rejected = error {
                upsert(.approval(approval), target: target)
            } else if case CompanionServiceError.incompleteRepresentation = error {
                upsert(.approval(approval), target: target)
            } else {
                submitted.resolution = .uncertain
                upsert(.approval(submitted), target: target)
                conversations[target, default: .init()].requiresResync = true
            }
            fail(error, for: target)
        }
    }

    func canApprove(_ approval: CompanionApproval, target: CompanionTarget) -> Bool {
        guard canOperate(target), approval.resolution == .pending, !approval.isExpired(at: Date()) else { return false }
        if let reference = approval.eventReference {
            guard let item = conversation(for: target).items.first(where: { $0.id == "approval:\(approval.id)" }),
                  case .approval(let current) = item, current.resolution == .pending,
                  current.eventReference == reference, conversation(for: target).sessionID == reference.sessionID else { return false }
        }
        guard fullReviewFailures[target]?[approval.id] == nil else { return false }
        guard approval.isIncomplete else { return true }
        return fullReviews[target]?[approval.id]?.reference == approval.eventReference
            && conversation(for: target).sessionID == approval.eventReference?.sessionID
    }
    private func clearFullReviews(_ target: CompanionTarget) {
        fullReviews[target] = nil; fetchedReviews[target] = nil; fullReviewFailures[target] = nil; fullFetchFailures[target] = nil
    }
    func fullReviewReason(_ approval: CompanionApproval, target: CompanionTarget) -> String? {
        guard approval.resolution == .pending else { return nil }
        if !canOperate(target) { return "Reconnect and refresh this conversation before answering the request." }
        if canApprove(approval, target: target) { return nil }
        return fullReviewFailures[target]?[approval.id] ?? fullFetchFailures[target]?[approval.id] ?? "Incomplete request. Review the full request before allowing it, or deny it here."
    }
    func fetchFullEvent(_ reference: CompanionEventReference, target: CompanionTarget) async throws -> AnnexFullEvent {
        guard canOperate(target) else { throw CompanionServiceError.rejected("Reconnect to the desktop, then review this event again.") }
        let id = reference.event["type"]?.string == "permission_request" ? reference.event["data"]?["requestId"]?.string : nil
        if let id { fullReviews[target]?[id] = nil; fetchedReviews[target]?[id] = nil }
        do {
            let full = try await service.fullEvent(reference, target: target)
            guard canOperate(target) else { throw CompanionServiceError.rejected("Reconnect to the desktop, then review this event again.") }
            if let id { fetchedReviews[target, default: [:]][id] = .init(reference: reference, digest: full.digest) }
            return full
        } catch {
            if let id { fullFetchFailures[target, default: [:]][id] = CompanionFullReview.reason(error) }
            throw error
        }
    }
    @discardableResult func acknowledgeFullReview(_ full: AnnexFullEvent, reference: CompanionEventReference, target: CompanionTarget) -> Bool {
        guard canOperate(target), full.agentID == target.agentID, full.sessionID == reference.sessionID, full.sequence == reference.sequence,
              let id = full.event["data"]?["requestId"]?.string,
              fetchedReviews[target]?[id]?.digest == full.digest, fetchedReviews[target]?[id]?.reference == reference,
              let item = conversation(for: target).items.first(where: { $0.id == "approval:\(id)" }),
              case .approval(let pending) = item, pending.resolution == .pending, pending.eventReference == reference,
              conversation(for: target).sessionID == reference.sessionID else { return false }
        fullReviews[target, default: [:]][id] = .init(reference: reference, digest: full.digest)
        fullReviewFailures[target]?[id] = nil
        fullFetchFailures[target]?[id] = nil
        return true
    }

    /// Older desktops take one-off decisions only; "Allow always" and the like are chosen there.
    func canAnswerPersistentApprovals(_ target: CompanionTarget) -> Bool { host(for: target)?.canAnswerPersistentApprovals == true }

    // MARK: Model, effort and permission level (#155)

    /// The composer's controls can send now: live, connected, and no other command in flight.
    func canChangeChatControls(_ target: CompanionTarget) -> Bool {
        canOperate(target) && !pendingCommands.contains(target) && agent(for: target)?.chatControls != nil
    }
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget) async {
        guard canChangeChatControls(target), let controls = agent(for: target)?.chatControls else { return }
        let switching = model != controls.model
        guard switching ? controls.showsModelMenu && controls.models.contains(where: { $0.id == model }) : effort != nil && controls.showsEffortMenu,
              effort != .providerDefault || controls.effortDefault else { return }
        await runChatControl(target) { try await service.setModel(model, effort: effort, target: target, clientCommandID: $0) }
    }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget) async {
        guard canChangeChatControls(target), let controls = agent(for: target)?.chatControls,
              level != controls.currentLevel, controls.liveLevels.contains(level) else { return }
        await runChatControl(target) { try await service.setLevel(level, target: target, clientCommandID: $0) }
    }
    /// The change shows when the session's own event arrives. A refusal means the phone's view was stale, so read it again.
    private func runChatControl(_ target: CompanionTarget, _ command: (String) async throws -> Void) async {
        pendingCommands.insert(target)
        operationErrors[target] = nil
        defer { pendingCommands.remove(target) }
        do { try await command(UUID().uuidString) }
        catch {
            fail(error, for: target)
            if case CompanionServiceError.uncertain = error { conversations[target, default: .init()].requiresResync = true }
            else if case CompanionServiceError.rejected = error { await load(target, force: true) }
        }
    }

    func canAnswer(_ request: CompanionHelperRequest) -> Bool {
        guard let host = hosts.first(where: { $0.id == request.hostID }) else { return false }
        return host.connection.canOperate && host.canAnswerHelperRequests && !helperRequestsInFlight.contains(request.slot)
            && !consumedHelperRequests.contains(request.slot) && host.helperRequests.contains { $0.id == request.id }
    }

    func canApprove(_ request: CompanionHelperRequest) -> Bool {
        canAnswer(request) && request.canApprove
            && (request.kind != .start || agent(for: request.agentTarget)?.orchestration?.mcpReportOnly != true)
    }
    func isMCPReportOnly(_ target: CompanionTarget) -> Bool { agent(for: target)?.orchestration?.mcpReportOnly == true }

    /// Approve or decline a helper request, as the desktop's Needs you does. Approving a dispose with work at risk is
    /// the desktop's "Dispose anyway"; one whose checks couldn't run can only be declined.
    func answer(_ request: CompanionHelperRequest, approve: Bool) async {
        guard canAnswer(request), !approve || canApprove(request) else { return }
        let force = approve && request.kind == .dispose && request.dispose?.workAtRisk == true
        helperRequestsInFlight.insert(request.slot)
        helperRequestErrors[request.slot] = nil
        defer { helperRequestsInFlight.remove(request.slot) }
        do {
            try await service.answerHelperRequest(request, approve: approve, force: force, clientCommandID: UUID().uuidString)
            // The desktop's next snapshot drops it too; don't leave it answerable until then.
            if let index = hosts.firstIndex(where: { $0.id == request.hostID }) {
                hosts[index].helperRequests.removeAll { $0.id == request.id }
            }
        } catch let error as CompanionHelperRequestConsumed {
            consumedHelperRequests.insert(request.slot)
            helperRequestNotice = error.message
            if let index = hosts.firstIndex(where: { $0.id == request.hostID }) { hosts[index].helperRequests.removeAll { $0.id == request.id } }
        } catch {
            helperRequestErrors[request.slot] = error.localizedDescription
        }
    }

    func canAnswer(_ request: CompanionGrantRequest) -> Bool {
        guard let host = hosts.first(where: { $0.id == request.hostID }) else { return false }
        return host.connection.canOperate && host.canAnswerGrantRequests && !grantRequestsInFlight.contains(request.slot)
            && request.controlEpoch == host.controlEpoch
            && (!request.isAppUpdate || (host.canUpdateApp && request.update != nil))
            && host.grantRequests.contains { $0.id == request.id && $0.controlEpoch == host.controlEpoch } && !request.isExpired(at: Date())
    }

    /// Answer a Clubhouse grant request, as the desktop's Needs you does. Only an answer the request lists is sent.
    func answer(_ request: CompanionGrantRequest, with answer: CompanionGrantRequest.Answer, updateMode: AnnexUpdateMode? = nil) async {
        guard canAnswer(request), request.answers.contains(answer) else { return }
        guard (request.isAppUpdate && answer == .allowOnce) == (updateMode != nil) else {
            grantRequestErrors[request.slot] = "Choose Restart now or When idle before allowing an update."
            return
        }
        let attempt = grantAnswerAttempts[request.slot].flatMap { $0.answer == answer && $0.mode == updateMode ? $0.commandID : nil } ?? UUID().uuidString
        grantAnswerAttempts[request.slot] = (answer, updateMode, attempt)
        grantRequestsInFlight.insert(request.slot)
        grantRequestErrors[request.slot] = nil
        defer { grantRequestsInFlight.remove(request.slot) }
        do {
            try await service.answerGrantRequest(request, answer: answer, updateMode: updateMode, clientCommandID: attempt)
            grantAnswerAttempts[request.slot] = nil
            removeGrantRequest(request)
        } catch CompanionGrantRequestError.gone(let message) {
            grantAnswerAttempts[request.slot] = nil
            grantRequestNotice = message
            removeGrantRequest(request)
        } catch let error as CompanionServiceError {
            // Only a lost reply keeps the command id: the same answer again replays the desktop's receipt.
            if case .uncertain = error {} else { grantAnswerAttempts[request.slot] = nil }
            grantRequestErrors[request.slot] = error.localizedDescription
        } catch {
            grantAnswerAttempts[request.slot] = nil
            grantRequestErrors[request.slot] = error.localizedDescription
        }
    }
    private func removeGrantRequest(_ request: CompanionGrantRequest) {
        if let index = hosts.firstIndex(where: { $0.id == request.hostID }) { hosts[index].grantRequests.removeAll { $0.id == request.id } }
    }

    func requestAppUpdate(hostID: String) async {
        guard let host = hosts.first(where: { $0.id == hostID }), host.connection.canOperate, host.canUpdateApp,
              host.appUpdate?.canRequest == true, !appUpdateInFlight.contains(hostID) else { return }
        await changeAppUpdate(hostID: hostID, epoch: host.controlEpoch, requestID: nil)
    }
    func cancelAppUpdate(hostID: String) async {
        guard let host = hosts.first(where: { $0.id == hostID }), host.connection.canOperate, host.canUpdateApp,
              let request = host.appUpdate?.request, request.canCancel, !appUpdateInFlight.contains(hostID) else { return }
        await changeAppUpdate(hostID: hostID, epoch: host.controlEpoch, requestID: request.requestId)
    }
    private func changeAppUpdate(hostID: String, epoch: String?, requestID: String?) async {
        let key = AppUpdateAttemptKey(hostID: hostID, epoch: epoch, requestID: requestID)
        let commandID = appUpdateAttempts[key] ?? UUID().uuidString
        appUpdateAttempts[key] = commandID
        appUpdateInFlight.insert(hostID); appUpdateErrors[hostID] = nil
        defer { appUpdateInFlight.remove(hostID) }
        do {
            if let requestID { try await service.cancelAppUpdate(hostID: hostID, requestID: requestID, clientCommandID: commandID) }
            else { try await service.requestAppUpdate(hostID: hostID, clientCommandID: commandID) }
            appUpdateAttempts[key] = nil
        } catch {
            if case CompanionServiceError.uncertain = error {} else { appUpdateAttempts[key] = nil }
            guard let host = hosts.first(where: { $0.id == hostID }), host.controlEpoch == epoch else {
                appUpdateAttempts[key] = nil
                return
            }
            appUpdateErrors[hostID] = error.localizedDescription
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
            fail(error, for: target)
        }
    }

    static func validAnswers(_ answers: [String: CompanionAnswer], for question: CompanionQuestion) -> Bool {
        guard question.canAnswerOnPhone, Set(answers.keys) == Set(question.prompts.map(\.id)) else { return false }
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
            && !(isDispatcher(target) && host(for: target)?.dispatcher?.mcpOff != nil)
    }
    func providerFlow(for target: CompanionTarget) -> CompanionProviderFlow {
        if let flow = providerFlows[target] { return flow }
        let flow = CompanionProviderFlow(target: target, service: service) { [weak self] in
            guard let self else { return false }
            return self.canEditSettings(target) && self.host(for: target)?.canControlProvider == true
                && self.host(for: target)?.connection.canOperate == true && !self.sleepRequests.contains(target)
                && !self.pendingCommands.contains(target) && self.agent(for: target)?.isSleepingOnDesktop == true
        }
        providerFlows[target] = flow
        return flow
    }
    func hasPendingProviderAction(_ target: CompanionTarget) -> Bool { providerFlows[target]?.blocksMutations == true }
    func helperRouting(hostID: String, projectID: String? = nil, agentID: String? = nil) async throws -> CompanionHelperRouting {
        guard hosts.first(where: { $0.id == hostID })?.connection.canOperate == true else { throw CompanionServiceError.unavailable("Connect to the desktop to read helper presets.") }
        return try await service.helperRouting(hostID: hostID, projectID: projectID, agentID: agentID)
    }
    func updateHelperRouting(_ update: AnnexHelperRoutingUpdate, hostID: String) async throws -> CompanionHelperRouting {
        guard let host = hosts.first(where: { $0.id == hostID }), host.connection.canOperate, host.canEditHelperPresets else {
            throw CompanionServiceError.unavailable("Connect to a desktop that offers helper preset changes.")
        }
        return try await service.updateHelperRouting(update, hostID: hostID, clientCommandID: UUID().uuidString)
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        guard canEditSettings(target) else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.") }
        return try await service.settings(for: target)
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget) async throws -> CompanionAgentSettings {
        guard !sleepRequests.contains(target), providerFlows[target]?.blocksMutations != true else {
            throw CompanionServiceError.rejected("Wait for the desktop to confirm that the agent is asleep.")
        }
        guard canEditSettings(target), host(for: target)?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to your desktop to change this agent's settings.")
        }
        return try await service.updateSettings(change, target: target, clientCommandID: UUID().uuidString)
    }

    func reconnect(hostID: String) async { await service.reconnect(hostID: hostID) }

    // MARK: Dispatcher (#2533)

    /// Hosts whose Dispatcher is being turned on or off, and why the last change failed.
    private(set) var dispatcherSwitching: Set<String> = []
    var dispatcherErrors: [String: String] = [:]
    /// Turns a desktop's Dispatcher on or off. Its row appears or goes when the desktop's snapshot follows.
    func setDispatcher(enabled: Bool, hostID: String) async {
        guard let host = hosts.first(where: { $0.id == hostID }), let dispatcher = host.dispatcher, !dispatcherSwitching.contains(hostID) else { return }
        guard host.connection.canOperate else { dispatcherErrors[hostID] = "Reconnect to your desktop to change the Dispatcher."; return }
        if enabled, let blocker = dispatcher.turnOnBlocker { dispatcherErrors[hostID] = blocker; return }
        dispatcherSwitching.insert(hostID)
        dispatcherErrors[hostID] = nil
        defer { dispatcherSwitching.remove(hostID) }
        do { try await service.setDispatcher(enabled: enabled, hostID: hostID, clientCommandID: UUID().uuidString) }
        catch { dispatcherErrors[hostID] = error.localizedDescription }
    }

    // MARK: Settings > Dispatcher (#338)

    /// A Clear chat or Forget everything waiting on the person. Shown as its own confirmation.
    var dispatcherResetPrompt: CompanionDispatcherResetPrompt?
    /// Hosts with a reset on its way to the desktop.
    private(set) var dispatcherResetting: Set<String> = []
    /// What the last reset did, or why it didn't, per host.
    var dispatcherResetNotices: [String: String] = [:]

    /// The host offers Settings > Dispatcher and its Dispatcher is on.
    func canEditDispatcherSettings(hostID: String) -> Bool {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return false }
        return host.canEditDispatcherSettings && host.dispatcher?.enabled == true && host.dispatcher?.mcpOff == nil
    }
    /// The last settings the desktop sent, kept current by the service.
    func dispatcherSettings(hostID: String) -> CompanionDispatcherSettings? {
        hosts.first { $0.id == hostID }?.dispatcherSettings
    }
    func loadDispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings {
        guard canEditDispatcherSettings(hostID: hostID) else { throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop) }
        return try await service.dispatcherSettings(hostID: hostID)
    }
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String) async throws -> CompanionDispatcherSettings {
        try requireDispatcherConnection(hostID)
        return try await service.updateDispatcher(update, hostID: hostID, clientCommandID: UUID().uuidString)
    }
    func setDispatcherModels(_ models: AnnexDispatcherModels, hostID: String) async throws -> CompanionDispatcherSettings {
        try requireDispatcherConnection(hostID)
        return try await service.setDispatcherModels(models, hostID: hostID, clientCommandID: UUID().uuidString)
    }
    private func requireDispatcherConnection(_ hostID: String) throws {
        guard canEditDispatcherSettings(hostID: hostID) else { throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop) }
        guard hosts.first(where: { $0.id == hostID })?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to your desktop to change the Dispatcher.")
        }
    }
    /// Reads the settings right before asking, so the confirmation is as fresh as it can be, then asks.
    func askDispatcherReset(_ reset: CompanionDispatcherReset, hostID: String) async {
        guard !dispatcherResetting.contains(hostID) else { return }
        dispatcherResetNotices[hostID] = nil
        do {
            try requireDispatcherConnection(hostID)
            let settings = try await service.dispatcherSettings(hostID: hostID)
            guard let prompt = CompanionDispatcherResetPrompt(reset, settings: settings, hostID: hostID) else {
                dispatcherResetNotices[hostID] = "This desktop didn't offer a confirmation for \(reset.action). Try again."
                return
            }
            dispatcherResetPrompt = prompt
        } catch { dispatcherResetNotices[hostID] = error.localizedDescription }
    }
    func cancelDispatcherReset() { dispatcherResetPrompt = nil }
    /// Sends the confirmed reset once. A stale confirmation did nothing: the person is asked again with what changed.
    func confirmDispatcherReset(_ prompt: CompanionDispatcherResetPrompt) async {
        let hostID = prompt.hostID
        guard !dispatcherResetting.contains(hostID) else { return }
        if dispatcherResetPrompt?.id == prompt.id { dispatcherResetPrompt = nil }
        let asked = dispatcherSettings(hostID: hostID)
        dispatcherResetting.insert(hostID)
        defer { dispatcherResetting.remove(hostID) }
        do {
            try requireDispatcherConnection(hostID)
            let outcome = try await service.resetDispatcher(prompt, clientCommandID: UUID().uuidString)
            dispatcherResetNotices[hostID] = outcome.message
        } catch CompanionDispatcherSettingsError.stale(let fresh) {
            let changed = CompanionDispatcherResetPrompt.changes(prompt.reset, from: asked, to: fresh)
            if let again = CompanionDispatcherResetPrompt(prompt.reset, settings: fresh, hostID: hostID, changed: changed) {
                dispatcherResetPrompt = again
            } else { dispatcherResetNotices[hostID] = changed }
        } catch { dispatcherResetNotices[hostID] = error.localizedDescription }
    }

    // MARK: Project page (#158)

    /// The project's "Finished, waiting on you", newest first: the desktop's list when it shares one (#167), else this phone's.
    func finished(in project: CompanionProjectTarget) -> [CompanionFinishedRun] {
        guard let host = hosts.first(where: { $0.id == project.hostID }), host.sharesFinishedQuick else { return finishedRuns.runs(in: project) }
        let exited = host.projects.first { $0.id == project.projectID }?.agents ?? []
        return CompanionFinishedRuns.merged(desktop: host.finishedQuickAgents?[project.projectID] ?? [], exited: exited,
                                            dismissed: finishedRuns.dismissed, now: Date())
            .filter { !pendingFinishedRemovals.contains($0.target) }
    }
    /// The project's desktop keeps the finished list, so Dismiss and Clear all change it there.
    func sharesFinished(_ project: CompanionProjectTarget) -> Bool {
        hosts.first { $0.id == project.hostID }?.sharesFinishedQuick == true
    }
    /// Dismisses a run: on its desktop when it shares the list (gone at once, back with the reason if the desktop refuses).
    func dismissFinished(_ target: CompanionTarget) async {
        let project = CompanionProjectTarget(hostID: target.hostID, projectID: target.projectID)
        await changeFinished(project, removing: [target]) { [service] id in
            try await service.dismissFinishedQuick(target, clientCommandID: id)
        } local: { $0.dismiss(target) }
    }
    /// The desktop's "Clear all", for one project.
    func clearFinished(in project: CompanionProjectTarget) async {
        let shown = finished(in: project).map(\.target)
        await changeFinished(project, removing: shown) { [service] id in
            try await service.clearFinishedQuick(project, clientCommandID: id)
        } local: { $0.clear(project) }
    }
    private func changeFinished(_ project: CompanionProjectTarget, removing targets: [CompanionTarget],
                                send: (String) async throws -> [CompanionFinishedRun], local: (inout CompanionFinishedRuns) -> Void) async {
        guard sharesFinished(project) else { local(&finishedRuns); return }
        guard hosts.first(where: { $0.id == project.hostID })?.connection.canOperate == true else {
            finishedError = "Reconnect to your desktop to change its finished list."
            return
        }
        finishedError = nil
        pendingFinishedRemovals.formUnion(targets)
        defer { pendingFinishedRemovals.subtract(targets) }
        do {
            let confirmed = try await send(UUID().uuidString)
            if let index = hosts.firstIndex(where: { $0.id == project.hostID }), hosts[index].finishedQuickAgents != nil {
                hosts[index].finishedQuickAgents?[project.projectID] = confirmed
            }
            // The catalog may still list an exited agent for a minute; this keeps it from coming back.
            local(&finishedRuns)
        } catch {
            finishedError = error.localizedDescription
        }
    }

    /// Durable agents asleep in a project, which a first message wakes (the desktop's "Wake a sleeping agent").
    func sleepingAgents(in project: CompanionProjectTarget) -> [CompanionAgent] {
        (hosts.first { $0.id == project.hostID }?.projects.first { $0.id == project.projectID }?.agents ?? [])
            .filter { !$0.isQuick && $0.status.dot == .sleeping }
    }

    /// Wakes a sleeping agent with a message and opens its chat, where the message's delivery shows.
    /// A message to a sleeping agent starts its session; the chat has to be read first to know it can.
    func wake(_ target: CompanionTarget, message: String) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, host(for: target)?.connection.canOperate == true else { return }
        drafts[target] = text
        selection = target
        await load(target)
        if canSend(target) { await sendDraft(to: target) }
        else if operationErrors[target] == nil { operationErrors[target] = "\(agent(for: target)?.name ?? "This agent") can't be woken from your phone. Your message is in its composer." }
    }

    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges {
        guard hosts.first(where: { $0.id == project.hostID })?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to your desktop to see its changes.")
        }
        return try await service.changes(for: project)
    }
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff {
        guard hosts.first(where: { $0.id == project.hostID })?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to your desktop to see this file's changes.")
        }
        return try await service.diff(of: file, in: project)
    }
    /// A project's pins, mark and idle flag when its desktop shares them, with any change still on its way.
    /// Nil when this phone keeps its own (an older desktop, or one that hasn't moved its pins over yet).
    func sharedProjectState(_ project: CompanionProjectTarget) -> CompanionProjectState? {
        guard let host = hosts.first(where: { $0.id == project.hostID }), host.sharesProjectState else { return nil }
        return pendingProjectStates[project] ?? host.projectState?[project.projectID] ?? .init()
    }
    /// Pins or unpins a project on its desktop: shown at once, then confirmed by the desktop.
    func setProject(_ project: CompanionProjectTarget, pinned: Bool) async {
        await changeProjectState(project, to: { $0.with(pinned: pinned) }) { [service] id in
            try await service.setProject(project, pinned: pinned, clientCommandID: id)
        }
    }
    /// Marks a project inactive or active on its desktop. Marking active counts as activity there.
    func setProject(_ project: CompanionProjectTarget, inactive: Bool) async {
        await changeProjectState(project, to: { $0.with(inactive: inactive) }) { [service] id in
            try await service.setProject(project, inactive: inactive, clientCommandID: id)
        }
    }
    private func changeProjectState(_ project: CompanionProjectTarget, to change: (CompanionProjectState) -> CompanionProjectState,
                                    send: (String) async throws -> CompanionProjectState) async {
        guard let current = sharedProjectState(project) else { return }
        guard host(for: .init(hostID: project.hostID, projectID: project.projectID, agentID: ""))?.connection.canOperate == true else {
            projectStateError = "Reconnect to your desktop to change this project."
            return
        }
        projectStateError = nil
        pendingProjectStates[project] = change(current)
        defer { pendingProjectStates[project] = nil }
        do {
            let confirmed = try await send(UUID().uuidString)
            if let index = hosts.firstIndex(where: { $0.id == project.hostID }), hosts[index].projectState != nil {
                hosts[index].projectState?[project.projectID] = confirmed
            }
        } catch {
            projectStateError = error.localizedDescription
        }
    }

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
            fail(error, for: target)
            if case CompanionServiceError.rejected = error {} else {
                conversations[target, default: .init()].requiresResync = true
            }
        }
    }
    func dismissError(for target: CompanionTarget) { operationErrors[target] = nil; wrongMachines[target] = nil }

    /// Shows a command's failure on the agent's chat, keeping a `wrong_machine` refusal's other machine.
    private func fail(_ error: Error, for target: CompanionTarget) {
        operationErrors[target] = error.localizedDescription
        if case CompanionServiceError.wrongMachine(let refusal) = error { wrongMachines[target] = refusal }
        else { wrongMachines[target] = nil }
    }
    /// The agent on another machine that the error showing on this chat says to use instead.
    func otherMachineTarget(for target: CompanionTarget) -> CompanionTarget? {
        guard operationErrors[target] != nil, let other = wrongMachines[target]?.target, agent(for: other) != nil else { return nil }
        return other
    }
    /// Opens the agent on the machine a `wrong_machine` refusal named. Nothing is sent there.
    func openOnOtherMachine(from target: CompanionTarget) {
        guard let other = otherMachineTarget(for: target) else { return }
        dismissError(for: target)
        selection = other
    }

    func apply(_ event: CompanionEvent) {
        AnnexTelemetry.shared.measurePerformance(.storeApply) {
            let assistant: (CompanionTarget, String)? = switch event {
            case .upsert(let target, .message(let message), _) where message.role == .assistant: (target, message.id)
            case .textDelta(let target, let id, _, _), .streamFinished(let target, let id, _): (target, id)
            default: nil
            }
            let tool: (CompanionTarget, String)? = switch event {
            case .upsert(let target, .tool(let tool), _): (target, tool.id)
            default: nil
            }
            let previousRevision = (assistant ?? tool).flatMap { conversations[$0.0]?.itemsRevision }
            applyEvent(event)
            if let (target, id) = assistant {
                timelineProjections[target]?.updateAssistant(id, previousRevision: previousRevision, conversation: conversation(for: target))
            }
            if let (target, id) = tool {
                timelineProjections[target]?.updateTool(id, previousRevision: previousRevision, conversation: conversation(for: target))
            }
            switch event {
            case .timeline(let target, _, _, _, _), .upsert(let target, _, _), .textDelta(let target, _, _, _), .streamFinished(let target, _, _):
                timelineProjections[target]?.discardIfStale(revision: conversation(for: target).itemsRevision)
            case .hosts(let hosts):
                let hostIDs = Set(hosts.map(\.id))
                timelineProjections = timelineProjections.filter { hostIDs.contains($0.key.hostID) && conversations[$0.key] != nil }
                readingBookmarks = readingBookmarks.filter { hostIDs.contains($0.key.hostID) && conversations[$0.key] != nil }
            case .resyncRequired, .helperStartWarning: break
            }
        }
    }
    private func applyEvent(_ event: CompanionEvent) {
        switch event {
        case .helperStartWarning(let warning): helperStartWarning = warning
        case .hosts(let incoming):
            for host in incoming {
                if let oldEpoch = hosts.first(where: { $0.id == host.id })?.controlEpoch, host.controlEpoch != oldEpoch {
                    let prefix = "\(host.id):"
                    grantAnswerAttempts = grantAnswerAttempts.filter { !$0.key.hasPrefix(prefix) }
                    grantRequestErrors = grantRequestErrors.filter { !$0.key.hasPrefix(prefix) }
                    appUpdateErrors[host.id] = nil
                }
            }
            appUpdateAttempts = appUpdateAttempts.filter { key, _ in
                incoming.contains { $0.id == key.hostID && $0.controlEpoch == key.epoch }
            }
            for host in incoming where !host.connection.canOperate {
                fullReviews = fullReviews.filter { $0.key.hostID != host.id }
                fetchedReviews = fetchedReviews.filter { $0.key.hostID != host.id }
                fullReviewFailures = fullReviewFailures.filter { $0.key.hostID != host.id }
                fullFetchFailures = fullFetchFailures.filter { $0.key.hostID != host.id }
            }
            let hosts = incoming.map { host in
                var host = host
                if host.dispatcher == nil, !host.connection.canOperate {
                    host.dispatcher = self.hosts.first { $0.id == host.id }?.dispatcher
                }
                return host
            }
            clearRemovedChats(in: hosts)
            self.hosts = hosts
            for target in sleepRequests {
                guard confirmedSleepCommands[target] == nil else { continue }
                guard let host = host(for: target), host.connection.canOperate else { continue }
                let confirmed: Bool
                if isDispatcher(target), let off = host.dispatcher?.mcpOff { confirmed = !off.running }
                else { confirmed = agent(for: target)?.isSleepingOnDesktop == true }
                if confirmed { sleepRequests.remove(target); operationErrors[target] = nil }
            }
            var runs = finishedRuns
            if runs.observe(hosts, now: Date()) { finishedRuns = runs }
        case .timeline(let target, let incoming, let sequence, let reset, let sessionID):
            if reset || conversation(for: target).sessionID != sessionID { clearFullReviews(target) }
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
            conversations[target, default: .init()].historyRevision = UUID()
            conversations[target, default: .init()].lastSequence = sequence
            conversations[target, default: .init()].sessionID = sessionID
        case .resyncRequired(let hostID):
            fullReviews = fullReviews.filter { $0.key.hostID != hostID }
            fetchedReviews = fetchedReviews.filter { $0.key.hostID != hostID }
            fullReviewFailures = fullReviewFailures.filter { $0.key.hostID != hostID }
            fullFetchFailures = fullFetchFailures.filter { $0.key.hostID != hostID }
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

    /// Compare listed identities once per host. Status broadcasts never scan every cached conversation,
    /// and a conversation opened before its agent is listed cannot be mistaken for a deletion.
    private func clearRemovedChats(in incoming: [CompanionHost]) {
        let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let removedHosts = Set(hosts.map(\.id)).subtracting(byID.keys)
        var gone: Set<CompanionTarget> = []
        if !removedHosts.isEmpty {
            gone.formUnion(conversations.keys.filter { removedHosts.contains($0.hostID) })
            gone.formUnion(pendingCommands.filter { removedHosts.contains($0.hostID) })
        }
        for previous in hosts {
            guard let current = byID[previous.id] else { continue }
            let listed = Set(current.allAgents.map(\.id))
            for agent in previous.allAgents where !listed.contains(agent.id) {
                if previous.isDispatcher(agent.id) {
                    if current.dispatcher?.mcpOff != nil { continue }
                    if current.dispatcher?.enabled == false || current.dispatcher?.flagOn == false ||
                        current.dispatcher?.liveAgent != nil || (current.dispatcher == nil && current.hasLoadedCatalog) {
                        gone.insert(agent.id)
                    }
                } else if current.hasLoadedCatalog && !agent.isQuick && !pendingCommands.contains(agent.id) {
                    // Quick catalogs expire after exit; retaining their cached chat matches existing behaviour.
                    // An in-flight command can also outlive a catalog read started before the agent existed.
                    gone.insert(agent.id)
                }
            }
        }
        for target in gone {
            conversations[target] = nil; historyGenerations[target] = nil; pendingCommands.remove(target)
            sleepRequests.remove(target); sleepRefreshes.remove(target)
            confirmedSleepCommands[target] = nil; providerFlows[target] = nil
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
        // Assistant text cannot reconcile optimistic user sends or carry phone-local images. Mutate in place,
        // avoiding a full-array copy and scans of unrelated history for every chunk.
        if case .message(let message) = incoming, message.role == .assistant {
            if let index = conversations[target]?.items.lastIndex(where: { $0.id == incoming.id }) {
                conversations[target]?.items[index] = incoming
            } else { conversations[target, default: .init()].items.append(incoming) }
            return
        }
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
