import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// A terminal over a desktop's WebSocket (`docs/mobile-control-v1.md` § Terminals): a shell this phone spawned, keyed
/// by its own session id, or a terminal-mode agent's PTY, keyed by the agent's id.
@MainActor final class CompanionLiveTerminalChannel: CompanionTerminalChannel {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    let scope: CompanionTerminalScope
    /// The `agentId` of every input, resize and output frame. A shell's changes only when the person starts a new
    /// one after it ended; a dropped connection, a reattach and "Try again" all keep it.
    private(set) var id: String
    private let makeSessionID: () -> String
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
    /// A shell the desktop has acked and that hasn't ended: after a dropped connection it may still be there to
    /// reattach to, if the desktop keeps shells through one.
    private var resumable = false
    /// A spawn was sent and not yet acked. The desktop may have made the shell and lost only the ack, leaving it
    /// detached and reclaimable; a spawn under the same id would replace it, so with `shellReattach` the phone
    /// reattaches instead. A "not found" answer says no shell was made, and is shown: only the person's New shell
    /// spawns, once, under a new id.
    private var spawnUnacked = false
    /// The reattach in flight is for a shell the phone never saw open.
    private var reattachingUnopened = false
    /// The shell ended (exit, or a refusal that ends this id): the next open is a new shell with a new id.
    private var needsNewIdentity = false

