import Foundation

/// Per-server connection state and data. Each ServerInstance manages its own
/// WebSocket, API client, reconnection, and cached agent/project data.
@Observable final class ServerInstance: Identifiable {
    // MARK: - Identity (immutable after init)
    let id: ServerInstanceID
    let protocolConfig: ServerProtocol

    // MARK: - Connection State
    var connectionState: ConnectionState = .disconnected
    var lastError: String?
    var serverName: String = ""

    // MARK: - Per-Instance Data
    var projects: [Project] = []
    var agentsByProject: [String: [DurableAgent]] = [:]
    var quickAgentsByProject: [String: [QuickAgent]] = [:]
    var activityByAgent: [String: [HookEvent]] = [:]
    var pendingPermissions: [String: PermissionRequest] = [:]
    var ptyBufferByAgent: [String: String] = [:]
    var structuredEventsByAgent: [String: [StructuredEvent]] = [:]
    var theme: ThemeColors = .mock
    var orchestrators: [String: OrchestratorEntry] = [:]
    var agentIcons: [String: Data] = [:]
    var projectIcons: [String: Data] = [:]
    var canvasByProject: [String: CanvasState] = [:]
    var plugins: [PluginSummary] = []

    // MARK: - Networking (private)
    private(set) var apiClient: AnnexAPIClient?
    private(set) var webSocket: WebSocketClient?
    private var wsStreamTask: Task<Void, Never>?
    private(set) var token: String?
    private var reconnectAttempt = 0
    private var lastSeq: Int?
    private var isReplaying = false
    private static let maxReconnectAttempts = 10
    private static let maxActivityEventsPerAgent = 200

    /// Per-agent PTY data callbacks — bypasses @Observable dictionary tracking
    /// to prevent cross-agent terminal bleed.
    private var ptyCallbacks: [String: (String) -> Void] = [:]

    /// Register a callback to receive PTY data for a specific agent.
    /// Returns a closure to unregister.
    func subscribePtyData(agentId: String, callback: @escaping (String) -> Void) -> (() -> Void) {
        ptyCallbacks[agentId] = callback
        return { [weak self] in
            self?.ptyCallbacks.removeValue(forKey: agentId)
        }
    }

    private var logPrefix: String { "[\(id.value.prefix(12))]" }

    init(id: ServerInstanceID, protocolConfig: ServerProtocol) {
        self.id = id
        self.protocolConfig = protocolConfig
        AppLog.shared.debug("Instance", "\(id.value.prefix(12)) created (proto=\(protocolConfig.label))")
    }

    // MARK: - Queries

    func agents(for project: Project) -> [DurableAgent] {
        agentsByProject[project.id] ?? []
    }

    var allAgents: [DurableAgent] {
        agentsByProject.values
            .flatMap { $0 }
            .sorted { $0.statusSortOrder < $1.statusSortOrder }
    }

    func project(for agent: DurableAgent) -> Project? {
        for project in projects {
            if agentsByProject[project.id]?.contains(where: { $0.id == agent.id }) == true {
                return project
            }
        }
        return nil
    }

    func allQuickAgents(for project: Project) -> [QuickAgent] {
        let nested = agents(for: project).flatMap { $0.quickAgents ?? [] }
        let standalone = quickAgentsByProject[project.id] ?? []
        var seen = Set<String>()
        var result: [QuickAgent] = []
        for agent in standalone {
            if seen.insert(agent.id).inserted { result.append(agent) }
        }
        for agent in nested {
            if seen.insert(agent.id).inserted { result.append(agent) }
        }
        return result
    }

    func quickAgent(byId id: String) -> QuickAgent? {
        for agents in quickAgentsByProject.values {
            if let agent = agents.first(where: { $0.id == id }) { return agent }
        }
        for agents in agentsByProject.values {
            for durable in agents {
                if let qa = durable.quickAgents?.first(where: { $0.id == id }) { return qa }
            }
        }
        return nil
    }

    func activity(for agentId: String) -> [HookEvent] {
        activityByAgent[agentId] ?? []
    }

    func structuredEvents(for agentId: String) -> [StructuredEvent] {
        structuredEventsByAgent[agentId] ?? []
    }

    func durableAgent(byId agentId: String) -> DurableAgent? {
        for agents in agentsByProject.values {
            if let agent = agents.first(where: { $0.id == agentId }) { return agent }
        }
        return nil
    }

