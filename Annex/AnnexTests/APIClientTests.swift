import Testing
import Foundation
@testable import ClubhouseGo

// All API tests must run serially since they share MockURLProtocol state.
@Suite(.serialized) struct AllAPITests {

// MARK: - API Client REST Endpoint Tests

struct APIClientTests {

    // Helper to create a mock-backed API client, register a response, and clean up after.
    private func withMockClient(
        path: String,
        response: MockURLProtocol.MockResponse,
        body: (AnnexAPIClient) async throws -> Void
    ) async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(path: path, response: response)
        let client = MockURLProtocol.mockClient()
        try await body(client)
        MockURLProtocol.reset()
    }

    // MARK: - POST /pair

    @Test func pairV2Success() async throws {
        try await withMockClient(path: "/pair", response: .json("""
        {
            "token": "test-token-123",
            "publicKey": "base64-public-key",
            "alias": "Test Server",
            "icon": "desktopcomputer",
            "color": "blue",
            "fingerprint": "AA:BB:CC:DD"
        }
        """)) { client in
            let response = try await client.pairV2(
                pin: "1234",
                publicKey: "my-public-key",
                alias: "iPhone",
                icon: "iphone",
                color: "green"
            )
            #expect(response.token == "test-token-123")
            #expect(response.alias == "Test Server")
            #expect(response.fingerprint == "AA:BB:CC:DD")
            #expect(response.publicKey == "base64-public-key")
            #expect(response.icon == "desktopcomputer")
            #expect(response.color == "blue")
        }
    }

    @Test func pairV2InvalidPin() async throws {
        try await withMockClient(path: "/pair", response: .json(
            "{\"error\":\"invalid_pin\"}", statusCode: 401
        )) { client in
            do {
                _ = try await client.pairV2(
                    pin: "0000", publicKey: "key", alias: "iPhone", icon: "iphone", color: "green"
                )
                Issue.record("Expected invalidPin error")
            } catch let error as APIError {
                #expect(error == .invalidPin)
            }
        }
    }

    // MARK: - GET /api/v1/status

    @Test func getStatusSuccess() async throws {
        try await withMockClient(path: "/api/v1/status", response: .json("""
        {"version":"2","deviceName":"Mason's Mac","agentCount":3,"orchestratorCount":1}
        """)) { client in
            let status = try await client.getStatus(token: "tok")
            #expect(status.version == "2")
            #expect(status.deviceName == "Mason's Mac")
            #expect(status.agentCount == 3)
            #expect(status.orchestratorCount == 1)
        }
    }

    @Test func getStatusUnauthorized() async throws {
        try await withMockClient(path: "/api/v1/status", response: .json(
            "{\"error\":\"unauthorized\"}", statusCode: 401
        )) { client in
            do {
                _ = try await client.getStatus(token: "bad-token")
                Issue.record("Expected unauthorized error")
            } catch let error as APIError {
                #expect(error == .unauthorized)
            }
        }
    }

    // MARK: - GET /api/v1/projects

    @Test func getProjectsSuccess() async throws {
        try await withMockClient(path: "/api/v1/projects", response: .json("""
        [
            {"id":"proj_001","name":"my-app","path":"/src/my-app","color":"emerald","icon":null,"displayName":"My App","orchestrator":"claude-code"},
            {"id":"proj_002","name":"api-server","path":"/src/api","color":null,"icon":null,"displayName":null,"orchestrator":null}
        ]
        """)) { client in
            let projects = try await client.getProjects(token: "tok")
            #expect(projects.count == 2)
            #expect(projects[0].id == "proj_001")
            #expect(projects[0].name == "my-app")
            #expect(projects[0].label == "My App")
            #expect(projects[1].id == "proj_002")
            #expect(projects[1].label == "api-server")
        }
    }

    @Test func getProjectsEmpty() async throws {
        try await withMockClient(path: "/api/v1/projects", response: .json("[]")) { client in
            let projects = try await client.getProjects(token: "tok")
            #expect(projects.isEmpty)
        }
    }

