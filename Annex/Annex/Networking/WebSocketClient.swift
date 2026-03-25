import Foundation

enum WSEvent: Sendable {
    case snapshot(SnapshotPayload)
    case ptyData(PtyDataPayload)
    case ptyExit(PtyExitPayload)
    case hookEvent(HookEventPayload)
    case structuredEvent(StructuredEventPayload)
    case themeChanged(ThemeColors)
    case agentSpawned(AgentSpawnedPayload)
    case agentStatus(AgentStatusPayload)
    case agentCompleted(AgentCompletedPayload)
    case agentWoken(AgentWokenPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResponse(PermissionResponsePayload)
    case canvasState(CanvasStatePayload)
    case replayGap(ReplayGapPayload)
    case replayStart(ReplayStartPayload)
    case replayEnd
    case disconnected(Error?)

    /// The sequence number from the server envelope, if present.
    var seq: Int? {
        // Stored externally via SeqWSEvent wrapper
        nil
    }
}

/// Wraps a WSEvent with its envelope metadata (seq, replayed).
struct SeqWSEvent: Sendable {
    let event: WSEvent
    let seq: Int?
    let replayed: Bool
}

final class WebSocketClient: Sendable {
    private let url: URL
    private let session: URLSession
    nonisolated(unsafe) private var task: URLSessionWebSocketTask?
    nonisolated(unsafe) private var isConnected = false

