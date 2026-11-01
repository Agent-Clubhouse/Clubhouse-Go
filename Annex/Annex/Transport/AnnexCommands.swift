import Foundation

nonisolated public struct AnnexCommand: Sendable, Equatable {
    public enum Delivery: String, Sendable { case auto, prompt, steer, queued }
    public enum Kind: Sendable, Equatable {
        /// `attachmentIDs` name images uploaded with `AnnexTransporting.upload`; `text` may then be empty.
        case send(agentID: String, sessionID: String, text: String, delivery: Delivery = .auto, attachmentIDs: [String] = [])
        case interrupt(agentID: String, sessionID: String)
        case removeQueued(agentID: String, sessionID: String, messageIDs: [String])
        case permission(agentID: String, sessionID: String, requestID: String, optionID: String)
        case question(agentID: String, sessionID: String, requestID: String, answers: [String: AnnexJSON])
        case start(agentID: String, message: String? = nil, resume: Bool? = nil)
        case stop(agentID: String)
        case spawn(projectID: String, prompt: String, model: String? = nil, orchestrator: String? = nil)
        case create(AnnexAgentCreate)
        case update(AnnexAgentUpdate)
        /// The desktop owns project pins and inactive marks when it offers `projectState`.
        case setProjectPinned(projectID: String, pinned: Bool)
        case setProjectInactive(projectID: String, inactive: Bool)
        /// The desktop owns "Finished, waiting on you" when it offers `finishedQuickAgents`.
        case dismissFinishedQuick(projectID: String, agentID: String)
        case clearFinishedQuick(projectID: String)
        /// A helper start or dispose an orchestrator asked the user to decide. `force` is the desktop's "Dispose anyway".
        case helperApprove(requestID: String, force: Bool = false)
        case helperDecline(requestID: String)
        /// The composer's model and effort menus. `effort` nil leaves it out: the desktop keeps a chosen effort the new model offers.
        case setModel(agentID: String, sessionID: String, model: String, effort: Effort? = nil)
        /// The composer's permission level menu: `plan`, `ask`, `auto_edit`, `auto` or `full_access`.
        case setLevel(agentID: String, sessionID: String, level: String)
        /// Turns the desktop's app-wide Dispatcher on or off (`dispatcher` v1). Turning it on needs the experimental flag.
        case setDispatcherEnabled(Bool)
    }
    /// A reasoning effort to switch to, or the provider's default (sent as `null`; needs `effortDefault`).
    public enum Effort: Sendable, Equatable {
        case set(String), providerDefault
    }
    public let createdAt: Date
    public let commandID: String
    public let epoch: String
    public let kind: Kind
    public init(commandID: String = UUID().uuidString, epoch: String, kind: Kind) {
        self.createdAt = Date()
        self.commandID = commandID; self.epoch = epoch; self.kind = kind
    }
    /// Images named by a `chat.send`.
    public var attachmentCount: Int {
        if case .send(_, _, _, _, let ids) = kind { ids.count } else { 0 }
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
        case .setModel: "chat.setModel"
        case .setLevel: "chat.setLevel"
        case .helperApprove: "helper.approve"
        case .helperDecline: "helper.decline"
        case .setProjectPinned: "project.setPinned"
        case .setProjectInactive: "project.setInactive"
        case .dismissFinishedQuick: "quick.dismiss"
        case .clearFinishedQuick: "quick.clear"
        case .setDispatcherEnabled: "dispatcher.setEnabled"
        }
    }
    /// The desktop's permission ladder, lowest first. `chat.setLevel` refuses anything else.
    public static let permissionLevels = ["plan", "ask", "auto_edit", "auto", "full_access"]
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
        case .send(let agent, let session, let text, let delivery, let attachments):
            target(agent, session); v["text"] = .string(text); v["delivery"] = .string(delivery.rawValue)
            // Part of the desktop's idempotency fingerprint: a retry repeats the same ids in the same order.
            if !attachments.isEmpty {
                guard attachments.count <= AnnexCapabilities.Attachments.maximumCount, Set(attachments).count == attachments.count,
                      attachments.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else { throw AnnexTransportError.malformedResponse }
                v["attachmentIds"] = .array(attachments.map(AnnexJSON.string))
            }
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
        case .setModel(let agent, let session, let model, let effort):
            guard !model.isEmpty, model.count <= 256 else { throw AnnexTransportError.malformedResponse }
            target(agent, session); v["model"] = .string(model)
            switch effort {
            case .set(let value)?:
                guard !value.isEmpty, value.count <= 64 else { throw AnnexTransportError.malformedResponse }
                v["effort"] = .string(value)
            case .providerDefault?: v["effort"] = .null
            case nil: break
            }
        case .setLevel(let agent, let session, let level):
            guard AnnexCommand.permissionLevels.contains(level) else { throw AnnexTransportError.malformedResponse }
            target(agent, session); v["level"] = .string(level)
        case .helperApprove(let request, let force):
            v["requestId"] = .string(request)
            if force { v["force"] = .bool(true) }
        case .helperDecline(let request): v["requestId"] = .string(request)
        case .setProjectPinned(let project, let pinned):
            v["projectId"] = .string(project); v["pinned"] = .bool(pinned)
        case .setProjectInactive(let project, let inactive):
            v["projectId"] = .string(project); v["inactive"] = .bool(inactive)
        case .dismissFinishedQuick(let project, let agent):
            v["projectId"] = .string(project); v["agentId"] = .string(agent)
        case .clearFinishedQuick(let project): v["projectId"] = .string(project)
        case .setDispatcherEnabled(let enabled): v["enabled"] = .bool(enabled)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnnexJSON.object(v))
        guard data.count <= 128 * 1024 else { throw AnnexTransportError.responseTooLarge }
        return data
    }
}

