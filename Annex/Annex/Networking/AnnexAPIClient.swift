import Foundation

enum APIError: Error, Sendable {
    case invalidURL
    case unauthorized
    case invalidPin
    case invalidJSON
    case notFound
    case projectNotFound
    case agentNotFound
    case agentAlreadyRunning
    case agentNotRunning
    case missingPrompt
    case missingMessage
    case missingRequestId
    case invalidDecision
    case missingApproved
    case requestNotFound
    case noStructuredSession
    case invalidOrchestrator
    case spawnFailed
    case wakeFailed
    case serverError(String)
    case networkError(Error)
    case decodingError(Error)

    var userMessage: String {
        switch self {
        case .invalidURL: return "Invalid server address"
        case .unauthorized: return "Session expired. Please re-pair."
        case .invalidPin: return "Invalid PIN. Check the code in Clubhouse."
        case .invalidJSON: return "Request error"
        case .notFound: return "Not found"
        case .projectNotFound: return "Project not found"
        case .agentNotFound: return "Agent not found"
        case .agentAlreadyRunning: return "Agent is already running"
        case .agentNotRunning: return "Agent is not running"
        case .missingPrompt: return "Prompt is required"
        case .missingMessage: return "Message is required"
        case .missingRequestId: return "Missing request ID"
        case .invalidDecision: return "Invalid decision"
        case .missingApproved: return "Missing approval value"
        case .requestNotFound: return "Permission request not found or expired"
        case .noStructuredSession: return "Agent is not in structured mode"
        case .invalidOrchestrator: return "Invalid orchestrator"
        case .spawnFailed: return "Failed to start agent"
        case .wakeFailed: return "Failed to wake agent"
        case .serverError(let msg): return msg
        case .networkError: return "Cannot reach server"
        case .decodingError: return "Unexpected server response"
        }
    }
}

/// Protocol-specific connection configuration.
enum APIClientConfig: Sendable {
    case v2(host: String, mainPort: UInt16)
    case v2Pairing(host: String, pairingPort: UInt16)
}

final class AnnexAPIClient: Sendable {
    let config: APIClientConfig
    let urlSession: URLSession

    var host: String {
        switch config {
        case .v2(let h, _), .v2Pairing(let h, _): return h
        }
    }

    var port: UInt16 {
        switch config {
        case .v2(_, let p), .v2Pairing(_, let p): return p
        }
    }

    private nonisolated var urlHost: String {
        if host.contains(":") {
            let escaped = host.replacingOccurrences(of: "%", with: "%25")
            return "[\(escaped)]"
        }
        return host
    }

    nonisolated var baseURL: String {
        switch config {
        case .v2: return "https://\(urlHost):\(port)"
        case .v2Pairing: return "http://\(urlHost):\(port)"
        }
    }

    private var configLabel: String {
        switch config {
        case .v2: return "v2-main"
        case .v2Pairing: return "v2-pairing"
        }
    }

    // MARK: - Factory Methods

    static func v2(host: String, mainPort: UInt16, delegate: TLSSessionDelegate) -> AnnexAPIClient {
        AppLog.shared.info("API", "Creating v2 client -> https://\(host):\(mainPort) (TLS, custom delegate)")
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        return AnnexAPIClient(config: .v2(host: host, mainPort: mainPort), session: session)
    }

    static func v2Pairing(host: String, pairingPort: UInt16) -> AnnexAPIClient {
        AppLog.shared.info("API", "Creating v2-pairing client -> http://\(host):\(pairingPort)")
        return AnnexAPIClient(config: .v2Pairing(host: host, pairingPort: pairingPort), session: .shared)
    }

    init(config: APIClientConfig, session: URLSession) {
        self.config = config
        self.urlSession = session
    }

    // MARK: - POST /pair

    func pairV2(
        pin: String, publicKey: String, alias: String, icon: String, color: String
    ) async throws(APIError) -> V2PairResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /pair (v2) alias=\(alias) publicKey=\(publicKey.prefix(20))...")
        let url = try makeURL("/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = V2PairRequest(pin: pin, publicKey: publicKey, alias: alias, icon: icon, color: color)
        request.httpBody = try? JSONEncoder().encode(body)
        let data = try await perform(request)
        let response = try decode(V2PairResponse.self, from: data)
        AppLog.shared.info("API", "[\(configLabel)] v2 Pair success: alias=\(response.alias) fingerprint=\(response.fingerprint)")
        return response
    }

    // MARK: - GET /api/v1/status

    func getStatus(token: String) async throws(APIError) -> StatusResponse {
        AppLog.shared.info("API", "[\(configLabel)] GET /api/v1/status")
        let url = try makeURL("/api/v1/status")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        let response = try decode(StatusResponse.self, from: data)
        AppLog.shared.info("API", "[\(configLabel)] Status: \(response.deviceName), \(response.agentCount) agents")
        return response
    }

