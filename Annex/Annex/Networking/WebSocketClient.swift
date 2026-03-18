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
            self.task = wsTask
            self.isConnected = true
            print("[Annex] WS connecting to \(url)")
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
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Send a JSON-encodable message to the server (e.g. replay request).
    func send<T: Encodable>(_ message: T) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error {
                print("[Annex] WS send error: \(error)")
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, continuation: AsyncStream<SeqWSEvent>.Continuation) async {
        while isConnected {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    if let event = parseMessage(text) {
                        continuation.yield(event)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let event = parseMessage(text) {
                        continuation.yield(event)
                    }
                @unknown default:
                    break
                }
            } catch {
                print("[Annex] WS receive error: \(error)")
                if isConnected {
                    continuation.yield(SeqWSEvent(event: .disconnected(error), seq: nil, replayed: false))
                }
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }

    private func parseMessage(_ text: String) -> SeqWSEvent? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        // Decode the envelope to get type, seq, and replayed
        guard let envelope = try? decoder.decode(WSEnvelope.self, from: data) else {
            print("[Annex] WS failed to decode envelope: \(text.prefix(200))")
            return nil
        }

        let seq = envelope.seq
        let replayed = envelope.replayed ?? false

        print("[Annex] WS received type=\(envelope.type) seq=\(seq.map(String.init) ?? "nil") replayed=\(replayed)")

        // Re-decode payload section based on type
        struct PayloadExtractor<T: Decodable>: Decodable {
            let payload: T
        }

        func extract<T: Decodable>(_ type: T.Type) -> T? {
            do {
                return try decoder.decode(PayloadExtractor<T>.self, from: data).payload
            } catch {
                print("[Annex] WS decode error for \(envelope.type): \(error)")
                return nil
            }
        }

        func wrap(_ event: WSEvent) -> SeqWSEvent {
            SeqWSEvent(event: event, seq: seq, replayed: replayed)
        }

        switch envelope.type {
        case "snapshot":
            guard let payload = extract(SnapshotPayload.self) else { return nil }
            return wrap(.snapshot(payload))

        case "pty:data":
            guard let payload = extract(PtyDataPayload.self) else { return nil }
            return wrap(.ptyData(payload))

        case "pty:exit":
            guard let payload = extract(PtyExitPayload.self) else { return nil }
            return wrap(.ptyExit(payload))

        case "hook:event":
            guard let payload = extract(HookEventPayload.self) else { return nil }
            return wrap(.hookEvent(payload))

        case "structured:event":
            guard let payload = extract(StructuredEventPayload.self) else { return nil }
            return wrap(.structuredEvent(payload))

        case "theme:changed":
            guard let payload = extract(ThemeColors.self) else { return nil }
            return wrap(.themeChanged(payload))

        case "agent:spawned":
            guard let payload = extract(AgentSpawnedPayload.self) else { return nil }
            return wrap(.agentSpawned(payload))

        case "agent:status":
            guard let payload = extract(AgentStatusPayload.self) else { return nil }
            return wrap(.agentStatus(payload))

        case "agent:completed":
            guard let payload = extract(AgentCompletedPayload.self) else { return nil }
            return wrap(.agentCompleted(payload))

        case "agent:woken":
            guard let payload = extract(AgentWokenPayload.self) else { return nil }
            return wrap(.agentWoken(payload))

        case "permission:request":
            guard let payload = extract(PermissionRequestPayload.self) else { return nil }
            return wrap(.permissionRequest(payload))

        case "permission:response":
            guard let payload = extract(PermissionResponsePayload.self) else { return nil }
            return wrap(.permissionResponse(payload))

        case "replay:gap":
            guard let payload = extract(ReplayGapPayload.self) else { return nil }
            return wrap(.replayGap(payload))

        case "replay:start":
            guard let payload = extract(ReplayStartPayload.self) else { return nil }
            return wrap(.replayStart(payload))

        case "replay:end":
            return wrap(.replayEnd)

        default:
            print("[Annex] WS unknown message type: \(envelope.type)")
            return nil
        }
    }
}
