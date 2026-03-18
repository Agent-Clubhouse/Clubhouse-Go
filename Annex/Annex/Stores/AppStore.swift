import Foundation

enum ConnectionState: Sendable {
    case disconnected
    case discovering
    case pairing
    case connecting
    case connected
    case reconnecting(attempt: Int)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .discovering: return "Searching..."
        case .pairing: return "Pairing..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let n): return "Reconnecting (\(n))..."
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@Observable final class AppStore {
    // MARK: - State

    var projects: [Project] = []
    var agentsByProject: [String: [DurableAgent]] = [:]
    var quickAgentsByProject: [String: [QuickAgent]] = [:]
    var activityByAgent: [String: [HookEvent]] = [:]
    var pendingPermissions: [String: PermissionRequest] = [:]  // keyed by requestId
    var ptyBufferByAgent: [String: String] = [:]
    var isPaired: Bool = false
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    var theme: ThemeColors = .mock
    var serverName: String = ""
    var orchestrators: [String: OrchestratorEntry] = [:]
    var connectionState: ConnectionState = .disconnected
    var lastError: String?

    /// Structured event streams per agent, keyed by agentId.
    var structuredEventsByAgent: [String: [StructuredEvent]] = [:]

    // MARK: - Networking

    private(set) var apiClient: AnnexAPIClient?
    private var webSocket: WebSocketClient?
    private var wsStreamTask: Task<Void, Never>?
    private var token: String?
    private var reconnectAttempt = 0
    private var lastSeq: Int?
    private var isReplaying = false
    private static let maxReconnectAttempts = 10

    // MARK: - Queries

    func agents(for project: Project) -> [DurableAgent] {
        agentsByProject[project.id] ?? []
    }

    /// All durable agents across every project, sorted by status (active first).
    var allAgents: [DurableAgent] {
        agentsByProject.values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                lhs.statusSortOrder < rhs.statusSortOrder
            }
    }

    /// Look up the project that owns a given agent.
    func project(for agent: DurableAgent) -> Project? {
        for project in projects {
            if agentsByProject[project.id]?.contains(where: { $0.id == agent.id }) == true {
                return project
            }
        }
        return nil
    }

