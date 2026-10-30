import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// A terminal over a desktop's WebSocket (`docs/mobile-control-v1.md` § Terminals): a shell this phone spawned, keyed
/// by its own session id, or a terminal-mode agent's PTY, keyed by the agent's id.
@MainActor final class CompanionLiveTerminalChannel: CompanionTerminalChannel {
    let scope: CompanionTerminalScope
    /// The `agentId` of every input, resize and output frame.
    let id: String
    private let transport: any AnnexTransporting
    private var subscription: Task<AsyncStream<AnnexTerminalEvent>, Never>?
    private var listening: Task<Void, Never>?
    private var continuation: AsyncStream<CompanionTerminalChannelEvent>.Continuation?
    private var size: (cols: Int, rows: Int)?
    private var isOpen = false
    private var connected = false
    private var lost = false
    /// An attached agent's output that came before its snapshot, and the snapshot's position.
    private var pendingOutput: [(data: String, outputSeq: Int64?)] = []
    private var awaitingSnapshot = false
    private var snapshotSeq: Int64?

    init(transport: any AnnexTransporting, scope: CompanionTerminalScope, sessionID: String = UUID().uuidString) {
        self.transport = transport; self.scope = scope
        if case .agentPTY(let target) = scope { id = target.agentID } else { id = sessionID }
    }

    func events() -> AsyncStream<CompanionTerminalChannelEvent> {
        let (stream, continuation) = AsyncStream<CompanionTerminalChannelEvent>.makeStream()
        self.continuation?.finish()
        self.continuation = continuation
        subscribe()
        return stream
    }

    /// The transport finishes a terminal stream that falls behind; it's taken again, and the terminal reopens.
    private func subscribe() {
        let transport = transport
        let subscription = Task { await transport.terminalEvents() }
        self.subscription = subscription
        listening?.cancel()
        listening = Task { [weak self] in
            let stream = await subscription.value
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
            guard !Task.isCancelled, let self, self.continuation != nil else { return }
            self.connectionLost()
            self.connected = false
            self.subscribe()
        }
    }

    func open(cols: Int, rows: Int) async {
        _ = await subscription?.value
        let frame: AnnexTerminalFrame
        switch scope {
        case .project(let project):
            size = (cols, rows)
            frame = .spawnShell(sessionID: id, projectID: project.projectID, agentID: nil)
        case .agentShell(let target):
            size = (cols, rows)
            frame = .spawnShell(sessionID: id, projectID: target.projectID, agentID: target.agentID)
        case .agentPTY:
            pendingOutput = []; snapshotSeq = nil; awaitingSnapshot = true
            frame = .attach(agentID: id)
        }
        isOpen = false
        do { try await transport.sendTerminal(frame) }
        catch { failed(error) }
    }

    func send(_ input: String) async throws {
        try await transport.sendTerminal(.input(id: id, data: input))
    }

    func resize(cols: Int, rows: Int) async {
        guard scope.resizesPTY else { return }
        size = (cols, rows)
        guard isOpen else { return }
        try? await transport.sendTerminal(.resize(id: id, cols: cols, rows: rows))
    }

    func close() async {
        let wasOpen = isOpen
        isOpen = false
        listening?.cancel(); listening = nil
        continuation?.finish(); continuation = nil
        // Viewing an agent ends by not rendering it; a shell is the phone's to end.
        if wasOpen, scope.resizesPTY { try? await transport.sendTerminal(.close(sessionID: id)) }
    }

    private func yield(_ event: CompanionTerminalChannelEvent) { continuation?.yield(event) }

    private func failed(_ error: Error) {
        switch error as? AnnexTransportError {
        case .disconnected?: connectionLost()
        case .unsupportedCapability?: yield(.failed(CompanionTerminalAvailability.updateDesktop))
        default: yield(.failed(CompanionLiveService.readableError(error)))
        }
    }

    private func connectionLost() {
        isOpen = false
        lost = true
        yield(.connectionLost)
    }

    private func receive(_ event: AnnexTerminalEvent) {
        switch event {
        case .connection(let state):
            let nowConnected = state == .connected
            defer { connected = nowConnected }
            if nowConnected, !connected, lost { lost = false; yield(.connectionRestored) }
            else if !nowConnected, connected { connectionLost() }
        case .frame(let envelope):
            guard AnnexTerminalFrame.id(of: envelope) == id, let payload = envelope.payload else { return }
            receive(envelope.type, payload)
        }
    }

    private func receive(_ type: String, _ payload: AnnexJSON) {
        switch type {
        case "pty:spawn-shell:ack":
            guard scope.resizesPTY else { return }
            isOpen = true
            yield(.opened(cwd: payload["cwd"]?.string, snapshot: nil, cols: nil, rows: nil))
        case "pty:attach:ack":
            guard !scope.resizesPTY else { return }
            isOpen = true; awaitingSnapshot = false
            snapshotSeq = payload["outputSeq"]?.integer
            yield(.opened(cwd: nil, snapshot: payload["buffer"]?.string ?? "", cols: Self.int(payload["cols"]), rows: Self.int(payload["rows"])))
            let early = pendingOutput
            pendingOutput = []
            for frame in early { output(frame.data, outputSeq: frame.outputSeq) }
        case "pty:data":
            guard let data = payload["data"]?.string else { return }
            let outputSeq = payload["outputSeq"]?.integer
            // Output can come before the snapshot it continues.
            if awaitingSnapshot { pendingOutput.append((data, outputSeq)); return }
            guard isOpen else { return }
            output(data, outputSeq: outputSeq)
        case "pty:exit":
            guard isOpen || awaitingSnapshot else { return }
            isOpen = false; awaitingSnapshot = false
            yield(.exited(code: Self.int(payload["exitCode"])))
        case "error":
            let code = payload["message"]?.string ?? ""
            switch payload["op"]?.string {
            case "pty:resize": return
            // A refused paste leaves the terminal running.
            case "pty:input" where code.hasPrefix("pty:input"):
                yield(.output("\r\n\u{1B}[2m[\(Self.message(for: code))]\u{1B}[0m\r\n"))
            default:
                awaitingSnapshot = false
                isOpen = false
                yield(.failed(Self.message(for: code)))
            }
        default: break
        }
    }

    private func output(_ data: String, outputSeq: Int64?) {
        guard let fresh = AnnexTerminalOutput.unseen(data, outputSeq: outputSeq, snapshotSeq: snapshotSeq), !fresh.isEmpty else { return }
        yield(.output(fresh))
    }

    private static func int(_ value: AnnexJSON?) -> Int? { value?.int }

    /// The desktop's error codes in the phone's words. A failed spawn sends the shell's own error text.
    nonisolated static func message(for code: String) -> String {
        switch code {
        case "project_not_found": "This project is no longer on your desktop."
        case "agent_not_found": "This agent is no longer on your desktop."
        case "agent_not_running": "This agent isn't running. Start it on your desktop to see its terminal."
        case "agent_not_terminal": "This agent doesn't run in a terminal."
        case "too_many_shells": "Too many terminals are open from this phone. Close one and try again."
        case "session_in_use", "session_not_found", "invalid_session_id": "The desktop lost track of this terminal. Open it again."
        case "internal_error", "": "The desktop couldn't open this terminal. Try again."
        case "Control messages require mTLS authentication": "Pair this desktop again to open terminals."
        case let text where text.hasPrefix("pty:input"): "That paste was too long for the desktop."
        default: "The desktop couldn't start a shell: \(code)"
        }
    }
}