    // MARK: - GET /api/v1/projects/{projectId}/agents

    @Test func getAgentsSuccess() async throws {
        try await withMockClient(path: "/api/v1/projects/proj_001/agents", response: .json("""
        [
            {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","branch":"faithful-urchin/standby","model":"claude-opus-4-5","orchestrator":"claude-code","freeAgentMode":false,"icon":null}
        ]
        """)) { client in
            let agents = try await client.getAgents(projectId: "proj_001", token: "tok")
            #expect(agents.count == 1)
            #expect(agents[0].id == "durable_001")
            #expect(agents[0].name == "faithful-urchin")
            #expect(agents[0].model == "claude-opus-4-5")
        }
    }

    @Test func getAgentsProjectNotFound() async throws {
        try await withMockClient(path: "/api/v1/projects/bad_id/agents", response: .json(
            "{\"error\":\"project_not_found\"}", statusCode: 404
        )) { client in
            do {
                _ = try await client.getAgents(projectId: "bad_id", token: "tok")
                Issue.record("Expected projectNotFound error")
            } catch let error as APIError {
                #expect(error == .projectNotFound)
            }
        }
    }

    // MARK: - GET /api/v1/agents/{agentId}/buffer

    @Test func getBufferSuccess() async throws {
        let terminalOutput = "$ npm test\n\u{1b}[32mPASSED\u{1b}[0m 42 tests\n"
        try await withMockClient(path: "/api/v1/agents/agent_001/buffer", response: .text(
            terminalOutput
        )) { client in
            let buffer = try await client.getBuffer(agentId: "agent_001", token: "tok")
            #expect(buffer.contains("npm test"))
            #expect(buffer.contains("PASSED"))
        }
    }

    @Test func getBufferAgentNotFound() async throws {
        try await withMockClient(path: "/api/v1/agents/bad_agent/buffer", response: .json(
            "{\"error\":\"agent_not_found\"}", statusCode: 404
        )) { client in
            do {
                _ = try await client.getBuffer(agentId: "bad_agent", token: "tok")
                Issue.record("Expected agentNotFound error")
            } catch let error as APIError {
                #expect(error == .agentNotFound)
            }
        }
    }

    // MARK: - POST /api/v1/projects/{projectId}/agents/quick

    @Test func spawnQuickAgentSuccess() async throws {
        try await withMockClient(path: "/agents/quick", response: .json("""
        {"id":"quick_001","name":"quick-1","kind":"quick","status":"starting","prompt":"Fix bug","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"parentAgentId":null,"projectId":"proj_001"}
        """)) { client in
            let request = SpawnQuickAgentRequest(
                prompt: "Fix bug", orchestrator: "claude-code",
                model: "claude-sonnet-4-5", freeAgentMode: false, systemPrompt: nil
            )
            let response = try await client.spawnQuickAgent(
                projectId: "proj_001", request: request, token: "tok"
            )
            #expect(response.id == "quick_001")
            #expect(response.status == "starting")
            #expect(response.prompt == "Fix bug")
            #expect(response.projectId == "proj_001")
        }
    }

    @Test func spawnQuickAgentMissingPrompt() async throws {
        try await withMockClient(path: "/agents/quick", response: .json(
            "{\"error\":\"missing_prompt\"}", statusCode: 400
        )) { client in
            let request = SpawnQuickAgentRequest(
                prompt: "", orchestrator: nil, model: nil, freeAgentMode: nil, systemPrompt: nil
            )
            do {
                _ = try await client.spawnQuickAgent(projectId: "proj_001", request: request, token: "tok")
                Issue.record("Expected missingPrompt error")
            } catch let error as APIError {
                #expect(error == .missingPrompt)
            }
        }
    }

