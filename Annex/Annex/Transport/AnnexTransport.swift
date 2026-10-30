import Foundation

/// One actor per verified host. No offline mutation queue and no automatic
/// mutation retries: a disconnected response may have already changed the host.
public actor AnnexTransport: AnnexTransporting {
    public nonisolated let host: TrustedAnnexHost
    private let io: any AnnexIO
    private let telemetry: AnnexTelemetry
    private let credentials: any AnnexCredentialStore
    private let backoff: AnnexBackoff
    private let eventCapacity: Int
    private let commandCapacity: Int
    private var subscribers: [UUID: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation] = [:]
    private var terminalSubscribers: [UUID: AsyncStream<AnnexTerminalEvent>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    private var connectionDiagnostic: AnnexDiagnosticSpan?
    private var telemetryBinding: AnnexTelemetryHandshake?
    private var telemetryHello: (request: AnnexTelemetryHandshake.Request, span: AnnexDiagnosticSpan)?
    private var telemetryDeadline: Task<Void, Never>?
    private var socket: (any AnnexWebSocket)?
    private var generation = UUID()
    private var state: AnnexConnectionState = .disconnected
    private var capabilities: AnnexCapabilities?
    private var cursor = AnnexReplayCursor()
    private var commandBusy = false
    private struct CommandRecord { let digest: String; let expiresAt: Date; var receipt: AnnexCommandReceipt? }
    private struct CommandKey: Hashable { let epoch: String; let id: String }
    private var commands: [CommandKey: CommandRecord] = [:]

    public init(host: TrustedAnnexHost, credentials: any AnnexCredentialStore, clientIdentity: AnnexClientIdentity? = nil,
                io: (any AnnexIO)? = nil, eventCapacity: Int = 256, commandCapacity: Int = 256, backoff: AnnexBackoff = AnnexBackoff(), telemetry: AnnexTelemetry = .shared) {
        self.telemetry = telemetry
        self.host = host; self.credentials = credentials; self.io = io ?? PinnedAnnexIO(host: host, clientIdentity: clientIdentity, telemetry: telemetry)
        self.eventCapacity = max(1, eventCapacity); self.commandCapacity = max(1, commandCapacity); self.backoff = backoff
    }

    public func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(eventCapacity))
        guard subscribers.count < 16 else {
            continuation.finish(throwing: AnnexTransportError.queueOverflow)
            return stream
        }
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
                telemetry.record(.replay, event: .overflow)
                // No silent loss of permissions/tool deltas. Consumer must resnapshot.
                continuation.finish(throwing: AnnexTransportError.queueOverflow)
                subscribers.removeValue(forKey: id)
            case .terminated: subscribers.removeValue(forKey: id)
            case .enqueued: break
            @unknown default: break
            }
        }
    }
    private func transition(_ state: AnnexConnectionState) { self.state = state; emit(.connection(state)); emitTerminal(.connection(state)) }

    /// Shell output can arrive far faster than chat, so terminals get their own, deeper stream. A terminal that
    /// falls behind is finished rather than shown with gaps; it opens again from a fresh spawn or snapshot.
    public func terminalEvents() async -> AsyncStream<AnnexTerminalEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AnnexTerminalEvent>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        terminalSubscribers[id] = continuation
        continuation.yield(.connection(state))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeTerminalSubscriber(id) } }
        return stream
    }
    private func removeTerminalSubscriber(_ id: UUID) { terminalSubscribers.removeValue(forKey: id) }
    private func emitTerminal(_ event: AnnexTerminalEvent) {
        for (id, continuation) in terminalSubscribers {
            switch continuation.yield(event) {
            case .dropped:
                continuation.finish()
                terminalSubscribers.removeValue(forKey: id)
            case .terminated: terminalSubscribers.removeValue(forKey: id)
            case .enqueued: break
            @unknown default: break
            }
        }
    }
    /// `pty:*` messages and the errors that answer them.
    static func isTerminalFrame(_ envelope: AnnexEnvelope) -> Bool {
        envelope.type.hasPrefix("pty:") || (envelope.type == "error" && envelope.payload?["op"]?.string?.hasPrefix("pty:") == true)
    }

    /// Terminal messages are mTLS-only on the desktop, like commands, and need its `terminal` capability.
    public func sendTerminal(_ frame: AnnexTerminalFrame) async throws {
        guard let capabilities, capabilities.supportsTerminal, let terminal = capabilities.terminal else {
            throw AnnexTransportError.unsupportedCapability("terminal")
        }
        guard state == .connected, let socket else { throw AnnexTransportError.disconnected }
        let frames: [AnnexTerminalFrame]
        if case .input(let id, let data) = frame {
            frames = AnnexTerminalInput.chunks(data, maxLength: terminal.maxInputLength).map { .input(id: id, data: $0) }
        } else {
            frames = [frame]
        }
        for frame in frames { try await socket.send(frame.encoded()) }
    }

    public func connect() async throws {
        return try await telemetry.measure(.connection) {
            guard loop == nil else { return }
            let requestedGeneration = generation
            guard try await credentials.credential(for: host.hostID) != nil else { throw AnnexTransportError.credentialMissing }
            guard loop == nil, generation == requestedGeneration else { return }
            try Task.checkCancellation()
            generation = UUID()
            let current = generation
            transition(.connecting)
            loop = Task { [weak self] in await self?.run(generation: current) }

        }
    }
    public func disconnect() async {
        telemetry.record(.disconnect)
        endTelemetryHello(.cancelled)
        telemetryBinding = nil
        connectionDiagnostic?.fail(.cancelled); connectionDiagnostic?.end(); connectionDiagnostic = nil
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
        if telemetry.isEnabled, let telemetryBinding {
            telemetryBinding.annotate(AnnexTelemetry.current)
        }
        return request
    }
    public func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        return try await telemetry.measure(route.diagnosticOperation) {
            let requestedGeneration = generation
            let path: [String]; var query: [URLQueryItem] = []
            switch route {
            case .identity: path = ["api", "v1", "identity"]
            case .status: path = ["api", "v1", "status"]
            case .projects: path = ["api", "v1", "projects"]
            case .capabilities: path = ["api", "v1", "mobile", "capabilities"]
            case .chatContent(let agent, let reference, let file):
                guard (reference != nil) != (file != nil) else { throw AnnexTransportError.invalidEndpoint }
                path = ["api", "v1", "mobile", "agents", agent, "content"]
                if let reference { query = [.init(name: "mediaRef", value: reference)] }
                if let file { query = [.init(name: "path", value: file)] }
            case .chat(let agent): path = ["api", "v1", "mobile", "agents", agent, "chat"]
            case .chatSessions(let agent): path = ["api", "v1", "mobile", "agents", agent, "chat", "sessions"]
            case .chatHistory(let agent, let session, let before, let limit):
                path = ["api", "v1", "mobile", "agents", agent, "chat"]
                query = [URLQueryItem(name: "limit", value: String(min(2000, max(1, limit))))]
                if let session { query.append(URLQueryItem(name: "sessionId", value: session)) }
                if let before { query.append(URLQueryItem(name: "beforeSeq", value: String(max(1, before)))) }
            case .agents(let project): path = ["api", "v1", "projects", project, "agents"]
            case .sessions(let agent): path = ["api", "v1", "agents", agent, "sessions"]
            case .transcript(let agent, let session, let offset, let limit):
                path = ["api", "v1", "agents", agent, "sessions", session, "transcript"]
                query = [URLQueryItem(name: "offset", value: String(max(0, offset))), URLQueryItem(name: "limit", value: String(min(500, max(1, limit))))]
            case .createOptions(let project): path = ["api", "v1", "mobile", "projects", project, "create-options"]
            case .agentSettings(let agent): path = ["api", "v1", "mobile", "agents", agent, "settings"]
            case .gitStatus(let project): path = ["api", "v1", "projects", project, "git", "info"]
            case .gitDiff(let project, let file, let staged):
                path = ["api", "v1", "projects", project, "git", "diff"]
                query = [.init(name: "file", value: file), .init(name: "staged", value: staged ? "true" : "false")]
            }
            let request = try await authorizedRequest(path: path, query: query)
            guard generation == requestedGeneration else { throw AnnexTransportError.disconnected }
            try Task.checkCancellation()
            let response = try await io.perform(request)
            guard generation == requestedGeneration else { throw AnnexTransportError.disconnected }
            try Task.checkCancellation()
            if case .capabilities = route {
                // Any refused capability document withdraws command authority; never keep a stale epoch.
                do {
                    let (value, decoded) = try Self.validatedCapabilities(response)
                    capabilities = decoded
                    return value
                } catch { capabilities = nil; throw error }
            }
            guard (200...299).contains(response.status) else { throw AnnexHTTPValidation.error(response) }
            guard let value = try? JSONDecoder().decode(AnnexJSON.self, from: response.data) else { throw AnnexTransportError.malformedResponse }
            return value

        }
    }

    private static func validatedCapabilities(_ response: AnnexHTTPResponse) throws -> (AnnexJSON, AnnexCapabilities) {
        guard (200...299).contains(response.status) else { throw AnnexHTTPValidation.error(response) }
        guard let value = try? JSONDecoder().decode(AnnexJSON.self, from: response.data) else { throw AnnexTransportError.malformedResponse }
        let decoded = try value.decode(AnnexCapabilities.self)
        guard decoded.version == 1, !decoded.epoch.isEmpty, decoded.controlAuth == "mtls-pinned-client" else {
            throw AnnexTransportError.unsupportedCapability("mobile-control-v1")
        }
        return (value, decoded)
    }

    public func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt {
        return try await telemetry.measure(command.diagnosticOperation) {
            let data = try command.encoded()
            let now = Date()
            let ttl = min(3600, max(1, Double(capabilities?.idempotency.ttlMs ?? 3600000) / 1000))
            guard now.timeIntervalSince(command.createdAt) < ttl else {
                throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
            }
            commands = commands.filter { $0.value.expiresAt > now }
            let digest = AnnexCertificatePin.digest(data)
            let key = CommandKey(epoch: command.epoch, id: command.commandID)
            if let recorded = commands[key] {
                guard recorded.digest == digest else { throw AnnexTransportError.duplicateCommandConflict }
                if let receipt = recorded.receipt { return receipt }
                throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
            }
            guard !commandBusy else { throw AnnexTransportError.commandInFlight }
            guard commands.count < commandCapacity else { throw AnnexTransportError.queueOverflow }
            guard let capabilities, capabilities.controlAvailable == true, capabilities.epoch == command.epoch, capabilities.commands.contains(command.type) else {
                throw AnnexTransportError.unsupportedCapability(command.type)
            }
            // Reserve before the first await so concurrent commands cannot overtake.
            let requestedGeneration = generation
            commandBusy = true
            defer { commandBusy = false }
            var request = try await authorizedRequest(path: ["api", "v1", "mobile", "commands"])
            guard generation == requestedGeneration, self.capabilities?.epoch == command.epoch,
                  self.capabilities?.controlAvailable == true else { throw AnnexTransportError.disconnected }
            try Task.checkCancellation()
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            commands[key] = CommandRecord(digest: digest, expiresAt: command.createdAt.addingTimeInterval(ttl), receipt: nil)
            do {
                let response = try await io.perform(request)
                // A valid receipt wins even if cancellation races after dispatch.
                guard let receipt = try? JSONDecoder().decode(AnnexCommandReceipt.self, from: response.data),
                      receipt.version == 1,
                      (receipt.commandId == command.commandID || (receipt.commandId == nil && receipt.status == .rejected)),
                      (receipt.epoch == command.epoch || (receipt.status == .rejected && receipt.error?.code == "epoch_mismatch")),
                      ((receipt.status == .completed && (200...299).contains(response.status))
                       || (receipt.status == .rejected && (400...499).contains(response.status))
                       || (receipt.status == .failed && (500...599).contains(response.status))) else {
                    throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
                }
                if receipt.status != .completed { AnnexTelemetry.current?.fail(receipt.status == .failed ? .server : .rejected) }
            commands[key]?.receipt = receipt
                return receipt
            } catch {
                // Cancellation after dispatch cannot prove the server did not execute.
                throw AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)
            }

        }
    }

    /// Raw bytes over the pinned client certificate, like commands. Never retried here: an upload whose reply
    /// is lost only leaves an unused id on the desktop, and the caller decides whether to upload again.
    public func upload(agentID: String, data: Data, mimeType: String) async throws -> AnnexAttachmentUpload {
        return try await telemetry.measure(.upload) {
            guard let capabilities, capabilities.controlAvailable == true, let limits = capabilities.attachments, limits.isUsable,
                  capabilities.commands.contains("chat.send") else { throw AnnexTransportError.unsupportedCapability("attachments") }
            guard limits.imageTypes.contains(mimeType), !data.isEmpty else { throw AnnexTransportError.rejected(status: 415, code: "unsupported_media_type") }
            guard data.count <= limits.maxImageBytes else { throw AnnexTransportError.rejected(status: 413, code: "too_large") }
            let requestedGeneration = generation
            let epoch = capabilities.epoch
            var request = try await authorizedRequest(path: ["api", "v1", "mobile", "agents", agentID, "attachments"])
            guard generation == requestedGeneration, self.capabilities?.epoch == epoch else { throw AnnexTransportError.disconnected }
            try Task.checkCancellation()
            request.httpMethod = "POST"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            // A few megabytes over a slow route can take longer than a command; the session caps it at 60 s.
            request.timeoutInterval = 60
            let response = try await io.perform(request)
            guard (200...299).contains(response.status) else { throw AnnexHTTPValidation.error(response) }
            guard let receipt = try? JSONDecoder().decode(AnnexAttachmentUpload.self, from: response.data), receipt.version == 1,
                  !receipt.attachmentId.isEmpty, receipt.attachmentId.count <= 128 else { throw AnnexTransportError.malformedResponse }
            return receipt

        }
    }

    /// Explicit self-revocation only; no caller-selected path or target identity.
    /// Unknown outcomes retain local credentials so the UI can explain recovery.
    public func revokeSessionPairing() async throws {
        return try await telemetry.measure(.revoke) {
            _ = try await read(.capabilities)
            guard let capabilities, capabilities.controlAvailable == true,
                  capabilities.pairing?.sessionRevokePath == "/api/v1/mobile/pairing" else {
                throw AnnexTransportError.unsupportedCapability("session-revocation")
            }
            let requestedGeneration = generation
            var request = try await authorizedRequest(path: ["api", "v1", "mobile", "pairing"])
            guard generation == requestedGeneration else { throw AnnexTransportError.disconnected }
            try Task.checkCancellation()
            request.httpMethod = "DELETE"
            let response: AnnexHTTPResponse
            do { response = try await io.perform(request) }
            catch { throw AnnexTransportError.pairingRevocationOutcomeUnknown }
            guard (200...299).contains(response.status) else { throw AnnexHTTPValidation.error(response) }
            guard let receipt = try? JSONDecoder().decode(AnnexJSON.self, from: response.data),
                  receipt["version"] == .integer(1), receipt["epoch"] == .string(capabilities.epoch),
                  receipt["revoked"] == .bool(true), receipt["pairingMode"] == .string("session") else {
                throw AnnexTransportError.pairingRevocationOutcomeUnknown
            }
            await disconnect()

        }
    }

    private func run(generation current: UUID) async {
        var attempt = 0
        var hasConnected = false
        while !Task.isCancelled && current == generation {
            let started = ContinuousClock.now
            let diagnostic = telemetry.begin(hasConnected ? .reconnect : .connection, parent: nil)
            connectionDiagnostic = diagnostic
            endTelemetryHello(.cancelled)
            telemetryBinding = nil
            let attemptID = UUID()
            diagnostic.identifier(.connectionAttemptID, attemptID)
            defer { diagnostic.end() }
            do {
                try await AnnexTelemetry.$current.withValue(diagnostic) {
                // Bind the stored host identity to the pinned endpoint on every connection.
                let identity = try await read(.identity)
                guard let publicKey = identity["publicKey"]?.string,
                      try AnnexPairingIdentity.fingerprint(publicKeyBase64: publicKey) == host.hostID,
                      identity["fingerprint"]?.string?.lowercased() == host.hostID else { throw AnnexTransportError.identityMismatch }
                do { _ = try await read(.capabilities) }
                catch AnnexTransportError.rejected(status: 404, code: _) { capabilities = nil }
                let request = try await authorizedRequest(path: ["ws"], webSocket: true)
                guard current == generation && !Task.isCancelled else { return }
                let newSocket = try await io.openWebSocket(request)
                guard current == generation && !Task.isCancelled else { await newSocket.close(); return }
                socket = newSocket
                try await sendTelemetryHello(on: newSocket, attemptID: attemptID, generation: current)
                cursor.beginConnection()
                if hasConnected { emit(.resyncRequired(.reconnected)) }
                hasConnected = true
                try await consume(newSocket, generation: current)
                }
            } catch {
                diagnostic.fail(error); diagnostic.end()
                if current == generation { endTelemetryHello(AnnexDiagnosticFailure.classify(error)) }
                guard current == generation && !Task.isCancelled else { return }
                capabilities = nil
                let oldSocket = socket; socket = nil; await oldSocket?.close()
                guard current == generation && !Task.isCancelled else { return }
                if let terminal = terminalError(error) {
                    transition(.failed(terminal)); loop = nil; return
                }
                if ContinuousClock.now - started > .seconds(30) { attempt = 0 }
                attempt += 1
                let delay = backoff.delay(attempt: attempt)
                let diagnostic = telemetry.begin(.backoff)
                diagnostic.fail(error); diagnostic.number(.attempt, Double(attempt)); diagnostic.number(.backoffMs, delay * 1000)
                diagnostic.end()
                transition(.reconnecting(attempt: attempt, delaySeconds: delay))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    /// Hello/ack is itself capability negotiation. Old hosts ignore unknown
    /// messages; normal snapshots/chat never wait for this optional ack.
    private func sendTelemetryHello(on socket: any AnnexWebSocket, attemptID: UUID, generation current: UUID) async throws {
        guard telemetry.isEnabled, capabilities?.controlAvailable == true else { return }
        let span = telemetry.begin(.handshake)
        let request = AnnexTelemetryHandshake.Request(instanceID: telemetry.instanceID, attemptID: attemptID)
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(request))
        var message: [String: AnnexJSON] = ["type": .string("telemetry:hello"), "payload": payload]
        if let tc = telemetry.traceparent(for: span) { message["tc"] = .string(tc) }
        telemetryHello = (request, span)
        do { try await socket.send(JSONEncoder().encode(AnnexJSON.object(message))) }
        catch {
            if current == generation { endTelemetryHello(AnnexDiagnosticFailure.classify(error)) }
            throw error
        }
        // A delayed old send must never clear a newer connection's pending hello.
        guard current == generation else { return }
        telemetryDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.expireTelemetryHello(generation: current)
        }
    }
    private func expireTelemetryHello(generation current: UUID) {
        guard current == generation else { return }
        telemetryHello?.span.event(.unsupported)
        endTelemetryHello(.timeout)
    }
    private func endTelemetryHello(_ failure: AnnexDiagnosticFailure) {
        telemetryDeadline?.cancel(); telemetryDeadline = nil
        telemetryHello?.span.fail(failure); telemetryHello?.span.end(); telemetryHello = nil
    }
    private func acceptTelemetryAck(_ payload: AnnexJSON?) {
        guard let pending = telemetryHello, telemetry.isEnabled,
              telemetry.traceparent(for: pending.span) != nil else { return }
        do {
            guard let payload else { throw AnnexTransportError.malformedResponse }
            let binding = try AnnexTelemetryHandshake.validate(JSONEncoder().encode(payload), request: pending.request)
            telemetryBinding = binding
            binding.annotate(pending.span); binding.annotate(connectionDiagnostic)
            endTelemetryHello(.none)
        } catch {
            pending.span.event(.rejected)
            // A later valid ack may still arrive; never replace identities from bad data.
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
                 .secureConnectionFailed, .userCancelledAuthentication, .cancelled: return .trustRequired
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
        guard data.count <= 16 * 1024 * 1024, var envelope = try? JSONDecoder().decode(AnnexEnvelope.self, from: data) else {
            throw AnnexTransportError.malformedResponse
        }
        if envelope.type == "telemetry:hello:ack" {
            acceptTelemetryAck(envelope.payload)
            return
        }
        if envelope.type == "snapshot" {
            guard let seq = envelope.snapshotSequence, seq >= 0,
                  envelope.epoch == nil || envelope.epoch == capabilities?.epoch else {
                throw AnnexTransportError.malformedResponse
            }
        }
        switch cursor.accept(envelope) {
        case .duplicate:
            telemetry.record(.replay, event: .duplicate)
            return
        case .resync(let reason):
            telemetry.record(.replay, event: .gap)
            emit(.resyncRequired(reason))
            if envelope.type != "snapshot" { throw AnnexTransportError.disconnected }
        case .deliver: break
        }
        if envelope.type == "snapshot" {
            connectionDiagnostic?.event(.connected); connectionDiagnostic?.end(); connectionDiagnostic = nil
            transition(.connected)
        }
        if Self.isTerminalFrame(envelope) { emitTerminal(.frame(envelope)); return }
        if telemetry.isEnabled { envelope.diagnosticBinding = telemetryBinding }
        emit(.message(envelope))
        if envelope.type == "snapshot", let seq = cursor.lastSequence {
            var replay: [String: AnnexJSON] = ["type": .string("replay"), "since": .integer(seq)]
            if let capabilities { replay["type"] = .string("mobile:replay"); replay["epoch"] = .string(capabilities.epoch) }
            telemetry.record(.replay, event: .replayRequested)
            try await socket.send(JSONEncoder().encode(AnnexJSON.object(replay)))
        }
    }
}
