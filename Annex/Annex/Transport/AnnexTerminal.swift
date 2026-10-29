import Foundation

/// Terminals over the mTLS WebSocket (desktop #2476): a shell at a project root or an agent's worktree, and an
/// attached view of a terminal-mode agent's own PTY. Shell output goes only to the socket that spawned it, never
/// into replay, and the desktop kills a socket's shells when it disconnects, so a reconnect spawns a new one.
nonisolated public extension AnnexCapabilities {
    /// The `terminal` block of `/api/v1/mobile/capabilities`. Absent on desktops without phone terminals.
    struct Terminal: Decodable, Sendable, Equatable {
        public static let defaultMaxInputLength = 65_536
        public let version: Int
        public let projectShell: Bool
        public let agentShell: Bool
        public let agentAttach: Bool
        public let maxShellsPerConnection: Int
        /// The cap on one `pty:input`, in UTF-16 code units (the desktop checks the JavaScript string's length).
        public let maxInputLength: Int
        public init(version: Int = 1, projectShell: Bool, agentShell: Bool, agentAttach: Bool,
                    maxShellsPerConnection: Int = 8, maxInputLength: Int = defaultMaxInputLength) {
            self.version = version; self.projectShell = projectShell; self.agentShell = agentShell; self.agentAttach = agentAttach
            self.maxShellsPerConnection = maxShellsPerConnection; self.maxInputLength = maxInputLength
        }
        /// A malformed block grants nothing rather than failing the whole capability document.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 0
            projectShell = (try? c.decode(Bool.self, forKey: .projectShell)) ?? false
            agentShell = (try? c.decode(Bool.self, forKey: .agentShell)) ?? false
            agentAttach = (try? c.decode(Bool.self, forKey: .agentAttach)) ?? false
            maxShellsPerConnection = (try? c.decode(Int.self, forKey: .maxShellsPerConnection)) ?? 8
            let length = (try? c.decode(Int.self, forKey: .maxInputLength)) ?? Self.defaultMaxInputLength
            maxInputLength = length > 0 ? length : Self.defaultMaxInputLength
        }
        private enum CodingKeys: String, CodingKey { case version, projectShell, agentShell, agentAttach, maxShellsPerConnection, maxInputLength }
        public var isUsable: Bool { version == 1 && (projectShell || agentShell || agentAttach) }
    }
}

/// One terminal message from the phone. `pty:input` and `pty:resize` are keyed by `agentId`, which is the shell's
/// session id for a shell and the agent's id for an attached agent.
nonisolated public enum AnnexTerminalFrame: Sendable, Equatable {
    case spawnShell(sessionID: String, projectID: String, agentID: String?)
    case input(id: String, data: String)
    case resize(id: String, cols: Int, rows: Int)
    case close(sessionID: String)
    case attach(agentID: String)

    public var type: String {
        switch self {
        case .spawnShell: "pty:spawn-shell"
        case .input: "pty:input"
        case .resize: "pty:resize"
        case .close: "pty:close"
        case .attach: "pty:attach"
        }
    }

    public var payload: AnnexJSON {
        switch self {
        case .spawnShell(let session, let project, let agent):
            var values: [String: AnnexJSON] = ["sessionId": .string(session), "projectId": .string(project)]
            if let agent { values["agentId"] = .string(agent) }
            return .object(values)
        case .input(let id, let data): return .object(["agentId": .string(id), "data": .string(data)])
        case .resize(let id, let cols, let rows): return .object(["agentId": .string(id), "cols": .integer(Int64(cols)), "rows": .integer(Int64(rows))])
        case .close(let session): return .object(["sessionId": .string(session)])
        case .attach(let agent): return .object(["agentId": .string(agent)])
        }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(AnnexJSON.object(["type": .string(type), "payload": payload]))
    }

    /// Whether a desktop message answers this terminal: its acks, output and errors carry the same id.
    public static func id(of envelope: AnnexEnvelope) -> String? {
        envelope.payload?["sessionId"]?.string ?? envelope.payload?["agentId"]?.string
    }
}

/// What a terminal hears from its desktop: its frames, and the connection they travel on.
nonisolated public enum AnnexTerminalEvent: Sendable, Equatable {
    case connection(AnnexConnectionState)
    case frame(AnnexEnvelope)
}

nonisolated public enum AnnexTerminalInput {
    /// Splits `text` into pieces of at most `maxLength` UTF-16 code units, never inside a Unicode scalar, so each
    /// piece passes the desktop's `pty:input` cap and a surrogate pair is never cut in two.
    public static func chunks(_ text: String, maxLength: Int = AnnexCapabilities.Terminal.defaultMaxInputLength) -> [String] {
        let limit = max(2, maxLength)
        guard text.utf16.count > limit else { return text.isEmpty ? [] : [text] }
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        var length = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if length + width > limit {
                pieces.append(String(current)); current = .init(); length = 0
            }
            current.append(scalar); length += width
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces
    }
}

nonisolated public enum AnnexTerminalOutput {
    /// The part of a live `pty:data` frame that an attach snapshot doesn't already hold. `outputSeq` counts UTF-16
    /// code units and is the total after the frame, so a frame at or before the snapshot is dropped and one that
    /// straddles it keeps only its newest units. A frame without `outputSeq` is kept whole.
    public static func unseen(_ data: String, outputSeq: Int64?, snapshotSeq: Int64?) -> String? {
        guard let outputSeq, let snapshotSeq else { return data }
        guard outputSeq > snapshotSeq else { return nil }
        let fresh = outputSeq - snapshotSeq
        let units = Int64(data.utf16.count)
        guard fresh < units else { return data }
        var start = data.utf16.index(data.utf16.endIndex, offsetBy: -Int(fresh))
        // A cut inside a surrogate pair moves to the next scalar.
        if start.samePosition(in: data.unicodeScalars) == nil { start = data.utf16.index(after: start) }
        return String(data.unicodeScalars[start...])
    }
}
