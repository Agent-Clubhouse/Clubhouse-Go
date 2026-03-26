import Foundation
import Network
import CryptoKit

/// A lightweight mock Annex server for integration testing.
/// Implements the minimum endpoints needed for pairing + snapshot delivery.
final class MockAnnexServer {
    let pairingPort: UInt16
    let mainPort: UInt16
    let token = UUID().uuidString
    let fingerprint = "mock-fingerprint-\(UUID().uuidString.prefix(8))"

    private var pairingListener: NWListener?
    private var mainListener: NWListener?
    private var connections: [NWConnection] = []

    /// Snapshot JSON to send over WebSocket after connection.
    var snapshotJSON: String = MockAnnexServer.defaultSnapshot

    init(pairingPort: UInt16 = 0, mainPort: UInt16 = 0) {
        self.pairingPort = pairingPort
        self.mainPort = mainPort
    }

    // MARK: - Start / Stop

    func start() throws -> (pairingPort: UInt16, mainPort: UInt16) {
        // Start pairing server (plain HTTP)
        let pairingParams = NWParameters.tcp
        pairingListener = try NWListener(using: pairingParams, on: pairingPort == 0 ? .any : NWEndpoint.Port(rawValue: pairingPort)!)
        pairingListener?.newConnectionHandler = { [weak self] conn in
            self?.handlePairingConnection(conn)
        }
        pairingListener?.start(queue: .global(qos: .userInitiated))

        // Start main server (plain HTTP + WebSocket for testing, no TLS in mock)
        let mainParams = NWParameters.tcp
        mainListener = try NWListener(using: mainParams, on: mainPort == 0 ? .any : NWEndpoint.Port(rawValue: mainPort)!)
        mainListener?.newConnectionHandler = { [weak self] conn in
            self?.handleMainConnection(conn)
        }
        mainListener?.start(queue: .global(qos: .userInitiated))

        // Wait for ports to be assigned
        Thread.sleep(forTimeInterval: 0.5)

        let actualPairingPort = pairingListener?.port?.rawValue ?? 0
        let actualMainPort = mainListener?.port?.rawValue ?? 0

        return (pairingPort: actualPairingPort, mainPort: actualMainPort)
    }

    func stop() {
        pairingListener?.cancel()
        mainListener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Pairing Connection (POST /pair)

    private func handlePairingConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTP(connection) { [weak self] request in
            guard let self else { return }
            if request.contains("POST /pair") {
                let response = """
                {
                    "token": "\(self.token)",
                    "publicKey": "mock-public-key-base64",
                    "alias": "Mock Clubhouse",
                    "icon": "desktopcomputer",
                    "color": "blue",
                    "fingerprint": "\(self.fingerprint)"
                }
                """
                self.sendHTTPResponse(connection, statusCode: 200, contentType: "application/json", body: response)
            } else {
                self.sendHTTPResponse(connection, statusCode: 404, contentType: "text/plain", body: "Not Found")
            }
        }
    }

    // MARK: - Main Connection (GET /api/v1/status, WebSocket /ws)

    private func handleMainConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTP(connection) { [weak self] request in
            guard let self else { return }
            if request.contains("GET /api/v1/status") {
                let response = """
                {
                    "version": "2",
                    "deviceName": "Mock Clubhouse",
                    "agentCount": 3,
                    "orchestratorCount": 1
                }
                """
                self.sendHTTPResponse(connection, statusCode: 200, contentType: "application/json", body: response)
            } else if request.contains("GET /ws") {
                self.upgradeToWebSocket(connection, request: request)
            } else if request.contains("GET /api/v1/projects") {
                let response = """
                [
                    {
                        "id": "proj_mock_001",
                        "name": "mock-project",
                        "path": "/tmp/mock-project",
                        "color": "blue",
                        "icon": null,
                        "displayName": "Mock Project",
                        "orchestrator": null
                    }
                ]
                """
                self.sendHTTPResponse(connection, statusCode: 200, contentType: "application/json", body: response)
            } else {
                self.sendHTTPResponse(connection, statusCode: 404, contentType: "text/plain", body: "Not Found")
            }
        }
    }

    // MARK: - WebSocket Upgrade

    private func upgradeToWebSocket(_ connection: NWConnection, request: String) {
        // Extract Sec-WebSocket-Key from request
        guard let keyLine = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else {
            sendHTTPResponse(connection, statusCode: 400, contentType: "text/plain", body: "Missing WebSocket key")
            return
        }
        let key = keyLine.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        let acceptKey = computeWebSocketAcceptKey(key)

        let upgradeResponse = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        connection.send(content: upgradeResponse.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            // Send snapshot as a WebSocket text frame
            let snapshotMessage = """
            {"type":"snapshot","payload":\(self.snapshotJSON)}
            """
            self.sendWebSocketTextFrame(connection, text: snapshotMessage)
        })
    }

    private func sendWebSocketTextFrame(_ connection: NWConnection, text: String) {
        guard let payload = text.data(using: .utf8) else { return }
        var frame = Data()

        // Text frame opcode
        frame.append(0x81)

        // Payload length
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
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func computeWebSocketAcceptKey(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        guard let data = magic.data(using: .utf8) else { return "" }
        let hash = Insecure.SHA1.hash(data: data)
        return Data(hash).base64EncodedString()
    }

    // MARK: - HTTP Helpers

    private func receiveHTTP(_ connection: NWConnection, handler: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data, error == nil,
                  let request = String(data: data, encoding: .utf8) else { return }
            handler(request)
        }
    }

    private func sendHTTPResponse(_ connection: NWConnection, statusCode: Int, contentType: String, body: String) {
        let statusText = statusCode == 200 ? "OK" : statusCode == 404 ? "Not Found" : "Error"
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Default Snapshot

    static let defaultSnapshot = """
    {
        "projects": [
            {
                "id": "proj_mock_001",
                "name": "mock-project",
                "path": "/tmp/mock-project",
                "color": "blue",
                "icon": null,
                "displayName": "Mock Project",
                "orchestrator": null
            }
        ],
        "agents": {
            "proj_mock_001": [
                {
                    "id": "agent_mock_001",
                    "name": "test-agent",
                    "kind": "durable",
                    "status": "running",
                    "color": "green",
                    "branch": "main",
                    "model": "claude-sonnet-4-6",
                    "orchestrator": null,
                    "freeAgentMode": false,
                    "mission": "Running integration tests"
                }
            ]
        },
        "quickAgents": {},
        "theme": {
            "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b",
            "text": "#cdd6f4", "subtext0": "#a6adc8", "subtext1": "#bac2de",
            "surface0": "#313244", "surface1": "#45475a", "surface2": "#585b70",
            "accent": "#89b4fa", "link": "#89b4fa",
            "warning": "#f9e2af", "error": "#f38ba8", "info": "#89dceb", "success": "#a6e3a1"
        },
        "orchestrators": {},
        "pendingPermissions": []
    }
    """
}
