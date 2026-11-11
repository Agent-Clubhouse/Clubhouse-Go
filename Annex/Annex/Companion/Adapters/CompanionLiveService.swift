import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor final class CompanionLiveService: CompanionService {
    // Production callbacks capture Runtime weakly; ownership review is enforced by the deinit lint.
    nonisolated deinit {}
    private var transports: [String: any AnnexTransporting] = [:]
    private var registeredTransportIDs: [String: UUID] = [:]
    private var hosts: [String: CompanionHost] = [:]
    private var capabilities: [String: AnnexCapabilities] = [:]
    /// A successful read can confirm an older desktop has no mobile capabilities; a failed read cannot.
    private var knownCapabilities: Set<String> = []
    private var projections: [CompanionTarget: CompanionChatProjector] = [:]
    private var fullReviews: [CompanionTarget: [String: (reference: CompanionEventReference, digest: String, epoch: String)]] = [:]
    private var reviewGenerations: [String: UUID] = [:]
    private var readOnly: Set<CompanionTarget> = []
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var eventGenerations: [String: UUID] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var refreshAgain: Set<String> = []
    /// Hosts whose next refresh also reconciles every cached chat status: set on each new connection and
    /// resync, since replay resumes from the snapshot and events missed while away never arrive.
    private var needsCatchUp: Set<String> = []
    private var subscribers: [UUID: AsyncStream<CompanionEvent>.Continuation] = [:]
    private var buffers: [CompanionTarget: [AnnexJSON]] = [:]
    private var historyGenerations: [CompanionTarget: UUID] = [:]
    private var quickCatalog: [String: AnnexJSON] = [:]
    /// The snapshot's Dispatcher record, retained for MCP-off and catalog refreshes; REST catalogs never list it.
    private var dispatcherCatalog: [String: AnnexJSON] = [:]
    /// Recognized MCP-off metadata, from the snapshot, change event or capability refresh.
    private var dispatcherMCPOff: [String: CompanionDispatcherMCPOff] = [:]
    /// The Dispatcher's on/off and flag per host, from capabilities and each `dispatcher:changed`.
    private var dispatcherFlags: [String: (enabled: Bool, flagOn: Bool)] = [:]
    /// Hosts whose snapshot says `ptyHost.platform == "win32"`, for matching content roots.
    private var windowsHosts: Set<String> = []
    /// Lightweight references from the last complete snapshot; REST catalog refreshes reuse these.
    private var iconCatalog: [String: CompanionIconCatalog] = [:]
    private let iconStore: CompanionIconStore
    private var helperLabelsCache: [String: (revision: String, labels: CompanionHelperRouting.Labels)] = [:]
    private var consumedHelperRequests: Set<String> = []
    /// Grant requests this connection saw resolved or answered, by host. A snapshot read before the answer can't bring
    /// one back; only its `grant_request:opened` (a lasting Allow that couldn't be saved) does. Cleared on reconnect.
    private var resolvedGrantRequests: [String: Set<String>] = [:]

    init(iconStore: CompanionIconStore = .shared) { self.iconStore = iconStore }
    /// A command as first sent, for its retries. Keyed by machine too: a command id names one command on one desktop,
    /// and the desktop ties its receipt to the command as sent, agent reference included.
    private var savedCommands: [CompanionCommandKey: AnnexCommand] = [:]
    private let streamDiagnostics = CompanionStreamDiagnostics()
    private var isSuspended = false
    /// Called when a host stops answering at its saved address while the app is active.
    var onUnreachable: ((String) -> Void)?
    /// Membership arrives only over the host's authenticated transport.
    var onNetwork: ((String, AnnexNetworkSnapshot) async -> Void)?
    var onNetworkRefusal: ((String) async -> Void)?
    var registeredHostIDs: Set<String> { Set(transports.keys) }
    func hasRegistration(_ registration: AnnexTransportRegistry.Registration) -> Bool {
        registeredTransportIDs[registration.host.hostID] == registration.transportID
    }
    /// Addresses a connected desktop reports for itself (home Wi-Fi, Tailscale).
    var onRoutes: ((String, AnnexCapabilities.Routes) -> Void)?
    /// Runs on resume before reconnecting; returns the hosts it already reconnected on a better route.
    var prepareResume: (() async -> Set<String>)?

    func events() -> AsyncStream<CompanionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(.hosts(sortedHosts))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func register(_ registration: AnnexTransportRegistry.Registration) async {
        let id = registration.host.hostID
        await iconStore.activate(host: id)
        let transport = registration.transport
        await iconStore.setFetcher(for: id) { key, _ in
            let response = try await transport.icon(kind: key.kind.rawValue, id: key.id, version: key.version, ifNoneMatch: nil)
            return .init(status: response.status, contentType: response.contentType ?? "", data: response.data,
                         version: CompanionIconMetadata.version(etag: response.etag))
        }
        invalidateEvents(hostID: id)
        transports[id] = registration.transport
        registeredTransportIDs[id] = registration.transportID
        let endpoint = registration.host.endpoint
        var host = hosts[id] ?? .init(id: id, name: "", endpoint: "", connection: .connecting, projects: [])
        host.name = registration.alias.isEmpty ? endpoint.host : registration.alias
        host.endpoint = "\(endpoint.host):\(endpoint.port)"
        host.connection = .connecting
        hosts[id] = host
        emitHosts()
        guard let generation = await subscribe(to: registration.transport, hostID: id), eventGenerations[id] == generation else { return }
        guard !isSuspended else { hosts[id]?.connection = .offline; emitHosts(); return }
        do { try await registration.transport.connect() }
        catch {
            guard !isSuspended, eventGenerations[id] == generation else { return }
            hosts[id]?.connection = .failed(Self.readableError(error)); emitHosts()
        }
    }

    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        return try await AnnexTelemetry.shared.measure(.history) {
            let transport = try transport(for: target.hostID)
            let generation = UUID()
            let previousSessionID = projections[target]?.sessionID
            historyGenerations[target] = generation
            if buffers[target] == nil { buffers[target] = [] }
            do {
                let snapshot = try await transport.read(.chat(agentID: target.agentID))
                guard historyGenerations[target] == generation else { throw CancellationError() }
                var projection = CompanionChatProjector()
                // A dead transcript describes its own queue era; today's host capability cannot govern its fallback.
                projection.queueStateEventsSupported = !snapshot["readOnly"].boolValue && capabilities[target.hostID]?.supportsQueueState == true
                projection.sessionID = snapshot["sessionId"]?.string
                // Queue kind must be known before replaying turn_started from a snapshot tail.
                if let caps = snapshot["capabilities"], caps != .null { projection.updateCapabilities(caps) }
                if projection.sessionID == projections[target]?.sessionID {
                    projection.commandIDsByMessage = projections[target]?.commandIDsByMessage ?? [:]
                }
                for event in snapshot["events"].arrayValue { projection.apply(event) }
                if projection.sessionID == nil { projection.sessionID = snapshot["sessionId"]?.string }
                for event in snapshot["pendingPermissions"].arrayValue + snapshot["pendingQuestions"].arrayValue {
                    projection.apply(event, allowOlderPending: true)
                }
                if let caps = snapshot["capabilities"], caps != .null { projection.updateCapabilities(caps) }
                // The desktop's own fold is authoritative; live events after it fold on top.
                if var controls = CompanionChatControls(snapshot: snapshot["chatControls"]) {
                    if let previous = projections[target], previous.sessionID == projection.sessionID {
                        controls.awaitingEfforts = previous.controls.awaitingEfforts && projection.effortsSequence <= previous.effortsSequence
                    }
                    projection.controls = controls
                }
                // The desktop's list stands even when the page of events doesn't reach back to commands_available.
                if case .array? = snapshot["slashCommands"] { projection.slashCommands = CompanionSlashCommand.list(snapshot["slashCommands"]) }
                projection.applyQueueSnapshot(snapshot)
                projection.status = CompanionChatProjector.status(snapshot["state"]?.string)
                if snapshot["readOnly"].boolValue || snapshot["sessionId"] == .null {
                    readOnly.insert(target)
                    projection.capabilities = snapshot["canStart"].boolValue && capabilities[target.hostID]?.commands.contains("agent.start") == true ? [.chat, .wake] : []
                } else { readOnly.remove(target) }
                // Live events received while HTTP was in flight are applied after its snapshot.
                let buffered = buffers.removeValue(forKey: target) ?? []
                var needsRefresh = false
                for event in buffered {
                    if event["sessionId"]?.string == projection.sessionID { projection.apply(event) }
                    else if event["sessionId"]?.string != previousSessionID || projection.sessionID == previousSessionID {
                        // Cross-session sequence numbers cannot establish whether a
                        // different session began before or after the HTTP snapshot.
                        needsRefresh = true
                    }
                    // A buffered event from the previously displayed session cannot
                    // roll a newer authoritative snapshot back to that old session.
                }
                if needsRefresh {
                    emit(.resyncRequired(hostID: target.hostID))
                    throw CompanionServiceError.unavailable("The conversation changed while loading. Refresh to synchronize its current session.")
                }
                projections[target] = projection
                updateAgent(target, projection: projection)
                emitHosts()
                return .init(items: projection.items, hasEarlierMessages: snapshot["truncated"].boolValue, lastSequence: projection.lastSequence, sessionID: projection.sessionID,
                             contentRoots: Self.contentRoots(from: snapshot, windows: windowsHosts.contains(target.hostID)),
                             capabilities: availableCapabilities(projection.capabilities, target: target))
            } catch {
                guard historyGenerations[target] == generation else { throw CancellationError() }
                let pending = buffers.removeValue(forKey: target) ?? []
                for event in pending { project(event, target: target) }
                throw CompanionServiceError.unavailable(Self.readableError(error))
            }

        }
    }

    func sessions(for target: CompanionTarget) async throws -> [CompanionSessionSummary] {
        return try await AnnexTelemetry.shared.measure(.archive) {
            let value: AnnexJSON
            do { value = try await transport(for: target.hostID).read(.chatSessions(agentID: target.agentID)) }
            catch let error as CompanionServiceError { throw error }
            catch { throw CompanionServiceError.unavailable(Self.sessionsReadError(error)) }
            return value["sessions"].arrayValue.compactMap { session in
                guard let id = session["sessionId"]?.string else { return nil }
                return CompanionSessionSummary(id: id, title: session["title"]?.string ?? "Conversation",
                    lastActiveAt: session["lastActiveAt"]?.integer.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    provider: session["provider"]?.string)
            }.sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }

        }
    }

    /// The desktop answers 404 agent_not_found for a removed agent and 500 chat_sessions_failed when it can't read its store.
    static func sessionsReadError(_ error: Error) -> String {
        switch error as? AnnexTransportError {
        case .rejected(_, _, let message?): message
        case .rejected(404, let code?, _): CompanionAgentCommandError.message(code: code, message: nil) ?? readableError(error)
        case .rejected(500, _, _): "The desktop couldn't read this agent's past conversations. Try again later."
        default: readableError(error)
        }
    }

    func archive(for target: CompanionTarget, sessionID: String) throws -> any CompanionArchiveReading {
        CompanionArchiveReader(transport: try transport(for: target.hostID), target: target, sessionID: sessionID,
                               windows: windowsHosts.contains(target.hostID))
    }

    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        if let off = mcpOff(for: request.target), !off.allows("chat.send") || readOnly.contains(request.target) || projections[request.target]?.sessionID == nil {
            throw CompanionServiceError.rejected(off.note)
        }
        let kind: AnnexCommand.Kind
        if readOnly.contains(request.target) || projections[request.target]?.sessionID == nil {
            // `agent.start` carries text only; the desktop answers an image upload for a stopped agent with `not_chat`.
            guard request.attachmentIDs.isEmpty else { throw CompanionServiceError.rejected(Self.notChatMessage) }
            // Resume the last session when there is one; the desktop starts fresh when asked to resume none.
            let hasSession = hosts[request.target.hostID]?.agent(for: request.target)?.hasSession
            kind = .start(agentID: request.target.agentID, message: request.text, resume: hasSession ?? true)
        } else {
            kind = .send(agentID: request.target.agentID, sessionID: try session(for: request.target), text: request.text,
                         delivery: request.isSteering ? .steer : request.queueIfBusy ? .queued : .auto, attachmentIDs: request.attachmentIDs)
        }
        let receipt = try await execute(kind, id: request.clientCommandID, hostID: request.target.hostID)
        if case .start = kind {
            // A message can wake a sleeping durable too. Reconcile the newly
            // running session before another send, rather than starting it twice.
            do { _ = try await history(for: request.target) }
            catch { emit(.resyncRequired(hostID: request.target.hostID)) }
        }
        if let messageID = receipt.result?["messageId"]?.string {
            if let item = projections[request.target]?.reconcile(messageID: messageID, commandID: request.clientCommandID) {
                emit(.upsert(request.target, item, sequence: nil))
            }
        }
        return .init(clientCommandID: request.clientCommandID)
    }

    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String {
        return try await AnnexTelemetry.shared.measure(.upload) {
            guard capabilities[target.hostID]?.attachments?.isUsable == true else {
                throw CompanionServiceError.unavailable("This desktop can't take images. Update Clubhouse on your desktop.")
            }
            do {
                return try await transport(for: target.hostID).upload(agentID: target.agentID, data: image.bytes.data, mimeType: image.mimeType).attachmentId
            } catch { throw Self.uploadError(error) }
        }
    }

    nonisolated static let notChatMessage = "Start this agent before sending images."

    /// An upload whose reply was lost is harmless (the next try gets a new id), so every failure here can be retried.
    static func uploadError(_ error: Error) -> Error {
        switch error as? AnnexTransportError {
        case .rejected(409, "not_chat", _): return CompanionServiceError.rejected(notChatMessage)
        case .rejected(409, "images_not_supported", _): return CompanionAttachmentError.imagesNotSupported
        case .rejected(413, _, _): return CompanionServiceError.rejected("This image is too large for the desktop.")
        case .rejected(415, _, _): return CompanionServiceError.rejected("The desktop can't read this image.")
        case .rejected(404, "agent_not_found", _): return CompanionServiceError.rejected("This agent is no longer on your desktop.")
        // `empty_body` / `upload_failed`: the request didn't arrive whole.
        case .rejected(400, _, _): return CompanionServiceError.rejected("The image couldn't be uploaded. Check the connection and try again.")
        case .rateLimited(_, let seconds): return CompanionAttachmentError.rateLimited(retryAfter: seconds)
        case .some(let error): return CompanionServiceError.rejected(readableError(error))
        case nil:
            if error is CancellationError { return error }
            return CompanionServiceError.rejected("The image couldn't be uploaded. Check the connection and try again.")
        }
    }

    func wake(_ target: CompanionTarget, resume: Bool, clientCommandID: String) async throws {
        return try await AnnexTelemetry.shared.measure(.wake) {
            guard readOnly.contains(target), projections[target]?.capabilities.contains(.wake) == true else {
                throw CompanionServiceError.rejected("Refresh the conversation before waking this agent.")
            }
            _ = try await execute(.start(agentID: target.agentID, resume: resume), id: clientCommandID, hostID: target.hostID)
            await refresh(hostID: target.hostID)

        }
    }

    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        return try await AnnexTelemetry.shared.measure(.media) {
            let hostName = hosts[target.hostID]?.name ?? "your desktop"
            guard hosts[target.hostID]?.richContentAvailable == true else {
                throw CompanionServiceError.unavailable("Rich chat content is off on \(hostName). Turn it on in the desktop's Experimental settings to preview images and files.")
            }
            do { return try await fetchContent(reference, target: target) }
            catch let error as CompanionContentError { throw error }
            // A link's own answers (missing, not shared, or a route refusal) are already worded.
            catch let error as CompanionLinkError { throw error }
            catch let error as CompanionServiceError { throw error }
            catch let error as AnnexTransportError {
                let message = Self.contentErrorMessage(error, reference: reference, hostName: hostName)
                if case .rejected(404, "content_unavailable", _) = error { throw CompanionContentError.unavailable(message) }
                throw CompanionServiceError.unavailable(message)
            }
            catch { throw CompanionServiceError.unavailable(Self.contentErrorMessage(error, reference: reference, hostName: hostName)) }
        }
    }

    func resolveLink(_ href: String, target: CompanionTarget) async throws -> CompanionLinkTarget {
        return try await AnnexTelemetry.shared.measure(.media) {
            let hostName = hosts[target.hostID]?.name ?? "your desktop"
            guard hosts[target.hostID]?.richContentAvailable == true else {
                throw CompanionServiceError.unavailable("Rich chat content is off on \(hostName). Turn it on in the desktop's Experimental settings to preview images and files.")
            }
            guard capabilities[target.hostID]?.supportsChatLinks == true else { throw CompanionServiceError.unavailable(CompanionContentReference.linksNeedUpdate) }
            do {
                let value = try await transport(for: target.hostID).read(.chatLink(agentID: target.agentID, href: href))
                return try CompanionLinkTarget(json: value, windows: windowsHosts.contains(target.hostID))
            } catch {
                throw CompanionServiceError.unavailable(Self.linkErrorMessage(error, hostName: hostName))
            }
        }
    }

    /// The chat-link route answers a missing or refused target in its body; these are the requests it couldn't take.
    static func linkErrorMessage(_ error: Error, hostName: String) -> String {
        switch error as? AnnexTransportError {
        case .rejected(404, "agent_not_found", _): return "This agent is no longer on \(hostName)."
        case .rejected(404, "content_unavailable", _):
            return "Rich chat content is off on \(hostName). Turn it on in the desktop's Experimental settings to preview images and files."
        case .rejected(404, "not_found", _): return CompanionContentReference.linksNeedUpdate
        case .rejected(400, _, _), .invalidEndpoint: return "This link can't be opened from the phone. Open it on \(hostName)."
        case .malformedResponse: return "\(hostName) sent an answer this phone can't read. Updating the desktop may help."
        default: return readableError(error)
        }
    }

    private func fetchContent(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        let route: AnnexReadRoute
        switch reference {
        case .image(let ref):
            guard CompanionContentReference.validMediaReference(ref) else { throw AnnexTransportError.invalidEndpoint }
            route = .chatContent(agentID: target.agentID, mediaRef: ref, filePath: nil)
        case .file(let path):
            guard CompanionContentReference.isValidFilePath(path, windows: windowsHosts.contains(target.hostID)) else { throw AnnexTransportError.invalidEndpoint }
            route = .chatContent(agentID: target.agentID, mediaRef: nil, filePath: path)
        case .link(let href):
            return try await CompanionContentReference.open(link: href, hostName: hosts[target.hostID]?.name ?? "your desktop",
                                                            resolve: { try await self.resolveLink($0, target: target) },
                                                            load: { try await self.content($0, target: target) })
        case .localImage: throw AnnexTransportError.invalidEndpoint
            }
            let value = try await transport(for: target.hostID).read(route)
            guard let kind = value["kind"]?.string,
                  let name = value["name"]?.string else { throw AnnexTransportError.malformedResponse }
            let encoded = value["base64"]?.string
            guard (encoded?.utf8.count ?? 0) <= 12 * 1024 * 1024 else { throw AnnexTransportError.responseTooLarge }
            let bytes = encoded.flatMap { Data(base64Encoded: $0) }
            guard encoded == nil || bytes != nil, (bytes?.count ?? 0) <= 8 * 1024 * 1024 else { throw AnnexTransportError.malformedResponse }
            // Future kinds stay named file chips, never active content selected by their MIME or payload.
            // Known `other` retains its existing semantics; malformed envelopes and caps still reject above.
            guard ["image", "text", "video", "audio", "pdf", "other"].contains(kind) else {
                return .init(kind: "other", name: name, tooLarge: value["tooLarge"].boolValue)
            }
            return .init(kind: kind, name: name, mimeType: value["mimeType"]?.string, bytes: bytes,
                         text: value["text"]?.string, truncated: value["truncated"].boolValue, tooLarge: value["tooLarge"].boolValue)
    }

    /// The desktop answers every refused preview with the same code, so name the likely reason for this reference.
    static func contentErrorMessage(_ error: Error, reference: CompanionContentReference, hostName: String) -> String {
        switch error as? AnnexTransportError {
        case .rejected(_, _, let message?): return message
        case .rejected(404, "agent_not_found", _): return "This agent is no longer on \(hostName)."
        // The desktop answers an invalid reference like a missing one (404 content_unavailable), so the phone does too.
        case .rejected(404, _, _), .invalidEndpoint:
            switch reference {
            case .file, .link: return CompanionContentReference.unavailableLinkMessage(hostName: hostName)
            case .image, .localImage: return "This image is no longer available on \(hostName)."
            }
        case .responseTooLarge: return "This file is too large to preview on your phone. Open it on \(hostName)."
        case .malformedResponse: return "\(hostName) sent a preview this phone can't read. Updating the desktop may help."
        default: return readableError(error)
        }
    }

    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {
        _ = try await execute(.interrupt(agentID: target.agentID, sessionID: try session(for: target)), id: clientCommandID, hostID: target.hostID)
    }
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool {
        let receipt = try await execute(.removeQueued(agentID: target.agentID, sessionID: try session(for: target), messageIDs: [messageID]),
                                        id: clientCommandID, hostID: target.hostID)
        return receipt.result?["removed"].arrayValue.contains(.string(messageID)) == true
    }
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws {
        guard capabilities[target.hostID]?.supportsModelSwitch == true else { throw CompanionServiceError.unavailable(CompanionChatControlError.updateDesktop) }
        let session = try session(for: target)
        let before = projections[target]?.effortsSequence ?? 0
        let switching = projections[target]?.controls.model != model
        let wire: AnnexCommand.Effort? = switch effort {
        case .set(let value)?: .set(value)
        case .providerDefault?: .providerDefault
        case nil: nil
        }
        let receipt = try await execute(.setModel(agentID: target.agentID, sessionID: session, model: model, effort: wire), id: clientCommandID, hostID: target.hostID)
        // The new model's efforts come with its `session_info`; until then the old list doesn't apply.
        guard switching, receipt.result?["changed"] != .bool(false), projections[target]?.sessionID == session,
              (projections[target]?.effortsSequence ?? 0) <= before else { return }
        projections[target]?.controls.awaitingEfforts = true
        if let projection = projections[target] { updateAgent(target, projection: projection); emitHosts() }
    }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws {
        guard capabilities[target.hostID]?.supportsLevelSwitch == true else { throw CompanionServiceError.unavailable(CompanionChatControlError.updateDesktop) }
        _ = try await execute(.setLevel(agentID: target.agentID, sessionID: try session(for: target), level: level.rawValue), id: clientCommandID, hostID: target.hostID)
    }
    func fullEvent(_ reference: CompanionEventReference, target: CompanionTarget) async throws -> AnnexFullEvent {
        guard capabilities[target.hostID]?.supportsFullEvents == true,
              let epoch = capabilities[target.hostID]?.epoch else {
            throw CompanionServiceError.unavailable("Reconnect to the latest desktop to review this event in full.")
        }
        let generation = reviewGenerations[target.hostID]
        let result = try await transport(for: target.hostID).fullEvent(agentID: target.agentID, sessionID: reference.sessionID, sequence: reference.sequence)
        guard reviewGenerations[target.hostID] == generation, capabilities[target.hostID]?.epoch == epoch,
              result.event["type"] == reference.event["type"] else {
            throw CompanionServiceError.rejected("The desktop connection changed. Fetch and review this request again.")
        }
        if result.event["type"]?.string == "permission_request" {
            guard let id = result.event["data"]?["requestId"]?.string,
                  let pending = pendingApproval(id, target: target), pending.eventReference == reference,
                  pending.resolution == .pending, projections[target]?.sessionID == reference.sessionID,
                  result.event["data"]?["options"] == reference.event["data"]?["options"] else {
                throw CompanionServiceError.rejected("This pending request changed. Refresh the conversation and review it again.")
            }
            fullReviews[target, default: [:]][id] = (reference, result.digest, epoch)
        }
        return result
    }
    private func pendingApproval(_ id: String, target: CompanionTarget) -> CompanionApproval? {
        projections[target]?.items.compactMap { if case .approval(let value) = $0, value.id == id { value } else { nil } }.first
    }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await respond(to: approvalID, optionID: optionID, reviewedDigest: nil, target: target, clientCommandID: clientCommandID)
    }
    func respond(to approvalID: String, optionID: String, reviewedDigest: String?, target: CompanionTarget, clientCommandID: String) async throws {
        let sessionID = try session(for: target)
        let pending = pendingApproval(approvalID, target: target)
        if let reviewedDigest {
            guard let pending, pending.resolution == .pending,
                  pending.options.first(where: { $0.id == optionID })?.allows == true,
                  let review = fullReviews[target]?[approvalID], review.digest == reviewedDigest,
                  review.reference == pending.eventReference, review.epoch == capabilities[target.hostID]?.epoch,
                  review.reference.sessionID == sessionID else {
                throw CompanionServiceError.rejected("This review expired or the request changed. Fetch and review it again on this device.")
            }
        } else if let pending, pending.isIncomplete, pending.options.first(where: { $0.id == optionID })?.allows == true {
            throw CompanionServiceError.rejected("Review the full request before allowing it, or deny it here.")
        }
        do {
            _ = try await execute(.permission(agentID: target.agentID, sessionID: sessionID, requestID: approvalID, optionID: optionID, reviewedDigest: reviewedDigest), id: clientCommandID, hostID: target.hostID)
        } catch {
            fullReviews[target]?[approvalID] = nil
            throw error
        }
        fullReviews[target]?[approvalID] = nil
    }
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws {
        let values = answers.mapValues { answer -> AnnexJSON in
            switch answer {
            case .text(let value): .string(value)
            case .choices(let values): .array(values.map(AnnexJSON.string))
            }
        }
        _ = try await execute(.question(agentID: target.agentID, sessionID: try session(for: target), requestID: questionID, answers: values), id: clientCommandID, hostID: target.hostID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        let receipt = try await execute(.spawn(projectID: request.project.projectID, prompt: request.prompt, model: request.model, orchestrator: request.provider), id: request.clientCommandID, hostID: request.project.hostID)
        let agentID = receipt.result?["id"]?.string ?? receipt.result?["agentId"]?.string
        if let agentID {
            rememberQuick(.object(["id": .string(agentID), "projectId": .string(request.project.projectID), "kind": .string("quick"),
                                   "name": receipt.result?["name"] ?? .string(agentID), "status": receipt.result?["state"] ?? .string("starting"),
                                   "prompt": .string(request.prompt)]), hostID: request.project.hostID)
        }
        await refresh(hostID: request.project.hostID)
        return .init(clientCommandID: request.clientCommandID, agentTarget: agentID.map {
            .init(hostID: request.project.hostID, projectID: request.project.projectID, agentID: $0)
        })
    }
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        guard capabilities[project.hostID]?.supportsAgentCreate == true else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to create durable agents from your phone.") }
        do { return try CompanionCreateOptions(json: try await transport(for: project.hostID).read(.createOptions(projectID: project.projectID))) }
        catch let error as CompanionServiceError { throw error }
        catch { throw CompanionServiceError.unavailable(Self.agentReadError(error, subject: "new agent options")) }
    }
    /// The receipt comes as soon as the agent's record exists; its worktree is made in the background, and the
    /// snapshot shows it leave `creating` for sleeping (or failed).
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt {
        guard capabilities[request.project.hostID]?.supportsAgentCreate == true else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to create durable agents from your phone.") }
        // Older desktops refuse the field outright, so it's left out for them.
        let freeAgentMode = capabilities[request.project.hostID]?.supportsFreeAgentMode == true ? request.freeAgentMode : nil
        let orchestration = capabilities[request.project.hostID]?.supportsOrchestration == true
            ? request.orchestrate.map { AnnexOrchestrationPatch(orchestrate: .set($0)) } : nil
        let create = AnnexAgentCreate(projectID: request.project.projectID, name: request.name, color: request.color, orchestrator: request.orchestrator,
                                      model: request.model, freeAgentMode: freeAgentMode, useWorktree: request.useWorktree, mcpIDs: request.mcpIDs,
                                      orchestration: orchestration)
        let receipt = try await execute(.create(create), id: request.clientCommandID, hostID: request.project.hostID)
        guard let agentID = receipt.result?["agentId"]?.string else { throw CompanionServiceError.uncertain("The desktop created the agent but didn't say which one. Check its agent list.") }
        await refresh(hostID: request.project.hostID)
        let projectID = receipt.result?["projectId"]?.string ?? request.project.projectID
        return .init(target: .init(hostID: request.project.hostID, projectID: projectID, agentID: agentID),
                     isCreating: receipt.result?["state"]?.string == "creating")
    }
    func helperRouting(hostID: String, projectID: String? = nil, agentID: String? = nil) async throws -> CompanionHelperRouting {
        guard capabilities[hostID]?.supportsHelperRouting == true else { throw CompanionServiceError.unavailable("This desktop does not offer helper presets.") }
        let generation = eventGenerations[hostID]
        let revision = hosts[hostID]?.helperRoutingRevision
        let raw = try await transport(for: hostID).read(.helperRouting(projectID: projectID, agentID: agentID))
        try Task.checkCancellation()
        guard eventGenerations[hostID] == generation else { throw CancellationError() }
        let page = try CompanionHelperRouting(json: raw)
        guard hosts[hostID]?.helperRoutingRevision == revision || hosts[hostID]?.helperRoutingRevision == page.revision else { throw CancellationError() }
        rememberHelperRouting(page, hostID: hostID)
        return page
    }
    func updateHelperRouting(_ update: AnnexHelperRoutingUpdate, hostID: String, clientCommandID: String) async throws -> CompanionHelperRouting {
        guard capabilities[hostID]?.supportsHelperRoutingUpdate == true,
              let feature = capabilities[hostID]?.helperRouting,
              feature.scopes.contains(update.scope),
              (update.auto == nil || feature.modes.contains("auto")),
              ((update.cells == nil && update.reset == nil) || feature.canEditPresets),
              (update.scope == "app" || (update.scope == "project" && update.projectId != nil && update.auto != nil && update.cells == nil && update.reset == nil)),
              update.cells?.allSatisfy({ feature.difficulties.contains($0.difficulty) }) != false else {
            throw CompanionServiceError.unavailable("This desktop does not offer these helper preset changes.")
        }
        let receipt = try await execute(.updateHelperRouting(update), id: clientCommandID, hostID: hostID, validateReceipt: false)
        if receipt.status == .rejected, receipt.error?.code == "helper_routing_stale", let raw = receipt.settings {
            let fresh = try CompanionHelperRouting(json: raw)
            rememberHelperRouting(fresh, hostID: hostID)
            throw CompanionHelperRoutingError.stale(fresh, Self.rejectionMessage(receipt.error))
        }
        if let error = Self.receiptError(receipt) { throw error }
        // The result is already fresh. Never repeat a write or follow it with another read.
        let page = try CompanionHelperRouting(json: receipt.result ?? .null)
        rememberHelperRouting(page, hostID: hostID)
        return page
    }
    private func rememberHelperRouting(_ page: CompanionHelperRouting, hostID: String) {
        guard hosts[hostID] != nil else { return }
        helperLabelsCache[hostID] = (page.revision, page.labels)
        hosts[hostID]?.helperRoutingRevision = page.revision
        hosts[hostID]?.helperRoutingLabels = page.labels
        emitHosts()
    }
    private func refreshHelperRoutingLabels(hostID: String) async {
        guard capabilities[hostID]?.supportsHelperRouting == true else { return }
        if let cached = helperLabelsCache[hostID], cached.revision == hosts[hostID]?.helperRoutingRevision {
            hosts[hostID]?.helperRoutingLabels = cached.labels
            return
        }
        _ = try? await helperRouting(hostID: hostID)
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        guard capabilities[target.hostID]?.supportsAgentSettings == true else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.") }
        do { return try CompanionAgentSettings(json: try await transport(for: target.hostID).read(.agentSettings(agentID: target.agentID))) }
        catch let error as CompanionServiceError { throw error }
        catch { throw CompanionServiceError.unavailable(Self.agentReadError(error)) }
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        guard capabilities[target.hostID]?.supportsAgentSettings == true else { throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change agent settings from your phone.") }
        guard !change.isEmpty else { throw CompanionServiceError.rejected("Nothing to change.") }
        if change.orchestration?.autoHelpers != nil, (capabilities[target.hostID]?.helperRouting?.modes.contains("auto") != true || capabilities[target.hostID]?.helperRouting?.scopes.contains("agent") != true) {
            throw CompanionServiceError.unavailable("This desktop does not offer Auto provider.")
        }
        if change.contextWindow != nil, capabilities[target.hostID]?.supportsContextWindow != true {
            throw CompanionServiceError.unavailable("This desktop doesn't offer context setting changes from the phone.")
        }
        if change.freeAgentMode != nil, capabilities[target.hostID]?.supportsFreeAgentMode != true {
            throw CompanionServiceError.rejected(CompanionAgentCommandError.message(code: "free_agent_mode_not_allowed", message: nil) ?? "")
        }
        if change.orchestration?.isEmpty == false, capabilities[target.hostID]?.supportsOrchestration != true {
            throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to change orchestration from your phone.")
        }
        let receipt = try await execute(.update(AnnexAgentUpdate(agentID: target.agentID, change: change)), id: clientCommandID, hostID: target.hostID)
        // The receipt carries the saved settings, without the option lists; the sheet keeps the ones it shows.
        if let result = receipt.result, let saved = try? CompanionAgentSettings(json: result) { return saved }
        return try await settings(for: target)
    }
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws {
        guard capabilities[request.hostID]?.supportsHelperRequests == true else {
            throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to answer helper requests from your phone.")
        }
        guard !consumedHelperRequests.contains(request.slot) else { throw CompanionServiceError.rejected("This helper request has already been answered.") }
        let kind: AnnexCommand.Kind = approve ? .helperApprove(requestID: request.id, force: force) : .helperDecline(requestID: request.id)
        let receipt = try await execute(kind, id: clientCommandID, hostID: request.hostID, validateReceipt: false)
        if approve, receipt.status == .rejected, ["no_valid_mapping", "auto_off", "no_candidate"].contains(receipt.error?.code ?? "") {
            consumedHelperRequests.insert(request.slot)
            hosts[request.hostID]?.helperRequests.removeAll { $0.id == request.id }
            emitHosts()
            throw CompanionHelperRequestConsumed(message: Self.rejectionMessage(receipt.error))
        }
        if let error = Self.receiptError(receipt) { throw error }
        if let warning = CompanionHelperStartWarning(json: receipt.result?["warning"]) { emit(.helperStartWarning(warning)) }
        // The desktop broadcasts a snapshot without it; drop it now so it can't be answered twice.
        hosts[request.hostID]?.helperRequests.removeAll { $0.id == request.id }
        emitHosts()
    }
    func answerGrantRequest(_ request: CompanionGrantRequest, answer: CompanionGrantRequest.Answer, clientCommandID: String) async throws {
        guard capabilities[request.hostID]?.supportsGrantRequests == true else { throw CompanionServiceError.unavailable(CompanionGrantRequestError.updateDesktop) }
        guard let wire = AnnexCommand.GrantAnswer(rawValue: answer.rawValue) else { throw CompanionServiceError.rejected(CompanionGrantRequestError.message(code: "", message: nil)) }
        let receipt = try await execute(.answerGrant(requestID: request.id, answer: wire), id: clientCommandID, hostID: request.hostID, validateReceipt: false)
        switch receipt.status {
        case .completed:
            dropGrantRequests([request.id], hostID: request.hostID)
        case .rejected where receipt.error?.code == "grant_request_not_found":
            // Expired, answered elsewhere, withdrawn, or not one this device may see.
            dropGrantRequests([request.id], hostID: request.hostID)
            throw CompanionGrantRequestError.gone(CompanionGrantRequestError.message(code: "grant_request_not_found", message: receipt.error?.message))
        case .rejected where receipt.error?.code.hasPrefix("grant_") == true:
            // Nothing changed; the request still waits.
            throw CompanionGrantRequestError.refused(CompanionGrantRequestError.message(code: receipt.error?.code ?? "", message: receipt.error?.message))
        default:
            if let error = Self.receiptError(receipt) { throw error }
        }
    }
    private func dropGrantRequests(_ ids: [String], hostID: String) {
        resolvedGrantRequests[hostID, default: []].formUnion(ids)
        guard hosts[hostID]?.grantRequests.contains(where: { ids.contains($0.id) }) == true else { return }
        hosts[hostID]?.grantRequests.removeAll { ids.contains($0.id) }
        emitHosts()
    }
    /// The snapshot's `grantRequests`, oldest first. An entry without an id, a known kind, a project or an agent is skipped.
    /// A request without `answers` takes its kind's: Allow once and Decline for a call, a lasting Allow and Decline for a grant.
    nonisolated static func grantRequests(from value: AnnexJSON, hostID: String) -> [CompanionGrantRequest] {
        Optional(value).arrayValue.compactMap { item -> CompanionGrantRequest? in
            guard let id = item["requestId"]?.string, !id.isEmpty, let kind = item["kind"]?.string.flatMap(CompanionGrantRequest.Kind.init(rawValue:)),
                  let projectID = item["projectId"]?.string, let agentID = item["agent"]?["agentId"]?.string else { return nil }
            func text(_ key: String) -> String? { item[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
            let labels = item["actionLabels"].arrayValue.compactMap(\.string)
            var answers = item["answers"].arrayValue.compactMap { $0.string.flatMap(CompanionGrantRequest.Answer.init(rawValue:)) }
            if answers.isEmpty { answers = kind == .call ? [.allowOnce, .decline] : [.allowLasting, .decline] }
            let summary = text("summary") ?? (labels.isEmpty ? "Asks for a Clubhouse permission." : "Asks for \(labels.joined(separator: ", ")).")
            return .init(id: id, hostID: hostID, projectID: projectID, kind: kind, agentID: agentID,
                         agentName: item["agent"]?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? agentID,
                         actionLabels: labels, whereLabel: text("where"), toolName: text("toolName"), summary: summary,
                         detail: text("detail"), arguments: text("arguments"), reason: text("reason"), allowEffect: text("allowEffect"),
                         requestedAt: item["requestedAt"].flatMap(date(from:)), expiresAt: item["expiresAt"].flatMap(date(from:)), answers: answers)
        }
    }
    /// The snapshot's `helperRequests`. An entry without an id, kind, project or requester is skipped.
    nonisolated static func helperRequests(from value: AnnexJSON, hostID: String) -> [CompanionHelperRequest] {
        Optional(value).arrayValue.compactMap { item -> CompanionHelperRequest? in
            guard let id = item["requestId"]?.string, let kind = item["kind"]?.string.flatMap(CompanionHelperRequest.Kind.init(rawValue:)),
                  let projectID = item["projectId"]?.string, let requesterID = item["requester"]?["agentId"]?.string else { return nil }
            let helperID = item["helper"]?["agentId"]?.string
            if kind == .dispose && helperID == nil { return nil }
            let helperName = item["helper"]?["name"]?.string ?? helperID ?? "a helper"
            let requesterName = item["requester"]?["name"]?.string ?? "An orchestrator"
            var dispose: CompanionHelperRequest.Dispose?
            if kind == .dispose, let facts = item["dispose"] {
                func count(_ key: String) -> Int? { facts[key]?.int }
                let checkError = facts["checkError"]?.string
                dispose = .init(uncommittedFiles: count("uncommittedFiles") ?? 0, unpushedCommits: count("unpushedCommits") ?? 0,
                                unmergedCommits: count("unmergedCommits"), checkError: checkError, forceRequested: facts["forceRequested"].boolValue,
                                workAtRisk: facts["workAtRisk"].boolValue, canDispose: facts["canDispose"].map { Optional($0).boolValue } ?? (checkError == nil))
            } else if kind == .dispose {
                // Without the facts the phone can't show what would be lost: only Decline.
                dispose = .init(canDispose: false)
            }
            let summary = item["summary"]?.string ?? (kind == .start ? "Wants to start the helper \(helperName)" : "\(requesterName) asked to dispose this helper.")
            return .init(id: id, hostID: hostID, projectID: projectID, kind: kind, requesterID: requesterID, requesterName: requesterName,
                         helperID: helperID, helperName: helperName, requestedAt: item["requestedAt"].flatMap(date(from:)),
                         expiresAt: item["expiresAt"].flatMap(date(from:)), summary: summary,
                         task: item["start"]?["task"]?.string, requestedRouting: CompanionRequestedRouting(json: item["requestedRouting"]), startWarning: CompanionHelperStartWarning(json: item["startWarning"]), dispose: dispose)
        }
    }
    func terminal(_ scope: CompanionTerminalScope) throws -> any CompanionTerminalChannel {
        guard let support = hosts[scope.hostID]?.terminal, support.allows(scope) else {
            throw CompanionServiceError.unavailable(CompanionTerminalAvailability.updateDesktop)
        }
        return CompanionLiveTerminalChannel(transport: try transport(for: scope.hostID), scope: scope)
    }
    nonisolated static func terminalSupport(_ capabilities: AnnexCapabilities?) -> CompanionTerminalSupport? {
        guard let capabilities, capabilities.supportsTerminal, let terminal = capabilities.terminal else { return nil }
        return .init(projectShell: terminal.projectShell, agentShell: terminal.agentShell, agentAttach: terminal.agentAttach)
    }
    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges {
        do { return try CompanionChanges(json: try await transport(for: project.hostID).read(.gitStatus(projectID: project.projectID))) }
        catch let error as CompanionServiceError { throw error }
        catch { throw CompanionServiceError.unavailable(Self.changesReadError(error)) }
    }
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff {
        let json: AnnexJSON
        do { json = try await transport(for: project.hostID).read(.gitDiff(projectID: project.projectID, filePath: file.path, staged: file.diffsStaged)) }
        catch { throw CompanionServiceError.unavailable(Self.changesReadError(error)) }
        guard let original = json["original"]?.string, let modified = json["modified"]?.string else {
            throw CompanionServiceError.unavailable("The desktop sent a diff this phone can't read.")
        }
        // Whole files: work out the lines away from the main actor.
        let deleted = file.status == .deleted
        return await Task.detached(priority: .userInitiated) {
            CompanionFileDiff.make(path: file.path, original: original, modified: deleted ? nil : modified)
        }.value
    }
    static func changesReadError(_ error: Error) -> String {
        switch error as? AnnexTransportError {
        case .rejected(_, _, let message?): message
        case .responseTooLarge: "This file is too large to show on your phone."
        case .rejected(404, _, _): "The desktop no longer has this project."
        case .rejected(500, _, _): "The desktop couldn't read this project's changes."
        default: readableError(error)
        }
    }
    func setProject(_ project: CompanionProjectTarget, pinned: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        try await setProjectState(.setProjectPinned(projectID: project.projectID, pinned: pinned), project: project, id: clientCommandID)
    }
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        try await setProjectState(.setProjectInactive(projectID: project.projectID, inactive: inactive), project: project, id: clientCommandID)
    }
    func dismissFinishedQuick(_ target: CompanionTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        try await changeFinishedQuick(.dismissFinishedQuick(projectID: target.projectID, agentID: target.agentID),
                                      project: .init(hostID: target.hostID, projectID: target.projectID), id: clientCommandID)
    }
    func clearFinishedQuick(_ project: CompanionProjectTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        try await changeFinishedQuick(.clearFinishedQuick(projectID: project.projectID), project: project, id: clientCommandID)
    }
    private func changeFinishedQuick(_ kind: AnnexCommand.Kind, project: CompanionProjectTarget, id: String) async throws -> [CompanionFinishedRun] {
        guard capabilities[project.hostID]?.supportsFinishedQuickAgents == true else {
            throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share its finished list with your phone.")
        }
        let receipt = try await execute(kind, id: id, hostID: project.hostID)
        // The reply is the project's list after the change; a fresh snapshot follows.
        guard let list = receipt.result?["finishedQuickAgents"], case .array = list else {
            throw CompanionServiceError.uncertain("The desktop took the change but didn't confirm it. It will show when the desktop next updates.")
        }
        let runs = CompanionFinishedRun.desktopList(list, project: project)
        if hosts[project.hostID]?.finishedQuickAgents != nil { hosts[project.hostID]?.finishedQuickAgents?[project.projectID] = runs; emitHosts() }
        return runs
    }
    private func setProjectState(_ kind: AnnexCommand.Kind, project: CompanionProjectTarget, id: String) async throws -> CompanionProjectState {
        guard capabilities[project.hostID]?.supportsProjectState == true else {
            throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to share pins with your phone.")
        }
        let receipt = try await execute(kind, id: id, hostID: project.hostID)
        // A fresh snapshot follows every change; the result covers the moment before it arrives.
        guard let state = CompanionProjectState(json: receipt.result) else {
            throw CompanionServiceError.uncertain("The desktop took the change but didn't confirm it. It will show when the desktop next updates.")
        }
        if hosts[project.hostID]?.projectState != nil { hosts[project.hostID]?.projectState?[project.projectID] = state; emitHosts() }
        return state
    }
    nonisolated static func idleDays(from value: AnnexJSON?) -> Int? { value?.int }
    /// `subject` names what was read, as the screen calls it: "settings", or "new agent options".
    static func agentReadError(_ error: Error, subject: String = "settings") -> String {
        switch error as? AnnexTransportError {
        case .rejected(_, _, let message?): message
        case .rejected(404, let code?, _): CompanionAgentCommandError.message(code: code, message: nil) ?? readableError(error)
        case .malformedResponse: "The desktop sent \(subject) this phone can't read. Updating the desktop may help."
        default: readableError(error)
        }
    }
    func reconnect(hostID: String) async {
        guard !isSuspended, let transport = transports[hostID] else { return }
        invalidateEvents(hostID: hostID)
        let generation = UUID()
        eventGenerations[hostID] = generation
        await transport.disconnect()
        guard !isSuspended, eventGenerations[hostID] == generation else { return }
        guard let subscription = await subscribe(to: transport, hostID: hostID),
              !isSuspended, eventGenerations[hostID] == subscription else { return }
        do { try await transport.connect() }
        catch {
            guard !isSuspended, eventGenerations[hostID] == subscription else { return }
            hosts[hostID]?.connection = .failed(Self.readableError(error)); emitHosts()
        }
    }
    func remove(hostID: String) {
        streamDiagnostics.remove(hostID: hostID)
        invalidateEvents(hostID: hostID)
        transports.removeValue(forKey: hostID)
        registeredTransportIDs.removeValue(forKey: hostID)
        hosts.removeValue(forKey: hostID)
        capabilities.removeValue(forKey: hostID)
        knownCapabilities.remove(hostID)
        quickCatalog.removeValue(forKey: hostID)
        needsCatchUp.remove(hostID)
        buffers = buffers.filter { $0.key.hostID != hostID }
        historyGenerations = historyGenerations.filter { $0.key.hostID != hostID }
        readOnly = readOnly.filter { $0.hostID != hostID }
        helperLabelsCache.removeValue(forKey: hostID)
        windowsHosts.remove(hostID)
        iconCatalog.removeValue(forKey: hostID)
        Task { await iconStore.remove(host: hostID) }
        dispatcherCatalog.removeValue(forKey: hostID)
        dispatcherFlags.removeValue(forKey: hostID)
        dispatcherMCPOff.removeValue(forKey: hostID)
        projections = projections.filter { $0.key.hostID != hostID }
        emitHosts()
    }
    func suspend() async {
        isSuspended = true
        for (id, transport) in Array(transports) {
            invalidateEvents(hostID: id)
            hosts[id]?.connection = .offline
            emit(.resyncRequired(hostID: id))
            await transport.disconnect()
        }
        emitHosts()
    }
    func shutdown() async {
        await suspend()
        transports.removeAll()
        registeredTransportIDs.removeAll()
    }
    func resume() async {
        isSuspended = false
        let reconnected = await prepareResume?() ?? []
        for id in Array(transports.keys) where !reconnected.contains(id) { await reconnect(hostID: id) }
    }

    private func clearFullReviews(hostID: String) {
        fullReviews = fullReviews.filter { $0.key.hostID != hostID }
        reviewGenerations[hostID] = UUID()
    }
    private func invalidateEvents(hostID: String) {
        clearFullReviews(hostID: hostID)
        streamDiagnostics.disconnect(hostID: hostID)
        eventGenerations.removeValue(forKey: hostID)
        eventTasks.removeValue(forKey: hostID)?.cancel()
        cancelRefresh(hostID: hostID)
    }

    private func cancelRefresh(hostID: String) {
        refreshTasks.removeValue(forKey: hostID)?.cancel()
        refreshAgain.remove(hostID)
    }

    private func subscribe(to transport: any AnnexTransporting, hostID: String) async -> UUID? {
        invalidateEvents(hostID: hostID)
        let generation = UUID()
        eventGenerations[hostID] = generation
        let stream = await transport.events()
        guard eventGenerations[hostID] == generation else { return nil }
        eventTasks[hostID] = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, self?.eventGenerations[hostID] == generation else { return }
                    await self?.receive(event, hostID: hostID)
                }
                guard !Task.isCancelled, self?.eventGenerations[hostID] == generation else { return }
                self?.subscriptionEnded(hostID: hostID, error: AnnexTransportError.disconnected)
            } catch {
                guard !Task.isCancelled, self?.eventGenerations[hostID] == generation else { return }
                self?.subscriptionEnded(hostID: hostID, error: error)
            }
        }
        return generation
    }

    private func subscriptionEnded(hostID: String, error: Error) {
        invalidateEvents(hostID: hostID)
        hosts[hostID]?.connection = .failed(Self.readableError(error))
        emit(.resyncRequired(hostID: hostID))
        emitHosts()
    }

    // Catalog reads must not stall consumption of the bounded transport stream.
    // Coalesce bursts into one active read plus at most one follow-up refresh.
    private func scheduleRefresh(hostID: String) {
        guard let generation = eventGenerations[hostID], !isSuspended else { return }
        guard refreshTasks[hostID] == nil else { refreshAgain.insert(hostID); return }
        refreshTasks[hostID] = Task { [weak self] in
            repeat {
                self?.refreshAgain.remove(hostID)
                await self?.refresh(hostID: hostID)
                guard !Task.isCancelled, self?.eventGenerations[hostID] == generation else { return }
            } while self?.refreshAgain.contains(hostID) == true
            self?.refreshTasks.removeValue(forKey: hostID)
        }
    }

    private func execute(_ kind: AnnexCommand.Kind, id: String, hostID: String, validateReceipt: Bool = true) async throws -> AnnexCommandReceipt {
        try validateDispatcherCommand(kind, hostID: hostID)
        guard let caps = capabilities[hostID] else { throw CompanionServiceError.unavailable("This desktop does not support mobile control. Update Clubhouse on desktop and reconnect.") }
        let key = CompanionCommandKey(hostID: hostID, commandID: id)
        let command = savedCommands[key] ?? AnnexCommand(commandID: id, epoch: caps.epoch, kind: kind)
        guard command.epoch == caps.epoch else { throw CompanionServiceError.uncertain("The desktop restarted. Refresh the conversation to check the previous command.") }
        savedCommands[key] = command
        do {
            let receipt = try await transport(for: hostID).execute(command)
            if let error = wrongMachineError(receipt, command: command, hostID: hostID) { throw error }
            if validateReceipt, let error = Self.receiptError(receipt, attachmentCount: command.attachmentCount) { throw error }
            return receipt
        } catch let error as CompanionServiceError { throw error }
        catch let error as CompanionAttachmentError { throw error }
        catch AnnexTransportError.rejected(_, "incomplete_representation", let message) {
            throw CompanionServiceError.incompleteRepresentation(message ?? "Fetch and review this request again before allowing it.")
        }
        catch AnnexTransportError.commandOutcomeUnknown { throw CompanionServiceError.uncertain("The desktop may have received this command, but its reply was lost.") }
        catch { throw CompanionServiceError.rejected(Self.readableError(error)) }
    }
    /// A `wrong_machine` refusal: the agent is on another machine. It's never sent on there by itself: the command
    /// carries this desktop's epoch and session, so only the person can decide to do it again on the other one.
    private func wrongMachineError(_ receipt: AnnexCommandReceipt, command: AnnexCommand, hostID: String) -> CompanionServiceError? {
        guard let machine = receipt.wrongMachine, machine != hostID.lowercased() else { return nil }
        let other = hosts[machine]
        let agentID = command.agentReference.map { AnnexAgentAddress(parsing: $0).agentID }
        let agent = agentID.flatMap { id in other?.allAgents.first { $0.id.agentID == id } }
        return .wrongMachine(.init(machine: machine, machineName: other?.name, agentName: agent?.name, target: agent?.id))
    }
    /// The off-state allowlist never authorizes a start, a wake, settings changes or enable=true.
    private func validateDispatcherCommand(_ kind: AnnexCommand.Kind, hostID: String) throws {
        guard let off = dispatcherMCPOff[hostID] else { return }
        let agentID: String?
        let allowed: Bool
        switch kind {
        case .send(let id, _, _, _, _): agentID = id; allowed = off.allows("chat.send")
        case .interrupt(let id, _): agentID = id; allowed = off.allows("chat.interrupt")
        case .stop(let id, _): agentID = id; allowed = off.allows("agent.stop")
        case .permission(let id, _, _, _, _): agentID = id; allowed = off.allows("chat.permission")
        case .question(let id, _, _, _): agentID = id; allowed = off.allows("chat.question")
        case .removeQueued(let id, _, _): agentID = id; allowed = off.allows("chat.queue.remove")
        case .start(let id, _, _, _, _), .setModel(let id, _, _, _), .setLevel(let id, _, _),
             .providerPreview(let id, _), .providerChange(let id, _, _): agentID = id; allowed = false
        case .update(let update): agentID = update.agentID; allowed = false
        case .setDispatcherEnabled(let enabled):
            guard !enabled && off.commands.contains("dispatcher.setEnabled") else { throw CompanionServiceError.rejected(off.note) }
            return
        default: return
        }
        let dispatcherID = dispatcherCatalog[hostID]?["agent"]?["id"]?.string
        if agentID == dispatcherID && !allowed { throw CompanionServiceError.rejected(off.note) }
    }

    /// What a receipt means for the user: nil when the command was dispatched. Image refusals keep their own recovery.
    nonisolated static func receiptError(_ receipt: AnnexCommandReceipt, attachmentCount: Int = 0) -> Error? {
        switch receipt.status {
        case .completed: return nil
        case .rejected:
            switch receipt.error?.code {
            case "incomplete_representation": return CompanionServiceError.incompleteRepresentation(rejectionMessage(receipt.error))
            case "attachment_unavailable": return CompanionAttachmentError.attachmentUnavailable
            case "images_not_supported": return CompanionAttachmentError.imagesNotSupported
            case "not_chat" where attachmentCount > 0: return CompanionServiceError.rejected(notChatMessage)
            default: return CompanionServiceError.rejected(rejectionMessage(receipt.error))
            }
        case .failed: return CompanionServiceError.uncertain(failureMessage(receipt.error))
        }
    }
    /// Refusals branch on the code. The desktop's message is a sentence only for some codes; otherwise it is the code itself.
    nonisolated static func rejectionMessage(_ failure: AnnexCommandReceipt.Failure?) -> String {
        guard let failure else { return "The desktop rejected this command." }
        if failure.code == "too_large" { return "The desktop rejected this command because it is too large." }
        return CompanionAgentCommandError.message(code: failure.code, message: failure.message)
            ?? (failure.message.isEmpty || failure.message == failure.code ? "The desktop rejected this command (\(failure.code))." : failure.message)
    }
    /// A failed command may have had partial effects; the desktop's sentence says what happened when it sends one.
    nonisolated static func failureMessage(_ failure: AnnexCommandReceipt.Failure?) -> String {
        let fallback = "The command may have partially run. Refresh to check its result."
        guard let failure else { return fallback }
        if !failure.message.isEmpty, failure.message != failure.code { return failure.message }
        return CompanionAgentCommandError.message(code: failure.code, message: nil) ?? fallback
    }
    private func session(for target: CompanionTarget) throws -> String {
        guard let session = projections[target]?.sessionID else { throw CompanionServiceError.unavailable("Refresh the conversation before sending a command.") }
        return session
    }
    private func transport(for hostID: String) throws -> any AnnexTransporting {
        guard let transport = transports[hostID] else { throw CompanionServiceError.unavailable("This desktop is not paired.") }
        return transport
    }
    private var sortedHosts: [CompanionHost] { hosts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func emit(_ event: CompanionEvent) { for continuation in subscribers.values { continuation.yield(event) } }
    private func emitHosts() { emit(.hosts(sortedHosts)) }

    private func receive(_ event: AnnexTransportEvent, hostID: String) async {
        switch event {
        case .connection(let state):
            if state != .connected { streamDiagnostics.disconnect(hostID: hostID); clearFullReviews(hostID: hostID) }
            switch state {
            case .connected:
                // Every socket snapshot emits connected, including broadcasts on the same socket.
                // A reconnect's preceding resync may already be reading (or have read) the catalog.
                // Neither needs another full pass; catalog-change events still enqueue follow-ups.
                if hosts[hostID]?.connection == .connected ||
                    (hosts[hostID]?.connection == .synchronizing && refreshTasks[hostID] != nil) { break }
                hosts[hostID]?.connection = .synchronizing; emitHosts()
                needsCatchUp.insert(hostID)
                scheduleRefresh(hostID: hostID)
            case .connecting:
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .connecting
            case .disconnected, .suspended:
                cancelRefresh(hostID: hostID)
                resolvedGrantRequests[hostID] = nil
                hosts[hostID]?.connection = .offline
                emit(.resyncRequired(hostID: hostID))
            case .reconnecting:
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .reconnecting
            case .failed(let error):
                if case .rejected(status: 401, code: "peer_not_paired", message: _) = error {
                    await onNetworkRefusal?(hostID)
                    guard hosts[hostID] != nil else { return }
                }
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .failed(Self.readableError(error))
            case .retrying(_, _, let error):
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .failed(Self.readableError(error) + (error == .responseTooLarge ? " We'll try again shortly." : ""))
            }
            emitHosts()
            switch state {
            case .reconnecting, .failed: if !isSuspended { onUnreachable?(hostID) }
            default: break
            }
        case .resyncRequired:
            clearFullReviews(hostID: hostID)
            // The next snapshot is whole; events missed since may have reopened a request.
            resolvedGrantRequests[hostID] = nil
            hosts[hostID]?.connection = .synchronizing
            emit(.resyncRequired(hostID: hostID)); emitHosts()
            needsCatchUp.insert(hostID)
            scheduleRefresh(hostID: hostID)
            // Store keeps active conversations blocked until its history is refreshed.
        case .message(let envelope):
            guard let payload = envelope.payload else { return }
            switch envelope.type {
            case "network:changed":
                if let snapshot = try? payload.decode(AnnexNetworkSnapshot.self) {
                    await onNetwork?(hostID, snapshot)
                }
            case "snapshot":
                if let quick = payload["quickAgents"] { quickCatalog[hostID] = quick }
                let dispatcherBefore = dispatcherCatalog[hostID]
                if let dispatcher = payload["dispatcher"] { rememberDispatcher(dispatcher, hostID: hostID) }
                // A change to its name, look, CLI or model, or its chat waking or sleeping, changes its settings and confirmations.
                let dispatcherChanged = dispatcherCatalog[hostID] != dispatcherBefore
                if payload["ptyHost"]?["platform"]?.string == "win32" { windowsHosts.insert(hostID) } else { windowsHosts.remove(hostID) }
                let generation = eventGenerations[hostID]
                let usesRefs = envelope.iconReferencesEnabled ?? ((capabilities[hostID]?.iconRefs?.version ?? 0) >= 1 || payload["iconRefs"] != nil)
                let icons: CompanionIconCatalog
                if usesRefs {
                    var current = iconCatalog[hostID] ?? .init()
                    current.applyReferences(payload["iconRefs"], host: hostID)
                    await iconStore.setReferences(current.references, for: hostID)
                    icons = current
                } else {
                    await iconStore.setReferences([], for: hostID)
                    icons = await CompanionIconCatalog.inline(projects: payload["projectIcons"], agents: payload["agentIcons"], host: hostID, store: iconStore)
                }
                guard eventGenerations[hostID] == generation, hosts[hostID] != nil else { return }
                iconCatalog[hostID] = icons
                applyCatalog(payload, hostID: hostID)
                // Only the WebSocket snapshot lists helper requests; a REST refresh keeps the last list.
                if let requests = payload["helperRequests"] { hosts[hostID]?.helperRequests = Self.helperRequests(from: requests, hostID: hostID).filter { !consumedHelperRequests.contains($0.slot) } }
                // Shown only once capabilities say the desktop takes answers (`canAnswerGrantRequests`).
                if let requests = payload[capabilities[hostID]?.grantRequests?.snapshotField ?? "grantRequests"] {
                    let resolved = resolvedGrantRequests[hostID] ?? []
                    hosts[hostID]?.grantRequests = Self.grantRequests(from: requests, hostID: hostID).filter { !resolved.contains($0.id) }
                }
                hosts[hostID]?.helperRoutingRevision = payload["helperRoutingRevision"]?.string
                // Sent only after the desktop's one-time migration; without it the phone keeps its own pins.
                hosts[hostID]?.projectState = CompanionProjectState.map(from: payload["projectState"])
                // Also sent only after the desktop's one-time migration; without it the phone keeps its own finished list.
                hosts[hostID]?.finishedQuickAgents = CompanionFinishedRun.desktopLists(payload["finishedQuickAgents"], hostID: hostID)
                hosts[hostID]?.idleDays = Self.idleDays(from: payload["idleDays"])
                if let theme = Self.theme(from: payload["theme"], terminal: payload["terminalColors"]) { hosts[hostID]?.theme = theme }
                emitHosts()
                await refreshHelperRoutingLabels(hostID: hostID)
                if dispatcherChanged { await refreshDispatcherSettings(hostID: hostID) }
            case "helper_routing:changed":
                if let revision = payload["revision"]?.string {
                    hosts[hostID]?.helperRoutingRevision = revision
                    emitHosts()
                    await refreshHelperRoutingLabels(hostID: hostID)
                }
            // Each is followed by a snapshot with the rows, so the list itself always comes from the snapshot.
            case "grant_request:opened":
                // The same id again: a lasting Allow that couldn't be saved. Its row comes back with the next snapshot.
                if let id = payload["requestId"]?.string { resolvedGrantRequests[hostID]?.remove(id) }
            case "grant_request:resolved":
                // Answered anywhere, expired or withdrawn. Ids never seen are fine.
                dropGrantRequests(payload["requestIds"].arrayValue.compactMap(\.string), hostID: hostID)
            case "theme:changed":
                // The payload is the color set itself, with terminal colors alongside.
                if let theme = Self.theme(from: payload, terminal: payload["terminalColors"]) { hosts[hostID]?.theme = theme; emitHosts() }
            case "chat:event":
                guard let agentID = payload["agentId"]?.string, let event = payload["event"], let target = target(agentID: agentID, hostID: hostID) else { return }
                if envelope.replayed != true {
                    let context = envelope.tc?.string.flatMap { AnnexTraceContext(traceparent: $0) }
                    streamDiagnostics.receive(event, target: target, context: context, binding: envelope.diagnosticBinding)
                }
                if buffers[target] != nil { buffers[target]?.append(event) }
                else { project(event, target: target) }
            case "agent:spawned":
                rememberQuick(payload, hostID: hostID)
                scheduleRefresh(hostID: hostID)
            case "agent:status", "agent:completed":
                if envelope.type == "agent:completed" { rememberExit(payload, hostID: hostID) }
                rememberDispatcherStatus(payload, hostID: hostID)
                if let agentID = payload["id"]?.string, let target = target(agentID: agentID, hostID: hostID) {
                    let status = CompanionChatProjector.status(payload["status"]?.string, detailed: payload["detailedStatus"])
                    // Desktop lifecycle status is coarser than the chat stream.
                    // Keep an outstanding question/approval visible until its
                    // authoritative chat event resolves it or the agent stops.
                    let pendingInteraction = projections[target]?.status == .waiting || projections[target]?.status == .approval
                    if status == .sleeping {
                        // The agent's process exited. Its chat's own end (stopped, failed) says more, when it came first.
                        if projections[target]?.isAwake == true { projections[target]?.endSession(.sleeping) }
                        // session_ended clears live capabilities. Recheck the desktop's canStart permission so an
                        // already-open durable chat can offer Wake again without being closed and reopened.
                        if projections[target] != nil, !readOnly.contains(target) {
                            Task { [weak self] in await self?.refreshWakePermission(for: target) }
                        }
                    } else if !pendingInteraction || (status != .working && status != .idle) {
                        projections[target]?.status = status
                    }
                }
                scheduleRefresh(hostID: hostID)
            case "agent:deleted": scheduleRefresh(hostID: hostID)
            case "dispatcher:changed":
                applyDispatcherChange(enabled: payload["enabled"].boolValue == true, flagOn: payload["flagOn"].boolValue == true,
                                      agentID: payload["agentId"]?.string, agent: payload["agent"], mcpOff: CompanionDispatcherMCPOff(json: payload), hostID: hostID)
                scheduleRefresh(hostID: hostID)
                await refreshDispatcherSettings(hostID: hostID, force: true)
            default: break
            }
        }
    }

    private func refresh(hostID: String) async {
        guard let transport = transports[hostID], let generation = eventGenerations[hostID], !isSuspended else { return }
        do {
            let rawCaps = try? await transport.read(.capabilities)
            let newCapabilities = rawCaps == nil ? capabilities[hostID]
                : (rawCaps?["controlAvailable"]).boolValue == true ? try rawCaps?.decode(AnnexCapabilities.self) : nil
            if newCapabilities?.supportsNetwork == true,
               let raw = try? await transport.read(.network), let snapshot = try? raw.decode(AnnexNetworkSnapshot.self) {
                await onNetwork?(hostID, snapshot)
                guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
            }
            let rawProjects = try await transport.read(.projects)
            let projects = rawProjects["projects"] ?? rawProjects
            var agents: [String: AnnexJSON] = [:]
            for project in Optional(projects).arrayValue {
                guard let projectID = project["id"]?.string, !projectID.isEmpty else { continue }
                let result = try await transport.read(.agents(projectID: projectID))
                agents[projectID] = result["agents"] ?? result
            }
            guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
            if rawCaps != nil {
                knownCapabilities.insert(hostID)
                if capabilities[hostID]?.epoch != newCapabilities?.epoch { clearFullReviews(hostID: hostID) }
                capabilities[hostID] = newCapabilities
                hosts[hostID]?.richContentAvailable = rawCaps?["richContent"]?["enabled"].boolValue == true
                hosts[hostID]?.canResolveLinks = newCapabilities?.supportsChatLinks == true
                hosts[hostID]?.canSpawn = newCapabilities?.commands.contains("agent.spawn") == true
                hosts[hostID]?.canCreateDurable = newCapabilities?.supportsAgentCreate == true
                hosts[hostID]?.canEditSettings = newCapabilities?.supportsAgentSettings == true
                hosts[hostID]?.canStopAgents = newCapabilities?.commands.contains("agent.stop") == true
                hosts[hostID]?.canControlProvider = newCapabilities?.supportsProviderControl == true
                hosts[hostID]?.canAnswerHelperRequests = newCapabilities?.supportsHelperRequests == true
                hosts[hostID]?.canAnswerGrantRequests = newCapabilities?.supportsGrantRequests == true
                hosts[hostID]?.canSyncProjectState = newCapabilities?.supportsProjectState == true
                hosts[hostID]?.canSyncFinishedQuick = newCapabilities?.supportsFinishedQuickAgents == true
                hosts[hostID]?.attachments = newCapabilities.flatMap(Self.attachmentLimits)
                hosts[hostID]?.canRevokeSession = rawCaps?["pairing"]?["sessionRevokePath"]?.string == "/api/v1/mobile/pairing"
                hosts[hostID]?.canAnswerPersistentApprovals = newCapabilities?.supportsPersistentApprovals == true
                hosts[hostID]?.canSetFreeAgentMode = newCapabilities?.supportsFreeAgentMode == true
                hosts[hostID]?.canSetContextWindow = newCapabilities?.supportsContextWindow == true
                hosts[hostID]?.helperRouting = newCapabilities?.supportsHelperRouting == true ? newCapabilities?.helperRouting : nil
                hosts[hostID]?.canEditHelperPresets = newCapabilities?.supportsHelperRoutingUpdate == true
                if newCapabilities?.supportsHelperRouting != true {
                    hosts[hostID]?.helperRoutingLabels = [:]
                    hosts[hostID]?.helperRoutingRevision = nil
                    helperLabelsCache[hostID] = nil
                }
                hosts[hostID]?.canOrchestrate = newCapabilities?.supportsOrchestration == true
                hosts[hostID]?.canEditDispatcherSettings = newCapabilities?.supportsDispatcherSettings == true
                if newCapabilities?.supportsDispatcherSettings != true { hosts[hostID]?.dispatcherSettings = nil }
                hosts[hostID]?.terminal = Self.terminalSupport(newCapabilities)
                if let dispatcher = newCapabilities?.dispatcher, newCapabilities?.supportsDispatcher == true {
                    dispatcherFlags[hostID] = (dispatcher.enabled, dispatcher.flagOn)
                    let off = !dispatcher.enabled || !dispatcher.flagOn ? CompanionDispatcherMCPOff(json: rawCaps?["dispatcher"]) : nil
                    // New capabilities carry the record too, including on a cold reconnect before any snapshot.
                    if off != nil, let value = rawCaps?["dispatcher"], value["agent"]?["id"]?.string?.isEmpty == false {
                        dispatcherCatalog[hostID] = value
                    }
                    rememberMCPOff(off, hostID: hostID)
                    if (!dispatcher.enabled || !dispatcher.flagOn) && dispatcherMCPOff[hostID] == nil { dropDispatcher(hostID: hostID) }
                } else {
                    dispatcherFlags[hostID] = nil
                    dispatcherMCPOff[hostID] = nil
                    dropDispatcher(hostID: hostID)
                }
                if let routes = try? rawCaps?["routes"]?.decode(AnnexCapabilities.Routes.self) { onRoutes?(hostID, routes) }
            }
            applyCatalog(.object(["projects": projects, "agents": .object(agents), "quickAgents": quickCatalog[hostID] ?? .object([:])]), hostID: hostID)
            if needsCatchUp.contains(hostID) {
                // A failed catch-up keeps the catalog's statuses and runs again on the next refresh.
                let caughtUp = (try? await catchUp(hostID: hostID, transport: transport, bulk: newCapabilities?.supportsAgentState == true)) != nil
                guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
                if caughtUp { needsCatchUp.remove(hostID) }
            }
            hosts[hostID]?.connection = .connected
            await refreshHelperRoutingLabels(hostID: hostID)
        } catch {
            guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
            hosts[hostID]?.connection = .failed(Self.readableError(error))
        }
        emitHosts()
    }

    /// One agent's live state, from the desktop's bulk `agentState` read or, on older desktops, a one-event chat page.
    struct LiveState: Equatable {
        var status: String?
        var sessionState: String?
        var pendingPermission = false
        var pendingQuestion = false
    }
    /// Concurrent chat pages on a desktop without the bulk read.
    static let catchUpConcurrency = 3

    /// After a reconnect, re-reads what each agent with a cached chat projection is doing now and reconciles,
    /// so one that slept, finished a turn or had its request answered while the phone was away stops showing
    /// the old state. Open conversations also reload their history, as before.
    private func catchUp(hostID: String, transport: any AnnexTransporting, bulk: Bool) async throws {
        let cached = projections.keys.filter { $0.hostID == hostID }
        guard !cached.isEmpty else { return }
        // A chat event that arrives during the read is newer than it; that projection keeps what the event said.
        let seen = Dictionary(uniqueKeysWithValues: cached.map { ($0, projections[$0].map { "\($0.sessionID ?? "")#\($0.lastSequence)" }) })
        var states: [String: LiveState] = [:]
        if bulk {
            for value in try await transport.read(.agentState)["agents"].arrayValue {
                guard let id = value["agentId"]?.string else { continue }
                states[id] = .init(status: value["status"]?.string, sessionState: value["sessionState"]?.string,
                                   pendingPermission: value["pendingPermission"].boolValue == true, pendingQuestion: value["pendingQuestion"].boolValue == true)
            }
        } else {
            // Only an agent still showing awake can be stale-awake; the catalog has already put the rest right.
            let awake = cached.filter { projections[$0]?.isAwake == true }.map(\.agentID)
            states = try await Self.chatStates(awake, transport: transport)
        }
        var changed = false
        for target in cached {
            guard let state = states[target.agentID], var projection = projections[target],
                  seen[target] == "\(projection.sessionID ?? "")#\(projection.lastSequence)" else { continue }
            let before = projection
            Self.reconcile(&projection, with: state)
            guard projection.status != before.status || projection.capabilities != before.capabilities else { continue }
            projections[target] = projection
            updateAgent(target, projection: projection)
            changed = true
        }
        if changed { emitHosts() }
    }

    private func refreshWakePermission(for target: CompanionTarget) async {
        guard !isSuspended, let generation = eventGenerations[target.hostID], let transport = transports[target.hostID],
              let agent = hosts[target.hostID]?.agent(for: target), !agent.isQuick,
              let previous = projections[target], !previous.isAwake else { return }
        guard let snapshot = try? await transport.read(.chatHistory(agentID: target.agentID, sessionID: nil, beforeSeq: nil, limit: 1)),
              snapshot["readOnly"].boolValue == true || snapshot["sessionId"] == .null,
              !isSuspended, eventGenerations[target.hostID] == generation,
              hosts[target.hostID]?.agent(for: target) != nil,
              var projection = projections[target], !projection.isAwake, projection.sessionID == previous.sessionID else { return }
        readOnly.insert(target)
        projection.capabilities = snapshot["canStart"].boolValue && capabilities[target.hostID]?.commands.contains("agent.start") == true
            ? [.chat, .wake] : []
        projections[target] = projection
        updateAgent(target, projection: projection)
        emitHosts()
    }

    /// Chat pages of one event each, a few at a time. A page that fails is skipped: that agent keeps the catalog's status.
    static func chatStates(_ agentIDs: [String], transport: any AnnexTransporting) async throws -> [String: LiveState] {
        try await withThrowingTaskGroup(of: (String, AnnexJSON?).self) { group in
            var pending = agentIDs[...], states: [String: LiveState] = [:]
            func next() {
                guard let id = pending.popFirst() else { return }
                group.addTask { (id, try? await transport.read(.chatHistory(agentID: id, sessionID: nil, beforeSeq: nil, limit: 1))) }
            }
            for _ in 0..<catchUpConcurrency { next() }
            while let (id, page) = try await group.next() {
                if let page {
                    let live = page["readOnly"].boolValue != true
                    states[id] = .init(status: live ? "running" : "sleeping", sessionState: live ? page["state"]?.string : nil,
                                       pendingPermission: live && !page["pendingPermissions"].arrayValue.isEmpty,
                                       pendingQuestion: live && !page["pendingQuestions"].arrayValue.isEmpty)
                }
                next()
            }
            return states
        }
    }

    /// The desktop's live state wins over the projection's last status. Without a live chat session the agent is
    /// asleep or finished (its chat's own stopped or failed end is kept); one running outside chat keeps its status.
    static func reconcile(_ projection: inout CompanionChatProjector, with state: LiveState) {
        guard let sessionState = state.sessionState else {
            let lifecycle = CompanionChatProjector.status(state.status)
            if projection.isAwake, [.sleeping, .completed, .failed, .stopped].contains(lifecycle) { projection.endSession(lifecycle) }
            return
        }
        // A session that started while the phone was away takes its status here; its own events reset the rest.
        let status: CompanionAgentStatus = state.pendingQuestion ? .waiting : state.pendingPermission ? .approval : CompanionChatProjector.status(sessionState)
        if status == .sleeping { projection.endSession(.sleeping); return }
        projection.status = status
        if status != .working { projection.turnStartedAt = nil }
    }

    private func rememberQuick(_ payload: AnnexJSON, hostID: String) {
        guard payload["kind"]?.string == "quick", let projectID = payload["projectId"]?.string, let agentID = payload["id"]?.string else { return }
        var projects: [String: AnnexJSON] = [:]
        if case .object(let existing) = quickCatalog[hostID] { projects = existing }
        var agents = projects[projectID].arrayValue
        agents.removeAll { $0["id"]?.string == agentID }
        agents.append(payload)
        projects[projectID] = .array(agents)
        quickCatalog[hostID] = .object(projects)
    }

    /// A quick agent's exit, kept on its catalog entry: the desktop drops the agent a minute later, and catalog
    /// refreshes between snapshots reuse these entries.
    private func rememberExit(_ payload: AnnexJSON, hostID: String) {
        guard payload["kind"]?.string == "quick", let agentID = payload["id"]?.string,
              case .object(var projects)? = quickCatalog[hostID] else { return }
        for (projectID, list) in projects {
            var agents = Optional(list).arrayValue
            guard let index = agents.firstIndex(where: { $0["id"]?.string == agentID }), case .object(var entry) = agents[index] else { continue }
            entry["status"] = payload["status"] ?? .string("completed")
            if let code = payload["exitCode"] { entry["exitCode"] = code }
            agents[index] = .object(entry)
            projects[projectID] = .array(agents)
        }
        quickCatalog[hostID] = .object(projects)
    }

    private func applyCatalog(_ payload: AnnexJSON, hostID: String) {
        guard var host = hosts[hostID] else { return }
        var projects: [CompanionProject] = []
        let previousProjects = Dictionary(host.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let projectIcons = iconCatalog[hostID]?.projects
        let agentIcons = iconCatalog[hostID]?.agents
        // Only a complete, well-formed catalog can establish absence. Snapshots may arrive before
        // all fields do; a missing map or project entry is unknown, whereas an explicit [] is empty.
        let complete: Bool
        if case .array(let values)? = payload["projects"], case .object? = payload["agents"] {
            complete = values.allSatisfy { project in
                guard let id = project["id"]?.string, !id.isEmpty,
                      case .array(let agents)? = payload["agents"]?[id] else { return false }
                return agents.allSatisfy { $0["id"]?.string?.isEmpty == false }
            }
        } else { complete = false }
        for project in payload["projects"].arrayValue {
            guard let projectID = project["id"]?.string, !projectID.isEmpty else { continue }
            let durableValues: [AnnexJSON] = (payload["agents"]?[projectID]).arrayValue
            let quickValues: [AnnexJSON] = (payload["quickAgents"]?[projectID] ?? quickCatalog[hostID]?[projectID]).arrayValue
            var agents: [CompanionAgent] = []
            for (index, value) in (durableValues + quickValues).enumerated() {
                guard let id = value["id"]?.string, !id.isEmpty else { continue }
                let isQuick = value["kind"]?.string.map { $0 == "quick" } ?? (index >= durableValues.count)
                agents.append(catalogAgent(value, target: .init(hostID: hostID, projectID: projectID, agentID: id), isQuick: isQuick,
                                           meta: payload["agentsMeta"]?[id], icon: agentIcons?[id]))
            }
            if !complete {
                let incoming = Set(agents.map(\.id))
                agents += previousProjects[projectID]?.agents.filter { !incoming.contains($0.id) } ?? []
            }
            projects.append(Self.project(project, id: projectID, agents: agents, icon: projectIcons?[projectID]))
        }
        if !complete {
            let incoming = Set(projects.map(\.id))
            projects += host.projects.filter { !incoming.contains($0.id) }
        }
        host.projects = projects
        if complete { host.hasLoadedCatalog = true }
        host.dispatcher = dispatcherState(hostID: hostID, icons: agentIcons, meta: payload["agentsMeta"])
        if case .object(let orchestrators)? = payload["orchestrators"] {
            host.providers = orchestrators.map { id, value in
                CompanionProvider(id: id, name: value["displayName"]?.string ?? value["shortName"]?.string ?? id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        hosts[hostID] = host
    }
    /// One catalog entry as an agent, with what its chat projection knows on top.
    private func catalogAgent(_ value: AnnexJSON, target: CompanionTarget, isQuick: Bool, meta: AnnexJSON?, icon: CompanionIconReference?) -> CompanionAgent {
        let id = target.agentID
        // A durable agent that slept while the phone was away: the desktop drops chat events from its
        // replay when the agent exits, and a reconnect resumes from the snapshot's seq anyway, so the
        // session's end never arrives. The catalog's "sleeping" is newer than the projection's last state.
        if value["kind"]?.string != "quick", value["status"]?.string == "sleeping", projections[target]?.isAwake == true {
            projections[target]?.endSession(.sleeping)
        }
        let projection = projections[target]
        let name: String = value["name"]?.string ?? id
        let mission: String? = value["mission"]?.string ?? value["prompt"]?.string
        let subtitle: String = mission ?? value["branch"]?.string ?? ""
        let detailed = value["detailedStatus"] ?? meta?["detailedStatus"]
        // Without a live chat session the chat snapshot can only say "sleeping". When the catalog says
        // the agent is running anyway (in a terminal or headless), the catalog is right.
        let runsOutsideChat = readOnly.contains(target) && value["status"]?.string == "running"
        let status: CompanionAgentStatus = (runsOutsideChat ? nil : projection?.status)
            ?? CompanionChatProjector.status(value["status"]?.string, detailed: detailed)
        let model: String? = projection?.model ?? value["model"]?.string
        let supported = availableCapabilities(projection?.capabilities ?? [], target: target)
        let activity = (value["lastActivityAt"] ?? value["spawnedAt"]).flatMap(Self.date(from:))
        var agent = CompanionAgent(id: target, name: name, subtitle: subtitle, status: status, model: model, capabilities: supported,
                                   executionMode: value["executionMode"]?.string ?? meta?["executionMode"]?.string, lastActivity: activity,
                                   isQuick: isQuick, hasExited: isQuick && Self.exitedStatuses.contains(value["status"]?.string ?? ""),
                                   exitCode: value["exitCode"]?.integer.map(Int.init),
                                   turnStartedAt: projection?.turnStartedAt, contextUsage: projection?.contextUsage)
        Self.applyIdentity(value, icon: icon, to: &agent)
        if !isQuick {
            switch value["status"]?.string {
            case "sleeping": agent.isSleepingOnDesktop = true
            case "running", "waking", "spawning", "starting", "stopping": agent.isSleepingOnDesktop = false
            default: agent.isSleepingOnDesktop = nil
            }
        }
        agent.detail = Self.detail(from: detailed)
        if case .bool(let has)? = value["hasSession"] { agent.hasSession = has }
        agent.branch = value["branch"]?.string
        agent.orchestrator = value["orchestrator"]?.string
        agent.routing = capabilities[target.hostID]?.supportsHelperRouting == true ? CompanionHelperRoutingDecision(json: value["routing"]) : nil
        if !isQuick { agent.parentAgentID = value["parentAgentId"]?.string }
        agent.session = projection.map(\.session)
        agent.chatControls = projection.flatMap { chatControls($0, target: target) }
        agent.slashCommands = projection.flatMap { slashCommands($0, target: target) }
        return agent
    }
    /// Each snapshot replaces the content hints. Missing or malformed any-path is false, including in archives.
    nonisolated static func contentRoots(from snapshot: AnnexJSON, windows: Bool) -> CompanionContentRoots {
        .init(paths: snapshot["contentRoots"].arrayValue.prefix(16).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } },
              windows: windows, anyPath: snapshot["contentAnyPath"].boolValue)
    }
    /// A project's name and identity. The desktop's `displayName` overrides its `name`.
    nonisolated static func project(_ value: AnnexJSON, id: String, agents: [CompanionAgent], icon: CompanionIconReference?) -> CompanionProject {
        CompanionProject(id: id, name: value["displayName"]?.string ?? value["name"]?.string ?? id, agents: agents,
                         color: value["color"]?.string, emoji: value["emoji"]?.string,
                         icon: icon)
    }
    /// An agent's identity, Free Agent Mode and orchestration policy from its catalog entry.
    nonisolated static func applyIdentity(_ value: AnnexJSON, icon: CompanionIconReference?, to agent: inout CompanionAgent) {
        agent.color = value["color"]?.string
        agent.emoji = value["emoji"]?.string
        agent.icon = icon
        agent.freeAgentMode = value["freeAgentMode"].boolValue == true
        agent.orchestration = CompanionOrchestration(json: value["orchestration"])
    }
    /// The desktop's `detailedStatus`, or nil when it sends none.
    nonisolated static func detail(from value: AnnexJSON?) -> CompanionAgentDetail? {
        guard let value, case .object = value else { return nil }
        return .init(state: value["state"]?.string, message: value["message"]?.string, toolName: value["toolName"]?.string,
                     since: value["timestamp"].flatMap(date(from:)))
    }
    /// A tracked quick agent's status once its process has exited (`trackedQuickAgents` in `annex-server.ts`).
    nonisolated static let exitedStatuses: Set<String> = ["completed", "failed", "cancelled"]
    /// Desktop timestamps are milliseconds since 1970, or ISO 8601 strings. Zero means unknown.
    nonisolated static func date(from value: AnnexJSON) -> Date? {
        switch value {
        case .integer(let ms) where ms > 0: Date(timeIntervalSince1970: Double(ms) / 1000)
        case .number(let ms) where ms > 0: Date(timeIntervalSince1970: ms / 1000)
        case .string(let text): try? Date(text, strategy: .iso8601)
        default: nil
        }
    }
    private func target(agentID: String, hostID: String) -> CompanionTarget? {
        hosts[hostID]?.allAgents.first { $0.id.agentID == agentID }?.id
    }
    private func project(_ event: AnnexJSON, target: CompanionTarget) {
        let oldSession = projections[target]?.sessionID
        let oldSequence = projections[target]?.lastSequence ?? 0
        projections[target, default: .init()].queueStateEventsSupported = capabilities[target.hostID]?.supportsQueueState == true
        AnnexTelemetry.shared.measurePerformance(.projectorApply, messageCount: projections[target]?.items.count ?? 0) {
            projections[target, default: .init()].apply(event)
        }
        guard let projection = projections[target], projection.sessionID != oldSession || projection.lastSequence > oldSequence else { return }
        // A live session started after a read-only snapshot, as when history loads before a new agent's chat is up.
        // Its start (with the capabilities) may have arrived before the agent was listed, so re-read the snapshot.
        if let session = projection.sessionID, session != oldSession, readOnly.remove(target) != nil {
            Task { _ = try? await history(for: target) }
        }
        let changed = updateAgent(target, projection: projection)
        emit(projection.liveUpdate(for: event, target: target, previousSessionID: oldSession))
        if changed { emitHosts() }
    }
    @discardableResult private func updateAgent(_ target: CompanionTarget, projection: CompanionChatProjector) -> Bool {
        guard var agent = hosts[target.hostID]?.agent(for: target) else { return false }
        let previous = agent
        // An agent running outside chat (it has an execution mode but no live chat) keeps its catalog status.
        let runsOutsideChat = readOnly.contains(target) && agent.executionMode != nil
        if !runsOutsideChat { agent.status = projection.status }
        if let off = mcpOff(for: target), !off.running { agent.status = CompanionChatProjector.status(off.status ?? "sleeping") }
        agent.capabilities = availableCapabilities(projection.capabilities, target: target)
        if let model = projection.model { agent.model = model }
        agent.turnStartedAt = projection.turnStartedAt
        agent.contextUsage = projection.contextUsage
        agent.session = projection.session
        agent.chatControls = chatControls(projection, target: target)
        agent.slashCommands = slashCommands(projection, target: target)
        guard agent != previous else { return false }
        if hosts[target.hostID]?.dispatcher?.agent?.id == target { hosts[target.hostID]?.dispatcher?.agent = agent; return true }
        guard let projectIndex = hosts[target.hostID]?.projects.firstIndex(where: { $0.id == target.projectID }),
              let agentIndex = hosts[target.hostID]?.projects[projectIndex].agents.firstIndex(where: { $0.id == target }) else { return false }
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex] = agent
        return true
    }

    // MARK: Dispatcher (`dispatcher` v1)

    func sleepDispatcher(_ target: CompanionTarget, clientCommandID: String) async throws {
        guard mcpOff(for: target)?.allows("agent.stop") == true else { throw CompanionServiceError.rejected("Sleep is not available for this session.") }
        try await sleepAgent(target, clientCommandID: clientCommandID)
    }

    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws {
        if let off = mcpOff(for: target) {
            guard off.allows("agent.stop") else { throw CompanionServiceError.rejected(off.note) }
        } else {
            guard capabilities[target.hostID]?.commands.contains("agent.stop") == true,
                  let agent = hosts[target.hostID]?.agent(for: target), !agent.isQuick,
                  agent.isSleepingOnDesktop == false else {
                throw CompanionServiceError.rejected("Refresh the agent's status before putting it to sleep.")
            }
        }
        _ = try await execute(.stop(agentID: target.agentID), id: clientCommandID, hostID: target.hostID)
    }

    func refreshSleepState(_ target: CompanionTarget) async throws {
        await refresh(hostID: target.hostID)
        guard hosts[target.hostID]?.connection.canOperate == true else {
            throw CompanionServiceError.unavailable("Reconnect to the desktop to confirm whether the agent is asleep.")
        }
    }

    private func requireProviderControl(_ target: CompanionTarget) throws {
        guard capabilities[target.hostID]?.supportsProviderControl == true, mcpOff(for: target) == nil,
              hosts[target.hostID]?.agent(for: target)?.isQuick == false else {
            throw CompanionServiceError.unavailable("This desktop does not offer the guided provider flow for this agent.")
        }
    }
    private func providerResult(_ kind: AnnexCommand.Kind, target: CompanionTarget, id: String) async throws -> AnnexJSON {
        try requireProviderControl(target)
        try validateDispatcherCommand(kind, hostID: target.hostID)
        guard let caps = capabilities[target.hostID] else { throw CompanionServiceError.unavailable("Reconnect to the desktop.") }
        let key = CompanionCommandKey(hostID: target.hostID, commandID: id)
        if let previous = savedCommands[key], Date().timeIntervalSince(previous.createdAt) * 1000 >= Double(caps.idempotency.ttlMs) {
            throw CompanionServiceError.uncertain("The desktop's retry window expired. The previous action's outcome is still unknown. Check the agent on the desktop before another action.")
        }
        let command = savedCommands[key] ?? AnnexCommand(commandID: id, epoch: caps.epoch, kind: kind)
        guard command.epoch == caps.epoch else { throw CompanionServiceError.uncertain("The desktop restarted. The previous action's outcome is still unknown. Check the agent on the desktop before another action.") }
        savedCommands[key] = command
        let receipt: AnnexCommandReceipt
        do { receipt = try await transport(for: target.hostID).execute(command) }
        catch AnnexTransportError.rejected(let status, let code, _) {
            if status == 409 { throw CompanionServiceError.rejected(CompanionProviderReason.message(code)) }
            // A transport/auth rejection cannot resolve a previously lost command's outcome.
            throw CompanionServiceError.unavailable("The desktop refused access to this provider action. Check the connection and desktop permissions.")
        }
        catch let error as CompanionServiceError { throw error }
        catch { throw CompanionServiceError.uncertain("The reply was lost. Check the previous result before another provider action.") }
        if let error = wrongMachineError(receipt, command: command, hostID: target.hostID) { throw error }
        switch receipt.status {
        case .rejected: throw CompanionServiceError.rejected(CompanionProviderReason.message(receipt.error?.code))
        case .failed: throw CompanionServiceError.uncertain(CompanionProviderReason.message(receipt.error?.code))
        case .completed:
            guard let result = receipt.result else { throw CompanionServiceError.uncertain("The desktop's result could not be verified. Check the previous result before another action.") }
            return result
        }
    }
    private func decodeProvider<T: Decodable>(_ type: T.Type, result: AnnexJSON) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(result)) }
        catch { throw CompanionServiceError.uncertain("The desktop's provider result could not be verified. Check the previous result before another action.") }
    }
    func providerPreview(_ target: CompanionTarget, provider: String) async throws -> AnnexProviderPreview {
        let result = try await providerResult(.providerPreview(agentID: target.agentID, provider: provider), target: target, id: UUID().uuidString)
        let preview = try decodeProvider(AnnexProviderPreview.self, result: result)
        guard preview.outcome.agentId == target.agentID, preview.outcome.provider == provider else {
            throw CompanionServiceError.unavailable("The desktop returned a preview for a different agent or provider. Refresh before saving.")
        }
        return preview
    }
    func changeProvider(_ target: CompanionTarget, preview: AnnexProviderPreview, clientCommandID: String) async throws -> AnnexProviderChangeResult {
        guard preview.outcome.agentId == target.agentID, preview.outcome.permitsSave else {
            throw CompanionServiceError.unavailable("Refresh the provider preview before saving.")
        }
        let result = try await providerResult(.providerChange(agentID: target.agentID, provider: preview.outcome.provider, expectedState: preview.expectedState), target: target, id: clientCommandID)
        let saved = try decodeProvider(AnnexProviderChangeResult.self, result: result)
        let outcome: AnnexProviderOutcome
        switch saved { case .changed(let value): outcome = value; case .alreadySelected(let value): outcome = value.outcome }
        guard outcome.agentId == target.agentID, outcome.provider == preview.outcome.provider, outcome.savedProvider == preview.outcome.provider,
              outcome.state == .sleeping, outcome.activeProvider == nil else {
            throw CompanionServiceError.uncertain("The saved provider could not be verified. Check the previous result before another action.")
        }
        await refresh(hostID: target.hostID)
        return saved
    }
    func startNewProvider(_ target: CompanionTarget, provider: String, clientCommandID: String) async throws {
        _ = try await providerResult(.start(agentID: target.agentID, resume: false, expectedProvider: provider), target: target, id: clientCommandID)
        await refresh(hostID: target.hostID)
    }
    func sleepAndWait(_ target: CompanionTarget, clientCommandID: String) async throws {
        let result = try await providerResult(.stop(agentID: target.agentID, waitForStopped: true), target: target, id: clientCommandID)
        let stopped = try decodeProvider(AnnexStoppedAcknowledgment.self, result: result)
        guard stopped.agentId == target.agentID, stopped.confirmsSleep else {
            throw CompanionServiceError.uncertain("Sleep was requested, but process exit and saved history are not confirmed yet.")
        }
    }

    func setDispatcher(enabled: Bool, hostID: String, clientCommandID: String) async throws {
        guard capabilities[hostID]?.supportsDispatcherToggle == true else {
            throw CompanionServiceError.unavailable("Update Clubhouse on your desktop to turn the Dispatcher on from your phone.")
        }
        let receipt = try await execute(.setDispatcherEnabled(enabled), id: clientCommandID, hostID: hostID)
        // The receipt says where it ended up; `dispatcher:changed` and a snapshot with its agent follow.
        let result = receipt.result
        applyDispatcherChange(enabled: result?["enabled"]?.boolOrNil ?? enabled, flagOn: result?["flagOn"]?.boolOrNil ?? dispatcherFlags[hostID]?.flagOn ?? true,
                              agentID: result?["agentId"]?.string, mcpOff: CompanionDispatcherMCPOff(json: result), hostID: hostID)
    }
    // MARK: Settings > Dispatcher

    func dispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings {
        guard capabilities[hostID]?.supportsDispatcherSettings == true else {
            throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
        }
        let generation = eventGenerations[hostID]
        do {
            let settings = try CompanionDispatcherSettings(json: try await transport(for: hostID).read(.dispatcherSettings))
            try Task.checkCancellation()
            guard eventGenerations[hostID] == generation else { throw CancellationError() }
            rememberDispatcherSettings(settings, hostID: hostID)
            return settings
        } catch AnnexTransportError.rejected(404, "dispatcher_off"?, _) {
            rememberDispatcherSettings(nil, hostID: hostID)
            throw CompanionServiceError.unavailable("The Dispatcher is turned off on the desktop. Turn it on first.")
        }
        catch let error as CompanionServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CompanionServiceError.unavailable(Self.agentReadError(error, subject: "Dispatcher settings")) }
    }
    /// `dispatcher.update` and `dispatcher.setModels` answer with the fresh settings; nothing is read again.
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        try await dispatcherSettingsCommand(.updateDispatcher(update), hostID: hostID, clientCommandID: clientCommandID)
    }
    func setDispatcherModels(_ models: AnnexDispatcherModels, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        try await dispatcherSettingsCommand(.setDispatcherModels(models), hostID: hostID, clientCommandID: clientCommandID)
    }
    private func dispatcherSettingsCommand(_ kind: AnnexCommand.Kind, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        guard capabilities[hostID]?.supportsDispatcherSettings == true else {
            throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
        }
        let receipt = try await execute(kind, id: clientCommandID, hostID: hostID)
        guard let settings = try? CompanionDispatcherSettings(json: receipt.result ?? .null) else {
            throw CompanionServiceError.uncertain("The desktop saved this but its settings couldn't be read. Open the settings again to check.")
        }
        rememberDispatcherSettings(settings, hostID: hostID)
        return settings
    }
    /// One confirmed reset, sent once with the confirmation the person was shown. A stale confirmation does nothing on
    /// the desktop: the settings are read again and returned in `.stale`, so the person can be asked again. Never retried here.
    func resetDispatcher(_ prompt: CompanionDispatcherResetPrompt, clientCommandID: String) async throws -> CompanionDispatcherResetOutcome {
        let hostID = prompt.hostID
        guard capabilities[hostID]?.supportsDispatcherSettings == true else {
            throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop)
        }
        let kind: AnnexCommand.Kind = prompt.reset == .clearChat ? .clearDispatcherChat(expectedState: prompt.expectedState)
            : .forgetDispatcherEverything(expectedState: prompt.expectedState)
        let receipt = try await execute(kind, id: clientCommandID, hostID: hostID, validateReceipt: false)
        if receipt.status == .rejected, receipt.error?.code == "stale_state" {
            throw CompanionDispatcherSettingsError.stale(try await dispatcherSettings(hostID: hostID))
        }
        if let error = Self.receiptError(receipt) { throw error }
        guard let outcome = CompanionDispatcherResetOutcome(prompt.reset, result: receipt.result) else {
            throw CompanionServiceError.uncertain("The desktop's result couldn't be read. Open the Dispatcher's settings to check.")
        }
        // Its confirmations are spent; the next ones come from a fresh read.
        _ = try? await dispatcherSettings(hostID: hostID)
        return outcome
    }
    private func rememberDispatcherSettings(_ settings: CompanionDispatcherSettings?, hostID: String) {
        guard hosts[hostID] != nil, hosts[hostID]?.dispatcherSettings != settings else { return }
        hosts[hostID]?.dispatcherSettings = settings
        emitHosts()
    }
    /// Keeps read settings current. `force` reads them even if nothing has asked yet, as after `dispatcher:changed`.
    private func refreshDispatcherSettings(hostID: String, force: Bool = false) async {
        guard capabilities[hostID]?.supportsDispatcherSettings == true else { return }
        guard hosts[hostID]?.dispatcher?.enabled == true else { rememberDispatcherSettings(nil, hostID: hostID); return }
        guard force || hosts[hostID]?.dispatcherSettings != nil else { return }
        _ = try? await dispatcherSettings(hostID: hostID)
    }
    /// The Dispatcher as the desktop last described it: its flags from capabilities and `dispatcher:changed`, its agent
    /// from the snapshot. Nil on desktops without `dispatcher` v1, which leaves everything as before.
    private func dispatcherState(hostID: String, icons: [String: CompanionIconReference]?, meta: AnnexJSON?) -> CompanionDispatcher? {
        let caps = capabilities[hostID]
        if knownCapabilities.contains(hostID), caps?.supportsDispatcher != true { return nil }
        let base = caps?.dispatcher
        let value = dispatcherCatalog[hostID]
        guard base != nil || value != nil else { return hosts[hostID]?.dispatcher }
        let flags = dispatcherFlags[hostID] ?? (base?.enabled ?? false, base?.flagOn ?? false)
        var state = CompanionDispatcher(enabled: flags.enabled && flags.flagOn, flagOn: flags.flagOn, newLayout: base?.newLayout ?? true,
                                        projectID: value?["projectId"]?.string ?? value?["agent"]?["projectId"]?.string ?? base?.projectID ?? CompanionDispatcher.defaultProjectID,
                                        canToggle: caps?.supportsDispatcherToggle == true, mcpOff: dispatcherMCPOff[hostID])
        if state.isVisible, let entry = value?["agent"], let id = entry["id"]?.string, !id.isEmpty {
            var agent = catalogAgent(entry, target: .init(hostID: hostID, projectID: state.projectID, agentID: id), isQuick: false,
                                     meta: meta?[id], icon: icons?[id])
            agent.isDispatcher = true
            if entry["name"]?.string?.isEmpty != false { agent.name = CompanionDispatcher.name }
            // Its orchestration is the desktop's, and locked.
            agent.orchestration = nil
            if let off = state.mcpOff {
                if !off.running { agent.status = CompanionChatProjector.status(off.status ?? "sleeping") }
                if !off.running, let detail = off.detail { agent.detail = .init(message: detail) }
                agent.capabilities = availableCapabilities(agent.capabilities, target: agent.id)
                agent.chatControls = nil; agent.slashCommands = nil
            }
            state.agent = agent
        }
        return state
    }
    /// Only an explicit null confirms shutdown. An omitted field never calls this method.
    private func rememberDispatcher(_ value: AnnexJSON, hostID: String) {
        if value == .null {
            dispatcherMCPOff[hostID] = nil
            dispatcherFlags[hostID] = (false, dispatcherFlags[hostID]?.flagOn ?? true)
            dropDispatcher(hostID: hostID)
            return
        }
        guard case .object = value else { return }
        let enabled = value["enabled"]?.boolOrNil
        let flagOn = value["flagOn"]?.boolOrNil
        let previous = dispatcherFlags[hostID]
        let resolved = (enabled: enabled ?? previous?.enabled ?? capabilities[hostID]?.dispatcher?.enabled ?? false,
                        flagOn: flagOn ?? previous?.flagOn ?? capabilities[hostID]?.dispatcher?.flagOn ?? false)
        rememberMCPOff((!resolved.enabled || !resolved.flagOn) ? CompanionDispatcherMCPOff(json: value) : nil, hostID: hostID)
        if dispatcherMCPOff[hostID] != nil {
            dispatcherCatalog[hostID] = value
            rememberMCPOff(dispatcherMCPOff[hostID], hostID: hostID)
            dispatcherFlags[hostID] = resolved
        } else if !resolved.enabled || !resolved.flagOn {
            dispatcherFlags[hostID] = resolved
            dropDispatcher(hostID: hostID)
        } else if value["agent"]?["id"]?.string?.isEmpty == false {
            dispatcherCatalog[hostID] = value
            dispatcherFlags[hostID] = resolved
        } else {
            // A starting or partial entry does not revoke the last known identity.
            if enabled != nil || flagOn != nil {
                dispatcherFlags[hostID] = (enabled ?? previous?.enabled ?? false, flagOn ?? previous?.flagOn ?? true)
            }
            if dispatcherCatalog[hostID] == nil, enabled == true { dispatcherCatalog[hostID] = value }
        }
    }
    /// Its live status, kept on the remembered entry: REST refreshes never carry the Dispatcher, and the next snapshot may be a while.
    private func rememberDispatcherStatus(_ payload: AnnexJSON, hostID: String) {
        guard let id = payload["id"]?.string, case .object(var dispatcher)? = dispatcherCatalog[hostID],
              case .object(var agent)? = dispatcher["agent"], agent["id"]?.string == id else { return }
        if let status = payload["status"] { agent["status"] = status }
        if let detailed = payload["detailedStatus"] { agent["detailedStatus"] = detailed }
        dispatcher["agent"] = .object(agent)
        dispatcherCatalog[hostID] = .object(dispatcher)
    }
    /// Change events and receipts preserve MCP-off records; legacy turn-off still removes their caches.
    private func applyDispatcherChange(enabled: Bool, flagOn: Bool, agentID: String?, agent: AnnexJSON? = nil, mcpOff: CompanionDispatcherMCPOff?, hostID: String) {
        guard capabilities[hostID]?.supportsDispatcher == true || !knownCapabilities.contains(hostID) else { return }
        dispatcherFlags[hostID] = (enabled, flagOn)
        let off = !enabled || !flagOn ? mcpOff : nil
        let cachedID = dispatcherCatalog[hostID]?["agent"]?["id"]?.string
        // Off events intentionally keep legacy agentId null. The additive agent record is authoritative.
        let reportedID = agent?["id"]?.string ?? agentID
        if ((!enabled || !flagOn) && off == nil) || (reportedID != nil && cachedID != nil && reportedID != cachedID) { dropDispatcher(hostID: hostID) }
        if (enabled && flagOn) || off != nil, let agent, agent["id"]?.string?.isEmpty == false {
            dispatcherCatalog[hostID] = .object(["agent": agent, "projectId": .string(agent["projectId"]?.string
                ?? hosts[hostID]?.dispatcher?.projectID ?? CompanionDispatcher.defaultProjectID)])
        }
        rememberMCPOff(off, hostID: hostID)
        let state = dispatcherState(hostID: hostID, icons: iconCatalog[hostID]?.agents, meta: nil)
        hosts[hostID]?.dispatcher = state
        emitHosts()
    }
    private func rememberMCPOff(_ off: CompanionDispatcherMCPOff?, hostID: String) {
        dispatcherMCPOff[hostID] = off
        guard let off, !off.running else { return }
        let projectID = hosts[hostID]?.dispatcher?.projectID ?? capabilities[hostID]?.dispatcher?.projectID ?? CompanionDispatcher.defaultProjectID
        for target in projections.keys where target.hostID == hostID && target.projectID == projectID {
            projections[target]?.endSession(CompanionChatProjector.status(off.status ?? "sleeping"))
            readOnly.insert(target)
        }
        if case .object(var block)? = dispatcherCatalog[hostID], case .object(var agent)? = block["agent"] {
            agent["status"] = .string(off.status ?? "sleeping")
            block["agent"] = .object(agent)
            dispatcherCatalog[hostID] = .object(block)
        }
    }

    private func dropDispatcher(hostID: String) {
        dispatcherCatalog[hostID] = .null
        let projectID = hosts[hostID]?.dispatcher?.projectID ?? capabilities[hostID]?.dispatcher?.projectID ?? CompanionDispatcher.defaultProjectID
        for target in Set(projections.keys).union(buffers.keys).union(historyGenerations.keys) where target.hostID == hostID && target.projectID == projectID {
            projections[target] = nil
            buffers[target] = nil
            historyGenerations[target] = nil
            readOnly.remove(target)
        }
    }
    private func slashCommands(_ projection: CompanionChatProjector, target: CompanionTarget) -> [CompanionSlashCommand]? {
        guard mcpOff(for: target) == nil else { return nil }
        return Self.slashCommands(projection.slashCommands, live: !readOnly.contains(target) && projection.capabilities.contains(.chat),
                           session: projection.capabilities, capabilities: capabilities[target.hostID])
    }
    /// The `/` menu needs a desktop that sends commands (`slashCommands` v1) and a live session that reports them.
    /// Older desktops get none, so `/` is plain text.
    nonisolated static func slashCommands(_ commands: [CompanionSlashCommand], live: Bool, session: CompanionCapabilities,
                                          capabilities: AnnexCapabilities?) -> [CompanionSlashCommand]? {
        guard live, session.contains(.slashCommands), capabilities?.supportsSlashCommands == true else { return nil }
        return commands
    }
    /// The composer's controls while the session is live, limited to the commands the desktop takes. Older desktops get none.
    private func chatControls(_ projection: CompanionChatProjector, target: CompanionTarget) -> CompanionChatControls? {
        guard mcpOff(for: target) == nil else { return nil }
        return Self.chatControls(projection.controls, live: !readOnly.contains(target) && projection.capabilities.contains(.chat),
                          capabilities: capabilities[target.hostID])
    }
    nonisolated static func chatControls(_ controls: CompanionChatControls, live: Bool, capabilities: AnnexCapabilities?) -> CompanionChatControls? {
        guard live, let capabilities, (capabilities.chatControls?.version ?? 0) >= 1,
              capabilities.supportsModelSwitch || capabilities.supportsLevelSwitch else { return nil }
        var offered = controls
        if !capabilities.supportsModelSwitch { offered.modelSwitch = .none; offered.effortSwitch = .none }
        if !capabilities.supportsLevelSwitch { offered.liveLevels = [] }
        return offered
    }
    private func availableCapabilities(_ proposed: CompanionCapabilities, target: CompanionTarget) -> CompanionCapabilities {
        let hostID = target.hostID
        guard let commands = capabilities[hostID]?.commands else { return [] }
        var result = proposed
        if !commands.contains("chat.send") || capabilities[hostID].flatMap(Self.attachmentLimits) == nil { result.remove(.images) }
        if !commands.contains("chat.send") {
            result.subtract([.steer, .queue])
            if !commands.contains("agent.start") { result.remove(.chat) }
        }
        if !commands.contains("agent.start") { result.remove(.wake) }
        if !commands.contains("chat.interrupt") { result.remove(.cancel) }
        if !commands.contains("chat.permission") { result.remove(.approve) }
        if !commands.contains("chat.question") { result.remove(.answer) }
        if !commands.contains("chat.queue.remove") { result.remove(.removeQueued) }
        if let off = mcpOff(for: target) {
            guard off.running, !readOnly.contains(target) else { return [] }
            let gates: [(CompanionCapabilities, String)] = [(.chat, "chat.send"), (.steer, "chat.send"), (.queue, "chat.send"),
                (.images, "chat.send"), (.cancel, "chat.interrupt"), (.approve, "chat.permission"),
                (.answer, "chat.question"), (.removeQueued, "chat.queue.remove")]
            result.remove(.wake)
            result.remove(.slashCommands)
            for (flag, command) in gates where !off.allows(command) { result.remove(flag) }
        }
        return result
    }

    private func mcpOff(for target: CompanionTarget) -> CompanionDispatcherMCPOff? {
        let projectID = hosts[target.hostID]?.dispatcher?.projectID ?? capabilities[target.hostID]?.dispatcher?.projectID ?? CompanionDispatcher.defaultProjectID
        return target.projectID == projectID ? dispatcherMCPOff[target.hostID] : nil
    }

    /// Images need the upload route and `chat.send`; an older desktop advertises neither and gets text only.
    nonisolated static func attachmentLimits(_ capabilities: AnnexCapabilities) -> CompanionAttachmentLimits? {
        guard let value = capabilities.attachments, value.isUsable, capabilities.commands.contains("chat.send") else { return nil }
        return .init(imageTypes: value.imageTypes, maxImageBytes: value.maxImageBytes, maxCount: min(value.maxCount, CompanionImageLimits.maximumPerMessage))
    }

    /// Reads the desktop's theme colors. A `gradients.accent` CSS gradient, if the desktop adds one, supplies the wash.
    nonisolated static func theme(from json: AnnexJSON?, terminal: AnnexJSON? = nil) -> CompanionDesktopTheme? {
        guard case .object(let values)? = json else { return nil }
        let colors = values.compactMapValues(\.string)
        let gradient = (json?["gradients"]?["accent"]?.string ?? "")
            .matches(of: /#[0-9a-fA-F]{6}/).map { String($0.output) }
        var terminalColors: [String: String]?
        if case .object(let values)? = terminal { terminalColors = values.compactMapValues(\.string) }
        return .transported(colors, gradient: gradient, terminal: terminalColors)
    }

    static func readableError(_ error: Error) -> String {
        guard let error = error as? AnnexTransportError else { return error.localizedDescription }
        switch error {
        case .identityMismatch, .trustRequired, .invalidPin: return "The desktop identity could not be verified. Compare the fingerprints on your desktop before pairing again."
        case .unauthorized, .credentialMissing: return "Pair this desktop again to restore access."
        case .forbidden: return "This desktop has not granted mobile control. Pair again using the secure invitation."
        case .disconnected: return "The desktop is offline. Reconnect to continue."
        case .responseTooLarge: return "The desktop sent more data than your phone can accept."
        case .commandTooLarge: return "This command is too large to send. Nothing was sent."
        case .unsupportedCapability: return "This action is not supported by the connected desktop."
        case .commandOutcomeUnknown: return "Delivery is unknown. Refresh the conversation to check the result."
        case .pairingRevocationOutcomeUnknown: return "The desktop may have ended this pairing, but its reply was lost. Access is kept here so you can check desktop settings before forgetting this device."
        case .commandInFlight: return "Another command is being sent to this desktop. Try again when it finishes."
        case .invalidEndpoint: return "Enter a valid desktop address and port."
        case .rateLimited: return "The desktop is busy. Try again in a moment."
        case .rejected(_, let code, _) where code == "persistent_pairing_requires_desktop": return "Remove this remembered pairing in the desktop's Annex settings. You can also forget its local access on this device."
        case .rejected(_, _, let message?): return message
        case .rejected(_, "pending_overflow", _): return "There are too many pending requests to show on your phone. Review them on the desktop, then refresh this conversation."
        case .rejected(let status, let code, _): return "Desktop request failed (\(status))\(code.map { ": \($0)" } ?? "")."
        default: return "The desktop connection could not complete. Reconnect and try again."
        }
    }
}
