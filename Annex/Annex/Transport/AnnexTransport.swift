import Foundation

/// One actor per verified host. No offline mutation queue and no automatic
/// mutation retries: a disconnected response may have already changed the host.
public actor AnnexTransport: AnnexTransporting {
    public nonisolated let host: TrustedAnnexHost
    private let io: any AnnexIO
    private let credentials: any AnnexCredentialStore
    private let backoff: AnnexBackoff
    private let eventCapacity: Int
    private let commandCapacity: Int
    private var subscribers: [UUID: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    private var socket: (any AnnexWebSocket)?
    private var generation = UUID()
    private var state: AnnexConnectionState = .disconnected
    private var capabilities: AnnexCapabilities?
    private var cursor = AnnexReplayCursor()
    private var commandBusy = false
    private struct CommandRecord { let digest: String; var receipt: AnnexCommandReceipt? }
    private var commands: [String: CommandRecord] = [:]

    public init(host: TrustedAnnexHost, credentials: any AnnexCredentialStore, clientIdentity: AnnexClientIdentity? = nil,
                io: (any AnnexIO)? = nil, eventCapacity: Int = 256, commandCapacity: Int = 256, backoff: AnnexBackoff = AnnexBackoff()) {
        self.host = host; self.credentials = credentials; self.io = io ?? PinnedAnnexIO(host: host, clientIdentity: clientIdentity)
        self.eventCapacity = max(1, eventCapacity); self.commandCapacity = max(1, commandCapacity); self.backoff = backoff
    }

    public func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(eventCapacity))
        subscribers[id] = continuation
        continuation.yield(.connection(state))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func emit(_ event: AnnexTransportEvent) {
        for (id, continuation) in subscribers {
            switch continuation.yield(event) {
            case .dropped:
                // No silent loss of permissions/tool deltas. Consumer must resnapshot.
                continuation.finish(throwing: AnnexTransportError.queueOverflow)
                subscribers.removeValue(forKey: id)
            case .terminated: subscribers.removeValue(forKey: id)
            case .enqueued: break
            @unknown default: break
            }
        }
    }
    private func transition(_ state: AnnexConnectionState) { self.state = state; emit(.connection(state)) }

    public func connect() async throws {
        guard loop == nil else { return }
        guard try await credentials.credential(for: host.hostID) != nil else { throw AnnexTransportError.credentialMissing }
        guard loop == nil else { return }
        generation = UUID()
        let current = generation
        transition(.connecting)
        loop = Task { [weak self] in await self?.run(generation: current) }
    }
    public func disconnect() async {
        generation = UUID()
        loop?.cancel(); loop = nil
        let oldSocket = socket; socket = nil
        capabilities = nil
        transition(.disconnected)
        await oldSocket?.close()
    }

    private func authorizedRequest(path: [String], query: [URLQueryItem] = [], webSocket: Bool = false) async throws -> URLRequest {
        guard let credential = try await credentials.credential(for: host.hostID) else { throw AnnexTransportError.credentialMissing }
        var request = URLRequest(url: try host.endpoint.url(path: path, query: query, webSocket: webSocket))
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }
    public func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        let path: [String]; var query: [URLQueryItem] = []
        switch route {
        case .identity: path = ["api", "v1", "identity"]
        case .status: path = ["api", "v1", "status"]
        case .projects: path = ["api", "v1", "projects"]
        case .capabilities: path = ["api", "v1", "mobile", "capabilities"]
        case .chat(let agent): path = ["api", "v1", "mobile", "agents", agent, "chat"]
        case .agents(let project): path = ["api", "v1", "projects", project, "agents"]
        case .sessions(let agent): path = ["api", "v1", "agents", agent, "sessions"]
        case .transcript(let agent, let session, let offset, let limit):
            path = ["api", "v1", "agents", agent, "sessions", session, "transcript"]
            query = [URLQueryItem(name: "offset", value: String(max(0, offset))), URLQueryItem(name: "limit", value: String(min(500, max(1, limit))))]
        }
        let request = try await authorizedRequest(path: path, query: query)
        try Task.checkCancellation()
        let response = try await io.perform(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else { throw AnnexHTTPValidation.error(response) }
        guard let value = try? JSONDecoder().decode(AnnexJSON.self, from: response.data) else { throw AnnexTransportError.malformedResponse }
        if case .capabilities = route {
            let decoded = try value.decode(AnnexCapabilities.self)
            guard decoded.version == 1, !decoded.epoch.isEmpty, decoded.controlAuth == "mtls-pinned-client" else {
                throw AnnexTransportError.unsupportedCapability("mobile-control-v1")
            }
            capabilities = decoded
        }
        return value
    }

    public func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt {
        let data = try command.encoded()
        let digest = AnnexCertificatePin.digest(data)
        let key = command.epoch + ":" + command.commandID
        if let recorded = commands[key] {
            guard recorded.digest == digest else { throw AnnexTransportError.duplicateCommandConflict }
            if let receipt = recorded.receipt { return receipt }
            throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
        }
        guard !commandBusy else { throw AnnexTransportError.commandInFlight }
        guard commands.count < commandCapacity else { throw AnnexTransportError.queueOverflow }
        guard let capabilities, capabilities.epoch == command.epoch, capabilities.commands.contains(command.type) else {
            throw AnnexTransportError.unsupportedCapability(command.type)
        }
        // Reserve before the first await so concurrent commands cannot overtake.
        commandBusy = true
        defer { commandBusy = false }
        var request = try await authorizedRequest(path: ["api", "v1", "mobile", "commands"])
        try Task.checkCancellation()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        commands[key] = CommandRecord(digest: digest, receipt: nil)
        do {
            let response = try await io.perform(request)
            // A valid receipt wins even if cancellation races after dispatch.
            guard let receipt = try? JSONDecoder().decode(AnnexCommandReceipt.self, from: response.data),
                  receipt.version == 1, receipt.commandId == command.commandID, receipt.epoch == command.epoch else {
                throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
            }
            commands[key]?.receipt = receipt
            return receipt
        } catch {
            // Cancellation after dispatch cannot prove the server did not execute.
            throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
        }
    }

    private func run(generation current: UUID) async {
        var attempt = 0
        var hasConnected = false
        while !Task.isCancelled && current == generation {
            do {
                // Bind the stored host identity to the pinned endpoint on every connection.
                let identity = try await read(.identity)
                guard let publicKey = identity["publicKey"]?.string,
                      try AnnexPairingIdentity.fingerprint(publicKeyBase64: publicKey) == host.hostID,
                      identity["fingerprint"]?.string?.lowercased() == host.hostID else { throw AnnexTransportError.identityMismatch }
                do { _ = try await read(.capabilities) }
                catch AnnexTransportError.rejected(status: 404, code: _) { capabilities = nil }
                let request = try await authorizedRequest(path: ["ws"], webSocket: true)
                let newSocket = try await io.openWebSocket(request)
                guard current == generation && !Task.isCancelled else { await newSocket.close(); return }
                socket = newSocket
                transition(.connected)
                if hasConnected { emit(.resyncRequired(.reconnected)) }
                hasConnected = true
                try await consume(newSocket, generation: current)
            } catch {
                guard current == generation && !Task.isCancelled else { return }
                let oldSocket = socket; socket = nil; await oldSocket?.close()
                if let terminal = terminalError(error) {
                    transition(.failed(terminal)); loop = nil; return
                }
                attempt += 1
                let delay = backoff.delay(attempt: attempt)
                transition(.reconnecting(attempt: attempt, delaySeconds: delay))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func terminalError(_ error: Error) -> AnnexTransportError? {
        if let error = error as? AnnexTransportError {
            switch error {
            case .identityMismatch, .trustRequired, .unauthorized, .forbidden, .credentialMissing, .malformedResponse, .responseTooLarge: return error
            default: return nil
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
                 .secureConnectionFailed, .userCancelledAuthentication: return .trustRequired
            default: return nil
            }
        }
        return nil
    }

    private func consume(_ socket: any AnnexWebSocket, generation current: UUID) async throws {
        // Structured lifetime: ping and receive are both cancelled on disconnect.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while !Task.isCancelled { try await Task.sleep(for: .seconds(20)); try await socket.ping() }
                } catch { await socket.close(); throw error }
            }
            group.addTask { [weak self] in
                do {
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        guard let self else { return }
                        try await self.receive(data, socket: socket, generation: current)
                    }
                } catch { await socket.close(); throw error }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func receive(_ data: Data, socket: any AnnexWebSocket, generation current: UUID) async throws {
        guard current == generation else { throw CancellationError() }
        guard data.count <= 16 * 1024 * 1024, let envelope = try? JSONDecoder().decode(AnnexEnvelope.self, from: data) else {
            throw AnnexTransportError.malformedResponse
        }
        switch cursor.accept(envelope) {
        case .duplicate: return
        case .resync(let reason):
            emit(.resyncRequired(reason))
            if envelope.type != "snapshot" { throw AnnexTransportError.disconnected }
        case .deliver: break
        }
        emit(.message(envelope))
        if envelope.type == "snapshot", let seq = envelope.snapshotSequence {
            var replay: [String: AnnexJSON] = ["type": .string("replay"), "since": .integer(seq)]
            if let capabilities { replay["type"] = .string("mobile:replay"); replay["epoch"] = .string(capabilities.epoch) }
            try await socket.send(JSONEncoder().encode(AnnexJSON.object(replay)))
        }
    }
}