    init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func connect() -> AsyncStream<SeqWSEvent> {
        AsyncStream { continuation in
            let wsTask = session.webSocketTask(with: url)
            wsTask.maximumMessageSize = 16 * 1024 * 1024 // 16 MB — snapshots can be large
            self.task = wsTask
            self.isConnected = true
            AppLog.shared.info("WS", "Connecting to \(url.host ?? "?")\(url.port.map { ":\($0)" } ?? "")")
            wsTask.resume()

            Task {
                await self.receiveLoop(task: wsTask, continuation: continuation)
            }

            continuation.onTermination = { @Sendable _ in
                wsTask.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func disconnect() {
        AppLog.shared.info("WS", "Disconnecting (wasConnected=\(isConnected))")
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Send a JSON-encodable message to the server (e.g. replay request).
    func send<T: Encodable>(_ message: T) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            AppLog.shared.error("WS", "Failed to encode outgoing message")
            return
        }
        AppLog.shared.debug("WS", "Sending: \(text.prefix(200))")
        task?.send(.string(text)) { error in
            if let error {
                AppLog.shared.error("WS", "Send error: \(error)")
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, continuation: AsyncStream<SeqWSEvent>.Continuation) async {
        AppLog.shared.debug("WS", "Receive loop started")
        var messageCount = 0
        while isConnected {
            do {
                let message = try await task.receive()
                messageCount += 1
                switch message {
                case .string(let text):
                    if let event = parseMessage(text) {
                        continuation.yield(event)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let event = parseMessage(text) {
                        continuation.yield(event)
                    } else {
                        AppLog.shared.warn("WS", "Received binary data (\(data.count) bytes) — could not parse")
                    }
                @unknown default:
                    AppLog.shared.warn("WS", "Unknown message format")
                }
            } catch {
                AppLog.shared.error("WS", "Receive error after \(messageCount) messages: \(error)")
                if isConnected {
                    continuation.yield(SeqWSEvent(event: .disconnected(error), seq: nil, replayed: false))
                }
                continuation.finish()
                return
            }
        }
        AppLog.shared.info("WS", "Receive loop ended (isConnected=false, processed \(messageCount) messages)")
        continuation.finish()
    }

    private func parseMessage(_ text: String) -> SeqWSEvent? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        // Decode the envelope to get type, seq, and replayed
        guard let envelope = try? decoder.decode(WSEnvelope.self, from: data) else {
            AppLog.shared.warn("WS", "Failed to decode envelope: \(text.prefix(200))")
            return nil
        }

        let seq = envelope.seq
        let replayed = envelope.replayed ?? false

        // Only log non-pty:data events at info level to avoid flooding
        if envelope.type != "pty:data" {
            AppLog.shared.debug("WS", "Received type=\(envelope.type) seq=\(seq.map(String.init) ?? "nil") replayed=\(replayed)")
        }

        // Re-decode payload section based on type
        struct PayloadExtractor<T: Decodable>: Decodable {
            let payload: T
        }

        func extract<T: Decodable>(_ type: T.Type) -> T? {
            do {
                return try decoder.decode(PayloadExtractor<T>.self, from: data).payload
            } catch {
                AppLog.shared.error("WS", "Decode error for \(envelope.type): \(error)")
                AppLog.shared.debug("WS", "Failed payload: \(text.prefix(500))")
                return nil
            }
        }

        func wrap(_ event: WSEvent) -> SeqWSEvent {
            SeqWSEvent(event: event, seq: seq, replayed: replayed)
        }

        switch envelope.type {
        case "snapshot":
            guard let payload = extract(SnapshotPayload.self) else { return nil }
            AppLog.shared.info("WS", "Snapshot received: \(payload.projects.count) projects, \(payload.agents.values.flatMap { $0 }.count) agents")
            return wrap(.snapshot(payload))

        case "pty:data":
            guard let payload = extract(PtyDataPayload.self) else { return nil }
            return wrap(.ptyData(payload))

        case "pty:exit":
            guard let payload = extract(PtyExitPayload.self) else { return nil }
            AppLog.shared.info("WS", "PTY exit: agent=\(payload.agentId) code=\(payload.exitCode)")
            return wrap(.ptyExit(payload))

        case "hook:event":
            guard let payload = extract(HookEventPayload.self) else { return nil }
            return wrap(.hookEvent(payload))

        case "structured:event":
            guard let payload = extract(StructuredEventPayload.self) else { return nil }
            return wrap(.structuredEvent(payload))

        case "theme:changed":
            guard let payload = extract(ThemeColors.self) else { return nil }
            AppLog.shared.info("WS", "Theme changed")
            return wrap(.themeChanged(payload))

        case "agent:spawned":
            guard let payload = extract(AgentSpawnedPayload.self) else { return nil }
            AppLog.shared.info("WS", "Agent spawned: \(payload.name ?? payload.id)")
            return wrap(.agentSpawned(payload))

        case "agent:status":
            guard let payload = extract(AgentStatusPayload.self) else { return nil }
            return wrap(.agentStatus(payload))

        case "agent:completed":
            guard let payload = extract(AgentCompletedPayload.self) else { return nil }
            AppLog.shared.info("WS", "Agent completed: \(payload.id)")
            return wrap(.agentCompleted(payload))

        case "agent:woken":
            guard let payload = extract(AgentWokenPayload.self) else { return nil }
            AppLog.shared.info("WS", "Agent woken: \(payload.agentId)")
            return wrap(.agentWoken(payload))

        case "permission:request":
            guard let payload = extract(PermissionRequestPayload.self) else { return nil }
            AppLog.shared.info("WS", "Permission request: agent=\(payload.agentId) tool=\(payload.toolName)")
            return wrap(.permissionRequest(payload))

        case "permission:response":
            guard let payload = extract(PermissionResponsePayload.self) else { return nil }
            AppLog.shared.info("WS", "Permission response: requestId=\(payload.requestId)")
            return wrap(.permissionResponse(payload))

        case "canvas:state":
            guard let payload = extract(CanvasStatePayload.self) else { return nil }
            AppLog.shared.info("WS", "Canvas state: project=\(payload.projectId) canvas=\(payload.state.canvasId)")
            return wrap(.canvasState(payload))

        case "replay:gap":
            guard let payload = extract(ReplayGapPayload.self) else { return nil }
            AppLog.shared.warn("WS", "Replay gap: lastSeq=\(payload.lastSeq)")
            return wrap(.replayGap(payload))

        case "replay:start":
            guard let payload = extract(ReplayStartPayload.self) else { return nil }
            AppLog.shared.info("WS", "Replay start: from=\(payload.fromSeq)")
            return wrap(.replayStart(payload))

        case "replay:end":
            AppLog.shared.info("WS", "Replay end")
            return wrap(.replayEnd)

        default:
            AppLog.shared.warn("WS", "Unknown message type: \(envelope.type)")
            return nil
        }
    }
}
