import Foundation
import Testing
@testable import ClubhouseTransport

/// The phone's transport against the desktop's recorded protocol (`Tests/Fixtures/AnnexContract/`).
@Suite struct AnnexContractTests {
    private static let commandTypes = ["chat.send", "chat.interrupt", "chat.permission", "chat.question", "chat.queue.remove", "agent.start",
                                       "agent.stop", "agent.spawn", "agent.create", "agent.update", "project.setPinned", "project.setInactive",
                                       "helper.approve", "helper.decline", "chat.setModel", "chat.setLevel", "quick.dismiss", "quick.clear"]

    private func capabilities() throws -> AnnexCapabilities {
        try #require(try AnnexContract.json("capabilities.json")["response"]?["body"]).decode(AnnexCapabilities.self)
    }

    @Test func vendoredFixturesAreCompleteAndRecordTheirDesktopCommit() throws {
        let files = try AnnexContract.files()
        #expect(files.count >= 40)
        for file in files { #expect(throws: Never.self, "\(file)") { _ = try AnnexContract.json(file) } }
        let source = try AnnexContract.json("SOURCE.json")
        #expect(source["repository"]?.string == "Agent-Clubhouse/Clubhouse")
        let commit = try #require(source["commit"]?.string)
        #expect(commit.count == 40 && commit.allSatisfy(\.isHexDigit))
        for type in Self.commandTypes { #expect(files.contains("commands/\(type).json"), "\(type)") }
    }

    // MARK: Capabilities

    @Test func capabilitiesDecodeWithEveryFeatureTheDesktopAdvertises() throws {
        let caps = try capabilities()
        #expect(caps.version == 1 && caps.controlAuth == "mtls-pinned-client" && caps.controlAvailable == true)
        #expect(Set(caps.commands) == Set(Self.commandTypes))
        #expect(caps.supportsAgentCreate && caps.supportsAgentSettings && caps.supportsModelSwitch && caps.supportsLevelSwitch)
        #expect(caps.supportsPersistentApprovals && caps.supportsFreeAgentMode && caps.supportsHelperRequests)
        #expect(caps.supportsFinishedQuickAgents && caps.supportsProjectState && caps.supportsTerminal && caps.supportsAgentState)
        #expect(caps.supportsSlashCommands && caps.slashCommands?.version == 1)
        #expect(caps.supportsOrchestration && caps.orchestration?.version == 1)
        #expect(caps.attachments == .init(imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"], maxImageBytes: 3_932_160, maxCount: 10))
        #expect(caps.terminal == .init(projectShell: true, agentShell: true, agentAttach: true, maxShellsPerConnection: 8, maxInputLength: 65_536))
        #expect(caps.idempotency.maxEntries == 2048 && caps.idempotency.ttlMs == 3_600_000 && caps.idempotency.scope == "peer-and-epoch")
        #expect(caps.pairing?.sessionRevokePath == "/api/v1/mobile/pairing")
        #expect(caps.routes == .init(hosts: ["127.0.0.1"], port: 7432))
        #expect(caps.createOptions?.path == "/api/v1/mobile/projects/{projectId}/create-options")
        #expect(caps.agentSettings?.path == "/api/v1/mobile/agents/{agentId}/settings")
    }

    /// The desktop's field list for every command is what the phone checks its encoder against.
    @Test func everyAdvertisedCommandHasAPhoneEncodingWithinTheDesktopsFields() throws {
        let schema = try AnnexContract.json("commands/_fields.json")
        #expect(Optional(schema["commands"] ?? .null).keys == Set(Self.commandTypes))
        for command in Self.maximalCommands() {
            let encoded = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
            let entry = schema["commands"]?[command.type]
            let allowed = Set(schema["base"].list.compactMap(\.string) + (entry?["fields"]).list.compactMap(\.string))
            #expect(encoded.optionalKeys.isSubset(of: allowed), "\(command.type) sends \(encoded.optionalKeys.subtracting(allowed).sorted()), which the desktop refuses")
            let required = Set((entry?["required"]).list.compactMap(\.string))
            #expect(required.isSubset(of: encoded.optionalKeys), "\(command.type) misses a required field")
        }
        #expect(Set(Self.maximalCommands().map(\.type)) == Set(Self.commandTypes))
    }

    /// Every accepted request the desktop recorded is one the phone builds identically (`AnnexCommand.encoded()`).
    @Test func phoneCommandsEncodeExactlyAsTheDesktopAcceptsThem() throws {
        var checked = 0
        for type in Self.commandTypes {
            for item in try AnnexContract.cases("commands/\(type).json") where item["name"]?.string?.hasPrefix("accepted") == true {
                let request = try #require(item["request"])
                guard let kind = Self.kind(from: request) else { Issue.record("No phone command for \(type) \(item["name"]?.string ?? "")"); continue }
                let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: kind)
                var expected = request
                // The phone always names delivery; `auto` is the desktop's default when it's left out.
                if type == "chat.send", case .object(var fields) = expected, fields["delivery"] == nil { fields["delivery"] = .string("auto"); expected = .object(fields) }
                #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == expected, "\(type): \(item["name"]?.string ?? "")")
                checked += 1
            }
        }
        #expect(checked >= 30)
    }

    // MARK: Receipts

    /// Every recorded receipt, at its recorded HTTP status, through the real `execute`: the phone must read the
    /// desktop's definitive answer, never mistake it for a lost reply.
    @Test func everyRecordedReceiptIsReadThroughTheTransport() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let epoch = try #require(caps?["body"]?["epoch"]?.string)
        var checked = 0
        for file in try AnnexContract.files() where file.hasPrefix("commands/") && file != "commands/_fields.json" {
            for item in try AnnexContract.cases(file) {
                let request = try #require(item["request"]), body = try #require(item["response"]?["body"])
                guard request["epoch"]?.string == epoch, let id = request["commandId"]?.string, body["status"] != nil else { continue }
                let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(item["response"])])
                let transport = try await annexContractTransport(io)
                _ = try await transport.read(.capabilities)
                let name = "\(file) \(item["name"]?.string ?? "")"
                do {
                    let receipt = try await transport.execute(AnnexCommand(commandID: id, epoch: epoch, kind: .stop(agentID: "durable_term")))
                    #expect(receipt.status.rawValue == body["status"]?.string, "\(name)")
                    #expect(receipt.error?.code == body["error"]?["code"]?.string, "\(name)")
                    #expect(receipt.result == body["result"], "\(name)")
                } catch { Issue.record("\(name): \(error)") }
                checked += 1
            }
        }
        #expect(checked >= 100)
    }

    @Test func everyRecordedReceiptDecodes() throws {
        for file in try AnnexContract.files() where file.hasPrefix("commands/") && file != "commands/_fields.json" {
            for item in try AnnexContract.cases(file) {
                guard let body = item["response"]?["body"], body["status"] != nil else { continue }
                let receipt = try body.decode(AnnexCommandReceipt.self)
                #expect(receipt.version == 1)
                #expect((receipt.status == .completed) == (receipt.error == nil), "\(file) \(item["name"]?.string ?? "")")
            }
        }
    }

    // MARK: Attachments

    @Test func everyRecordedUploadAnswerIsReadThroughTheTransport() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        for item in try AnnexContract.cases("attachments.json") {
            let name = item["name"]?.string ?? ""
            let response = item["response"]
            let retry = response?["headers"]?["retry-after"] != nil ? 30 : nil
            let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(response, retryAfter: retry)])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            let status = Int(response?["status"]?.integer ?? 0), code = response?["body"]?["error"]?.string
            do {
                let upload = try await transport.upload(agentID: "durable_chat", data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
                #expect(status == 200, "\(name)")
                #expect(try response?["body"]?.decode(AnnexAttachmentUpload.self) == upload, "\(name)")
            } catch let error as AnnexTransportError {
                switch status {
                case 401: #expect(error == .unauthorized, "\(name)")
                case 403: #expect(error == .forbidden, "\(name)")
                case 429: #expect(error == .rateLimited(code: code, retryAfterSeconds: 30), "\(name)")
                default: #expect(error == .rejected(status: status, code: code), "\(name)")
                }
            }
        }
    }

    // MARK: WebSocket frames

    @Test func everyRecordedWebSocketFrameDecodesAsAnEnvelope() throws {
        let snapshot = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(try #require(AnnexContract.json("snapshot.json")["frame"])))
        #expect(snapshot.type == "snapshot" && snapshot.snapshotSequence != nil)
        let events = try AnnexContract.json("chat-events.json")["frames"].list
        #expect(events.count >= 30)
        for frame in events {
            let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(frame))
            #expect(envelope.type == "chat:event" && envelope.seq != nil && envelope.payload?["event"]?["sessionId"]?.string == "sess_live")
        }
        let replay = try AnnexContract.cases("replay.json")
        let frames = try replay.flatMap { $0["replies"].list }.map { try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode($0)) }
        let start = try #require(frames.first { $0.type == "replay:start" })
        #expect(start.epoch != nil && start.fromSeq != nil && start.replayUpperBound != nil && start.count == 1)
        #expect(frames.contains { $0.type == "chat:event" && $0.replayed == true && $0.seq != nil })
        #expect(frames.contains { $0.type == "replay:end" && $0.epoch != nil })
        #expect(frames.filter { $0.type == "replay:gap" }.allSatisfy { $0.epoch != nil && $0.lastSeq != nil && $0.oldestAvailable != nil })
    }

    /// The phone's `pty:*` frames are the desktop's, and every answer carries the id the phone routes it by.
    @Test func terminalFramesMatchTheDesktop() throws {
        var built = 0
        for item in try AnnexContract.cases("pty.json") {
            let name = item["name"]?.string ?? ""
            if let request = item["request"], let frame = Self.terminalFrame(from: request) {
                #expect(try JSONDecoder().decode(AnnexJSON.self, from: frame.encoded()) == request, "\(name)")
                built += 1
            }
            for reply in item["replies"].list {
                let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(reply))
                // A durable agent's exit also says it sleeps, for the agent list rather than the terminal.
                if envelope.type == "agent:status", name.hasPrefix("agent output") {
                    #expect(!AnnexTransport.isTerminalFrame(envelope) && envelope.payload?["status"]?.string == "sleeping")
                    continue
                }
                #expect(envelope.type.hasPrefix("pty:") || envelope.type == "error", "\(name)")
                if envelope.payload?["sessionId"] != nil || envelope.payload?["agentId"] != nil {
                    #expect(AnnexTerminalFrame.id(of: envelope) != nil, "\(name)")
                }
                // Shell output is never kept for replay; agent output is.
                if name.hasPrefix("shell output") { #expect(envelope.seq == nil) }
                if name.hasPrefix("agent output") { #expect(envelope.seq != nil) }
            }
        }
        #expect(built >= 12)
        let ack = try #require(try AnnexContract.cases("pty.json").first { $0["name"]?.string == "attach" }?["replies"].list.first)
        #expect(ack["payload"]?["outputSeq"]?.integer == 42)
        #expect(AnnexTerminalOutput.unseen("abc", outputSeq: 42, snapshotSeq: ack["payload"]?["outputSeq"]?.integer) == nil)
    }

    // MARK: Fixture → phone command

    /// The phone command a desktop request corresponds to. Nil for a request the phone can't build.
    static func kind(from r: AnnexJSON) -> AnnexCommand.Kind? {
        func s(_ key: String) -> String? { r[key]?.string }
        func b(_ key: String) -> Bool? { if case .bool(let v)? = r[key] { v } else { nil } }
        func strings(_ key: String) -> [String]? { r[key].map { Optional($0).list.compactMap(\.string) } }
        guard let type = s("type") else { return nil }
        switch type {
        case "chat.send":
            guard let agent = s("agentId"), let session = s("sessionId"), let text = s("text") else { return nil }
            return .send(agentID: agent, sessionID: session, text: text, delivery: s("delivery").flatMap(AnnexCommand.Delivery.init(rawValue:)) ?? .auto,
                         attachmentIDs: strings("attachmentIds") ?? [])
        case "chat.interrupt": return s("agentId").flatMap { a in s("sessionId").map { .interrupt(agentID: a, sessionID: $0) } }
        case "chat.queue.remove":
            guard let a = s("agentId"), let session = s("sessionId"), let ids = strings("messageIds") else { return nil }
            return .removeQueued(agentID: a, sessionID: session, messageIDs: ids)
        case "chat.permission":
            guard let a = s("agentId"), let session = s("sessionId"), let request = s("requestId"), let option = s("optionId") else { return nil }
            return .permission(agentID: a, sessionID: session, requestID: request, optionID: option)
        case "chat.question":
            guard let a = s("agentId"), let session = s("sessionId"), let request = s("requestId"), case .object(let answers)? = r["answers"] else { return nil }
            return .question(agentID: a, sessionID: session, requestID: request, answers: answers)
        case "chat.setModel":
            guard let a = s("agentId"), let session = s("sessionId"), let model = s("model") else { return nil }
            let effort: AnnexCommand.Effort? = switch r["effort"] { case .string(let v)?: .set(v); case .null?: .providerDefault; default: nil }
            return .setModel(agentID: a, sessionID: session, model: model, effort: effort)
        case "chat.setLevel":
            guard let a = s("agentId"), let session = s("sessionId"), let level = s("level") else { return nil }
            return .setLevel(agentID: a, sessionID: session, level: level)
        case "agent.start": return s("agentId").map { .start(agentID: $0, message: s("message"), resume: b("resume")) }
        case "agent.stop": return s("agentId").map { .stop(agentID: $0) }
        case "agent.spawn":
            guard let p = s("projectId"), let prompt = s("prompt") else { return nil }
            return .spawn(projectID: p, prompt: prompt, model: s("model"), orchestrator: s("orchestrator"))
        case "agent.create":
            guard let p = s("projectId"), let name = s("name"), let color = s("color") else { return nil }
            return .create(.init(projectID: p, name: name, color: color, orchestrator: s("orchestrator"), model: s("model"), persona: s("persona"),
                                 freeAgentMode: b("freeAgentMode"), useWorktree: b("useWorktree"), mcpIDs: strings("mcpIds"),
                                 branchName: s("branchName"), branchFrom: s("branchFrom"), folderName: s("folderName"),
                                 orchestration: orchestration(r["orchestration"])))
        case "agent.update":
            guard let a = s("agentId") else { return nil }
            func clearable(_ key: String) -> AnnexAgentUpdate.Clearable? { switch r[key] { case .string(let v)?: .set(v); case .null?: .clear; default: nil } }
            let idle: AnnexAgentUpdate.IdleSleep? = switch r["idleSleep"] {
            case .string("inherit")?: .inherit
            case .string("never")?: .never
            case .integer(let m)?: .minutes(Int(m))
            default: nil
            }
            return .update(.init(agentID: a, name: s("name"), color: s("color"), emoji: clearable("emoji"), orchestrator: s("orchestrator"), model: s("model"),
                                 runtime: s("runtime").flatMap(AnnexAgentUpdate.Runtime.init(rawValue:)), persona: clearable("persona"),
                                 clubhouseMode: b("clubhouseMode"), freeAgentMode: b("freeAgentMode"), idleSleep: idle,
                                 orchestration: orchestration(r["orchestration"])))
        case "project.setPinned": return s("projectId").flatMap { p in b("pinned").map { .setProjectPinned(projectID: p, pinned: $0) } }
        case "project.setInactive": return s("projectId").flatMap { p in b("inactive").map { .setProjectInactive(projectID: p, inactive: $0) } }
        case "helper.approve": return s("requestId").map { .helperApprove(requestID: $0, force: b("force") ?? false) }
        case "helper.decline": return s("requestId").map { .helperDecline(requestID: $0) }
        case "quick.dismiss": return s("projectId").flatMap { p in s("agentId").map { .dismissFinishedQuick(projectID: p, agentID: $0) } }
        case "quick.clear": return s("projectId").map { .clearFinishedQuick(projectID: $0) }
        case "dispatcher.setEnabled": return b("enabled").map { .setDispatcherEnabled($0) }
        default: return nil
        }
    }

    /// The phone's patch for a recorded `orchestration` object, or `null` for clear all.
    static func orchestration(_ value: AnnexJSON?) -> AnnexOrchestrationPatch? {
        guard let value else { return nil }
        if value == .null { return .clearAll }
        func field<T>(_ key: String, _ read: (AnnexJSON) -> T?) -> AnnexOrchestrationPatch.Field<T>? {
            guard let raw = value[key] else { return nil }
            return raw == .null ? .clear : read(raw).map { .set($0) }
        }
        return .init(orchestrate: field("orchestrate") { if case .bool(let v) = $0 { v } else { nil } }, access: field("access") { $0.string },
                     control: field("control") { $0.string }, maxHelpers: field("maxHelpers") { $0.int },
                     crossProjectHelpers: field("crossProjectHelpers") { if case .bool(let v) = $0 { v } else { nil } },
                     connectToDispatcher: field("connectToDispatcher") { if case .bool(let v) = $0 { v } else { nil } })
    }

    /// One of every command with every optional field the phone can send.
    static func maximalCommands() -> [AnnexCommand] {
        let kinds: [AnnexCommand.Kind] = [
            .send(agentID: "a", sessionID: "s", text: "t", delivery: .queued, attachmentIDs: ["i"]),
            .interrupt(agentID: "a", sessionID: "s"),
            .removeQueued(agentID: "a", sessionID: "s", messageIDs: ["m"]),
            .permission(agentID: "a", sessionID: "s", requestID: "r", optionID: "o"),
            .question(agentID: "a", sessionID: "s", requestID: "r", answers: ["q": .array([.string("x")])]),
            .start(agentID: "a", message: "m", resume: true),
            .stop(agentID: "a"),
            .spawn(projectID: "p", prompt: "p", model: "m", orchestrator: "o"),
            .create(.init(projectID: "p", name: "n", color: "c", orchestrator: "o", model: "m", persona: "p", freeAgentMode: true, useWorktree: true,
                          mcpIDs: ["x"], branchName: "b", branchFrom: "main", folderName: "f", orchestration: .init(orchestrate: .set(true)))),
            .update(.init(agentID: "a", name: "n", color: "c", emoji: .clear, orchestrator: "o", model: "m", runtime: .chat, persona: .set("p"),
                          clubhouseMode: true, freeAgentMode: true, idleSleep: .minutes(30), orchestration: .init(maxHelpers: .clear))),
            .setProjectPinned(projectID: "p", pinned: true),
            .setProjectInactive(projectID: "p", inactive: true),
            .dismissFinishedQuick(projectID: "p", agentID: "a"),
            .clearFinishedQuick(projectID: "p"),
            .helperApprove(requestID: "r", force: true),
            .helperDecline(requestID: "r"),
            .setModel(agentID: "a", sessionID: "s", model: "m", effort: .providerDefault),
            .setLevel(agentID: "a", sessionID: "s", level: "plan"),
        ]
        return kinds.map { AnnexCommand(commandID: "c", epoch: "e", kind: $0) }
    }

    static func terminalFrame(from r: AnnexJSON) -> AnnexTerminalFrame? {
        let p = r["payload"]
        func s(_ key: String) -> String? { p?[key]?.string }
        switch r["type"]?.string {
        case "pty:spawn-shell": return s("sessionId").flatMap { id in s("projectId").map { .spawnShell(sessionID: id, projectID: $0, agentID: s("agentId")) } }
        case "pty:input":
            guard let id = s("agentId"), let data = s("data"), !data.hasPrefix("<") else { return nil }
            return .input(id: id, data: data)
        case "pty:resize":
            guard let id = s("agentId"), let cols = p?["cols"]?.integer, let rows = p?["rows"]?.integer else { return nil }
            return .resize(id: id, cols: Int(cols), rows: Int(rows))
        case "pty:close": return s("sessionId").map { .close(sessionID: $0) }
        case "pty:attach": return s("agentId").map { .attach(agentID: $0) }
        default: return nil
        }
    }
}

extension AnnexJSON {
    var optionalKeys: Set<String> { Optional(self).keys }
}