    @Test func spawnQuickAgentInvalidOrchestrator() async throws {
        try await withMockClient(path: "/agents/quick", response: .json(
            "{\"error\":\"invalid_orchestrator\"}", statusCode: 400
        )) { client in
            let request = SpawnQuickAgentRequest(
                prompt: "Fix", orchestrator: "bad-orch", model: nil, freeAgentMode: nil, systemPrompt: nil
            )
            do {
                _ = try await client.spawnQuickAgent(projectId: "proj_001", request: request, token: "tok")
                Issue.record("Expected invalidOrchestrator error")
            } catch let error as APIError {
                #expect(error == .invalidOrchestrator)
            }
        }
    }

    @Test func spawnQuickAgentSpawnFailed() async throws {
        try await withMockClient(path: "/agents/quick", response: .json(
            "{\"error\":\"spawn_failed\"}", statusCode: 500
        )) { client in
            let request = SpawnQuickAgentRequest(
                prompt: "Fix", orchestrator: nil, model: nil, freeAgentMode: nil, systemPrompt: nil
            )
            do {
                _ = try await client.spawnQuickAgent(projectId: "proj_001", request: request, token: "tok")
                Issue.record("Expected spawnFailed error")
            } catch let error as APIError {
                #expect(error == .spawnFailed)
            }
        }
    }

    // MARK: - POST /api/v1/agents/{parentAgentId}/agents/quick