/// An agent's orchestration policy fields to change (`orchestration` v1): only the keys set are sent.
/// `clear` sends `null`, putting the field back to the persona's value or the default. `agent.create` takes no `null`.
nonisolated public struct AnnexOrchestrationPatch: Sendable, Equatable {
    public enum Field<Value: Sendable & Equatable>: Sendable, Equatable { case set(Value), clear }
    public var orchestrate: Field<Bool>?
    /// `same` or a launch access level (`standard`, `auto`, `bypass`).
    public var access: Field<String>?
    /// `hands-off`, `ask-before-start` or `ask-everything`.
    public var control: Field<String>?
    /// 1 to the desktop's `maxHelpersCap`.
    public var maxHelpers: Field<Int>?
    /// "Cross-project helpers": the agent may start helpers in other projects.
    public var crossProjectHelpers: Field<Bool>?
    /// "Connect to Dispatcher": the Dispatcher may message the agent. Refused (`dispatcher_off`) while the Dispatcher is off.
    public var connectToDispatcher: Field<Bool>?
    /// Sends `"orchestration": null` on `agent.update`, clearing every field the agent sets. The fields above are ignored.
    public var clearsAll = false
    public init(orchestrate: Field<Bool>? = nil, access: Field<String>? = nil, control: Field<String>? = nil, maxHelpers: Field<Int>? = nil,
                crossProjectHelpers: Field<Bool>? = nil, connectToDispatcher: Field<Bool>? = nil) {
        self.orchestrate = orchestrate; self.access = access; self.control = control; self.maxHelpers = maxHelpers
        self.crossProjectHelpers = crossProjectHelpers; self.connectToDispatcher = connectToDispatcher
    }
    /// Every field back to the persona's value or the default.
    public static var clearAll: AnnexOrchestrationPatch { var patch = AnnexOrchestrationPatch(); patch.clearsAll = true; return patch }
    public var isEmpty: Bool { json == .object([:]) }
    var json: AnnexJSON {
        guard !clearsAll else { return .null }
        func value<T>(_ field: Field<T>, _ wrap: (T) -> AnnexJSON) -> AnnexJSON { if case .set(let v) = field { wrap(v) } else { .null } }
        var v: [String: AnnexJSON] = [:]
        if let orchestrate { v["orchestrate"] = value(orchestrate, AnnexJSON.bool) }
        if let access { v["access"] = value(access, AnnexJSON.string) }
        if let control { v["control"] = value(control, AnnexJSON.string) }
        if let maxHelpers { v["maxHelpers"] = value(maxHelpers) { .integer(Int64($0)) } }
        if let crossProjectHelpers { v["crossProjectHelpers"] = value(crossProjectHelpers, AnnexJSON.bool) }
        if let connectToDispatcher { v["connectToDispatcher"] = value(connectToDispatcher, AnnexJSON.bool) }
        return .object(v)
    }
    /// The set fields only, for `agent.create`, which refuses `null`.
    var creationJSON: AnnexJSON? {
        guard !clearsAll, case .object(let fields) = json else { return nil }
        let set = fields.filter { $0.value != .null }
        return set.isEmpty ? nil : .object(set)
    }
}