    func allQuickAgents(for project: Project) -> [QuickAgent] {
        // Merge project-level quick agents with those nested under durable agents
        let nested = agents(for: project).flatMap { $0.quickAgents ?? [] }
        let standalone = quickAgentsByProject[project.id] ?? []
        // Deduplicate by ID, preferring standalone (more up-to-date from WS events)
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

    /// Look up a durable agent by ID across all projects.
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

    // MARK: - Pairing

    func pair(host: String, port: UInt16, pin: String) async throws {
        connectionState = .pairing
        lastError = nil
        let client = AnnexAPIClient(host: host, port: port)
        print("[Annex] Pairing with host=\(host) port=\(port) baseURL=\(client.baseURL)")

        do {
            let response = try await client.pair(pin: pin)
            self.token = response.token
            self.apiClient = client
            KeychainHelper.saveToken(response.token)
            KeychainHelper.saveServer(host: host, port: port)
            await connectAfterPairing()
        } catch let error as APIError {
            connectionState = .disconnected
            lastError = error.userMessage
            print("[Annex] Pair failed: \(error) — \(error.userMessage)")
            throw error
        }
    }

    /// Attempt to restore a previous session from Keychain.
    func restoreSession() async {
        guard let token = KeychainHelper.loadToken(),
              let server = KeychainHelper.loadServer() else { return }

        self.token = token
        let client = AnnexAPIClient(host: server.host, port: server.port)
        self.apiClient = client

        connectionState = .connecting
        do {
            let status = try await client.getStatus(token: token)
            serverName = status.deviceName
            await connectWebSocket()
        } catch {
            // Token invalid or server unreachable — clear and go to pairing
            KeychainHelper.clearAll()
            self.token = nil
            self.apiClient = nil
            connectionState = .disconnected
        }
    }

    // MARK: - Connection Lifecycle

    private func connectAfterPairing() async {
        guard let apiClient, let token else {
            print("[Annex] connectAfterPairing: no apiClient or token")
            return
        }
        connectionState = .connecting

        do {
            let status = try await apiClient.getStatus(token: token)
            print("[Annex] Status: device=\(status.deviceName) agents=\(status.agentCount)")
            serverName = status.deviceName
            isPaired = true
            await connectWebSocket()
        } catch {
            print("[Annex] connectAfterPairing failed: \(error)")
            connectionState = .disconnected
            lastError = "Failed to connect after pairing"
        }
    }

    private func connectWebSocket() async {
        guard let apiClient, let token else { return }
        wsStreamTask?.cancel()
        webSocket?.disconnect()

        guard let url = try? apiClient.webSocketURL(token: token) else { return }
        let ws = WebSocketClient(url: url)
        self.webSocket = ws

        let stream = ws.connect()
        let previousSeq = lastSeq
        reconnectAttempt = 0
        isReplaying = false

        wsStreamTask = Task {
            for await seqEvent in stream {
                // Track seq for replay
                if let seq = seqEvent.seq {
                    self.lastSeq = seq
                }
                await handleWSEvent(seqEvent.event)
            }
        }

        // If we had a previous seq, request replay of missed events
        if let since = previousSeq {
            let replayReq = ReplayRequest(type: "replay", since: since)
            ws.send(replayReq)
            print("[Annex] Sent replay request since seq=\(since)")
        }
    }

    private func handleWSEvent(_ event: WSEvent) async {
        switch event {
        case .snapshot(let payload):
            print("[Annex] Snapshot: \(payload.projects.count) projects, \(payload.agents.count) agent groups")
            projects = payload.projects
            agentsByProject = payload.agents
            quickAgentsByProject = payload.quickAgents ?? [:]
            theme = payload.theme
            orchestrators = payload.orchestrators
            activityByAgent = [:]
            ptyBufferByAgent = [:]
            structuredEventsByAgent = [:]
            // Track lastSeq from snapshot for reconnection replay
            if let seq = payload.lastSeq {
                lastSeq = seq
            }
            // Populate pending permissions from snapshot
            pendingPermissions = [:]
            if let perms = payload.pendingPermissions {
                for perm in perms {
                    pendingPermissions[perm.id] = perm
                }
            }
            connectionState = .connected
            isPaired = true
            Task { await fetchIcons() }

        case .ptyData(let payload):
            var buf = ptyBufferByAgent[payload.agentId] ?? ""
            buf.append(payload.data)
            // Cap at ~64KB to avoid unbounded growth
            if buf.count > 65_536 {
                buf = String(buf.suffix(49_152))
            }
            ptyBufferByAgent[payload.agentId] = buf

        case .ptyExit:
            // Could update agent status, but snapshot updates will cover this
            break

        case .hookEvent(let payload):
            print("[Annex] Hook event: agent=\(payload.agentId) kind=\(payload.event.kind)")
            let hookEvent = payload.event.toHookEvent(agentId: payload.agentId)
            var events = activityByAgent[payload.agentId] ?? []
            events.append(hookEvent)
            activityByAgent[payload.agentId] = events

        case .themeChanged(let newTheme):
            theme = newTheme

        case .structuredEvent(let payload):
            print("[Annex] Structured event: agent=\(payload.agentId) type=\(payload.event.type)")
            var events = structuredEventsByAgent[payload.agentId] ?? []
            events.append(payload.event)
            structuredEventsByAgent[payload.agentId] = events

        case .replayGap(let payload):
            print("[Annex] Replay gap: oldest=\(payload.oldestAvailable) last=\(payload.lastSeq)")
            // Our seq is too old — the snapshot we already received is our fresh state.
            // Update lastSeq to the server's current value.
            lastSeq = payload.lastSeq
            isReplaying = false

        case .replayStart(let payload):
            print("[Annex] Replay start: from=\(payload.fromSeq) to=\(payload.toSeq) count=\(payload.count)")
            isReplaying = true

        case .replayEnd:
            print("[Annex] Replay end")
            isReplaying = false

        case .agentSpawned(let payload):
            print("[Annex] Agent spawned: \(payload.id) in project \(payload.projectId)")
            // Skip if optimistic update already added this agent
            if let existing = quickAgentsByProject[payload.projectId],
               existing.contains(where: { $0.id == payload.id }) { break }
            let qa = QuickAgent(
                id: payload.id,
                name: payload.name,
                kind: payload.kind,
                status: AgentStatus(rawValue: payload.status),
                mission: payload.prompt,
                prompt: payload.prompt,
                model: payload.model,
                detailedStatus: nil,
                orchestrator: payload.orchestrator,
                parentAgentId: payload.parentAgentId,
                projectId: payload.projectId,
                freeAgentMode: payload.freeAgentMode
            )
            var agents = quickAgentsByProject[payload.projectId] ?? []
            agents.append(qa)
            quickAgentsByProject[payload.projectId] = agents

        case .agentStatus(let payload):
            print("[Annex] Agent status: \(payload.id) → \(payload.status)")
            guard let projectId = payload.projectId else { break }
            if var agents = quickAgentsByProject[projectId],
               let idx = agents.firstIndex(where: { $0.id == payload.id }) {
                agents[idx].status = AgentStatus(rawValue: payload.status)
                quickAgentsByProject[projectId] = agents
            }

        case .agentCompleted(let payload):
            print("[Annex] Agent completed: \(payload.id) exit=\(payload.exitCode ?? -1)")
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
            print("[Annex] Agent woken: \(payload.agentId) source=\(payload.source ?? "unknown")")
            // Update the durable agent's status to running
            for (projectId, var agents) in agentsByProject {
                if let idx = agents.firstIndex(where: { $0.id == payload.agentId }) {
                    agents[idx].status = .running
                    agentsByProject[projectId] = agents
                    break
                }
            }

        case .permissionRequest(let payload):
            print("[Annex] Permission request: agent=\(payload.agentId) tool=\(payload.toolName) requestId=\(payload.requestId)")
            let perm = PermissionRequest(
                requestId: payload.requestId,
                agentId: payload.agentId,
                toolName: payload.toolName,
                toolInput: payload.toolInput,
                message: payload.message,
                timeout: payload.timeout,
                deadline: payload.deadline
            )
            // Remove any stale permission for this agent before adding new one
            for (key, existing) in pendingPermissions where existing.agentId == payload.agentId {
                pendingPermissions.removeValue(forKey: key)
            }
            pendingPermissions[perm.id] = perm

        case .permissionResponse(let payload):
            print("[Annex][WS] permission:response — requestId=\(payload.requestId) decision=\(payload.decision)")
            pendingPermissions.removeValue(forKey: payload.requestId)

        case .disconnected(let error):
            print("[Annex] WS disconnected: \(String(describing: error))")
            if isPaired {
                await attemptReconnect()
            }
        }
    }

    private func attemptReconnect() async {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            // Exhausted retries — return to pairing
            disconnectInternal()
            lastError = "Lost connection to server"
            return
        }

        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)