    func pendingPermission(for agentId: String) -> PermissionRequest? {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return pendingPermissions.values
            .first { $0.agentId == agentId && ($0.deadline ?? Int.max) > now }
    }

    func ptyBuffer(for agentId: String) -> String {
        ptyBufferByAgent[agentId] ?? ""
    }

    var totalAgentCount: Int {
        agentsByProject.values.flatMap { $0 }.count
    }

    var runningAgentCount: Int {
        agentsByProject.values.flatMap { $0 }.filter { $0.status == .running }.count
    }

    func agentIconURL(agentId: String) -> URL? {
        guard let apiClient, let token else { return nil }
        return URL(string: "\(apiClient.baseURL)/api/v1/icons/agent/\(agentId)?token=\(token)")
    }

    func projectIconURL(projectId: String) -> URL? {
        guard let apiClient, let token else { return nil }
        return URL(string: "\(apiClient.baseURL)/api/v1/icons/project/\(projectId)?token=\(token)")
    }

    // MARK: - Connection Lifecycle

    /// Connect using plain HTTP/WS (no TLS) for integration testing with mock servers.
    func connectPlaintext(token: String) async {
        self.token = token
        let host = protocolConfig.host
        let mainPort = protocolConfig.mainPort
        AppLog.shared.info("Instance", "\(logPrefix) Connecting (plaintext) -> \(host):\(mainPort)")
        let client = AnnexAPIClient.v2Pairing(host: host, pairingPort: mainPort)
        self.apiClient = client
        connectionState = .connecting

        do {
            let status = try await client.getStatus(token: token)
            serverName = status.deviceName
            connectionState = .connected
            AppLog.shared.info("Instance", "\(logPrefix) Connected (plaintext): \(status.deviceName)")
            // Connect WebSocket using plain ws://
            await connectWebSocketPlaintext()
        } catch {
            connectionState = .disconnected
            lastError = "Failed to connect"
            AppLog.shared.error("Instance", "\(logPrefix) Plaintext connection failed: \(error)")
        }
    }

    private func connectWebSocketPlaintext() async {
        guard let token else { return }
        wsStreamTask?.cancel()
        webSocket?.disconnect()

        let urlHost = protocolConfig.host.contains(":") ? "[\(protocolConfig.host)]" : protocolConfig.host
        guard let url = URL(string: "ws://\(urlHost):\(protocolConfig.mainPort)/ws?token=\(token)") else {
            AppLog.shared.error("Instance", "\(logPrefix) Failed to construct plaintext WebSocket URL")
            return
        }
        AppLog.shared.info("Instance", "\(logPrefix) Connecting WebSocket (plaintext)...")
        let ws = WebSocketClient(url: url, session: .shared)
        self.webSocket = ws

        let stream = ws.connect()
        reconnectAttempt = 0
        isReplaying = false

        wsStreamTask = Task {
            for await seqEvent in stream {
                if let seq = seqEvent.seq {
                    self.lastSeq = seq
                }
                await handleWSEvent(seqEvent.event)
            }
        }
    }

    func connect(token: String) async {
        self.token = token
        let host = protocolConfig.host
        let mainPort = protocolConfig.mainPort
        AppLog.shared.info("Instance", "\(logPrefix) Connecting -> \(host):\(mainPort) (TLS)")
        // Load Ed25519 identity to get our fingerprint for mTLS CN
        let ed25519 = CryptoIdentity.loadOrCreate()
        let mtlsIdentity = MTLSIdentity.loadOrCreate(fingerprint: ed25519.fingerprint)
        let delegate = TLSSessionDelegate(clientIdentity: mtlsIdentity)
        let client = AnnexAPIClient.v2(host: host, mainPort: mainPort, delegate: delegate)
        self.apiClient = client
        connectionState = .connecting
        AppLog.shared.info("Instance", "\(logPrefix) State -> connecting")

        do {
            AppLog.shared.info("Instance", "\(logPrefix) Fetching status...")
            let status = try await client.getStatus(token: token)
            serverName = status.deviceName
            connectionState = .connected
            AppLog.shared.info("Instance", "\(logPrefix) Connected: \(status.deviceName) (\(status.agentCount) agents, \(status.orchestratorCount) orchestrators)")
            await connectWebSocket()
        } catch {
            connectionState = .disconnected
            lastError = "Failed to connect"
            AppLog.shared.error("Instance", "\(logPrefix) Connection failed: \(error)")
        }
    }

    func disconnect() {
        AppLog.shared.info("Instance", "\(logPrefix) Disconnect requested")
        disconnectInternal()
    }