/// `agent.create`: a durable agent, as the desktop's New agent page makes one. Send `freeAgentMode` only to a desktop
/// that advertises `permissions.freeAgentMode`; older ones refuse the field (403 `free_agent_mode_not_allowed`).
nonisolated public struct AnnexAgentCreate: Sendable, Equatable {
    public var projectID: String
    public var name: String
    /// A colour id from the create options, such as `indigo`.
    public var color: String
    public var orchestrator: String?
    public var model: String?
    public var persona: String?
    /// Skip every permission prompt. Omitted follows the project's agent defaults.
    public var freeAgentMode: Bool?
    public var useWorktree: Bool?
    public var mcpIDs: [String]?
    public var branchName: String?
    public var branchFrom: String?
    public var folderName: String?
    /// Only to a desktop that advertises `orchestration` v1. Cleared fields are left out.
    public var orchestration: AnnexOrchestrationPatch?
    public init(projectID: String, name: String, color: String, orchestrator: String? = nil, model: String? = nil, persona: String? = nil,
                freeAgentMode: Bool? = nil, useWorktree: Bool? = nil, mcpIDs: [String]? = nil, branchName: String? = nil, branchFrom: String? = nil,
                folderName: String? = nil, orchestration: AnnexOrchestrationPatch? = nil) {
        self.projectID = projectID; self.name = name; self.color = color; self.orchestrator = orchestrator; self.model = model
        self.persona = persona; self.freeAgentMode = freeAgentMode; self.useWorktree = useWorktree; self.mcpIDs = mcpIDs
        self.branchName = branchName; self.branchFrom = branchFrom; self.folderName = folderName; self.orchestration = orchestration
    }
    var fields: [String: AnnexJSON] {
        var v: [String: AnnexJSON] = ["projectId": .string(projectID), "name": .string(name), "color": .string(color)]
        if let orchestrator { v["orchestrator"] = .string(orchestrator) }
        if let model { v["model"] = .string(model) }
        if let persona { v["persona"] = .string(persona) }
        if let freeAgentMode { v["freeAgentMode"] = .bool(freeAgentMode) }
        if let useWorktree { v["useWorktree"] = .bool(useWorktree) }
        if let mcpIDs { v["mcpIds"] = .array(mcpIDs.map(AnnexJSON.string)) }
        if let branchName { v["branchName"] = .string(branchName) }
        if let branchFrom { v["branchFrom"] = .string(branchFrom) }
        if let folderName { v["folderName"] = .string(folderName) }
        if let orchestration = orchestration?.creationJSON { v["orchestration"] = orchestration }
        return v
    }
}

