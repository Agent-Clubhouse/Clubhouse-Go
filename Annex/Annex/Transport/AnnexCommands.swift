import Foundation

nonisolated public struct AnnexCommand: Sendable, Equatable {
    public enum Delivery: String, Sendable { case auto, prompt, steer, queued }
    public enum Kind: Sendable, Equatable {
        case send(agentID: String, sessionID: String, text: String, delivery: Delivery = .auto)
        case interrupt(agentID: String, sessionID: String)
        case removeQueued(agentID: String, sessionID: String, messageIDs: [String])
        case permission(agentID: String, sessionID: String, requestID: String, optionID: String)
        case question(agentID: String, sessionID: String, requestID: String, answers: [String: AnnexJSON])
        case start(agentID: String, message: String? = nil, resume: Bool? = nil)
        case stop(agentID: String)
        case spawn(projectID: String, prompt: String, model: String? = nil, orchestrator: String? = nil)
        case create(AnnexAgentCreate)
        case update(AnnexAgentUpdate)
    }
    public let createdAt: Date
    public let commandID: String
    public let epoch: String
    public let kind: Kind
    public init(commandID: String = UUID().uuidString, epoch: String, kind: Kind) {
        self.createdAt = Date()
        self.commandID = commandID; self.epoch = epoch; self.kind = kind
    }
    public var type: String {
        switch kind {
        case .send: "chat.send"
        case .interrupt: "chat.interrupt"
        case .removeQueued: "chat.queue.remove"
        case .permission: "chat.permission"
        case .question: "chat.question"
        case .start: "agent.start"
        case .stop: "agent.stop"
        case .spawn: "agent.spawn"
        case .create: "agent.create"
        case .update: "agent.update"
        }
    }
    public func encoded() throws -> Data {
        guard !commandID.isEmpty, commandID.count <= 128, !epoch.isEmpty, epoch.count <= 128 else {
            throw AnnexTransportError.malformedResponse
        }
        var v: [String: AnnexJSON] = ["version": .integer(1), "commandId": .string(commandID), "epoch": .string(epoch), "type": .string(type)]
        func target(_ agent: String, _ session: String? = nil) {
            v["agentId"] = .string(agent)
            if let session { v["sessionId"] = .string(session) }
        }
        switch kind {
        case .send(let agent, let session, let text, let delivery):
            target(agent, session); v["text"] = .string(text); v["delivery"] = .string(delivery.rawValue)
        case .interrupt(let agent, let session): target(agent, session)
        case .removeQueued(let agent, let session, let ids):
            target(agent, session); v["messageIds"] = .array(ids.map(AnnexJSON.string))
        case .permission(let agent, let session, let request, let option):
            target(agent, session); v["requestId"] = .string(request); v["optionId"] = .string(option)
        case .question(let agent, let session, let request, let answers):
            target(agent, session); v["requestId"] = .string(request); v["answers"] = .object(answers)
        case .start(let agent, let message, let resume):
            target(agent); if let message { v["message"] = .string(message) }; if let resume { v["resume"] = .bool(resume) }
        case .stop(let agent): target(agent)
        case .spawn(let project, let prompt, let model, let orchestrator):
            v["projectId"] = .string(project); v["prompt"] = .string(prompt)
            if let model { v["model"] = .string(model) }; if let orchestrator { v["orchestrator"] = .string(orchestrator) }
        case .create(let create): v.merge(create.fields) { _, new in new }
        case .update(let update):
            // The desktop refuses an update that changes nothing.
            guard !update.isEmpty else { throw AnnexTransportError.malformedResponse }
            v.merge(update.fields) { _, new in new }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnnexJSON.object(v))
        guard data.count <= 128 * 1024 else { throw AnnexTransportError.responseTooLarge }
        return data
    }
}

/// `agent.create`: a durable agent, as the desktop's New agent page makes one. There is deliberately no
/// Free Agent Mode field: the desktop refuses it from a phone (403 `free_agent_mode_not_allowed`).
nonisolated public struct AnnexAgentCreate: Sendable, Equatable {
    public var projectID: String
    public var name: String
    /// A colour id from the create options, such as `indigo`.
    public var color: String
    public var orchestrator: String?
    public var model: String?
    public var persona: String?
    public var useWorktree: Bool?
    public var mcpIDs: [String]?
    public var branchName: String?
    public var branchFrom: String?
    public var folderName: String?
    public init(projectID: String, name: String, color: String, orchestrator: String? = nil, model: String? = nil, persona: String? = nil,
                useWorktree: Bool? = nil, mcpIDs: [String]? = nil, branchName: String? = nil, branchFrom: String? = nil, folderName: String? = nil) {
        self.projectID = projectID; self.name = name; self.color = color; self.orchestrator = orchestrator; self.model = model
        self.persona = persona; self.useWorktree = useWorktree; self.mcpIDs = mcpIDs
        self.branchName = branchName; self.branchFrom = branchFrom; self.folderName = folderName
    }
    var fields: [String: AnnexJSON] {
        var v: [String: AnnexJSON] = ["projectId": .string(projectID), "name": .string(name), "color": .string(color)]
        if let orchestrator { v["orchestrator"] = .string(orchestrator) }
        if let model { v["model"] = .string(model) }
        if let persona { v["persona"] = .string(persona) }
        if let useWorktree { v["useWorktree"] = .bool(useWorktree) }
        if let mcpIDs { v["mcpIds"] = .array(mcpIDs.map(AnnexJSON.string)) }
        if let branchName { v["branchName"] = .string(branchName) }
        if let branchFrom { v["branchFrom"] = .string(branchFrom) }
        if let folderName { v["folderName"] = .string(folderName) }
        return v
    }
}