    private func connectWebSocket() async {
        guard let apiClient, let token else {
            AppLog.shared.error("Instance", "\(logPrefix) Cannot connect WS: no apiClient or token")
            return
        }
        wsStreamTask?.cancel()
        webSocket?.disconnect()

        guard let url = try? apiClient.webSocketURL(token: token) else {
            AppLog.shared.error("Instance", "\(logPrefix) Failed to construct WebSocket URL")
            return
        }
        AppLog.shared.info("Instance", "\(logPrefix) Connecting WebSocket...")
        let ws = WebSocketClient(url: url, session: apiClient.urlSession)
        self.webSocket = ws

        let stream = ws.connect()
        let previousSeq = lastSeq
        reconnectAttempt = 0
        isReplaying = false

        wsStreamTask = Task {
            for await seqEvent in stream {
                if let seq = seqEvent.seq {
                    self.lastSeq = seq
                }
                await handleWSEvent(seqEvent.event)
            }
            AppLog.shared.info("Instance", "\(logPrefix) WS stream ended")
        }

        if let since = previousSeq {
            AppLog.shared.info("Instance", "\(logPrefix) Requesting replay since seq=\(since)")
            let replayReq = ReplayRequest(type: "replay", since: since)
            ws.send(replayReq)
        }
    }