    // MARK: - GET /api/v1/projects

    func getProjects(token: String) async throws(APIError) -> [Project] {
        AppLog.shared.info("API", "[\(configLabel)] GET /api/v1/projects")
        let url = try makeURL("/api/v1/projects")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        let response = try decode([Project].self, from: data)
        AppLog.shared.info("API", "[\(configLabel)] Projects: \(response.count)")
        return response
    }

    // MARK: - GET /api/v1/projects/{projectId}/agents

    func getAgents(projectId: String, token: String) async throws(APIError) -> [DurableAgent] {
        AppLog.shared.debug("API", "[\(configLabel)] GET /api/v1/projects/\(projectId)/agents")
        let url = try makeURL("/api/v1/projects/\(projectId)/agents")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        return try decode([DurableAgent].self, from: data)
    }

    // MARK: - GET /api/v1/agents/{agentId}/buffer

    func getBuffer(agentId: String, token: String) async throws(APIError) -> String {
        AppLog.shared.debug("API", "[\(configLabel)] GET /api/v1/agents/\(agentId)/buffer")
        let url = try makeURL("/api/v1/agents/\(agentId)/buffer")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - POST /api/v1/projects/{projectId}/agents/quick

    func spawnQuickAgent(
        projectId: String, request: SpawnQuickAgentRequest, token: String
    ) async throws(APIError) -> SpawnQuickAgentResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/projects/\(projectId)/agents/quick")
        let url = try makeURL("/api/v1/projects/\(projectId)/agents/quick")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        let response = try decode(SpawnQuickAgentResponse.self, from: data)
        AppLog.shared.info("API", "[\(configLabel)] Quick agent spawned: \(response.id)")
        return response
    }

    // MARK: - POST /api/v1/agents/{agentId}/agents/quick

