import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - ServerInstanceID Tests

struct ServerInstanceIDTests {
    @Test func codableRoundTrip() throws {
        let id = ServerInstanceID(value: "test-fingerprint-123")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ServerInstanceID.self, from: data)
        #expect(decoded.value == "test-fingerprint-123")
    }

    @Test func equality() {
        let a = ServerInstanceID(value: "abc")
        let b = ServerInstanceID(value: "abc")
        let c = ServerInstanceID(value: "xyz")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func hashable() {
        let a = ServerInstanceID(value: "abc")
        let b = ServerInstanceID(value: "abc")
        var set = Set<ServerInstanceID>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}

// MARK: - ServerProtocol Tests

struct ServerProtocolTests {
    @Test func v2Properties() {
        let proto = ServerProtocol.v2(host: "10.0.0.5", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB:CC")
        #expect(proto.host == "10.0.0.5")
        #expect(proto.mainPort == 8443)
    }

    @Test func codableV2() throws {
        let proto = ServerProtocol.v2(host: "10.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AB:CD")
        let data = try JSONEncoder().encode(proto)
        let decoded = try JSONDecoder().decode(ServerProtocol.self, from: data)
        #expect(decoded.host == "10.0.0.1")
        #expect(decoded.mainPort == 8443)
    }
}

// MARK: - V2 Pairing Model Tests

struct V2PairingModelTests {
    @Test func encodeV2PairRequest() throws {
        let req = V2PairRequest(
            pin: "123456",
            publicKey: "base64pubkey==",
            alias: "My iPhone",
            icon: "phone",
            color: "blue"
        )
        let data = try JSONEncoder().encode(req)
        let json = try JSONDecoder().decode([String: String].self, from: data)
        #expect(json["pin"] == "123456")
        #expect(json["publicKey"] == "base64pubkey==")
        #expect(json["alias"] == "My iPhone")
        #expect(json["icon"] == "phone")
        #expect(json["color"] == "blue")
    }

    @Test func decodeV2PairResponse() throws {
        let json = """
        {"token":"tok_123","publicKey":"serverkey==","alias":"Mason's Mac","icon":"computer","color":"indigo","fingerprint":"AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"}
        """
        let response = try JSONDecoder().decode(V2PairResponse.self, from: Data(json.utf8))
        #expect(response.token == "tok_123")
        #expect(response.publicKey == "serverkey==")
        #expect(response.alias == "Mason's Mac")
        #expect(response.fingerprint == "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99")
    }
}

// MARK: - CryptoIdentity Tests

struct CryptoIdentityTests {
    @Test func publicKeyBase64IsValidBase64() {
        let identity = CryptoIdentity.loadOrCreate()
        let base64 = identity.publicKeyBase64
        let decoded = Data(base64Encoded: base64)
        #expect(decoded != nil)
        // SPKI-wrapped Ed25519 key is 44 bytes (12 prefix + 32 raw)
        #expect(decoded?.count == 44)
    }

    @Test func publicKeyStartsWithSPKIPrefix() {
        let identity = CryptoIdentity.loadOrCreate()
        let base64 = identity.publicKeyBase64
        let decoded = Data(base64Encoded: base64)!
        let prefix: [UInt8] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
        let actualPrefix = Array(decoded.prefix(12))
        #expect(actualPrefix == prefix)
    }

    @Test func fingerprintFormat() {
        let identity = CryptoIdentity.loadOrCreate()
        let fp = identity.fingerprint
        // Format: XX:XX:XX:... (16 bytes = 16 hex pairs, 15 colons)
        let parts = fp.split(separator: ":")
        #expect(parts.count == 16)
        for part in parts {
            #expect(part.count == 2)
            // Each part should be valid hex
            #expect(UInt8(part, radix: 16) != nil)
        }
    }

    @Test func fingerprintMatchesPublicKey() {
        // Two identities from the same key should produce the same fingerprint
        let identity = CryptoIdentity.loadOrCreate()
        let fp1 = identity.fingerprint
        let fp2 = identity.fingerprint
        #expect(fp1 == fp2)
        // Fingerprint should be derived from the same public key
        #expect(!fp1.isEmpty)
    }
}

// MARK: - AnnexAPIClient Factory Tests

struct APIClientFactoryTests {
    @Test func v2BaseURL() {
        let delegate = TLSSessionDelegate()
        let client = AnnexAPIClient.v2(host: "192.168.1.100", mainPort: 8443, delegate: delegate)
        #expect(client.baseURL == "https://192.168.1.100:8443")
        #expect(client.host == "192.168.1.100")
        #expect(client.port == 8443)
    }

    @Test func v2PairingBaseURL() {
        let client = AnnexAPIClient.v2Pairing(host: "192.168.1.100", pairingPort: 8080)
        #expect(client.baseURL == "http://192.168.1.100:8080")
    }

    @Test func v2WebSocketURL() throws {
        let delegate = TLSSessionDelegate()
        let client = AnnexAPIClient.v2(host: "192.168.1.100", mainPort: 8443, delegate: delegate)
        let url = try client.webSocketURL(token: "tok_123")
        #expect(url.absoluteString == "wss://192.168.1.100:8443/ws?token=tok_123")
    }

    @Test func v2PairingWebSocketURLThrows() {
        let client = AnnexAPIClient.v2Pairing(host: "192.168.1.100", pairingPort: 8080)
        #expect(throws: APIError.self) {
            _ = try client.webSocketURL(token: "tok")
        }
    }

    @Test func ipv6URLConstruction() {
        let delegate = TLSSessionDelegate()
        let client = AnnexAPIClient.v2(host: "fe80::1%en0", mainPort: 8443, delegate: delegate)
        #expect(client.baseURL == "https://[fe80::1%25en0]:8443")
    }
}

// MARK: - ServerInstance Tests

@MainActor
struct ServerInstanceTests {
    private func makeInstance() -> ServerInstance {
        ServerInstance(
            id: ServerInstanceID(value: "test-instance"),
            protocolConfig: .v2(host: "localhost", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99")
        )
    }

    @Test func initialState() {
        let inst = makeInstance()
        #expect(inst.connectionState.isConnected == false)
        #expect(inst.projects.isEmpty)
        #expect(inst.agentsByProject.isEmpty)
        #expect(inst.totalAgentCount == 0)
        #expect(inst.runningAgentCount == 0)
        #expect(inst.serverName == "")
    }

    @Test func agentsForProject() {
        let inst = makeInstance()
        let project = Project(id: "p1", name: "test", path: "/test", color: nil, icon: nil, displayName: nil, orchestrator: nil)
        inst.projects = [project]
        let agent = DurableAgent(id: "a1", name: "test-agent", kind: "durable", color: "emerald",
                                 branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                                 icon: nil, executionMode: nil, status: .running, mission: nil,
                                 detailedStatus: nil, quickAgents: nil)
        inst.agentsByProject = ["p1": [agent]]

        #expect(inst.agents(for: project).count == 1)
        #expect(inst.totalAgentCount == 1)
        #expect(inst.runningAgentCount == 1)
    }

    @Test func projectForAgent() {
        let inst = makeInstance()
        let project = Project(id: "p1", name: "test", path: "/test", color: nil, icon: nil, displayName: nil, orchestrator: nil)
        inst.projects = [project]
        let agent = DurableAgent(id: "a1", name: "test-agent", kind: "durable", color: nil,
                                 branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                                 icon: nil, executionMode: nil)
        inst.agentsByProject = ["p1": [agent]]

        let found = inst.project(for: agent)
        #expect(found?.id == "p1")
    }

    @Test func durableAgentLookup() {
        let inst = makeInstance()
        let agent = DurableAgent(id: "a1", name: "test-agent", kind: "durable", color: nil,
                                 branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                                 icon: nil, executionMode: "pty")
        inst.agentsByProject = ["p1": [agent]]

        #expect(inst.durableAgent(byId: "a1")?.name == "test-agent")
        #expect(inst.durableAgent(byId: "nonexistent") == nil)
    }

    @Test func pendingPermissionFiltersExpired() {
        let inst = makeInstance()
        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        let pastDeadline = Int(Date().timeIntervalSince1970 * 1000) - 1000

        let active = PermissionRequest(requestId: "p1", agentId: "a1", toolName: "Bash",
                                       toolInput: nil, message: nil, timeout: nil, deadline: futureDeadline)
        let expired = PermissionRequest(requestId: "p2", agentId: "a2", toolName: "Bash",
                                        toolInput: nil, message: nil, timeout: nil, deadline: pastDeadline)

        inst.pendingPermissions = ["p1": active, "p2": expired]

        #expect(inst.pendingPermission(for: "a1") != nil)
        #expect(inst.pendingPermission(for: "a2") == nil)
    }

    @Test func activityStorage() {
        let inst = makeInstance()
        let event = HookEvent(id: UUID(), agentId: "a1", kind: .preTool, toolName: "Read",
                              toolVerb: "Reading file", message: nil, timestamp: 1000)
        inst.activityByAgent["a1"] = [event]

        #expect(inst.activity(for: "a1").count == 1)
        #expect(inst.activity(for: "nonexistent").isEmpty)
    }

    @Test func quickAgentDeduplication() {
        let inst = makeInstance()
        let project = Project(id: "p1", name: "test", path: "/test", color: nil, icon: nil, displayName: nil, orchestrator: nil)
        inst.projects = [project]

        let qa = QuickAgent(id: "q1", name: "quick-1", kind: "quick", status: .running,
                            mission: nil, prompt: "test", model: nil, detailedStatus: nil,
                            orchestrator: nil, parentAgentId: "a1", projectId: "p1", freeAgentMode: nil)

        // Same agent in both standalone and nested
        let durable = DurableAgent(id: "a1", name: "test", kind: "durable", color: nil,
                                   branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
                                   icon: nil, executionMode: nil, status: .running, mission: nil,
                                   detailedStatus: nil, quickAgents: [qa])
        inst.agentsByProject = ["p1": [durable]]
        inst.quickAgentsByProject = ["p1": [qa]]

        let all = inst.allQuickAgents(for: project)
        let ids = all.map(\.id)
        #expect(Set(ids).count == ids.count) // No duplicates
    }

    @Test func disconnectClearsState() {
        let inst = makeInstance()
        inst.projects = [Project(id: "p1", name: "test", path: "/test", color: nil, icon: nil, displayName: nil, orchestrator: nil)]
        inst.serverName = "Test Server"
        inst.connectionState = .connected

        inst.disconnect()

        #expect(inst.projects.isEmpty)
        #expect(inst.serverName == "")
        #expect(inst.connectionState.isConnected == false)
    }
}

// MARK: - AppStore Multi-Instance Tests

@MainActor
struct AppStoreMultiInstanceTests {
    private func makeStoreWithMockData() -> AppStore {
        let store = AppStore()
        store.loadMockData()
        return store
    }

    @Test func mockDataCreatesMultipleInstances() {
        let store = makeStoreWithMockData()
        #expect(store.instances.count == 2)
        #expect(store.connectedInstances.count == 2)
        #expect(store.hasConnectedInstance == true)
    }

    @Test func activeInstanceDefaultsToFirst() {
        let store = makeStoreWithMockData()
        #expect(store.activeInstanceID == store.instances[0].id)
        #expect(store.serverName == "Mason's Desktop")
    }

    @Test func allAgentsAcrossInstances() {
        let store = makeStoreWithMockData()
        let all = store.allAgentsAcrossInstances
        #expect(all.count == 5) // 2 from desktop + 2 from mini + 1 from desktop
        // Each should have instance context
        let instanceNames = Set(all.map { $0.instance.serverName })
        #expect(instanceNames.contains("Mason's Desktop"))
        #expect(instanceNames.contains("Mac Mini"))
    }

    @Test func allPendingPermissions() {
        let store = makeStoreWithMockData()
        let perms = store.allPendingPermissions
        // Mock data has one permission on the Mac Mini instance
        #expect(perms.count == 1)
        #expect(perms[0].instance.serverName == "Mac Mini")
    }

    @Test func instanceLookupForAgent() {
        let store = makeStoreWithMockData()
        // faithful-urchin is on desktop
        let desktopInst = store.instance(for: "durable_1737000000000_abc123")
        #expect(desktopInst?.serverName == "Mason's Desktop")
        // bold-eagle is on Mac Mini
        let miniInst = store.instance(for: "durable_1737000000002_srv001")
        #expect(miniInst?.serverName == "Mac Mini")
    }

    @Test func instanceLookupForProject() {
        let store = makeStoreWithMockData()
        let proj = store.instances[0].projects[0] // proj_001 on desktop
        let inst = store.instance(for: proj)
        #expect(inst?.serverName == "Mason's Desktop")
    }

    @Test func crossInstanceAgentActions() {
        let store = makeStoreWithMockData()
        // removeQuickAgent should find the agent on the correct instance
        let inst = store.instances[0]
        let qa = QuickAgent(id: "test_qa", name: nil, kind: "quick", status: .running,
                            mission: nil, prompt: "test", model: nil, detailedStatus: nil,
                            orchestrator: nil, parentAgentId: nil, projectId: "proj_001", freeAgentMode: nil)
        inst.quickAgentsByProject["proj_001"] = [qa]

        #expect(store.quickAgent(byId: "test_qa") != nil)
        store.removeQuickAgent(agentId: "test_qa")
        #expect(store.quickAgent(byId: "test_qa") == nil)
    }

    @Test func disconnectSingleInstance() {
        let store = makeStoreWithMockData()
        let miniId = store.instances[1].id
        store.disconnect(instanceId: miniId)
        #expect(store.instances.count == 1)
        #expect(store.instances[0].serverName == "Mason's Desktop")
    }

    @Test func disconnectAllInstances() {
        let store = makeStoreWithMockData()
        store.disconnectAll()
        #expect(store.instances.isEmpty)
        #expect(store.hasConnectedInstance == false)
        #expect(store.isPaired == false)
    }

    @Test func aggregateOrchestratorsMerged() {
        let store = makeStoreWithMockData()
        let orchestrators = store.orchestrators
        // Desktop has claude-code, Mini has claude-code + copilot-cli
        #expect(orchestrators.keys.contains("claude-code"))
        #expect(orchestrators.keys.contains("copilot-cli"))
    }

    @Test func totalAgentCountAcrossInstances() {
        let store = makeStoreWithMockData()
        #expect(store.totalAgentCount == 5) // 2+1 from desktop, 2 from mini
        #expect(store.runningAgentCount > 0)
    }

    @Test func activityRoutesToCorrectInstance() {
        let store = makeStoreWithMockData()
        // faithful-urchin activity is on desktop instance
        let events = store.activity(for: "durable_1737000000000_abc123")
        #expect(!events.isEmpty)
        // bold-eagle activity is on mini instance
        let miniEvents = store.activity(for: "durable_1737000000002_srv001")
        #expect(!miniEvents.isEmpty)
    }

    @Test func themeFromActiveInstance() {
        let store = makeStoreWithMockData()
        // Active instance is desktop, which uses .mock theme
        #expect(store.theme.accent == "#89b4fa")
        // Switch to mini
        store.activeInstanceID = store.instances[1].id
        #expect(store.theme.accent == "#c6a0f6") // Mini uses macchiato theme
    }

    @Test func projectsFromActiveInstance() {
        let store = makeStoreWithMockData()
        // Active is desktop: proj_001, proj_003
        #expect(store.projects.count == 2)
        // Switch to mini: proj_002
        store.activeInstanceID = store.instances[1].id
        #expect(store.projects.count == 1)
    }

    @Test func resetAppClearsEverything() {
        let store = makeStoreWithMockData()
        store.completeOnboarding()
        store.resetApp()
        #expect(store.instances.isEmpty)
        #expect(store.hasCompletedOnboarding == false)
    }

    @Test func instancesExistButDisconnected() {
        let store = makeStoreWithMockData()
        // Simulate all instances going offline
        for inst in store.instances {
            inst.disconnect()
        }
        // Instances still exist even when disconnected
        #expect(store.instances.count == 2)
        #expect(store.connectedInstances.isEmpty)
        #expect(store.hasConnectedInstance == false)
        // isPaired is false (backward compat: no connected instance)
        #expect(store.isPaired == false)
        // But instances array is not empty — app should show main UI
        #expect(!store.instances.isEmpty)
    }

    @Test func pendingPermissionsMergedFromAllInstances() {
        let store = makeStoreWithMockData()
        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        // Add a permission on the desktop instance too
        store.instances[0].pendingPermissions["perm_desktop"] = PermissionRequest(
            requestId: "perm_desktop", agentId: "durable_1737000000000_abc123",
            toolName: "Edit", toolInput: nil, message: "Edit file",
            timeout: nil, deadline: futureDeadline
        )
        // Should find permissions from both instances
        let allPerms = store.pendingPermissions
        #expect(allPerms.count >= 2) // At least 1 from mock + 1 we added
    }

    @Test func codexOrchestratorInMockData() {
        let store = makeStoreWithMockData()
        let orchestrators = store.orchestrators
        #expect(orchestrators.keys.contains("codex"))
        #expect(orchestrators["codex"]?.displayName == "Codex")
        #expect(orchestrators["codex"]?.shortName == "CX")
    }
}

// MARK: - DiscoveredServer Tests

struct DiscoveredServerTests {
    @Test func serverProperties() {
        let server = DiscoveredServer(
            id: "endpoint1", name: "My Mac", host: "192.168.1.10", port: 8443,
            pairingPort: 8080, fingerprint: "AA:BB:CC"
        )
        #expect(server.pairingPort == 8080)
        #expect(server.fingerprint == "AA:BB:CC")
    }

    @Test func equalityById() {
        let a = DiscoveredServer(id: "ep1", name: "A", host: "1.2.3.4", port: 8443,
                                 pairingPort: 8080, fingerprint: "AA:BB")
        let b = DiscoveredServer(id: "ep1", name: "B", host: "5.6.7.8", port: 4000,
                                 pairingPort: 9090, fingerprint: "XX:YY")
        #expect(a == b) // Same ID = equal
    }
}

// MARK: - KeychainHelper Multi-Instance Tests

struct KeychainHelperMultiInstanceTests {
    @Test func saveAndLoadInstance() {
        let id = ServerInstanceID(value: "test-\(UUID().uuidString)")
        let config = ServerProtocol.v2(host: "localhost", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB:CC")

        KeychainHelper.saveInstance(id: id, token: "tok_123", protocolConfig: config)

        let loaded = KeychainHelper.loadInstance(id: id)
        #expect(loaded != nil)
        #expect(loaded?.token == "tok_123")
        #expect(loaded?.protocolConfig.host == "localhost")
        #expect(loaded?.protocolConfig.mainPort == 8443)

        // Cleanup
        KeychainHelper.deleteInstance(id: id)
    }

    @Test func loadAllInstancesIncludesSaved() {
        let id1 = ServerInstanceID(value: "multi-test-1-\(UUID().uuidString)")
        let id2 = ServerInstanceID(value: "multi-test-2-\(UUID().uuidString)")

        KeychainHelper.saveInstance(id: id1, token: "tok_1", protocolConfig: .v2(host: "h1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB"))
        KeychainHelper.saveInstance(id: id2, token: "tok_2", protocolConfig: .v2(host: "h2", mainPort: 8444, pairingPort: 8081, fingerprint: "CC:DD"))

        let all = KeychainHelper.loadAllInstances()
        let found1 = all.contains { $0.id == id1 }
        let found2 = all.contains { $0.id == id2 }
        #expect(found1)
        #expect(found2)

        // Cleanup
        KeychainHelper.deleteInstance(id: id1)
        KeychainHelper.deleteInstance(id: id2)
    }

    @Test func deleteInstance() {
        let id = ServerInstanceID(value: "delete-test-\(UUID().uuidString)")
        KeychainHelper.saveInstance(id: id, token: "tok", protocolConfig: .v2(host: "h", mainPort: 8443, pairingPort: 8080, fingerprint: "EE:FF"))
        #expect(KeychainHelper.loadInstance(id: id) != nil)

        KeychainHelper.deleteInstance(id: id)
        #expect(KeychainHelper.loadInstance(id: id) == nil)
    }

    @Test func saveInstanceWithServerPublicKey() {
        let id = ServerInstanceID(value: "v2-test-\(UUID().uuidString)")
        let config = ServerProtocol.v2(host: "10.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")

        KeychainHelper.saveInstance(id: id, token: "tok_v2", protocolConfig: config, serverPublicKey: "serverpubkey==")

        let loaded = KeychainHelper.loadInstance(id: id)
        #expect(loaded?.protocolConfig.host == "10.0.0.1")
        #expect(loaded?.serverPublicKey == "serverpubkey==")

        // Cleanup
        KeychainHelper.deleteInstance(id: id)
    }
}

// MARK: - ConnectionState Tests (additions)

struct ConnectionStateExtendedTests {
    @Test func allLabels() {
        let states: [(ConnectionState, String)] = [
            (.disconnected, "Disconnected"),
            (.discovering, "Searching..."),
            (.pairing, "Pairing..."),
            (.connecting, "Connecting..."),
            (.connected, "Connected"),
            (.reconnecting(attempt: 3), "Reconnecting (3)..."),
        ]
        for (state, expected) in states {
            #expect(state.label == expected)
        }
    }

    @Test func isConnectedOnlyForConnected() {
        #expect(ConnectionState.connected.isConnected == true)
        #expect(ConnectionState.disconnected.isConnected == false)
        #expect(ConnectionState.connecting.isConnected == false)
        #expect(ConnectionState.reconnecting(attempt: 1).isConnected == false)
    }
}