    @Test func spawnQuickAgentUnderParentSuccess() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/agents/quick", response: .json("""
        {"id":"quick_002","name":null,"kind":"quick","status":"starting","prompt":"Run tests","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"parentAgentId":"durable_001","projectId":"proj_001"}
        """)) { client in
            let request = SpawnQuickAgentRequest(
                prompt: "Run tests", orchestrator: "claude-code",
                model: "claude-sonnet-4-5", freeAgentMode: false, systemPrompt: nil
            )
            let response = try await client.spawnQuickAgentUnder(
                parentAgentId: "durable_001", request: request, token: "tok"
            )
            #expect(response.id == "quick_002")
            #expect(response.parentAgentId == "durable_001")
        }
    }

    // MARK: - POST /api/v1/agents/{agentId}/cancel

    @Test func cancelAgentSuccess() async throws {
        try await withMockClient(path: "/api/v1/agents/quick_001/cancel", response: .json("""
        {"id":"quick_001","status":"cancelled"}
        """)) { client in
            let response = try await client.cancelAgent(agentId: "quick_001", token: "tok")
            #expect(response.id == "quick_001")
            #expect(response.status == "cancelled")
        }
    }

    // MARK: - POST /api/v1/agents/{agentId}/wake

    @Test func wakeAgentSuccess() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/wake", response: .json("""
        {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","status":"starting","branch":"faithful-urchin/standby","model":"claude-sonnet-4-5","orchestrator":"claude-code","freeAgentMode":false,"icon":null,"detailedStatus":null}
        """)) { client in
            let request = WakeAgentRequest(message: "Rebase on main", model: "claude-opus-4-5")
            let response = try await client.wakeAgent(
                agentId: "durable_001", request: request, token: "tok"
            )
            #expect(response.id == "durable_001")
            #expect(response.status == "starting")
            #expect(response.name == "faithful-urchin")
        }
    }

    @Test func wakeAgentAlreadyRunning() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/wake", response: .json(
            "{\"error\":\"agent_already_running\"}", statusCode: 409
        )) { client in
            do {
                let request = WakeAgentRequest(message: "Wake up", model: nil)
                _ = try await client.wakeAgent(agentId: "durable_001", request: request, token: "tok")
                Issue.record("Expected agentAlreadyRunning error")
            } catch let error as APIError {
                #expect(error == .agentAlreadyRunning)
            }
        }
    }

    @Test func wakeAgentFailed() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/wake", response: .json(
            "{\"error\":\"wake_failed\"}", statusCode: 500
        )) { client in
            do {
                let request = WakeAgentRequest(message: "Wake", model: nil)
                _ = try await client.wakeAgent(agentId: "durable_001", request: request, token: "tok")
                Issue.record("Expected wakeFailed error")
            } catch let error as APIError {
                #expect(error == .wakeFailed)
            }
        }
    }

    // MARK: - POST /api/v1/agents/{agentId}/message

    @Test func sendMessageSuccess() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/message", response: .json("""
        {"id":"durable_001","status":"running","delivered":true}
        """)) { client in
            let request = SendMessageRequest(message: "Also update the README")
            let response = try await client.sendMessage(
                agentId: "durable_001", request: request, token: "tok"
            )
            #expect(response.id == "durable_001")
            #expect(response.delivered == true)
        }
    }

    @Test func sendMessageMissing() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/message", response: .json(
            "{\"error\":\"missing_message\"}", statusCode: 400
        )) { client in
            do {
                let request = SendMessageRequest(message: "")
                _ = try await client.sendMessage(agentId: "durable_001", request: request, token: "tok")
                Issue.record("Expected missingMessage error")
            } catch let error as APIError {
                #expect(error == .missingMessage)
            }
        }
    }

    @Test func sendMessageAgentNotRunning() async throws {
        try await withMockClient(path: "/api/v1/agents/durable_001/message", response: .json(
            "{\"error\":\"agent_not_running\"}", statusCode: 409
        )) { client in
            do {
                let request = SendMessageRequest(message: "hello")
                _ = try await client.sendMessage(agentId: "durable_001", request: request, token: "tok")
                Issue.record("Expected agentNotRunning error")
            } catch let error as APIError {
                #expect(error == .agentNotRunning)
            }
        }
    }

    // MARK: - POST /api/v1/agents/{agentId}/permission-response

    @Test func respondToPermissionSuccess() async throws {
        try await withMockClient(path: "/permission-response", response: .json("""
        {"ok":true,"requestId":"req_001","decision":"allow"}
        """)) { client in
            let request = PermissionResponseRequest(requestId: "req_001", decision: "allow")
            let response = try await client.respondToPermission(
                agentId: "agent_001", request: request, token: "tok"
            )
            #expect(response.ok == true)
            #expect(response.requestId == "req_001")
            #expect(response.decision == "allow")
        }
    }

    @Test func respondToPermissionInvalidDecision() async throws {
        try await withMockClient(path: "/permission-response", response: .json(
            "{\"error\":\"invalid_decision\"}", statusCode: 400
        )) { client in
            do {
                let request = PermissionResponseRequest(requestId: "req_001", decision: "maybe")
                _ = try await client.respondToPermission(agentId: "agent_001", request: request, token: "tok")
                Issue.record("Expected invalidDecision error")
            } catch let error as APIError {
                #expect(error == .invalidDecision)
            }
        }
    }

    @Test func respondToPermissionRequestNotFound() async throws {
        try await withMockClient(path: "/permission-response", response: .json(
            "{\"error\":\"request_not_found\"}", statusCode: 404
        )) { client in
            do {
                let request = PermissionResponseRequest(requestId: "expired_req", decision: "allow")
                _ = try await client.respondToPermission(agentId: "agent_001", request: request, token: "tok")
                Issue.record("Expected requestNotFound error")
            } catch let error as APIError {
                #expect(error == .requestNotFound)
            }
        }
    }

    // MARK: - POST /api/v1/agents/{agentId}/structured-permission

    @Test func respondToStructuredPermissionSuccess() async throws {
        try await withMockClient(path: "/structured-permission", response: .json("""
        {"ok":true,"requestId":"req_002","approved":true}
        """)) { client in
            let request = StructuredPermissionRequest(requestId: "req_002", approved: true, reason: nil)
            let response = try await client.respondToStructuredPermission(
                agentId: "agent_001", request: request, token: "tok"
            )
            #expect(response.ok == true)
            #expect(response.approved == true)
        }
    }

    @Test func respondToStructuredPermissionNoSession() async throws {
        try await withMockClient(path: "/structured-permission", response: .json(
            "{\"error\":\"no_structured_session\"}", statusCode: 404
        )) { client in
            do {
                let request = StructuredPermissionRequest(requestId: "req_002", approved: true, reason: nil)
                _ = try await client.respondToStructuredPermission(agentId: "agent_001", request: request, token: "tok")
                Issue.record("Expected noStructuredSession error")
            } catch let error as APIError {
                #expect(error == .noStructuredSession)
            }
        }
    }

    // MARK: - GET /api/v1/projects/{projectId}/files/tree

    @Test func getFileTreeSuccess() async throws {
        try await withMockClient(path: "/files/tree", response: .json("""
        [
            {"name":"src","path":"src","isDirectory":true,"children":[
                {"name":"main.ts","path":"src/main.ts","isDirectory":false,"children":null}
            ]},
            {"name":"package.json","path":"package.json","isDirectory":false,"children":null}
        ]
        """)) { client in
            let tree = try await client.getFileTree(projectId: "proj_001", token: "tok")
            #expect(tree.count == 2)
            #expect(tree[0].name == "src")
            #expect(tree[0].isDirectory == true)
            #expect(tree[0].children?.count == 1)
            #expect(tree[1].name == "package.json")
            #expect(tree[1].isDirectory == false)
        }
    }

    // MARK: - GET /api/v1/projects/{projectId}/files/read

    @Test func getFileContentSuccess() async throws {
        let fileContent = "console.log('hello world');\n"
        try await withMockClient(path: "/files/read", response: .text(fileContent)) { client in
            let content = try await client.getFileContent(
                projectId: "proj_001", path: "src/main.ts", token: "tok"
            )
            #expect(content.contains("hello world"))
        }
    }

    // MARK: - WebSocket URL

    @Test func webSocketURLConstruction() throws {
        MockURLProtocol.reset()
        let client = MockURLProtocol.mockV2Client(host: "192.168.1.100", port: 4321)
        let url = try client.webSocketURL(token: "my-token-123")
        #expect(url.absoluteString == "wss://192.168.1.100:4321/ws?token=my-token-123")
    }

    @Test func webSocketURLWithIPv6() throws {
        MockURLProtocol.reset()
        let client = MockURLProtocol.mockV2Client(host: "fe80::1", port: 4321)
        let url = try client.webSocketURL(token: "tok")
        #expect(url.absoluteString.contains("[fe80::1]"))
    }

    @Test func webSocketURLFailsForPairingClient() throws {
        MockURLProtocol.reset()
        let client = MockURLProtocol.mockClient()
        do {
            _ = try client.webSocketURL(token: "tok")
            Issue.record("Expected invalidURL error")
        } catch let error as APIError {
            #expect(error == .invalidURL)
        }
    }

    // MARK: - Base URL construction

    @Test func baseURLV2UsesHTTPS() {
        MockURLProtocol.reset()
        let client = MockURLProtocol.mockV2Client(host: "myhost", port: 1234)
        #expect(client.baseURL == "https://myhost:1234")
    }

    @Test func baseURLV2PairingUsesHTTP() {
        MockURLProtocol.reset()
        let client = MockURLProtocol.mockClient(host: "myhost", port: 5678)
        #expect(client.baseURL == "http://myhost:5678")
    }
}

// MARK: - Error Path Tests

struct APIErrorPathTests {

    @Test func networkErrorOnConnectionFailure() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .networkError(URLError(.timedOut))
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected networkError")
        } catch let error as APIError {
            if case .networkError = error {
                // expected
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func networkErrorNotConnected() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .networkError(URLError(.notConnectedToInternet))
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected networkError")
        } catch let error as APIError {
            if case .networkError = error {
                #expect(error.userMessage == "Cannot reach server")
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func decodingErrorOnMalformedJSON() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("this is not json at all")
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected decodingError")
        } catch let error as APIError {
            if case .decodingError = error {
                #expect(error.userMessage == "Unexpected server response")
            } else {
                Issue.record("Expected decodingError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func decodingErrorOnWrongShape() async throws {
        MockURLProtocol.reset()
        // Valid JSON but wrong shape for StatusResponse
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"unexpected\":\"fields\"}")
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected decodingError")
        } catch let error as APIError {
            if case .decodingError = error {
                // expected
            } else {
                Issue.record("Expected decodingError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func serverError500Generic() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"error\":\"internal_error\"}", statusCode: 500)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected serverError")
        } catch let error as APIError {
            if case .serverError(let msg) = error {
                #expect(msg == "internal_error")
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func serverError500NoBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .text("Internal Server Error", statusCode: 500)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected serverError")
        } catch let error as APIError {
            if case .serverError(let msg) = error {
                #expect(msg == "HTTP 500")
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func unknownHTTPStatusCode() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"error\":\"rate_limited\"}", statusCode: 429)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected serverError")
        } catch let error as APIError {
            if case .serverError(let msg) = error {
                #expect(msg == "rate_limited")
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        }
        MockURLProtocol.reset()
    }

    @Test func badRequest400GenericFallback() async throws {
        MockURLProtocol.reset()
        // 400 with unrecognized error field falls back to invalidJSON
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"error\":\"some_unknown_error\"}", statusCode: 400)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected invalidJSON error")
        } catch let error as APIError {
            #expect(error == .invalidJSON)
        }
        MockURLProtocol.reset()
    }

    @Test func badRequest400InvalidJSON() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"error\":\"invalid_json\"}", statusCode: 400)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected invalidJSON error")
        } catch let error as APIError {
            #expect(error == .invalidJSON)
        }
        MockURLProtocol.reset()
    }

    @Test func notFound404Generic() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register(
            path: "/api/v1/status",
            response: .json("{\"error\":\"unknown_resource\"}", statusCode: 404)
        )
        let client = MockURLProtocol.mockClient()
        do {
            _ = try await client.getStatus(token: "tok")
            Issue.record("Expected notFound error")
        } catch let error as APIError {
            #expect(error == .notFound)
        }
        MockURLProtocol.reset()
    }

    @Test func apiErrorUserMessages() {
        let errors: [(APIError, String)] = [
            (.invalidURL, "Invalid server address"),
            (.unauthorized, "Session expired. Please re-pair."),
            (.invalidPin, "Invalid PIN. Check the code in Clubhouse."),
            (.projectNotFound, "Project not found"),
            (.agentNotFound, "Agent not found"),
            (.agentAlreadyRunning, "Agent is already running"),
            (.agentNotRunning, "Agent is not running"),
            (.missingPrompt, "Prompt is required"),
            (.missingMessage, "Message is required"),
            (.missingRequestId, "Missing request ID"),
            (.invalidDecision, "Invalid decision"),
            (.missingApproved, "Missing approval value"),
            (.requestNotFound, "Permission request not found or expired"),
            (.noStructuredSession, "Agent is not in structured mode"),
            (.invalidOrchestrator, "Invalid orchestrator"),
            (.spawnFailed, "Failed to start agent"),
            (.wakeFailed, "Failed to wake agent"),
        ]
        for (error, expected) in errors {
            #expect(error.userMessage == expected, "Expected '\(expected)' for \(error)")
        }
    }
}

} // end AllAPITests

// MARK: - APIError Equatable conformance for testing

extension APIError: Equatable {
    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.unauthorized, .unauthorized),
             (.invalidPin, .invalidPin),
             (.invalidJSON, .invalidJSON),
             (.notFound, .notFound),
             (.projectNotFound, .projectNotFound),
             (.agentNotFound, .agentNotFound),
             (.agentAlreadyRunning, .agentAlreadyRunning),
             (.agentNotRunning, .agentNotRunning),
             (.missingPrompt, .missingPrompt),
             (.missingMessage, .missingMessage),
             (.missingRequestId, .missingRequestId),
             (.invalidDecision, .invalidDecision),
             (.missingApproved, .missingApproved),
             (.requestNotFound, .requestNotFound),
             (.noStructuredSession, .noStructuredSession),
             (.invalidOrchestrator, .invalidOrchestrator),
             (.spawnFailed, .spawnFailed),
             (.wakeFailed, .wakeFailed):
            return true
        case (.serverError(let a), .serverError(let b)):
            return a == b
        case (.networkError, .networkError),
             (.decodingError, .decodingError):
            return true
        default:
            return false
        }
    }
}