    func spawnQuickAgentUnder(
        parentAgentId: String, request: SpawnQuickAgentRequest, token: String
    ) async throws(APIError) -> SpawnQuickAgentResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(parentAgentId)/agents/quick")
        let url = try makeURL("/api/v1/agents/\(parentAgentId)/agents/quick")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        let response = try decode(SpawnQuickAgentResponse.self, from: data)
        AppLog.shared.info("API", "[\(configLabel)] Quick agent spawned under parent: \(response.id)")
        return response
    }

    // MARK: - POST /api/v1/agents/{agentId}/cancel

    func cancelAgent(agentId: String, token: String) async throws(APIError) -> CancelAgentResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(agentId)/cancel")
        let url = try makeURL("/api/v1/agents/\(agentId)/cancel")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(req)
        return try decode(CancelAgentResponse.self, from: data)
    }

    // MARK: - POST /api/v1/agents/{agentId}/wake

    func wakeAgent(
        agentId: String, request: WakeAgentRequest, token: String
    ) async throws(APIError) -> WakeAgentResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(agentId)/wake")
        let url = try makeURL("/api/v1/agents/\(agentId)/wake")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        return try decode(WakeAgentResponse.self, from: data)
    }

    // MARK: - POST /api/v1/agents/{agentId}/message

    func sendMessage(
        agentId: String, request: SendMessageRequest, token: String
    ) async throws(APIError) -> SendMessageResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(agentId)/message")
        let url = try makeURL("/api/v1/agents/\(agentId)/message")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        return try decode(SendMessageResponse.self, from: data)
    }

    // MARK: - POST /api/v1/agents/{agentId}/permission-response

    func respondToPermission(
        agentId: String, request: PermissionResponseRequest, token: String
    ) async throws(APIError) -> PermissionResponseResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(agentId)/permission-response decision=\(request.decision)")
        let url = try makeURL("/api/v1/agents/\(agentId)/permission-response")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        return try decode(PermissionResponseResponse.self, from: data)
    }

    // MARK: - POST /api/v1/agents/{agentId}/structured-permission

    func respondToStructuredPermission(
        agentId: String, request: StructuredPermissionRequest, token: String
    ) async throws(APIError) -> StructuredPermissionResponse {
        AppLog.shared.info("API", "[\(configLabel)] POST /api/v1/agents/\(agentId)/structured-permission approved=\(request.approved)")
        let url = try makeURL("/api/v1/agents/\(agentId)/structured-permission")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(request)
        let data = try await perform(req)
        return try decode(StructuredPermissionResponse.self, from: data)
    }

    // MARK: - GET /api/v1/projects/{projectId}/files/tree

    func getFileTree(
        projectId: String, path: String = ".", depth: Int = 2, token: String
    ) async throws(APIError) -> [FileNode] {
        AppLog.shared.debug("API", "[\(configLabel)] GET /api/v1/projects/\(projectId)/files/tree?path=\(path)&depth=\(depth)")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = try makeURL("/api/v1/projects/\(projectId)/files/tree?path=\(encodedPath)&depth=\(depth)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        return try decode([FileNode].self, from: data)
    }

    // MARK: - GET /api/v1/projects/{projectId}/files/read

    func getFileContent(
        projectId: String, path: String, token: String
    ) async throws(APIError) -> String {
        AppLog.shared.debug("API", "[\(configLabel)] GET /api/v1/projects/\(projectId)/files/read?path=\(path)")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = try makeURL("/api/v1/projects/\(projectId)/files/read?path=\(encodedPath)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Icons

    func fetchAgentIcon(agentId: String, token: String) async -> Data? {
        guard let url = try? makeURL("/api/v1/icons/agent/\(agentId)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    func fetchProjectIcon(projectId: String, token: String) async -> Data? {
        guard let url = try? makeURL("/api/v1/icons/project/\(projectId)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - WebSocket URL

    func webSocketURL(token: String) throws(APIError) -> URL {
        guard case .v2 = config else { throw .invalidURL }
        guard let url = URL(string: "wss://\(urlHost):\(port)/ws?token=\(token)") else {
            throw .invalidURL
        }
        AppLog.shared.debug("API", "[\(configLabel)] WebSocket URL: wss://\(urlHost):\(port)/ws?token=\(token.prefix(8))...")
        return url
    }

    // MARK: - Helpers

    private func makeURL(_ path: String) throws(APIError) -> URL {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            AppLog.shared.error("API", "[\(configLabel)] Invalid URL: \(baseURL)\(path)")
            throw .invalidURL
        }
        return url
    }

    private nonisolated func perform(_ request: URLRequest) async throws(APIError) -> Data {
        let method = request.httpMethod ?? "GET"
        let urlStr = request.url?.absoluteString ?? "?"
        AppLog.shared.debug("API", "\(method) \(urlStr)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            AppLog.shared.error("API", "\(method) \(urlStr) — network error: \(error)")
            throw .networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLog.shared.error("API", "\(method) \(urlStr) — not an HTTP response")
            throw .networkError(URLError(.badServerResponse))
        }

        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
        AppLog.shared.debug("API", "\(method) \(urlStr) -> HTTP \(http.statusCode) (\(data.count) bytes)")
        if http.statusCode >= 400 {
            AppLog.shared.warn("API", "\(method) \(urlStr) error body: \(bodyPreview)")
        }

        switch http.statusCode {
        case 200, 201:
            return data
        case 401:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                if errResp.error == "invalid_pin" {
                    AppLog.shared.error("API", "Invalid PIN")
                    throw .invalidPin
                }
            }
            AppLog.shared.error("API", "Unauthorized (401)")
            throw .unauthorized
        case 400:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                AppLog.shared.error("API", "Bad request: \(errResp.error)")
                switch errResp.error {
                case "missing_prompt": throw .missingPrompt
                case "missing_message": throw .missingMessage
                case "missing_request_id": throw .missingRequestId
                case "invalid_decision": throw .invalidDecision
                case "missing_approved": throw .missingApproved
                case "invalid_json": throw .invalidJSON
                case "invalid_orchestrator": throw .invalidOrchestrator
                default: break
                }
            }
            throw .invalidJSON
        case 404:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                AppLog.shared.error("API", "Not found: \(errResp.error)")
                switch errResp.error {
                case "project_not_found": throw .projectNotFound
                case "agent_not_found": throw .agentNotFound
                case "icon_not_found": throw .notFound
                case "request_not_found": throw .requestNotFound
                case "no_structured_session": throw .noStructuredSession
                default: break
                }
            }
            throw .notFound
        case 409:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                switch errResp.error {
                case "agent_already_running": throw .agentAlreadyRunning
                case "agent_not_running": throw .agentNotRunning
                default: break
                }
            }
            throw .serverError("Conflict")
        case 500:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                switch errResp.error {
                case "spawn_failed": throw .spawnFailed
                case "wake_failed": throw .wakeFailed
                default: throw .serverError(errResp.error)
                }
            }
            throw .serverError("HTTP 500")
        default:
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                AppLog.shared.error("API", "Unexpected HTTP \(http.statusCode): \(errResp.error)")
                throw .serverError(errResp.error)
            }
            AppLog.shared.error("API", "Unexpected HTTP \(http.statusCode)")
            throw .serverError("HTTP \(http.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(APIError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            AppLog.shared.error("API", "Decode \(T.self) failed: \(error)\nBody: \(preview)")
            throw .decodingError(error)
        }
    }
}
