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

    struct InstanceProject {
        let instance: ServerInstance
        let project: Project
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
        activeInstance?.pendingPermissions ?? [:]
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
        return merged
    }

    var projectIcons: [String: Data] {
        var merged: [String: Data] = [:]
        for inst in connectedInstances {
            merged.merge(inst.projectIcons) { _, new in new }
        }
        return merged
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

    // MARK: - Pairing

    func pair(server: DiscoveredServer, pin: String) async throws {
        switch server.protocolVersion {
        case .v1:
            try await pairV1(server: server, pin: pin)
        case .v2:
            try await pairV2(server: server, pin: pin)
        }
    }

    private func pairV1(server: DiscoveredServer, pin: String) async throws {
        let client = AnnexAPIClient.v1(host: server.host, port: server.port)
        let response = try await client.pair(pin: pin)

        let instanceId = ServerInstanceID(value: UUID().uuidString)
        let config = ServerProtocol.v1(host: server.host, port: server.port)
        let inst = ServerInstance(id: instanceId, protocolConfig: config)

        KeychainHelper.saveInstance(
            id: instanceId, token: response.token, protocolConfig: config
        )

        instances.append(inst)
        activeInstanceID = instanceId
        await inst.connect(token: response.token)
    }

    private func pairV2(server: DiscoveredServer, pin: String) async throws {
        guard let pairingPort = server.pairingPort else {
            throw APIError.invalidURL
        }

        let identity = CryptoIdentity.loadOrCreate()
        let client = AnnexAPIClient.v2Pairing(host: server.host, pairingPort: pairingPort)

        let response = try await client.pairV2(
            pin: pin,
            publicKey: identity.publicKeyBase64,
            alias: UIDevice.current.name,
            icon: "phone",
            color: "blue"
        )

        let instanceId = ServerInstanceID(value: response.fingerprint)
        let config = ServerProtocol.v2(
            host: server.host, mainPort: server.port,
            pairingPort: pairingPort, fingerprint: response.fingerprint
        )
        let inst = ServerInstance(id: instanceId, protocolConfig: config)

        KeychainHelper.saveInstance(
            id: instanceId, token: response.token,
            protocolConfig: config, serverPublicKey: response.publicKey
        )

        instances.append(inst)
        activeInstanceID = instanceId
        await inst.connect(token: response.token)
    }

    // MARK: - Session Restore

    func restoreAllSessions() async {
        KeychainHelper.migrateIfNeeded()
        let saved = KeychainHelper.loadAllInstances()
        for s in saved {
            let inst = ServerInstance(id: s.id, protocolConfig: s.protocolConfig)
            instances.append(inst)
            await inst.connect(token: s.token)
        }
        if activeInstanceID == nil {
            activeInstanceID = connectedInstances.first?.id ?? instances.first?.id
        }
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
            protocolConfig: .v1(host: "192.168.1.10", port: 3000)
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
            protocolConfig: .v1(host: "192.168.1.20", port: 3000)
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

        instances = [inst1, inst2]
        activeInstanceID = inst1.id
        hasCompletedOnboarding = true
    }
}
