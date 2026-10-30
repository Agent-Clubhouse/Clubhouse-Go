import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor final class CompanionLiveService: CompanionService {
    private var transports: [String: any AnnexTransporting] = [:]
    private var hosts: [String: CompanionHost] = [:]
    private var capabilities: [String: AnnexCapabilities] = [:]
    private var projections: [CompanionTarget: CompanionChatProjector] = [:]
    private var readOnly: Set<CompanionTarget> = []
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var eventGenerations: [String: UUID] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var refreshAgain: Set<String> = []
    private var subscribers: [UUID: AsyncStream<CompanionEvent>.Continuation] = [:]
    private var buffers: [CompanionTarget: [AnnexJSON]] = [:]
    private var historyGenerations: [CompanionTarget: UUID] = [:]
    private var quickCatalog: [String: AnnexJSON] = [:]
    /// Hosts whose snapshot says `ptyHost.platform == "win32"`, for matching content roots.
    private var windowsHosts: Set<String> = []
    /// The snapshot's `projectIcons` and `agentIcons` per host, kept for catalog refreshes that don't carry them.
    private var iconCatalog: [String: (projects: AnnexJSON, agents: AnnexJSON)] = [:]
    private var savedCommands: [String: AnnexCommand] = [:]
    private let streamDiagnostics = CompanionStreamDiagnostics()
    private var isSuspended = false
    /// Called when a host stops answering at its saved address while the app is active.
    var onUnreachable: ((String) -> Void)?
    /// Called with the addresses a connected desktop reports for itself (home Wi-Fi, Tailscale).
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
        invalidateEvents(hostID: id)
        transports[id] = registration.transport
        let endpoint = registration.host.endpoint
        hosts[id] = .init(id: id, name: registration.alias.isEmpty ? endpoint.host : registration.alias,
                          endpoint: "\(endpoint.host):\(endpoint.port)", connection: .connecting,
                          projects: hosts[id]?.projects ?? [])
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
                projection.commandIDsByMessage = projections[target]?.commandIDsByMessage ?? [:]
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
                             contentRoots: Self.contentRoots(from: snapshot, windows: windowsHosts.contains(target.hostID)))
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
        case .rejected(404, let code?): CompanionAgentCommandError.message(code: code, message: nil) ?? readableError(error)
        case .rejected(500, _): "The desktop couldn't read this agent's past conversations. Try again later."
        default: readableError(error)
        }
    }

    func archive(for target: CompanionTarget, sessionID: String) throws -> any CompanionArchiveReading {
        CompanionArchiveReader(transport: try transport(for: target.hostID), target: target, sessionID: sessionID)
    }

    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        let kind: AnnexCommand.Kind
        if readOnly.contains(request.target) || projections[request.target]?.sessionID == nil {
            // `agent.start` carries text only; the desktop answers an image upload for a stopped agent with `not_chat`.
            guard request.attachmentIDs.isEmpty else { throw CompanionServiceError.rejected(Self.notChatMessage) }
            // Resume the last session when there is one; the desktop starts fresh when asked to resume none.
            let hasSession = hosts[request.target.hostID]?.projects.flatMap(\.agents).first { $0.id == request.target }?.hasSession
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
        case .rejected(409, "not_chat"): return CompanionServiceError.rejected(notChatMessage)
        case .rejected(409, "images_not_supported"): return CompanionAttachmentError.imagesNotSupported
        case .rejected(413, _): return CompanionServiceError.rejected("This image is too large for the desktop.")
        case .rejected(415, _): return CompanionServiceError.rejected("The desktop can't read this image.")
        case .rejected(404, "agent_not_found"): return CompanionServiceError.rejected("This agent is no longer on your desktop.")
        // `empty_body` / `upload_failed`: the request didn't arrive whole.
        case .rejected(400, _): return CompanionServiceError.rejected("The image couldn't be uploaded. Check the connection and try again.")
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
            catch { throw CompanionServiceError.unavailable(Self.contentErrorMessage(error, reference: reference, hostName: hostName)) }
        }
    }

    private func fetchContent(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        let route: AnnexReadRoute
        switch reference {
        case .image(let ref):
            guard CompanionContentReference.validMediaReference(ref) else { throw AnnexTransportError.invalidEndpoint }
            route = .chatContent(agentID: target.agentID, mediaRef: ref, filePath: nil)
        case .file(let path): route = .chatContent(agentID: target.agentID, mediaRef: nil, filePath: path)
        case .localImage: throw AnnexTransportError.invalidEndpoint
            }
            let value = try await transport(for: target.hostID).read(route)
            guard let kind = value["kind"]?.string, ["image", "text", "video", "audio", "other"].contains(kind),
                  let name = value["name"]?.string else { throw AnnexTransportError.malformedResponse }
            let encoded = value["base64"]?.string
            guard (encoded?.utf8.count ?? 0) <= 12 * 1024 * 1024 else { throw AnnexTransportError.responseTooLarge }
            let bytes = encoded.flatMap { Data(base64Encoded: $0) }
            guard encoded == nil || bytes != nil, (bytes?.count ?? 0) <= 8 * 1024 * 1024 else { throw AnnexTransportError.malformedResponse }
            return .init(kind: kind, name: name, mimeType: value["mimeType"]?.string, bytes: bytes,
                         text: value["text"]?.string, truncated: value["truncated"].boolValue, tooLarge: value["tooLarge"].boolValue)
    }

    /// The desktop answers every refused preview with the same code, so name the likely reason for this reference.
    static func contentErrorMessage(_ error: Error, reference: CompanionContentReference, hostName: String) -> String {
        switch error as? AnnexTransportError {
        case .rejected(404, "agent_not_found"): return "This agent is no longer on \(hostName)."
        // The desktop answers an invalid reference like a missing one (404 content_unavailable), so the phone does too.
        case .rejected(404, _), .invalidEndpoint:
            if case .file = reference {} else { return "This image is no longer available on \(hostName)." }
            return "\(hostName) couldn't share this file. It may have moved, or be outside the agent's folders."
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
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        _ = try await execute(.permission(agentID: target.agentID, sessionID: try session(for: target), requestID: approvalID, optionID: optionID), id: clientCommandID, hostID: target.hostID)
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
        let create = AnnexAgentCreate(projectID: request.project.projectID, name: request.name, color: request.color, orchestrator: request.orchestrator,
                                      model: request.model, persona: request.persona, freeAgentMode: freeAgentMode, useWorktree: request.useWorktree, mcpIDs: request.mcpIDs)
        let receipt = try await execute(.create(create), id: request.clientCommandID, hostID: request.project.hostID)
        guard let agentID = receipt.result?["agentId"]?.string else { throw CompanionServiceError.uncertain("The desktop created the agent but didn't say which one. Check its agent list.") }
        await refresh(hostID: request.project.hostID)
        let projectID = receipt.result?["projectId"]?.string ?? request.project.projectID
        return .init(target: .init(hostID: request.project.hostID, projectID: projectID, agentID: agentID),
                     isCreating: receipt.result?["state"]?.string == "creating")
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
        if change.freeAgentMode != nil, capabilities[target.hostID]?.supportsFreeAgentMode != true {
            throw CompanionServiceError.rejected(CompanionAgentCommandError.message(code: "free_agent_mode_not_allowed", message: nil) ?? "")
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
        let kind: AnnexCommand.Kind = approve ? .helperApprove(requestID: request.id, force: force) : .helperDecline(requestID: request.id)
        _ = try await execute(kind, id: clientCommandID, hostID: request.hostID)
        // The desktop broadcasts a snapshot without it; drop it now so it can't be answered twice.
        hosts[request.hostID]?.helperRequests.removeAll { $0.id == request.id }
        emitHosts()
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
                         task: item["start"]?["task"]?.string, dispose: dispose)
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
        case .responseTooLarge: "This file is too large to show on your phone."
        case .rejected(404, _): "The desktop no longer has this project."
        case .rejected(500, _): "The desktop couldn't read this project's changes."
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
        case .rejected(404, let code?): CompanionAgentCommandError.message(code: code, message: nil) ?? readableError(error)
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
        hosts.removeValue(forKey: hostID)
        capabilities.removeValue(forKey: hostID)
        windowsHosts.remove(hostID)
        iconCatalog.removeValue(forKey: hostID)
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
    func resume() async {
        isSuspended = false
        let reconnected = await prepareResume?() ?? []
        for id in Array(transports.keys) where !reconnected.contains(id) { await reconnect(hostID: id) }
    }

    private func invalidateEvents(hostID: String) {
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

    private func execute(_ kind: AnnexCommand.Kind, id: String, hostID: String) async throws -> AnnexCommandReceipt {
        guard let caps = capabilities[hostID] else { throw CompanionServiceError.unavailable("This desktop does not support mobile control. Update Clubhouse on desktop and reconnect.") }
        let command = savedCommands[id] ?? AnnexCommand(commandID: id, epoch: caps.epoch, kind: kind)
        guard command.epoch == caps.epoch else { throw CompanionServiceError.uncertain("The desktop restarted. Refresh the conversation to check the previous command.") }
        savedCommands[id] = command
        do {
            let receipt = try await transport(for: hostID).execute(command)
            if let error = Self.receiptError(receipt, attachmentCount: command.attachmentCount) { throw error }
            return receipt
        } catch let error as CompanionServiceError { throw error }
        catch let error as CompanionAttachmentError { throw error }
        catch AnnexTransportError.commandOutcomeUnknown { throw CompanionServiceError.uncertain("The desktop may have received this command, but its reply was lost.") }
        catch { throw CompanionServiceError.rejected(Self.readableError(error)) }
    }
    /// What a receipt means for the user: nil when the command was dispatched. Image refusals keep their own recovery.
    nonisolated static func receiptError(_ receipt: AnnexCommandReceipt, attachmentCount: Int = 0) -> Error? {
        switch receipt.status {
        case .completed: return nil
        case .rejected:
            switch receipt.error?.code {
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
            if state != .connected { streamDiagnostics.disconnect(hostID: hostID) }
            switch state {
            case .connected:
                hosts[hostID]?.connection = .synchronizing; emitHosts()
                scheduleRefresh(hostID: hostID)
            case .connecting:
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .connecting
            case .disconnected, .suspended:
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .offline
                emit(.resyncRequired(hostID: hostID))
            case .reconnecting:
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .reconnecting
            case .failed(let error):
                cancelRefresh(hostID: hostID)
                hosts[hostID]?.connection = .failed(Self.readableError(error))
            }
            emitHosts()
            switch state {
            case .reconnecting, .failed: if !isSuspended { onUnreachable?(hostID) }
            default: break
            }
        case .resyncRequired:
            hosts[hostID]?.connection = .synchronizing
            emit(.resyncRequired(hostID: hostID)); emitHosts()
            scheduleRefresh(hostID: hostID)
            // Store keeps active conversations blocked until its history is refreshed.
        case .message(let envelope):
            guard let payload = envelope.payload else { return }
            switch envelope.type {
            case "snapshot":
                if let quick = payload["quickAgents"] { quickCatalog[hostID] = quick }
                if payload["ptyHost"]?["platform"]?.string == "win32" { windowsHosts.insert(hostID) } else { windowsHosts.remove(hostID) }
                if payload["projectIcons"] != nil || payload["agentIcons"] != nil {
                    iconCatalog[hostID] = (payload["projectIcons"] ?? .object([:]), payload["agentIcons"] ?? .object([:]))
                }
                applyCatalog(payload, hostID: hostID)
                // Only the WebSocket snapshot lists helper requests; a REST refresh keeps the last list.
                if let requests = payload["helperRequests"] { hosts[hostID]?.helperRequests = Self.helperRequests(from: requests, hostID: hostID) }
                // Sent only after the desktop's one-time migration; without it the phone keeps its own pins.
                hosts[hostID]?.projectState = CompanionProjectState.map(from: payload["projectState"])
                // Also sent only after the desktop's one-time migration; without it the phone keeps its own finished list.
                hosts[hostID]?.finishedQuickAgents = CompanionFinishedRun.desktopLists(payload["finishedQuickAgents"], hostID: hostID)
                hosts[hostID]?.idleDays = Self.idleDays(from: payload["idleDays"])
                if let theme = Self.theme(from: payload["theme"], terminal: payload["terminalColors"]) { hosts[hostID]?.theme = theme }
                emitHosts()
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
                if let agentID = payload["id"]?.string, let target = target(agentID: agentID, hostID: hostID) {
                    let status = CompanionChatProjector.status(payload["status"]?.string, detailed: payload["detailedStatus"])
                    // Desktop lifecycle status is coarser than the chat stream.
                    // Keep an outstanding question/approval visible until its
                    // authoritative chat event resolves it or the agent stops.
                    let pendingInteraction = projections[target]?.status == .waiting || projections[target]?.status == .approval
                    if !pendingInteraction || (status != .working && status != .idle) {
                        projections[target]?.status = status
                    }
                }
                scheduleRefresh(hostID: hostID)
            case "agent:deleted": scheduleRefresh(hostID: hostID)
            default: break
            }
        }
    }

    private func refresh(hostID: String) async {
        guard let transport = transports[hostID], let generation = eventGenerations[hostID], !isSuspended else { return }
        do {
            let rawCaps = try? await transport.read(.capabilities)
            let newCapabilities = (rawCaps?["controlAvailable"]).boolValue == true ? try rawCaps?.decode(AnnexCapabilities.self) : nil
            let rawProjects = try await transport.read(.projects)
            let projects = rawProjects["projects"].arrayValue.isEmpty ? Optional(rawProjects).arrayValue : rawProjects["projects"].arrayValue
            var agents: [String: AnnexJSON] = [:]
            for project in projects {
                guard let projectID = project["id"]?.string else { continue }
                let result = try await transport.read(.agents(projectID: projectID))
                agents[projectID] = result["agents"] ?? result
            }
            guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
            capabilities[hostID] = newCapabilities
            hosts[hostID]?.richContentAvailable = rawCaps?["richContent"]?["enabled"].boolValue == true
            hosts[hostID]?.canSpawn = newCapabilities?.commands.contains("agent.spawn") == true
            hosts[hostID]?.canCreateDurable = newCapabilities?.supportsAgentCreate == true
            hosts[hostID]?.canEditSettings = newCapabilities?.supportsAgentSettings == true
            hosts[hostID]?.canAnswerHelperRequests = newCapabilities?.supportsHelperRequests == true
            hosts[hostID]?.canSyncProjectState = newCapabilities?.supportsProjectState == true
            hosts[hostID]?.canSyncFinishedQuick = newCapabilities?.supportsFinishedQuickAgents == true
            hosts[hostID]?.attachments = newCapabilities.flatMap(Self.attachmentLimits)
            hosts[hostID]?.canRevokeSession = rawCaps?["pairing"]?["sessionRevokePath"]?.string == "/api/v1/mobile/pairing"
            hosts[hostID]?.canAnswerPersistentApprovals = newCapabilities?.supportsPersistentApprovals == true
            hosts[hostID]?.canSetFreeAgentMode = newCapabilities?.supportsFreeAgentMode == true
            hosts[hostID]?.terminal = Self.terminalSupport(newCapabilities)
            if let routes = try? rawCaps?["routes"]?.decode(AnnexCapabilities.Routes.self) { onRoutes?(hostID, routes) }
            applyCatalog(.object(["projects": .array(projects), "agents": .object(agents), "quickAgents": quickCatalog[hostID] ?? .object([:])]), hostID: hostID)
            hosts[hostID]?.connection = .connected
        } catch {
            guard !Task.isCancelled, eventGenerations[hostID] == generation, !isSuspended else { return }
            hosts[hostID]?.connection = .failed(Self.readableError(error))
        }
        emitHosts()
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
        let projectIcons = payload["projectIcons"] ?? iconCatalog[hostID]?.projects
        let agentIcons = payload["agentIcons"] ?? iconCatalog[hostID]?.agents
        for project in payload["projects"].arrayValue {
            guard let projectID = project["id"]?.string else { continue }
            let durableValues: [AnnexJSON] = (payload["agents"]?[projectID]).arrayValue
            let quickValues: [AnnexJSON] = (payload["quickAgents"]?[projectID]).arrayValue
            var agents: [CompanionAgent] = []
            for (index, value) in (durableValues + quickValues).enumerated() {
                guard let id = value["id"]?.string else { continue }
                let target = CompanionTarget(hostID: hostID, projectID: projectID, agentID: id)
                let projection = projections[target]
                let name: String = value["name"]?.string ?? id
                let mission: String? = value["mission"]?.string ?? value["prompt"]?.string
                let subtitle: String = mission ?? value["branch"]?.string ?? ""
                let meta = payload["agentsMeta"]?[id]
                let detailed = value["detailedStatus"] ?? meta?["detailedStatus"]
                // Without a live chat session the chat snapshot can only say "sleeping". When the catalog says
                // the agent is running anyway (in a terminal or headless), the catalog is right.
                let runsOutsideChat = readOnly.contains(target) && value["status"]?.string == "running"
                let status: CompanionAgentStatus = (runsOutsideChat ? nil : projection?.status)
                    ?? CompanionChatProjector.status(value["status"]?.string, detailed: detailed)
                let model: String? = projection?.model ?? value["model"]?.string
                let supported = availableCapabilities(projection?.capabilities ?? [], hostID: hostID)
                let activity = (value["lastActivityAt"] ?? value["spawnedAt"]).flatMap(Self.date(from:))
                let isQuick = value["kind"]?.string.map { $0 == "quick" } ?? (index >= durableValues.count)
                var agent = CompanionAgent(id: target, name: name, subtitle: subtitle, status: status, model: model, capabilities: supported,
                                           executionMode: value["executionMode"]?.string ?? meta?["executionMode"]?.string, lastActivity: activity,
                                           isQuick: isQuick, hasExited: isQuick && Self.exitedStatuses.contains(value["status"]?.string ?? ""),
                                           exitCode: value["exitCode"]?.integer.map(Int.init),
                                           turnStartedAt: projection?.turnStartedAt, contextUsage: projection?.contextUsage)
                Self.applyIdentity(value, icon: agentIcons?[id], to: &agent)
                agent.detail = Self.detail(from: detailed)
                if case .bool(let has)? = value["hasSession"] { agent.hasSession = has }
                agent.branch = value["branch"]?.string
                agent.orchestrator = value["orchestrator"]?.string
                agent.session = projection.map(\.session)
                agent.chatControls = projection.flatMap { chatControls($0, target: target) }
                agents.append(agent)
            }
            projects.append(Self.project(project, id: projectID, agents: agents, icon: projectIcons?[projectID]))
        }
        host.projects = projects
        if case .object(let orchestrators)? = payload["orchestrators"] {
            host.providers = orchestrators.map { id, value in
                CompanionProvider(id: id, name: value["displayName"]?.string ?? value["shortName"]?.string ?? id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        hosts[hostID] = host
    }
    /// The chat snapshot's `contentRoots` (desktop #2460). Older desktops omit it, which leaves relative paths only.
    nonisolated static func contentRoots(from snapshot: AnnexJSON, windows: Bool) -> CompanionContentRoots {
        .init(paths: snapshot["contentRoots"].arrayValue.prefix(16).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } }, windows: windows)
    }
    /// A project's name and identity. The desktop's `displayName` overrides its `name`.
    nonisolated static func project(_ value: AnnexJSON, id: String, agents: [CompanionAgent], icon: AnnexJSON?) -> CompanionProject {
        CompanionProject(id: id, name: value["displayName"]?.string ?? value["name"]?.string ?? id, agents: agents,
                         color: value["color"]?.string, emoji: value["emoji"]?.string,
                         iconData: CompanionIdentityColor.data(fromDataURL: icon?.string))
    }
    /// An agent's identity and Free Agent Mode from its catalog entry.
    nonisolated static func applyIdentity(_ value: AnnexJSON, icon: AnnexJSON?, to agent: inout CompanionAgent) {
        agent.color = value["color"]?.string
        agent.emoji = value["emoji"]?.string
        agent.iconData = CompanionIdentityColor.data(fromDataURL: icon?.string)
        agent.freeAgentMode = value["freeAgentMode"].boolValue == true
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
        hosts[hostID]?.projects.flatMap(\.agents).first { $0.id.agentID == agentID }?.id
    }
    private func project(_ event: AnnexJSON, target: CompanionTarget) {
        var projection = projections[target] ?? .init()
        let oldSession = projection.sessionID
        projection.apply(event)
        // A live session started after a read-only snapshot, as when history loads before a new agent's chat is up.
        // Its start (with the capabilities) may have arrived before the agent was listed, so re-read the snapshot.
        if let session = projection.sessionID, session != oldSession, readOnly.remove(target) != nil {
            Task { _ = try? await history(for: target) }
        }
        projections[target] = projection
        updateAgent(target, projection: projection)
        emit(.timeline(target, items: projection.items, sequence: projection.lastSequence, reset: oldSession != projection.sessionID, sessionID: projection.sessionID))
        emitHosts()
    }
    private func updateAgent(_ target: CompanionTarget, projection: CompanionChatProjector) {
        guard let projectIndex = hosts[target.hostID]?.projects.firstIndex(where: { $0.id == target.projectID }),
              let agentIndex = hosts[target.hostID]?.projects[projectIndex].agents.firstIndex(where: { $0.id == target }) else { return }
        // An agent running outside chat (it has an execution mode but no live chat) keeps its catalog status.
        let runsOutsideChat = readOnly.contains(target) && hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].executionMode != nil
        if !runsOutsideChat { hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].status = projection.status }
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].capabilities = availableCapabilities(projection.capabilities, hostID: target.hostID)
        if let model = projection.model { hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].model = model }
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].turnStartedAt = projection.turnStartedAt
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].contextUsage = projection.contextUsage
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].session = projection.session
        hosts[target.hostID]?.projects[projectIndex].agents[agentIndex].chatControls = chatControls(projection, target: target)
    }
    /// The composer's controls while the session is live, limited to the commands the desktop takes. Older desktops get none.
    private func chatControls(_ projection: CompanionChatProjector, target: CompanionTarget) -> CompanionChatControls? {
        Self.chatControls(projection.controls, live: !readOnly.contains(target) && projection.capabilities.contains(.chat),
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
    private func availableCapabilities(_ proposed: CompanionCapabilities, hostID: String) -> CompanionCapabilities {
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
        return result
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
        case .unsupportedCapability: return "This action is not supported by the connected desktop."
        case .commandOutcomeUnknown: return "Delivery is unknown. Refresh the conversation to check the result."
        case .pairingRevocationOutcomeUnknown: return "The desktop may have ended this pairing, but its reply was lost. Access is kept here so you can check desktop settings before forgetting this device."
        case .commandInFlight: return "Another command is being sent to this desktop. Try again when it finishes."
        case .invalidEndpoint: return "Enter a valid desktop address and port."
        case .rateLimited: return "The desktop is busy. Try again in a moment."
        case .rejected(_, let code) where code == "persistent_pairing_requires_desktop": return "Remove this remembered pairing in the desktop's Annex settings. You can also forget its local access on this device."
        case .rejected(let status, let code): return "Desktop request failed (\(status))\(code.map { ": \($0)" } ?? "")."
        default: return "The desktop connection could not complete. Reconnect and try again."
        }
    }
}
