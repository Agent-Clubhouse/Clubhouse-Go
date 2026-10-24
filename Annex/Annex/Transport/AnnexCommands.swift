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
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnnexJSON.object(v))
        guard data.count <= 128 * 1024 else { throw AnnexTransportError.responseTooLarge }
        return data
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
    public struct Telemetry: Decodable, Sendable { public let version: Int; public let handshakePath: String }
    public let telemetry: Telemetry?
    public let pairing: Pairing?
    public let idempotency: Idempotency
    private enum CodingKeys: String, CodingKey { case version, epoch, controlAuth, controlAvailable, commands, pairing, idempotency, telemetry }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        epoch = try values.decode(String.self, forKey: .epoch)
        controlAuth = try values.decode(String.self, forKey: .controlAuth)
        controlAvailable = try values.decodeIfPresent(Bool.self, forKey: .controlAvailable)
        commands = try values.decode([String].self, forKey: .commands)
        pairing = try values.decodeIfPresent(Pairing.self, forKey: .pairing)
        idempotency = try values.decode(Idempotency.self, forKey: .idempotency)
        // Optional diagnostics cannot make otherwise compatible control unavailable.
        telemetry = try? values.decode(Telemetry.self, forKey: .telemetry)
    }
}