    init(transport: any AnnexTransporting, scope: CompanionTerminalScope, sessionID: String = UUID().uuidString,
         makeSessionID: @escaping () -> String = { UUID().uuidString }) {
        self.transport = transport; self.scope = scope; self.makeSessionID = makeSessionID
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
        case .project, .agentShell:
            size = (cols, rows)
            guard let shell = await shellFrame(cols: cols, rows: rows) else {
                // Whether this desktop keeps shells isn't known right now (a flap, or capabilities not read yet). A
                // shell that may still be there is neither respawned nor failed: it stays reconnecting, with
                // everything kept and nothing sent, until the connection settles and `connectionRestored` reopens it.
                connectionLost()
                connected = false
                return
            }
            frame = shell
        case .agentPTY:
            pendingOutput = []; snapshotSeq = nil; awaitingSnapshot = true
            frame = .attach(agentID: id)
        }
        isOpen = false
        do { try await transport.sendTerminal(frame) }
        catch {
            if case .reattachShell = frame, case .unsupportedCapability? = error as? AnnexTransportError {
                // The capability went away between the check and the send: a flap, not "update the desktop".
                connectionLost(); connected = false
            } else {
                failed(error)
            }
        }
    }

    /// A shell opens one of three ways. Its desktop kept it through the drop: reattach, same id, and never fall back
    /// to a spawn. The desktop doesn't keep shells: a spawn under the same id, as before. It ended, or the person asks
    /// for a new one: a spawn under a new id.
    /// Nil when a shell that may still be on the desktop can't be opened yet because the capability isn't known.
    private func shellFrame(cols: Int, rows: Int) async -> AnnexTerminalFrame? {
        if resumable || spawnUnacked {
            switch await transport.supportsShellReattach() {
            case nil: return nil
            case true?:
                pendingOutput = []; snapshotSeq = nil; awaitingSnapshot = true
                reattachingUnopened = !resumable
                return .reattachShell(sessionID: id, cols: cols, rows: rows)
            case false?: break
            }
        }
        if needsNewIdentity { id = makeSessionID(); needsNewIdentity = false }
        resumable = false; reattachingUnopened = false; awaitingSnapshot = false; snapshotSeq = nil; pendingOutput = []
        spawnUnacked = true
        switch scope {
        case .project(let project): return .spawnShell(sessionID: id, projectID: project.projectID, agentID: nil)
        case .agentShell(let target): return .spawnShell(sessionID: id, projectID: target.projectID, agentID: target.agentID)
        case .agentPTY(let target): return .attach(agentID: target.agentID)
        }
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
        case .unsupportedCapability?:
            if scope.resizesPTY { spawnUnacked = false; needsNewIdentity = true }
            yield(.failed(CompanionTerminalAvailability.updateDesktop))
        default:
            if scope.resizesPTY { spawnUnacked = false; needsNewIdentity = true }
            yield(.failed(CompanionLiveService.readableError(error)))
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
            isOpen = true; resumable = true; spawnUnacked = false
            yield(.opened(cwd: payload["cwd"]?.string, snapshot: nil, cols: nil, rows: nil))
        case "pty:reattach-shell:ack":
            // Like an attach: a snapshot, the output that raced ahead of it after it, and only what it lacks.
            guard scope.resizesPTY, awaitingSnapshot else { return }
            isOpen = true; resumable = true; spawnUnacked = false; reattachingUnopened = false; awaitingSnapshot = false
            snapshotSeq = payload["outputSeq"]?.integer
            yield(.opened(cwd: payload["cwd"]?.string, snapshot: payload["buffer"]?.string ?? "", cols: Self.int(payload["cols"]), rows: Self.int(payload["rows"])))
            let early = pendingOutput
            pendingOutput = []
            for frame in early { output(frame.data, outputSeq: frame.outputSeq) }
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
            if scope.resizesPTY { resumable = false; spawnUnacked = false; needsNewIdentity = true }
            yield(.exited(code: Self.int(payload["exitCode"])))
        case "error":
            let code = payload["code"]?.string ?? payload["message"]?.string ?? ""
            // The desktop's reason may come as `code` or as `message`; a refused input is recognized in either.
            let refusedInput = [payload["code"]?.string, payload["message"]?.string].contains { $0?.hasPrefix("pty:input") == true }
            switch payload["op"]?.string {
            case "pty:resize": return
            case "pty:reattach-shell": reattachFailed(code, payload)
            // A refused input clears queued keys/paste without reopening or replacing the terminal.
            case "pty:input" where refusedInput:
                yield(.inputRejected(CompanionTerminalSession.inputRefusedMessage))
            default:
                awaitingSnapshot = false
                isOpen = false
                // A refused spawn or attach leaves no shell under this id: the next try is a new one.
                if scope.resizesPTY { resumable = false; spawnUnacked = false; needsNewIdentity = true }
                yield(.failed(Self.message(for: code)))
            }
        default: break
        }
    }

    /// A refused reattach never becomes a spawn: the person decides. Only an unreachable shell may be tried again
    /// under the same id; every other answer says the shell is gone or the id unusable, so "New shell" takes a new id.
    private func reattachFailed(_ code: String, _ payload: AnnexJSON) {
        awaitingSnapshot = false; pendingOutput = []
        isOpen = false
        let unopened = reattachingUnopened
        reattachingUnopened = false
        if unopened, code == "session_not_found" || code == "invalid_session_id" {
            // No shell was ever made under this id. That is still a refusal, shown to the person: only their
            // "New shell" starts one, under a new id, so nothing is spawned behind their back.
            resumable = false; spawnUnacked = false; needsNewIdentity = true
            yield(.failed(Self.neverStartedMessage))
            return
        }
        if code == "session_exited" {
            resumable = false; spawnUnacked = false; needsNewIdentity = true
            yield(.exited(code: Self.int(payload["exitCode"])))
        } else if code == "terminal_unavailable" {
            yield(.failed(Self.message(for: code)))
        } else {
            resumable = false; spawnUnacked = false; needsNewIdentity = true
            let known: Set<String> = ["session_expired", "session_not_found", "invalid_session_id", "session_in_use", "authorization_revoked",
                                      "too_many_shells", "internal_error", ""]
            yield(.failed(known.contains(code) ? Self.message(for: code) : "The desktop couldn't reattach this shell: \(code)"))
        }
    }

    private func output(_ data: String, outputSeq: Int64?) {
        guard let fresh = AnnexTerminalOutput.unseen(data, outputSeq: outputSeq, snapshotSeq: snapshotSeq), !fresh.isEmpty else { return }
        yield(.output(fresh))
    }

    private static func int(_ value: AnnexJSON?) -> Int? { value?.int }

    static let neverStartedMessage = "This shell didn't start before the connection dropped."

    /// The desktop's error codes in the phone's words. A failed spawn sends the shell's own error text.
    nonisolated static func message(for code: String) -> String {
        switch code {
        case "project_not_found": "This project is no longer on your desktop."
        case "agent_not_found": "This agent is no longer on your desktop."
        case "agent_not_running": "This agent isn't running. Start it on your desktop to see its terminal."
        case "agent_not_terminal": "This agent doesn't run in a terminal."
        case "too_many_shells": "Too many terminals are open from this phone. Close one and try again."
        case "session_expired": "The desktop ended this shell after it was away too long."
        case "terminal_unavailable": "The desktop couldn't reach this shell right now. Try again."
        case "authorization_revoked": "This phone's access to the desktop was revoked. Pair it again to open terminals."
        case "session_in_use", "session_not_found", "invalid_session_id": "The desktop lost track of this terminal. Open it again."
        case "internal_error", "": "The desktop couldn't open this terminal. Try again."
        case "Control messages require mTLS authentication": "Pair this desktop again to open terminals."
        case let text where text.hasPrefix("pty:input"): "That paste was too long for the desktop."
        default: "The desktop couldn't start a shell: \(code)"
        }
    }
}