/// `agent.update`: only the settings that changed. Free Agent Mode is read-only from a phone, so it has no field.
nonisolated public struct AnnexAgentUpdate: Sendable, Equatable {
    /// A value that can also be cleared, sent as `null`.
    public enum Clearable: Sendable, Equatable {
        case set(String), clear
        var json: AnnexJSON { if case .set(let value) = self { .string(value) } else { .null } }
    }
    public enum Runtime: String, Sendable { case `default`, chat, terminal }
    /// Follow the app's chat idle timeout, never sleep, or sleep after this many minutes idle.
    public enum IdleSleep: Sendable, Equatable, Hashable {
        case inherit, never, minutes(Int)
        var json: AnnexJSON {
            switch self {
            case .inherit: .string("inherit")
            case .never: .string("never")
            case .minutes(let minutes): .integer(Int64(minutes))
            }
        }
    }
    public var agentID: String
    public var name: String?
    public var color: String?
    public var emoji: Clearable?
    public var orchestrator: String?
    /// `"default"` clears it back to the provider default.
    public var model: String?
    public var runtime: Runtime?
    /// Clearing it means the project default.
    public var persona: Clearable?
    public var clubhouseMode: Bool?
    public var idleSleep: IdleSleep?
    public init(agentID: String, name: String? = nil, color: String? = nil, emoji: Clearable? = nil, orchestrator: String? = nil, model: String? = nil,
                runtime: Runtime? = nil, persona: Clearable? = nil, clubhouseMode: Bool? = nil, idleSleep: IdleSleep? = nil) {
        self.agentID = agentID; self.name = name; self.color = color; self.emoji = emoji; self.orchestrator = orchestrator
        self.model = model; self.runtime = runtime; self.persona = persona; self.clubhouseMode = clubhouseMode; self.idleSleep = idleSleep
    }
    /// True when it changes nothing; the desktop needs at least one setting.
    public var isEmpty: Bool { fields.count == 1 }
    var fields: [String: AnnexJSON] {
        var v: [String: AnnexJSON] = ["agentId": .string(agentID)]
        if let name { v["name"] = .string(name) }
        if let color { v["color"] = .string(color) }
        if let emoji { v["emoji"] = emoji.json }
        if let orchestrator { v["orchestrator"] = .string(orchestrator) }
        if let model { v["model"] = .string(model) }
        if let runtime { v["runtime"] = .string(runtime.rawValue) }
        if let persona { v["persona"] = persona.json }
        if let clubhouseMode { v["clubhouseMode"] = .bool(clubhouseMode) }
        if let idleSleep { v["idleSleep"] = idleSleep.json }
        return v
    }
}

nonisolated public struct AnnexCommandReceipt: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case completed, rejected, failed }
    public struct Failure: Codable, Sendable, Equatable { public let code: String; public let message: String }
    public let version: Int
    public let commandId: String?
    public let epoch: String
    public let status: Status
    public let result: AnnexJSON?
    public let error: Failure?
    /// 'completed' means dispatch completed, not that the agent's turn ended.
    public var isDispatchAcknowledged: Bool { status == .completed }
}

nonisolated public struct AnnexCapabilities: Decodable, Sendable {
    public let version: Int
    public let epoch: String
    public let controlAuth: String
    public let controlAvailable: Bool?
    public let commands: [String]
    public struct Idempotency: Decodable, Sendable {
        public let scope: String
        public let maxEntries: Int
        public let ttlMs: Int
    }
    public struct Pairing: Decodable, Sendable { public let sessionRevokePath: String? }
    public let pairing: Pairing?
    public let idempotency: Idempotency
    /// Every address the desktop answers on, LAN first then Tailscale. A hint: each is pin-checked before use.
    public struct Routes: Decodable, Sendable, Equatable {
        public let hosts: [String]
        public let port: UInt16
        public init(hosts: [String], port: UInt16) { self.hosts = hosts; self.port = port }
        public var endpoints: [AnnexEndpoint] { hosts.compactMap { try? AnnexEndpoint.advertised(host: $0, port: port) } }
    }
    public let routes: Routes?
    /// A versioned read route the desktop offers, such as create options or agent settings.
    public struct Feature: Decodable, Sendable, Equatable {
        public let version: Int
        public let path: String?
    }
    public let createOptions: Feature?
    public let agentSettings: Feature?
    /// Durable agents can be created (`agent.create` with create options v1). Older desktops offer quick agents only.
    public var supportsAgentCreate: Bool { commands.contains("agent.create") && (createOptions?.version ?? 0) >= 1 }
    /// An agent's settings can be read and changed (`agent.update` with agent settings v1).
    public var supportsAgentSettings: Bool { commands.contains("agent.update") && (agentSettings?.version ?? 0) >= 1 }
}
