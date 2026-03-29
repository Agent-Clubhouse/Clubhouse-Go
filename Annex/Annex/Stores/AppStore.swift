import Foundation
import UIKit

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
    // MARK: - Instance Management

    var instances: [ServerInstance] = []
    var activeInstanceID: ServerInstanceID?
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    let iconCache = IconCache()

    // MARK: - Instance Accessors

    var activeInstance: ServerInstance? {
        instances.first { $0.id == activeInstanceID }
    }

    var connectedInstances: [ServerInstance] {
        instances.filter { $0.connectionState.isConnected }
    }

    var hasConnectedInstance: Bool {
        instances.contains { $0.connectionState.isConnected }
    }

    /// Aggregate replay state across all connected instances.
    var replayState: ReplayState {
        for inst in connectedInstances {
            if inst.replayState.isReplaying { return inst.replayState }
        }
        for inst in connectedInstances {
            if inst.replayState.hasGap { return inst.replayState }
        }
        return .idle
    }

    func instanceByID(_ id: ServerInstanceID) -> ServerInstance? {
        instances.first { $0.id == id }
    }

    // MARK: - Aggregate Queries (cross-instance)

    struct InstanceAgent {
        let instance: ServerInstance
        let agent: DurableAgent
    }

    struct InstancePermission: Identifiable {
        let instance: ServerInstance
        let permission: PermissionRequest
        var id: String { "\(instance.id.value):\(permission.id)" }
    }

    struct InstanceProject: Identifiable {
        let instance: ServerInstance
        let project: Project
        var id: String { "\(instance.id.value):\(project.id)" }
    }

    var allAgentsAcrossInstances: [InstanceAgent] {
        connectedInstances.flatMap { inst in
            inst.allAgents.map { InstanceAgent(instance: inst, agent: $0) }
        }
        .sorted { $0.agent.statusSortOrder < $1.agent.statusSortOrder }
    }

    var allPendingPermissions: [InstancePermission] {
        connectedInstances.flatMap { inst in
            inst.pendingPermissions.values.map { InstancePermission(instance: inst, permission: $0) }
        }
    }

    var allProjects: [InstanceProject] {
        connectedInstances.flatMap { inst in
            inst.projects.map { InstanceProject(instance: inst, project: $0) }
        }
    }

    // MARK: - Instance Lookup

    func instance(for agentId: String) -> ServerInstance? {
        connectedInstances.first { $0.durableAgent(byId: agentId) != nil || $0.quickAgent(byId: agentId) != nil }
    }

    func instance(for project: Project) -> ServerInstance? {
        connectedInstances.first { $0.projects.contains(where: { $0.id == project.id }) }
    }

    func instance(forProject projectId: String) -> ServerInstance? {
        connectedInstances.first { $0.projects.contains(where: { $0.id == projectId }) }
    }

    // MARK: - Backward-Compatible Shims
    // Existing views use store.projects, store.agentsByProject, etc.
    // These delegate to the active instance so views need minimal changes.

    var isPaired: Bool { hasConnectedInstance }

    var connectionState: ConnectionState {
        activeInstance?.connectionState ?? .disconnected
    }

    var lastError: String? {
        activeInstance?.lastError
    }

    var theme: ThemeColors {
        activeInstance?.theme ?? instances.first?.theme ?? .mock
    }

    var serverName: String {
        activeInstance?.serverName ?? ""
    }

    var orchestrators: [String: OrchestratorEntry] {
        // Merge orchestrators from all connected instances
        var merged: [String: OrchestratorEntry] = [:]
        for inst in connectedInstances {
            merged.merge(inst.orchestrators) { _, new in new }
        }
        return merged
    }

    var projects: [Project] {
        activeInstance?.projects ?? []
    }

    var agentsByProject: [String: [DurableAgent]] {
        activeInstance?.agentsByProject ?? [:]
    }

    var quickAgentsByProject: [String: [QuickAgent]] {
        activeInstance?.quickAgentsByProject ?? [:]
    }

    var pendingPermissions: [String: PermissionRequest] {
        // Merge from all instances so cross-instance permission lookups work
        var merged: [String: PermissionRequest] = [:]
        for inst in connectedInstances {
            merged.merge(inst.pendingPermissions) { _, new in new }
        }
        return merged
    }

    var allAgents: [DurableAgent] {
        activeInstance?.allAgents ?? []
    }

    var apiClient: AnnexAPIClient? {
        activeInstance?.apiClient
    }

    var agentIcons: [String: Data] {
        var merged: [String: Data] = [:]
        for inst in connectedInstances {
            merged.merge(inst.agentIcons) { _, new in new }
        }
        // Populate icon cache as icons arrive from instances
        for (id, data) in merged {
            iconCache.storeIfNeeded(key: "agent:\(id)", data: data)
        }
        return merged
    }

    var projectIcons: [String: Data] {
        var merged: [String: Data] = [:]
        for inst in connectedInstances {
            merged.merge(inst.projectIcons) { _, new in new }
        }
        for (id, data) in merged {
            iconCache.storeIfNeeded(key: "project:\(id)", data: data)
        }
        return merged
    }

    /// Get cached agent icon Data, or nil if not available.
    func agentIconData(_ agentId: String) -> Data? {
        agentIcons[agentId]
    }

    /// Get cached project icon Data, or nil if not available.
    func projectIconData(_ projectId: String) -> Data? {
        projectIcons[projectId]
    }

    var allCanvasStates: [(instance: ServerInstance, projectId: String, canvas: CanvasState)] {
        connectedInstances.flatMap { inst in
            inst.canvasByProject.map { (instance: inst, projectId: $0.key, canvas: $0.value) }
        }
    }

    var totalAgentCount: Int {
        connectedInstances.reduce(0) { $0 + $1.totalAgentCount }
    }

    var runningAgentCount: Int {
        connectedInstances.reduce(0) { $0 + $1.runningAgentCount }
    }

    // MARK: - Delegating Queries

    func agents(for project: Project) -> [DurableAgent] {
        instance(for: project)?.agents(for: project) ?? []
    }

    func project(for agent: DurableAgent) -> Project? {
        for inst in connectedInstances {
            if let p = inst.project(for: agent) { return p }
        }
        return nil
    }

    func allQuickAgents(for project: Project) -> [QuickAgent] {
        instance(for: project)?.allQuickAgents(for: project) ?? []
    }

    func quickAgent(byId id: String) -> QuickAgent? {
        for inst in connectedInstances {
            if let qa = inst.quickAgent(byId: id) { return qa }
        }
        return nil
    }

    func activity(for agentId: String) -> [HookEvent] {
        instance(for: agentId)?.activity(for: agentId) ?? []
    }

    func structuredEvents(for agentId: String) -> [StructuredEvent] {
        instance(for: agentId)?.structuredEvents(for: agentId) ?? []
    }

    func durableAgent(byId agentId: String) -> DurableAgent? {
        for inst in connectedInstances {
            if let agent = inst.durableAgent(byId: agentId) { return agent }
        }
        return nil
    }

    func pendingPermission(for agentId: String) -> PermissionRequest? {
        instance(for: agentId)?.pendingPermission(for: agentId)
    }

    func ptyBuffer(for agentId: String) -> String {
        instance(for: agentId)?.ptyBuffer(for: agentId) ?? ""
    }

    func agentIconURL(agentId: String) -> URL? {
        instance(for: agentId)?.agentIconURL(agentId: agentId)
    }

    func projectIconURL(projectId: String) -> URL? {
        for inst in connectedInstances {
            if inst.projects.contains(where: { $0.id == projectId }) {
                return inst.projectIconURL(projectId: projectId)
            }
        }
        return nil
    }

    // MARK: - Delegating Agent Actions

    func spawnQuickAgent(
        projectId: String, prompt: String,
        orchestrator: String? = nil, model: String? = nil,
        freeAgentMode: Bool? = nil, systemPrompt: String? = nil
    ) async throws {
        guard let inst = connectedInstances.first(where: {
            $0.projects.contains { $0.id == projectId }
        }) else { return }
        try await inst.spawnQuickAgent(
            projectId: projectId, prompt: prompt, orchestrator: orchestrator,
            model: model, freeAgentMode: freeAgentMode, systemPrompt: systemPrompt
        )
    }

    func spawnQuickAgentUnder(
        parentAgentId: String, prompt: String,
        model: String? = nil, freeAgentMode: Bool? = nil,
        systemPrompt: String? = nil
    ) async throws {
        guard let inst = instance(for: parentAgentId) else { return }
        try await inst.spawnQuickAgentUnder(
            parentAgentId: parentAgentId, prompt: prompt,
            model: model, freeAgentMode: freeAgentMode, systemPrompt: systemPrompt
        )
    }

    func cancelQuickAgent(agentId: String) async throws {
        for inst in connectedInstances {
            if inst.quickAgent(byId: agentId) != nil {
                try await inst.cancelQuickAgent(agentId: agentId)
                return
            }
        }
    }

    func removeQuickAgent(agentId: String) {
        for inst in connectedInstances {
            if inst.quickAgent(byId: agentId) != nil {
                inst.removeQuickAgent(agentId: agentId)
                return
            }
        }
    }

    func wakeAgent(agentId: String, message: String, model: String? = nil) async throws {
        guard let inst = instance(for: agentId) else { return }
        try await inst.wakeAgent(agentId: agentId, message: message, model: model)
    }

    func sendMessage(agentId: String, message: String) async throws {
        guard let inst = instance(for: agentId) else { return }
        try await inst.sendMessage(agentId: agentId, message: message)
    }

    func respondToPermission(agentId: String, requestId: String, allow: Bool) async throws {
        guard let inst = instance(for: agentId) else { return }
        try await inst.respondToPermission(agentId: agentId, requestId: requestId, allow: allow)
    }

    func createDurableAgent(
        projectId: String, name: String, color: String?,
        model: String?, orchestrator: String?, freeAgentMode: Bool?
    ) async throws -> CreateDurableAgentResponse {
        guard let inst = connectedInstances.first(where: {
            $0.projects.contains { $0.id == projectId }
        }) else { throw APIError.projectNotFound }
        return try await inst.createDurableAgent(
            projectId: projectId, name: name, color: color,
            model: model, orchestrator: orchestrator, freeAgentMode: freeAgentMode
        )
    }

    func deleteAgent(agentId: String) async throws {
        guard let inst = instance(for: agentId) else { return }
        try await inst.deleteAgent(agentId: agentId)
    }

    // MARK: - Pairing

    func pair(server: DiscoveredServer, pin: String) async throws {
        let identity = CryptoIdentity.loadOrCreate()
        AppLog.shared.info("Pairing", "Pairing with \(server.name) (\(server.host):\(server.port)) pairingPort=\(server.pairingPort)")
        AppLog.shared.info("Pairing", "Our fingerprint=\(identity.fingerprint), publicKey=\(identity.publicKeyBase64.prefix(30))...")
        let client = AnnexAPIClient.v2Pairing(host: server.host, pairingPort: server.pairingPort)

        let response = try await client.pairV2(
            pin: pin,
            publicKey: identity.publicKeyBase64,
            alias: UIDevice.current.name,
            icon: "phone",
            color: "blue"
        )

        AppLog.shared.info("Pairing", "Paired: server=\(response.alias) fingerprint=\(response.fingerprint) token=\(response.token.prefix(8))...")
        let instanceId = ServerInstanceID(value: response.fingerprint)
        let config = ServerProtocol.v2(
            host: server.host, mainPort: server.port,
            pairingPort: server.pairingPort, fingerprint: response.fingerprint
        )
        AppLog.shared.info("Pairing", "Instance config: mainPort=\(server.port), pairingPort=\(server.pairingPort)")
        let inst = ServerInstance(id: instanceId, protocolConfig: config)
        inst.serverPublicKey = response.publicKey

        KeychainHelper.saveInstance(
            id: instanceId, token: response.token,
            protocolConfig: config, serverPublicKey: response.publicKey
        )

        instances.append(inst)
        activeInstanceID = instanceId
        AppLog.shared.info("Pairing", "v2 instance \(instanceId.value.prefix(12)) saved, connecting to main port...")
        await inst.connect(token: response.token)
    }

    // MARK: - Test Server (integration testing)

    func connectToTestServer(host: String, mainPort: UInt16, pairingPort: UInt16, pin: String) async {
        AppLog.shared.info("TestServer", "Connecting to test server at \(host):\(mainPort) (pairing: \(pairingPort))")

        // Pair with the test server
        let pairingClient = AnnexAPIClient.v2Pairing(host: host, pairingPort: pairingPort)
        do {
            let identity = CryptoIdentity.loadOrCreate()
            let response = try await pairingClient.pairV2(
                pin: pin,
                publicKey: identity.publicKeyBase64,
                alias: "Test Device",
                icon: "phone",
                color: "blue"
            )
            AppLog.shared.info("TestServer", "Paired: token=\(response.token.prefix(8))... fingerprint=\(response.fingerprint)")

            let instanceId = ServerInstanceID(value: response.fingerprint)
            let config = ServerProtocol.v2(
                host: host, mainPort: mainPort,
                pairingPort: pairingPort, fingerprint: response.fingerprint
            )
            let inst = ServerInstance(id: instanceId, protocolConfig: config)
            instances.append(inst)
            activeInstanceID = instanceId
            await inst.connect(token: response.token)
        } catch {
            AppLog.shared.error("TestServer", "Failed to connect: \(error)")
        }
    }

    // MARK: - Session Restore

    func restoreAllSessions() async {
        AppLog.shared.info("Restore", "Restoring saved sessions...")
        KeychainHelper.migrateServiceIfNeeded()
        let saved = KeychainHelper.loadAllInstances()
        AppLog.shared.info("Restore", "Found \(saved.count) saved instance(s)")
        for s in saved {
            AppLog.shared.info("Restore", "Restoring instance \(s.id.value.prefix(12)) (proto=\(s.protocolConfig.label))")
            let inst = ServerInstance(id: s.id, protocolConfig: s.protocolConfig)
            inst.serverPublicKey = s.serverPublicKey
            instances.append(inst)
            await inst.connect(token: s.token)
        }
        if activeInstanceID == nil {
            activeInstanceID = connectedInstances.first?.id ?? instances.first?.id
            AppLog.shared.info("Restore", "Active instance: \(activeInstanceID?.value.prefix(12) ?? "none")")
        }
        AppLog.shared.info("Restore", "Session restore complete: \(instances.count) instance(s), \(connectedInstances.count) connected")
    }

    // MARK: - Reconnect

    func reconnect(instanceId: ServerInstanceID) async {
        guard let inst = instanceByID(instanceId),
              let saved = KeychainHelper.loadInstance(id: instanceId) else { return }
        inst.serverPublicKey = saved.serverPublicKey
        await inst.connect(token: saved.token)
    }

    // MARK: - Disconnect & Reset

    func disconnect(instanceId: ServerInstanceID) {
        guard let inst = instanceByID(instanceId) else { return }
        inst.disconnect()
        KeychainHelper.deleteInstance(id: instanceId)
        instances.removeAll { $0.id == instanceId }
        if activeInstanceID == instanceId {
            activeInstanceID = connectedInstances.first?.id
        }
    }

    func disconnectAll() {
        for inst in instances { inst.disconnect() }
        instances.removeAll()
        KeychainHelper.clearAll()
        activeInstanceID = nil
    }

    func resetApp() {
        disconnectAll()
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    // MARK: - Mock Data

    func loadMockData() {
        let inst1 = ServerInstance(
            id: ServerInstanceID(value: "mock-desktop"),
            protocolConfig: .v2(host: "192.168.1.10", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99")
        )
        inst1.serverName = "Mason's Desktop"
        inst1.projects = [MockData.projects[0], MockData.projects[2]]
        inst1.agentsByProject = [
            "proj_001": MockData.agents["proj_001"]!,
            "proj_003": MockData.agents["proj_003"]!,
        ]
        inst1.activityByAgent = [
            "durable_1737000000000_abc123": MockData.activity["durable_1737000000000_abc123"]!,
            "durable_1737000000004_ds001": MockData.activity["durable_1737000000004_ds001"]!,
        ]
        inst1.orchestrators = ["claude-code": MockData.orchestrators["claude-code"]!]
        inst1.theme = .mock
        inst1.connectionState = .connected

        let inst2 = ServerInstance(
            id: ServerInstanceID(value: "mock-mini"),
            protocolConfig: .v2(host: "192.168.1.20", mainPort: 8443, pairingPort: 8080, fingerprint: "11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00")
        )
        inst2.serverName = "Mac Mini"
        inst2.projects = [MockData.projects[1]]
        inst2.agentsByProject = [
            "proj_002": MockData.agents["proj_002"]!,
        ]
        inst2.activityByAgent = [
            "durable_1737000000002_srv001": MockData.activity["durable_1737000000002_srv001"]!,
            "durable_1737000000003_srv003": MockData.activity["durable_1737000000003_srv003"]!,
        ]
        inst2.orchestrators = MockData.orchestrators
        inst2.pendingPermissions = [
            "perm_001": PermissionRequest(
                requestId: "perm_001", agentId: "durable_1737000000002_srv001",
                toolName: "Bash", toolInput: .object(["command": .string("npm test")]),
                message: "Run bash command: npm test",
                timeout: 120_000,
                deadline: Int(Date().timeIntervalSince1970 * 1000) + 90_000
            )
        ]
        inst2.theme = ThemeColors(
            base: "#24273a", mantle: "#1e2030", crust: "#181926",
            text: "#cad3f5", subtext0: "#a5adcb", subtext1: "#b8c0e0",
            surface0: "#363a4f", surface1: "#494d64", surface2: "#5b6078",
            accent: "#c6a0f6", link: "#c6a0f6",
            warning: "#eed49f", error: "#ed8796", info: "#91d7e3", success: "#a6da95"
        )
        inst2.connectionState = .connected

        // Mock canvas data on desktop instance
        inst1.canvasByProject["proj_001"] = CanvasState(
            canvasId: "canvas_001",
            name: "Architecture",
            views: [
                CanvasView(id: "cv_1", type: .agent, position: .init(x: -200, y: -100), size: .init(width: 160, height: 80),
                           title: "faithful-urchin", displayName: nil, zIndex: 1, metadata: nil,
                           agentId: "durable_1737000000000_abc123", projectId: "proj_001",
                           label: nil, autoCollapse: nil, pluginWidgetType: nil, pluginId: nil, themeId: nil, containedViewIds: nil),
                CanvasView(id: "cv_2", type: .anchor, position: .init(x: 50, y: -100), size: .init(width: 140, height: 60),
                           title: nil, displayName: nil, zIndex: 2, metadata: nil,
                           agentId: nil, projectId: nil,
                           label: "API Gateway", autoCollapse: false, pluginWidgetType: nil, pluginId: nil, themeId: nil, containedViewIds: nil),
                CanvasView(id: "cv_3", type: .plugin, position: .init(x: -80, y: 50), size: .init(width: 180, height: 80),
                           title: "Terminal", displayName: nil, zIndex: 3, metadata: nil,
                           agentId: nil, projectId: nil,
                           label: nil, autoCollapse: nil, pluginWidgetType: "terminal", pluginId: "plugin_term", themeId: nil, containedViewIds: nil),
                CanvasView(id: "cv_4", type: .zone, position: .init(x: -250, y: -150), size: .init(width: 500, height: 300),
                           title: "Development", displayName: nil, zIndex: 0, metadata: nil,
                           agentId: nil, projectId: nil,
                           label: nil, autoCollapse: nil, pluginWidgetType: nil, pluginId: nil, themeId: "blue", containedViewIds: ["cv_1", "cv_2", "cv_3"]),
            ],
            viewport: CanvasViewport(panX: 0, panY: 0, zoom: 1.0),
            nextZIndex: 5,
            zoomedViewId: nil,
            selectedViewId: nil,
            allCanvasTabs: [
                CanvasTab(id: "canvas_001", name: "Architecture"),
                CanvasTab(id: "canvas_002", name: "Deployments"),
            ],
            activeCanvasId: "canvas_001"
        )

        instances = [inst1, inst2]
        activeInstanceID = inst1.id
        hasCompletedOnboarding = true
    }
}