/// `agent.update`: only the settings that changed. `freeAgentMode` needs a desktop that advertises `permissions.freeAgentMode`.
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
    /// A spawn setting: the desktop refuses it while the agent is awake (409 `agent_running`).
    public var freeAgentMode: Bool?
    public var idleSleep: IdleSleep?
    /// Changes any time, even while the agent runs. Needs a desktop that advertises `orchestration` v1.
    public var orchestration: AnnexOrchestrationPatch?
    public init(agentID: String, name: String? = nil, color: String? = nil, emoji: Clearable? = nil, orchestrator: String? = nil, model: String? = nil,
                runtime: Runtime? = nil, persona: Clearable? = nil, clubhouseMode: Bool? = nil, freeAgentMode: Bool? = nil, idleSleep: IdleSleep? = nil,
                orchestration: AnnexOrchestrationPatch? = nil) {
        self.agentID = agentID; self.name = name; self.color = color; self.emoji = emoji; self.orchestrator = orchestrator
        self.model = model; self.runtime = runtime; self.persona = persona; self.clubhouseMode = clubhouseMode
        self.freeAgentMode = freeAgentMode; self.idleSleep = idleSleep; self.orchestration = orchestration
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
        if let freeAgentMode { v["freeAgentMode"] = .bool(freeAgentMode) }
        if let idleSleep { v["idleSleep"] = idleSleep.json }
        if let orchestration, !orchestration.isEmpty { v["orchestration"] = orchestration.json }
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
    /// Every agent's live state in one read (`agentState` v1). Older desktops have no bulk read.
    public let agentState: Feature?
    public var supportsAgentState: Bool { (agentState?.version ?? 0) >= 1 }
    /// Project pins, inactive marks and the idle rule, owned by the desktop (`projectState` v1).
    public let projectState: Feature?
    /// "Finished, waiting on you", owned by the desktop (`finishedQuickAgents` v1).
    public let finishedQuickAgents: Feature?
    /// Durable agents can be created (`agent.create` with create options v1). Older desktops offer quick agents only.
    public var supportsAgentCreate: Bool { commands.contains("agent.create") && (createOptions?.version ?? 0) >= 1 }
    /// An agent's settings can be read and changed (`agent.update` with agent settings v1).
    public var supportsAgentSettings: Bool { commands.contains("agent.update") && (agentSettings?.version ?? 0) >= 1 }
    /// The composer's model, effort and level controls (`chatControls` v1). Absent on older desktops.
    public let chatControls: Feature?
    public var supportsModelSwitch: Bool { commands.contains("chat.setModel") && (chatControls?.version ?? 0) >= 1 }
    public var supportsLevelSwitch: Bool { commands.contains("chat.setLevel") && (chatControls?.version ?? 0) >= 1 }
    /// The composer's `/` menu: the chat snapshot's `slashCommands` and `commands_available` events (`slashCommands` v1).
    public let slashCommands: Feature?
    public var supportsSlashCommands: Bool { commands.contains("chat.send") && (slashCommands?.version ?? 0) >= 1 }
    /// What a paired phone may do with permissions. Older desktops have no block: one-off approvals only, and no Free Agent Mode.
    public struct Permissions: Decodable, Sendable, Equatable {
        public let version: Int
        /// `chat.permission` answers `allow_session`, `allow_always` and `reject_always`.
        public let persistentApprovals: Bool
        /// `agent.create` and `agent.update` take `freeAgentMode`.
        public let freeAgentMode: Bool
        public init(version: Int = 1, persistentApprovals: Bool, freeAgentMode: Bool) {
            self.version = version; self.persistentApprovals = persistentApprovals; self.freeAgentMode = freeAgentMode
        }
        /// A malformed block grants nothing rather than failing the whole capability document.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 0
            persistentApprovals = (try? c.decode(Bool.self, forKey: .persistentApprovals)) ?? false
            freeAgentMode = (try? c.decode(Bool.self, forKey: .freeAgentMode)) ?? false
        }
        private enum CodingKeys: String, CodingKey { case version, persistentApprovals, freeAgentMode }
    }
    public let permissions: Permissions?
    /// Agents' orchestration policy in the catalog and settings, and `orchestration` on `agent.create` and `agent.update` (`orchestration` v1).
    public let orchestration: Feature?
    public var supportsOrchestration: Bool { commands.contains("agent.update") && (orchestration?.version ?? 0) >= 1 }
    public var supportsPersistentApprovals: Bool { commands.contains("chat.permission") && (permissions?.version ?? 0) >= 1 && permissions?.persistentApprovals == true }
    public var supportsFreeAgentMode: Bool { (permissions?.version ?? 0) >= 1 && permissions?.freeAgentMode == true }
    /// Helper starts and disposes waiting on the user, in the snapshot's `helperRequests`.
    public let helperRequests: Feature?
    /// Helper requests are listed and can be answered (`helper.approve` and `helper.decline` with helper requests v1).
    public var supportsHelperRequests: Bool {
        commands.contains("helper.approve") && commands.contains("helper.decline") && (helperRequests?.version ?? 0) >= 1
    }
    /// Finished quick agents are shared with the desktop. Older desktops leave the list on the phone.
    public var supportsFinishedQuickAgents: Bool {
        commands.contains("quick.dismiss") && commands.contains("quick.clear") && (finishedQuickAgents?.version ?? 0) >= 1
    }
    /// Pins and inactive marks are shared with the desktop. Older desktops leave them on the phone.
    public var supportsProjectState: Bool {
        commands.contains("project.setPinned") && commands.contains("project.setInactive") && (projectState?.version ?? 0) >= 1
    }
    /// The desktop's app-wide Dispatcher agent (`dispatcher` v1). Absent on older desktops: no Dispatcher anywhere.
    public struct Dispatcher: Decodable, Sendable, Equatable {
        public static let defaultProjectID = "__dispatcher__"
        public let version: Int
        /// The experimental flag and the app setting are both on.
        public let enabled: Bool
        /// The experimental flag alone. Turning the Dispatcher on needs it.
        public let flagOn: Bool
        /// The desktop runs its New layout, which turning the Dispatcher on also needs. Older drafts don't say: assumed on.
        public let newLayout: Bool
        /// The project id its agent is listed under.
        public let projectID: String
        public init(version: Int = 1, enabled: Bool, flagOn: Bool, newLayout: Bool = true, projectID: String = Self.defaultProjectID) {
            self.version = version; self.enabled = enabled; self.flagOn = flagOn; self.newLayout = newLayout; self.projectID = projectID
        }
        /// A malformed block reads as off rather than failing the whole capability document.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 0
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            flagOn = (try? c.decode(Bool.self, forKey: .flagOn)) ?? false
            newLayout = (try? c.decode(Bool.self, forKey: .newLayout)) ?? true
            projectID = (try? c.decode(String.self, forKey: .projectId)).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultProjectID
        }
        private enum CodingKeys: String, CodingKey { case version, enabled, flagOn, newLayout, projectId }
    }
    public let dispatcher: Dispatcher?
    public var supportsDispatcher: Bool { (dispatcher?.version ?? 0) >= 1 }
    /// The phone can turn the Dispatcher on and off (`dispatcher.setEnabled`).
    public var supportsDispatcherToggle: Bool { supportsDispatcher && commands.contains("dispatcher.setEnabled") }
    /// Image upload limits. Absent on desktops that can't take images: send text only.
    public struct Attachments: Decodable, Sendable, Equatable {
        public static let maximumCount = 10
        public let version: Int
        public let imageTypes: [String]
        public let maxImageBytes: Int
        public let maxCount: Int
        public init(version: Int = 1, imageTypes: [String], maxImageBytes: Int, maxCount: Int) {
            self.version = version; self.imageTypes = imageTypes; self.maxImageBytes = maxImageBytes; self.maxCount = maxCount
        }
        /// A malformed block reads as unusable rather than failing the whole capability document.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 0
            imageTypes = (try? c.decode([String].self, forKey: .imageTypes)) ?? []
            maxImageBytes = (try? c.decode(Int.self, forKey: .maxImageBytes)) ?? 0
            maxCount = min(Self.maximumCount, (try? c.decode(Int.self, forKey: .maxCount)) ?? 0)
        }
        private enum CodingKeys: String, CodingKey { case version, imageTypes, maxImageBytes, maxCount }
        public var isUsable: Bool { version == 1 && maxImageBytes > 0 && maxCount > 0 && !imageTypes.isEmpty }
    }
    public let attachments: Attachments?
    /// Project and agent shells and attached agent terminals (`terminal` v1). Absent on older desktops.
    public let terminal: Terminal?
    public var supportsTerminal: Bool { controlAvailable == true && terminal?.isUsable == true }

    /// The core fields are required. An optional block the phone can't read (the wrong type, a missing version)
    /// reads as absent, so that feature is off, rather than failing the whole document and the host with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        epoch = try c.decode(String.self, forKey: .epoch)
        controlAuth = try c.decode(String.self, forKey: .controlAuth)
        commands = try c.decode([String].self, forKey: .commands)
        idempotency = try c.decode(Idempotency.self, forKey: .idempotency)
        func optional<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        controlAvailable = optional(.controlAvailable)
        pairing = optional(.pairing)
        routes = optional(.routes)
        createOptions = optional(.createOptions)
        agentSettings = optional(.agentSettings)
        agentState = optional(.agentState)
        projectState = optional(.projectState)
        finishedQuickAgents = optional(.finishedQuickAgents)
        chatControls = optional(.chatControls)
        slashCommands = optional(.slashCommands)
        permissions = optional(.permissions)
        orchestration = optional(.orchestration)
        helperRequests = optional(.helperRequests)
        attachments = optional(.attachments)
        terminal = optional(.terminal)
        dispatcher = optional(.dispatcher)
    }
    private enum CodingKeys: String, CodingKey {
        case version, epoch, controlAuth, controlAvailable, commands, pairing, idempotency, routes, createOptions, agentSettings, agentState
        case projectState, finishedQuickAgents, chatControls, slashCommands, permissions, helperRequests, attachments, terminal, orchestration, dispatcher
    }
}

/// The desktop's reply to an image upload. The id is bound to this phone and agent, and expires.
nonisolated public struct AnnexAttachmentUpload: Decodable, Sendable, Equatable {
    public let version: Int
    public let attachmentId: String
    public let mimeType: String
    public let bytes: Int
    public let width: Int?
    public let height: Int?
}
