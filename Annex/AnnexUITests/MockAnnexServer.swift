import Foundation
import Network

/// A lightweight mock Annex server for E2E testing.
/// Implements the minimum HTTP + WebSocket surface needed to test the iOS app:
/// - POST /pair → returns a bearer token
/// - GET /api/v1/status → server metadata
/// - GET /ws?token= → WebSocket upgrade → sends snapshot
///
/// Runs on localhost with a dynamic port. Safe to use alongside production Clubhouse.
final class MockAnnexServer {
    let pin: String
    let token: String

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var wsConnections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(pin: String = "123456", token: String = "e2e-test-token-\(UUID().uuidString)") {
        self.pin = pin
        self.token = token
    }

    // MARK: - Lifecycle

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[MockServer] Listener failed: \(error)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var assignedPort: UInt16 = 0

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                assignedPort = listener.port?.rawValue ?? 0
                semaphore.signal()
            } else if case .failed = state {
                semaphore.signal()
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        semaphore.wait()

        guard assignedPort > 0 else {
            throw NSError(domain: "MockAnnexServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to bind port"])
        }

        self.listener = listener
        self.port = assignedPort
        print("[MockServer] Listening on port \(assignedPort)")
        return assignedPort
    }

    func stop() {
        for conn in connections { conn.cancel() }
        for conn in wsConnections { conn.cancel() }
        connections.removeAll()
        wsConnections.removeAll()
        listener?.cancel()
        listener = nil
        print("[MockServer] Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: .global(qos: .userInitiated))
        receiveHTTPRequest(conn)
    }

    private func receiveHTTPRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            guard let request = String(data: data, encoding: .utf8) else { return }
            self.routeRequest(request, rawData: data, connection: conn)
        }
    }

    // MARK: - HTTP Routing

    private func routeRequest(_ request: String, rawData: Data, connection conn: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let fullPath = String(parts[1])
        let path = fullPath.split(separator: "?").first.map(String.init) ?? fullPath
        let headers = parseHeaders(lines)

        print("[MockServer] \(method) \(fullPath)")

        // Check for WebSocket upgrade
        if path == "/ws" && headers["upgrade"]?.lowercased() == "websocket" {
            handleWebSocketUpgrade(request: request, headers: headers, connection: conn)
            return
        }

        switch (method, path) {
        case ("POST", "/pair"):
            handlePair(body: extractBody(from: request), connection: conn)
        case ("GET", "/api/v1/status"):
            handleStatus(headers: headers, connection: conn)
        case ("GET", "/api/v1/projects"):
            handleProjects(headers: headers, connection: conn)
        case ("GET", _) where path.hasPrefix("/api/v1/projects/") && path.hasSuffix("/agents"):
            handleAgents(path: path, headers: headers, connection: conn)
        case ("GET", _) where path.hasPrefix("/api/v1/agents/") && path.hasSuffix("/buffer"):
            handleBuffer(headers: headers, connection: conn)
        case ("POST", _) where path.hasSuffix("/agents/quick"):
            handleSpawnQuickAgent(body: extractBody(from: request), path: path, headers: headers, connection: conn)
        case ("POST", _) where path.hasSuffix("/wake"):
            handleWake(body: extractBody(from: request), path: path, headers: headers, connection: conn)
        case ("POST", _) where path.hasSuffix("/message"):
            handleSendMessage(body: extractBody(from: request), path: path, headers: headers, connection: conn)
        case ("POST", _) where path.hasSuffix("/permission-response"):
            handlePermissionResponse(body: extractBody(from: request), headers: headers, connection: conn)
        case ("POST", _) where path.hasSuffix("/cancel"):
            handleCancel(path: path, headers: headers, connection: conn)
        default:
            sendHTTPResponse(conn, status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    // MARK: - HTTP Handlers

    private func handlePair(body: String?, connection conn: NWConnection) {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let submittedPin = json["pin"] as? String else {
            sendHTTPResponse(conn, status: 400, body: #"{"error":"invalid_json"}"#)
            return
        }

        if submittedPin != pin {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"invalid_pin"}"#)
            return
        }

        sendHTTPResponse(conn, status: 200, body: #"{"token":"\#(token)"}"#)
    }

    private func handleStatus(headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let json = #"""
        {"version":"1","deviceName":"E2E Test Server","agentCount":5,"orchestratorCount":1}
        """#
        sendHTTPResponse(conn, status: 200, body: json)
    }

    private func handleProjects(headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let json = #"""
        [
            {"id":"proj_001","name":"my-app","path":"/Users/test/my-app","color":"emerald","displayName":"My App","orchestrator":"claude-code"},
            {"id":"proj_002","name":"api-server","path":"/Users/test/api-server","color":"cyan","orchestrator":"claude-code"}
        ]
        """#
        sendHTTPResponse(conn, status: 200, body: json)
    }

    private func handleAgents(path: String, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        // Extract projectId from path: /api/v1/projects/{id}/agents
        let segments = path.split(separator: "/")
        let projectId = segments.count >= 4 ? String(segments[3]) : "unknown"

        if projectId == "proj_001" {
            let json = #"""
            [
                {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","branch":"faithful-urchin/standby","model":"claude-opus-4-5","orchestrator":"claude-code","status":"running","detailedStatus":{"state":"working","message":"Editing src/main.ts","toolName":"Edit","timestamp":1708531200000},"quickAgents":[]},
                {"id":"durable_002","name":"gentle-fox","kind":"durable","color":"rose","branch":"gentle-fox/standby","model":"claude-sonnet-4-5","orchestrator":"claude-code","status":"sleeping","quickAgents":[]}
            ]
            """#
            sendHTTPResponse(conn, status: 200, body: json)
        } else if projectId == "proj_002" {
            let json = #"""
            [
                {"id":"durable_003","name":"bold-eagle","kind":"durable","color":"cyan","branch":"bold-eagle/standby","model":"claude-opus-4-5","orchestrator":"claude-code","status":"running","mission":"Add rate limiting","quickAgents":[]}
            ]
            """#
            sendHTTPResponse(conn, status: 200, body: json)
        } else {
            sendHTTPResponse(conn, status: 200, body: "[]")
        }
    }

    private func handleBuffer(headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        sendHTTPResponse(conn, status: 200, body: "$ npm test\nAll tests passed.\n", contentType: "text/plain")
    }

    private func handleSpawnQuickAgent(body: String?, path: String, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let segments = path.split(separator: "/")
        let projectId = segments.count >= 4 ? String(segments[3]) : "proj_001"
        let id = "quick_\(Int(Date().timeIntervalSince1970 * 1000))"
        let json = """
        {"id":"\(id)","name":"quick-test","kind":"quick","status":"running","prompt":"test prompt","model":"claude-sonnet-4-5","orchestrator":"claude-code","projectId":"\(projectId)"}
        """
        sendHTTPResponse(conn, status: 201, body: json)
    }

    private func handleWake(body: String?, path: String, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let segments = path.split(separator: "/")
        let agentId = segments.count >= 4 ? String(segments[3]) : "unknown"
        let json = """
        {"id":"\(agentId)","status":"running"}
        """
        sendHTTPResponse(conn, status: 200, body: json)
    }

    private func handleSendMessage(body: String?, path: String, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let segments = path.split(separator: "/")
        let agentId = segments.count >= 4 ? String(segments[3]) : "unknown"
        let json = """
        {"id":"\(agentId)","status":"running","delivered":true}
        """
        sendHTTPResponse(conn, status: 200, body: json)
    }

    private func handlePermissionResponse(body: String?, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["requestId"] as? String,
              let decision = json["decision"] as? String else {
            sendHTTPResponse(conn, status: 400, body: #"{"error":"missing_request_id"}"#)
            return
        }
        let resp = """
        {"ok":true,"requestId":"\(requestId)","decision":"\(decision)"}
        """
        sendHTTPResponse(conn, status: 200, body: resp)
    }

    private func handleCancel(path: String, headers: [String: String], connection conn: NWConnection) {
        guard isAuthorized(headers) else {
            sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
            return
        }
        let segments = path.split(separator: "/")
        let agentId = segments.count >= 4 ? String(segments[3]) : "unknown"
        let json = """
        {"id":"\(agentId)","status":"cancelled"}
        """
        sendHTTPResponse(conn, status: 200, body: json)
    }

    // MARK: - WebSocket

    private func handleWebSocketUpgrade(request: String, headers: [String: String], connection conn: NWConnection) {
        guard let wsKey = headers["sec-websocket-key"] else {
            sendHTTPResponse(conn, status: 400, body: "Missing Sec-WebSocket-Key")
            return
        }

        // Validate token from query string
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let fullPath = String(parts[1])

        if let queryStart = fullPath.firstIndex(of: "?") {
            let query = String(fullPath[fullPath.index(after: queryStart)...])
            let params = query.split(separator: "&").reduce(into: [String: String]()) { result, pair in
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
            }
            guard params["token"] == token else {
                sendHTTPResponse(conn, status: 401, body: #"{"error":"unauthorized"}"#)
                return
            }
        }

        // Compute accept key per RFC 6455
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = wsKey + magic
        let sha1 = sha1Hash(combined.data(using: .utf8)!)
        let acceptKey = sha1.base64EncodedString()

        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
            "",
            ""
        ].joined(separator: "\r\n")

        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.wsConnections.append(conn)
            // Send snapshot after upgrade
            self.sendWebSocketSnapshot(conn)
        })
    }

    func sendWebSocketSnapshot(_ conn: NWConnection) {
        let snapshot = #"""
        {
            "type": "snapshot",
            "payload": {
                "projects": [
                    {"id":"proj_001","name":"my-app","path":"/Users/test/my-app","color":"emerald","displayName":"My App","orchestrator":"claude-code"},
                    {"id":"proj_002","name":"api-server","path":"/Users/test/api-server","color":"cyan","orchestrator":"claude-code"}
                ],
                "agents": {
                    "proj_001": [
                        {"id":"durable_001","name":"faithful-urchin","kind":"durable","color":"emerald","branch":"faithful-urchin/standby","model":"claude-opus-4-5","orchestrator":"claude-code","status":"running","detailedStatus":{"state":"working","message":"Editing src/main.ts","toolName":"Edit","timestamp":1708531200000},"quickAgents":[]},
                        {"id":"durable_002","name":"gentle-fox","kind":"durable","color":"rose","branch":"gentle-fox/standby","model":"claude-sonnet-4-5","orchestrator":"claude-code","status":"sleeping","quickAgents":[]}
                    ],
                    "proj_002": [
                        {"id":"durable_003","name":"bold-eagle","kind":"durable","color":"cyan","branch":"bold-eagle/standby","model":"claude-opus-4-5","orchestrator":"claude-code","status":"running","mission":"Add rate limiting","quickAgents":[]}
                    ]
                },
                "quickAgents": {},
                "theme": {
                    "base":"#1e1e2e","mantle":"#181825","crust":"#11111b",
                    "text":"#cdd6f4","subtext0":"#a6adc8","subtext1":"#bac2de",
                    "surface0":"#313244","surface1":"#45475a","surface2":"#585b70",
                    "accent":"#89b4fa","link":"#89b4fa",
                    "warning":"#f9e2af","error":"#f38ba8","info":"#89dceb","success":"#a6e3a1"
                },
                "orchestrators": {
                    "claude-code": {"displayName":"Claude Code","shortName":"CC"}
                },
                "pendingPermissions": [
                    {"requestId":"perm_e2e_001","agentId":"durable_003","toolName":"Bash","message":"Run bash command: npm test","timeout":120000,"deadline":\#(Int(Date().timeIntervalSince1970 * 1000) + 300_000)}
                ],
                "lastSeq": 1
            }
        }
        """#

        sendWebSocketFrame(conn, text: snapshot)
    }

    /// Send a pty:data event to all connected WebSocket clients.
    func broadcastPtyData(agentId: String, data: String) {
        let msg = #"{"type":"pty:data","payload":{"agentId":"\#(agentId)","data":"\#(data)"},"seq":2}"#
        for conn in wsConnections {
            sendWebSocketFrame(conn, text: msg)
        }
    }

    /// Send a hook:event to all connected WebSocket clients.
    func broadcastHookEvent(agentId: String, kind: String, toolName: String?, message: String?) {
        var payload = #"{"agentId":"\#(agentId)","event":{"kind":"\#(kind)","timestamp":\#(Int(Date().timeIntervalSince1970 * 1000))"#
        if let toolName { payload += #","toolName":"\#(toolName)""# }
        if let message { payload += #","message":"\#(message)""# }
        payload += "}}"
        let msg = #"{"type":"hook:event","payload":\#(payload),"seq":3}"#
        for conn in wsConnections {
            sendWebSocketFrame(conn, text: msg)
        }
    }

    // MARK: - WebSocket Framing (RFC 6455)

    private func sendWebSocketFrame(_ conn: NWConnection, text: String) {
        guard let payload = text.data(using: .utf8) else { return }
        var frame = Data()

        // FIN + text opcode
        frame.append(0x81)

        // Payload length (no mask for server→client)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }

        frame.append(payload)

        conn.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("[MockServer] WS send error: \(error)")
            }
        })
    }

    // MARK: - HTTP Helpers

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        headers["authorization"] == "Bearer \(token)"
    }

    private func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased().trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    private func extractBody(from request: String) -> String? {
        guard let range = request.range(of: "\r\n\r\n") else { return nil }
        let body = String(request[range.upperBound...])
        return body.isEmpty ? nil : body
    }

    private func sendHTTPResponse(_ conn: NWConnection, status: Int, body: String, contentType: String = "application/json") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 409: statusText = "Conflict"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let response = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var data = response.data(using: .utf8) ?? Data()
        data.append(bodyData)

        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - SHA-1 (for WebSocket handshake)

    private func sha1Hash(_ data: Data) -> Data {
        // CC_SHA1 via CommonCrypto
        var digest = [UInt8](repeating: 0, count: 20)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

// CommonCrypto import for SHA-1
import CommonCrypto