        // Exponential backoff: 1s, 2s, 4s, 8s... capped at 30s
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        try? await Task.sleep(for: .seconds(delay))

        guard isPaired else { return }

        // Check if token is still valid
        guard let apiClient, let token else {
            disconnectInternal()
            return
        }

        do {
            _ = try await apiClient.getStatus(token: token)
            await connectWebSocket()
        } catch let error as APIError {
            if case .unauthorized = error {
                // Token revoked — must re-pair
                disconnectInternal()
                lastError = "Session expired. Please re-pair."
            } else {
                // Network issue — keep trying
                await attemptReconnect()
            }
        }
    }

    // MARK: - Agent Actions

    func spawnQuickAgent(
        projectId: String,
        prompt: String,
        orchestrator: String? = nil,
        model: String? = nil,
        freeAgentMode: Bool? = nil,
        systemPrompt: String? = nil
    ) async throws {
        guard let apiClient, let token else { return }
        let request = SpawnQuickAgentRequest(
            prompt: prompt,
            orchestrator: orchestrator,
            model: model,
            freeAgentMode: freeAgentMode,
            systemPrompt: systemPrompt
        )
        let response = try await apiClient.spawnQuickAgent(projectId: projectId, request: request, token: token)
        addQuickAgentFromResponse(response)
    }

    func spawnQuickAgentUnder(
        parentAgentId: String,
        prompt: String,
        model: String? = nil,
        freeAgentMode: Bool? = nil,
        systemPrompt: String? = nil
    ) async throws {
        guard let apiClient, let token else { return }
        let request = SpawnQuickAgentRequest(
            prompt: prompt,
            orchestrator: nil,
            model: model,
            freeAgentMode: freeAgentMode,
            systemPrompt: systemPrompt
        )
        let response = try await apiClient.spawnQuickAgentUnder(parentAgentId: parentAgentId, request: request, token: token)
        addQuickAgentFromResponse(response)
    }

    private func addQuickAgentFromResponse(_ response: SpawnQuickAgentResponse) {
        // Skip if WS event already added this agent
        if let existing = quickAgentsByProject[response.projectId],
           existing.contains(where: { $0.id == response.id }) { return }

        let qa = QuickAgent(
            id: response.id,
            name: response.name,
            kind: response.kind,
            status: AgentStatus(rawValue: response.status),
            mission: response.prompt,
            prompt: response.prompt,
            model: response.model,
            detailedStatus: nil,
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
        let response = try await apiClient.cancelAgent(agentId: agentId, token: token)
        // Optimistically update status from response
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
        let request = WakeAgentRequest(message: message, model: model)
        _ = try await apiClient.wakeAgent(agentId: agentId, request: request, token: token)
        // State updated via agent:woken WS event
    }

    func sendMessage(agentId: String, message: String) async throws {
        guard let apiClient, let token else { return }
        let request = SendMessageRequest(message: message)
        _ = try await apiClient.sendMessage(agentId: agentId, request: request, token: token)
    }

    func respondToPermission(agentId: String, requestId: String, allow: Bool) async throws {
        print("[Annex][Perm] respondToPermission — agent=\(agentId) requestId=\(requestId) allow=\(allow)")
        guard let apiClient, let token else {
            print("[Annex][Perm] ❌ BAIL: apiClient=\(apiClient != nil) token=\(token != nil)")
            return
        }

        // Route to the correct endpoint based on agent's execution mode
        let agent = durableAgent(byId: agentId)
        let isStructured = agent?.executionMode == "structured"

        if isStructured {
            let request = StructuredPermissionRequest(
                requestId: requestId,
                approved: allow,
                reason: nil
            )
            print("[Annex][Perm] POST /api/v1/agents/\(agentId)/structured-permission …")
            let response = try await apiClient.respondToStructuredPermission(agentId: agentId, request: request, token: token)
            print("[Annex][Perm] ✅ Structured response: ok=\(response.ok) approved=\(response.approved)")
        } else {
            let request = PermissionResponseRequest(
                requestId: requestId,
                decision: allow ? "allow" : "deny"
            )
            print("[Annex][Perm] POST /api/v1/agents/\(agentId)/permission-response …")
            let response = try await apiClient.respondToPermission(agentId: agentId, request: request, token: token)
            print("[Annex][Perm] ✅ Response: ok=\(response.ok)")
        }

        // Remove from pending after successful response
        pendingPermissions.removeValue(forKey: requestId)
    }

    // MARK: - Icon Cache

    var agentIcons: [String: Data] = [:]
    var projectIcons: [String: Data] = [:]

    func agentIconURL(agentId: String) -> URL? {
        guard let apiClient, let token else { return nil }
        return URL(string: "\(apiClient.baseURL)/api/v1/icons/agent/\(agentId)?token=\(token)")
    }

    func projectIconURL(projectId: String) -> URL? {
        guard let apiClient, let token else { return nil }
        return URL(string: "\(apiClient.baseURL)/api/v1/icons/project/\(projectId)?token=\(token)")
    }

    func fetchIcons() async {
        guard let apiClient, let token else { return }

        // Fetch agent icons for agents that have an icon field set
        for agents in agentsByProject.values {
            for agent in agents where agent.icon != nil {
                if agentIcons[agent.id] != nil { continue }
                if let data = await apiClient.fetchAgentIcon(agentId: agent.id, token: token) {
                    agentIcons[agent.id] = data
                }
            }
        }

        // Fetch project icons for projects that have an icon field set
        for project in projects where project.icon != nil {
            if projectIcons[project.id] != nil { continue }
            if let data = await apiClient.fetchProjectIcon(projectId: project.id, token: token) {
                projectIcons[project.id] = data
            }
        }
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    // MARK: - Disconnect & Reset

    func disconnect() {
        disconnectInternal()
        KeychainHelper.clearAll()
    }

    /// Full reset: disconnect, clear credentials, and return to welcome screen.
    func resetApp() {
        disconnect()
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private func disconnectInternal() {
        wsStreamTask?.cancel()
        wsStreamTask = nil
        webSocket?.disconnect()
        webSocket = nil
        isPaired = false
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
        serverName = ""
        orchestrators = [:]
        token = nil
        apiClient = nil
        reconnectAttempt = 0
        lastSeq = nil
        isReplaying = false
    }

    // MARK: - Mock Data (for previews)

    func loadMockData() {
        projects = MockData.projects
        agentsByProject = MockData.agents
        activityByAgent = MockData.activity
        serverName = "Clubhouse on Mason's Mac"
        orchestrators = MockData.orchestrators
        isPaired = true
        connectionState = .connected
    }
}