    private func handleWSEvent(_ event: WSEvent) async {
        switch event {
        case .snapshot(let payload):
            let agentCount = payload.agents.values.flatMap { $0 }.count
            let permCount = payload.pendingPermissions?.count ?? 0
            AppLog.shared.info("Instance", "\(logPrefix) Snapshot: \(payload.projects.count) projects, \(agentCount) agents, \(permCount) permissions, seq=\(payload.lastSeq ?? -1)")
            projects = payload.projects
            agentsByProject = payload.agents
            quickAgentsByProject = payload.quickAgents ?? [:]
            theme = payload.theme
            orchestrators = payload.orchestrators
            activityByAgent = [:]
            ptyBufferByAgent = [:]
            structuredEventsByAgent = [:]
            if let seq = payload.lastSeq {
                lastSeq = seq
            }
            pendingPermissions = [:]
            if let perms = payload.pendingPermissions {
                for perm in perms {
                    pendingPermissions[perm.id] = perm
                }
            }
            plugins = payload.plugins ?? []
            // Populate canvas state from snapshot
            canvasByProject = [:]
            if let canvasEntries = payload.canvasState {
                for (projectId, entry) in canvasEntries {
                    let activeId = entry.activeCanvasId ?? entry.canvases.first?.canvasId ?? ""
                    if let canvas = entry.canvases.first(where: { $0.canvasId == activeId }) ?? entry.canvases.first {
                        canvasByProject[projectId] = canvas
                    }
                }
                AppLog.shared.info("Instance", "\(logPrefix) Canvas: \(canvasByProject.count) project canvas(es)")
            }
            if let appCanvas = payload.appCanvasState {
                let activeId = appCanvas.activeCanvasId ?? appCanvas.canvases.first?.canvasId ?? ""
                if let canvas = appCanvas.canvases.first(where: { $0.canvasId == activeId }) ?? appCanvas.canvases.first {
                    canvasByProject["__app__"] = canvas
                    AppLog.shared.info("Instance", "\(logPrefix) Canvas: app-level canvas loaded")
                }
            }
            connectionState = .connected
            Task { await fetchIcons() }

        case .ptyData(let payload):
            var buf = ptyBufferByAgent[payload.agentId] ?? ""
            buf.append(payload.data)
            if buf.count > 65_536 {
                buf = String(buf.suffix(49_152))
            }
            ptyBufferByAgent[payload.agentId] = buf
            // Deliver directly to subscribed terminal (bypasses @Observable dict tracking)
            ptyCallbacks[payload.agentId]?(payload.data)

        case .ptyExit:
            break

        case .hookEvent(let payload):
            let hookEvent = payload.event.toHookEvent(agentId: payload.agentId)
            var events = activityByAgent[payload.agentId] ?? []
            events.append(hookEvent)
            // Cap to prevent unbounded memory growth
            if events.count > Self.maxActivityEventsPerAgent {
                events = Array(events.suffix(Self.maxActivityEventsPerAgent))
            }
            activityByAgent[payload.agentId] = events

        case .themeChanged(let newTheme):
            AppLog.shared.info("Instance", "\(logPrefix) Theme updated")
            theme = newTheme

        case .structuredEvent(let payload):
            var events = structuredEventsByAgent[payload.agentId] ?? []
            events.append(payload.event)
            structuredEventsByAgent[payload.agentId] = events

        case .replayGap(let payload):
            AppLog.shared.warn("Instance", "\(logPrefix) Replay gap — resetting to seq=\(payload.lastSeq)")
            lastSeq = payload.lastSeq
            isReplaying = false

        case .replayStart:
            AppLog.shared.info("Instance", "\(logPrefix) Replay started")
            isReplaying = true

        case .replayEnd:
            AppLog.shared.info("Instance", "\(logPrefix) Replay ended")
            isReplaying = false

        case .agentSpawned(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Agent spawned: \(payload.name ?? payload.id) in project \(payload.projectId)")
            if let existing = quickAgentsByProject[payload.projectId],
               existing.contains(where: { $0.id == payload.id }) { break }
            let qa = QuickAgent(
                id: payload.id, name: payload.name, kind: payload.kind,
                status: AgentStatus(rawValue: payload.status),
                mission: payload.prompt, prompt: payload.prompt,
                model: payload.model, detailedStatus: nil,
                orchestrator: payload.orchestrator,
                parentAgentId: payload.parentAgentId,
                projectId: payload.projectId,
                freeAgentMode: payload.freeAgentMode
            )
            var agents = quickAgentsByProject[payload.projectId] ?? []
            agents.append(qa)
            quickAgentsByProject[payload.projectId] = agents

        case .agentStatus(let payload):
            guard let projectId = payload.projectId else { break }
            if var agents = quickAgentsByProject[projectId],
               let idx = agents.firstIndex(where: { $0.id == payload.id }) {
                agents[idx].status = AgentStatus(rawValue: payload.status)
                quickAgentsByProject[projectId] = agents
            }

        case .agentCompleted(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Agent completed: \(payload.id)")
            guard let projectId = payload.projectId else { break }
            if var agents = quickAgentsByProject[projectId],
               let idx = agents.firstIndex(where: { $0.id == payload.id }) {
                agents[idx].status = AgentStatus(rawValue: payload.status)
                agents[idx].summary = payload.summary
                agents[idx].filesModified = payload.filesModified
                agents[idx].durationMs = payload.durationMs
                agents[idx].costUsd = payload.costUsd
                agents[idx].toolsUsed = payload.toolsUsed
                quickAgentsByProject[projectId] = agents
            }

        case .agentWoken(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Agent woken: \(payload.agentId)")
            for (projectId, var agents) in agentsByProject {
                if let idx = agents.firstIndex(where: { $0.id == payload.agentId }) {
                    agents[idx].status = .running
                    agentsByProject[projectId] = agents
                    break
                }
            }

        case .permissionRequest(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Permission request: agent=\(payload.agentId) tool=\(payload.toolName) id=\(payload.requestId)")
            let perm = PermissionRequest(
                requestId: payload.requestId,
                agentId: payload.agentId,
                toolName: payload.toolName,
                toolInput: payload.toolInput,
                message: payload.message,
                timeout: payload.timeout,
                deadline: payload.deadline
            )
            for (key, existing) in pendingPermissions where existing.agentId == payload.agentId {
                pendingPermissions.removeValue(forKey: key)
            }
            pendingPermissions[perm.id] = perm

        case .permissionResponse(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Permission response: \(payload.requestId)")
            pendingPermissions.removeValue(forKey: payload.requestId)

        case .canvasState(let payload):
            AppLog.shared.info("Instance", "\(logPrefix) Canvas state: project=\(payload.projectId) canvas=\(payload.state.canvasId) views=\(payload.state.views.count)")
            canvasByProject[payload.projectId] = payload.state

        case .disconnected(let error):
            AppLog.shared.warn("Instance", "\(logPrefix) WS disconnected: \(error?.localizedDescription ?? "clean close")")
            if connectionState.isConnected || isReconnecting {
                await attemptReconnect()
            }
        }
    }

    private var isReconnecting: Bool {
        if case .reconnecting = connectionState { return true }
        return false
    }

    private func attemptReconnect() async {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            AppLog.shared.error("Instance", "\(logPrefix) Max reconnect attempts (\(Self.maxReconnectAttempts)) reached — giving up")
            disconnectInternal()
            lastError = "Lost connection to server"
            return
        }

        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        AppLog.shared.warn("Instance", "\(logPrefix) Reconnecting attempt \(reconnectAttempt)/\(Self.maxReconnectAttempts), delay=\(delay)s")

        try? await Task.sleep(for: .seconds(delay))

        guard let apiClient, let token else {
            AppLog.shared.error("Instance", "\(logPrefix) Cannot reconnect: no apiClient or token")
            disconnectInternal()
            return
        }

        do {
            _ = try await apiClient.getStatus(token: token)
            AppLog.shared.info("Instance", "\(logPrefix) Reconnect status check passed — reconnecting WS")
            await connectWebSocket()
        } catch let error as APIError {
            if case .unauthorized = error {
                AppLog.shared.error("Instance", "\(logPrefix) Token expired during reconnect")
                disconnectInternal()
                lastError = "Session expired. Please re-pair."
            } else {
                AppLog.shared.warn("Instance", "\(logPrefix) Reconnect status check failed: \(error) — will retry")
                await attemptReconnect()
            }
        }
    }

    // MARK: - Agent Actions

    func spawnQuickAgent(
        projectId: String, prompt: String,
        orchestrator: String? = nil, model: String? = nil,
        freeAgentMode: Bool? = nil, systemPrompt: String? = nil
    ) async throws {
        guard let apiClient, let token else { return }
        AppLog.shared.info("Instance", "\(logPrefix) Spawning quick agent in project=\(projectId)")
        let request = SpawnQuickAgentRequest(
            prompt: prompt, orchestrator: orchestrator,
            model: model, freeAgentMode: freeAgentMode,
            systemPrompt: systemPrompt
        )
        let response = try await apiClient.spawnQuickAgent(projectId: projectId, request: request, token: token)
        addQuickAgentFromResponse(response)
    }

    func spawnQuickAgentUnder(
        parentAgentId: String, prompt: String,
        model: String? = nil, freeAgentMode: Bool? = nil,
        systemPrompt: String? = nil
    ) async throws {
        guard let apiClient, let token else { return }
        AppLog.shared.info("Instance", "\(logPrefix) Spawning quick agent under parent=\(parentAgentId)")
        let request = SpawnQuickAgentRequest(
            prompt: prompt, orchestrator: nil,
            model: model, freeAgentMode: freeAgentMode,
            systemPrompt: systemPrompt
        )
        let response = try await apiClient.spawnQuickAgentUnder(parentAgentId: parentAgentId, request: request, token: token)
        addQuickAgentFromResponse(response)
    }

    private func addQuickAgentFromResponse(_ response: SpawnQuickAgentResponse) {
        if let existing = quickAgentsByProject[response.projectId],
           existing.contains(where: { $0.id == response.id }) { return }
        let qa = QuickAgent(
            id: response.id, name: response.name, kind: response.kind,
            status: AgentStatus(rawValue: response.status),
            mission: response.prompt, prompt: response.prompt,
            model: response.model, detailedStatus: nil,
            orchestrator: response.orchestrator,
            parentAgentId: response.parentAgentId,
            projectId: response.projectId,
            freeAgentMode: response.freeAgentMode
        )
        var agents = quickAgentsByProject[response.projectId] ?? []
        agents.append(qa)
        quickAgentsByProject[response.projectId] = agents
    }

    func cancelQuickAgent(agentId: String) async throws {
        guard let apiClient, let token else { return }
        AppLog.shared.info("Instance", "\(logPrefix) Cancelling quick agent \(agentId)")
        let response = try await apiClient.cancelAgent(agentId: agentId, token: token)
        for (projectId, var agents) in quickAgentsByProject {
            if let idx = agents.firstIndex(where: { $0.id == response.id }) {
                agents[idx].status = AgentStatus(rawValue: response.status)
                quickAgentsByProject[projectId] = agents
                break
            }
        }
    }

    func removeQuickAgent(agentId: String) {
        for (projectId, var agents) in quickAgentsByProject {
            if let idx = agents.firstIndex(where: { $0.id == agentId }) {
                agents.remove(at: idx)
                quickAgentsByProject[projectId] = agents
                break
            }
        }
    }

    func wakeAgent(agentId: String, message: String, model: String? = nil) async throws {
        guard let apiClient, let token else { return }
        AppLog.shared.info("Instance", "\(logPrefix) Waking agent \(agentId)")
        let request = WakeAgentRequest(message: message, model: model)
        _ = try await apiClient.wakeAgent(agentId: agentId, request: request, token: token)
    }

    func spawnShell(sessionId: String, projectId: String) {
        guard let webSocket else {
            AppLog.shared.warn("Instance", "\(logPrefix) Cannot spawn shell: no WebSocket")
            return
        }
        AppLog.shared.info("Instance", "\(logPrefix) Spawning shell: session=\(sessionId) project=\(projectId)")
        let msg = SpawnShellMessage(
            type: "pty:spawn-shell",
            payload: SpawnShellPayload(sessionId: sessionId, projectId: projectId)
        )
        webSocket.send(msg)
    }

    func sendPtyInput(sessionId: String, data: String) {
        guard let webSocket else { return }
        let msg = PtyInputMessage(
            type: "pty:input",
            payload: PtyInputPayload(agentId: sessionId, data: data)
        )
        webSocket.send(msg)
    }

    func sendPtyResize(sessionId: String, cols: Int, rows: Int) {
        guard let webSocket else { return }
        let msg = PtyResizeMessage(
            type: "pty:resize",
            payload: PtyResizePayload(agentId: sessionId, cols: cols, rows: rows)
        )
        webSocket.send(msg)
    }

    func sendMessage(agentId: String, message: String) async throws {
        // Send via pty:input on the WebSocket (no REST /message endpoint in v2)
        guard let webSocket else {
            AppLog.shared.warn("Instance", "\(logPrefix) Cannot send message: no WebSocket")
            return
        }
        AppLog.shared.info("Instance", "\(logPrefix) Sending message to agent \(agentId) via pty:input")
        let msg = PtyInputMessage(
            type: "pty:input",
            payload: PtyInputPayload(agentId: agentId, data: message + "\r")
        )
        webSocket.send(msg)
    }

    func respondToPermission(agentId: String, requestId: String, allow: Bool) async throws {
        guard let apiClient, let token else { return }
        AppLog.shared.info("Instance", "\(logPrefix) Permission response: agent=\(agentId) request=\(requestId) allow=\(allow)")

        let agent = durableAgent(byId: agentId)
        let isStructured = agent?.executionMode == "structured"
        AppLog.shared.debug("Instance", "\(logPrefix) Agent execution mode: \(agent?.executionMode ?? "nil"), isStructured=\(isStructured)")

        if isStructured {
            let request = StructuredPermissionRequest(
                requestId: requestId, approved: allow, reason: nil
            )
            _ = try await apiClient.respondToStructuredPermission(agentId: agentId, request: request, token: token)
        } else {
            let request = PermissionResponseRequest(
                requestId: requestId, decision: allow ? "allow" : "deny"
            )
            _ = try await apiClient.respondToPermission(agentId: agentId, request: request, token: token)
        }

        pendingPermissions.removeValue(forKey: requestId)
    }

    // MARK: - Icon Cache

    func fetchIcons() async {
        guard let apiClient, let token else { return }

        var agentIconCount = 0
        var projectIconCount = 0

        for agents in agentsByProject.values {
            for agent in agents where agent.icon != nil {
                if agentIcons[agent.id] != nil { continue }
                if let data = await apiClient.fetchAgentIcon(agentId: agent.id, token: token) {
                    agentIcons[agent.id] = data
                    agentIconCount += 1
                }
            }
        }

        for project in projects where project.icon != nil {
            if projectIcons[project.id] != nil { continue }
            if let data = await apiClient.fetchProjectIcon(projectId: project.id, token: token) {
                projectIcons[project.id] = data
                projectIconCount += 1
            }
        }

        if agentIconCount > 0 || projectIconCount > 0 {
            AppLog.shared.info("Instance", "\(logPrefix) Fetched \(agentIconCount) agent icon(s), \(projectIconCount) project icon(s)")
        }
    }

    // MARK: - Private

    private func disconnectInternal() {
        AppLog.shared.info("Instance", "\(logPrefix) Disconnecting (clearing all state)")
        wsStreamTask?.cancel()
        wsStreamTask = nil
        webSocket?.disconnect()
        webSocket = nil
        connectionState = .disconnected
        projects = []
        agentsByProject = [:]
        quickAgentsByProject = [:]
        activityByAgent = [:]
        structuredEventsByAgent = [:]
        pendingPermissions = [:]
        ptyBufferByAgent = [:]
        agentIcons = [:]
        projectIcons = [:]
        canvasByProject = [:]
        serverName = ""
        orchestrators = [:]
        token = nil
        apiClient = nil
        reconnectAttempt = 0
        lastSeq = nil
        isReplaying = false
    }
}
