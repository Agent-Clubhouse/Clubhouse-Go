import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Reduces the desktop's versioned rich-chat contract into native presentation.
/// `lastSequence` is session-local; Annex's global websocket sequence never enters it.
struct CompanionChatProjector {
    var sessionID: String?
    var lastSequence = 0
    var items: [CompanionTimelineItem] = []
    var status: CompanionAgentStatus = .idle
    var capabilities: CompanionCapabilities = []
    var model: String?
    /// When the running turn started (`turn_started`), for the header's elapsed time.
    var turnStartedAt: Date?
    var contextUsage: CompanionContextUsage?
    /// CLI version, effort, permission level and MCP servers, for Agent details.
    var session = CompanionSessionFacts()
    var commandIDsByMessage: [String: String] = [:]
    var queueStateSequence: Int64 = 0
    var queuedMessageIDs: Set<String> = []
    var queueRemovalSupported = false
    /// The composer's model, effort and level, folded from this session's events. Shown only while the session is live.
    var controls = CompanionChatControls()
    /// The sequence of the latest `session_info` that listed efforts, so a model switch can wait for the new list.
    var effortsSequence = 0

    mutating func apply(_ event: AnnexJSON, allowOlderPending: Bool = false) {
        guard let session = event["sessionId"]?.string,
              let sequence = event["seq"]?.integer, let type = event["type"]?.string else { return }
        if sessionID != session {
            sessionID = session; lastSequence = 0; items = []; capabilities = []; model = nil; turnStartedAt = nil; contextUsage = nil
            self.session = .init()
            queueStateSequence = 0; queuedMessageIDs = []; queueRemovalSupported = false
            controls = .init(); effortsSequence = 0
        }
        guard allowOlderPending || sequence > lastSequence else { return }
        lastSequence = max(lastSequence, Int(sequence))
        let data = event["data"] ?? .object([:])
        controls.apply(type: type, data: data)
        if type == "session_info", data["efforts"] != nil { effortsSequence = Int(sequence) }
        let time = event["ts"]?.integer.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        switch type {
        case "session_started", "session_info":
            if let caps = data["capabilities"] { updateCapabilities(caps) }
            if let model = data["model"]?.string { self.model = model }
            applySessionFacts(data)
        case "session_state":
            status = Self.status(data["state"]?.string)
            if status != .working && status != .approval && status != .waiting { turnStartedAt = nil }
        case "turn_started": status = .working; turnStartedAt = time ?? turnStartedAt
        case "turn_ended":
            turnStartedAt = nil
            // A cancelled turn leaves the session alive between turns, which the desktop shows as Done.
            status = data["stopReason"]?.string == "error" ? .failed : .idle
            finishStreams()
        case "session_ended":
            // An idle timeout puts the agent to sleep; it resumes on the next message or a wake.
            switch data["reason"]?.string { case "error": status = .failed; case "idle_timeout": status = .sleeping; default: status = .stopped }
            capabilities = []; turnStartedAt = nil; finishStreams()
        case "user_message":
            guard let messageID = data["messageId"]?.string else { return }
            let content = data["content"].arrayValue
            let text = content.filter { $0["type"]?.string != "image" }.map { Self.contentText($0) }.joined(separator: "\n")
            upsert(.message(.init(id: messageID, role: .user, text: text, timestamp: time,
                                  clientCommandID: data["clientCommandId"]?.string ?? commandIDsByMessage[messageID],
                                  queueState: queuedMessageIDs.contains(messageID) ? .queued : data["delivery"]?.string == "queued" ? .submitted : nil,
                                  source: data["source"]?.string, isSteered: data["delivery"]?.string == "steer",
                                  images: Self.userImages(content, messageID: messageID))))
        case "queue_state":
            guard sequence > queueStateSequence else { return }
            queueStateSequence = sequence
            queuedMessageIDs = Set(data["queuedMessageIds"].arrayValue.compactMap(\.string))
            applyQueueMembership()
            if let transition = data["transition"], let name = transition["status"]?.string,
               let state = CompanionMessage.QueueState(rawValue: name) {
                let ids = Set(transition["messageIds"].arrayValue.compactMap(\.string))
                for index in items.indices {
                    if case .message(var message) = items[index], ids.contains(message.id) {
                        message.queueState = queuedMessageIDs.contains(message.id) ? .queued : state == .queued ? .submitted : state
                        items[index] = .message(message)
                    }
                }
            }
        case "queue_removed":
            // Legacy event remains useful for history. New queue_state/snapshot
            // watermarks prevent an older event from overriding newer membership.
            guard sequence > queueStateSequence else { return }
            queueStateSequence = sequence
            let ids = Set(data["messageIds"].arrayValue.compactMap(\.string))
            queuedMessageIDs.subtract(ids)
            for index in items.indices {
                if case .message(var message) = items[index], ids.contains(message.id) {
                    message.queueState = .removed; items[index] = .message(message)
                }
            }
        case "agent_message_chunk", "agent_message":
            guard let messageID = data["messageId"]?.string, let text = data["text"]?.string else { return }
            let existing = message(id: messageID)
            let chunk = type == "agent_message_chunk"
            upsert(.message(.init(id: messageID, role: .assistant, text: chunk ? (existing?.text ?? "") + text : text,
                                  timestamp: existing?.timestamp ?? time, isStreaming: chunk)))
        case "tool_call", "tool_call_update":
            guard let toolID = data["toolCallId"]?.string else { return }
            let old = tool(id: toolID)
            let blocks = data["content"].arrayValue
            let content = blocks.map { Self.contentText($0) }.joined(separator: "\n")
            let output = content.isEmpty ? data["error"]?.string ?? data["rawOutput"]?.displayText : content
            let input = Self.inputSummary(data["rawInput"])
            let state: CompanionTool.State
            let rawStatus = data["status"]?.string
            switch rawStatus {
            case "completed": state = .completed
            case "failed", "cancelled": state = .failed
            case "pending", "in_progress": state = .running
            default: state = old?.state ?? .running
            }
            // A diff or terminal output makes the call worth seeing on its own. An update without content keeps what came before.
            let changes = data["content"] == nil ? old?.hasChanges ?? false
                : blocks.contains { ["diff", "terminal"].contains($0["type"]?.string) } || (data["contentMode"]?.string == "append" && old?.hasChanges == true)
            let images: [CompanionContentReference] = data["media"] == nil ? old?.images ?? [] : data["media"].arrayValue.prefix(16).compactMap { image in
                guard let reference = image["mediaRef"]?.string, CompanionContentReference.validMediaReference(reference) else { return nil }
                return .image(reference)
            }
            let kind: CompanionTool.Kind? = data["kind"]?.string.map { CompanionTool.Kind(rawValue: $0) ?? .other } ?? old?.kind
            let location: String? = data["locations"].arrayValue.first?["path"]?.string ?? old?.location
            let awaitsApproval: Bool = rawStatus.map { $0 == "pending" } ?? old?.awaitsApproval ?? false
            let name: String = data["title"]?.string ?? data["toolName"]?.string ?? old?.name ?? "Tool activity"
            let combined: String? = data["contentMode"]?.string == "append" ? (old?.output ?? "") + (output ?? "") : output ?? old?.output
            upsert(.tool(.init(id: toolID, name: name, summary: input ?? old?.summary ?? "", output: combined, state: state, images: images,
                               kind: kind, location: location, hasChanges: changes, awaitsApproval: awaitsApproval)))
        case "permission_request":
            guard let requestID = data["requestId"]?.string else { return }
            let options = data["options"].arrayValue.compactMap { value -> CompanionApprovalOption? in
                guard let id = value["optionId"]?.string, let label = value["label"]?.string else { return nil }
                let kind: CompanionApprovalOption.Kind
                switch value["kind"]?.string {
                case "allow_once": kind = .allowOnce
                case "reject_once": kind = .rejectOnce
                case "cancel_turn": kind = .cancelTurn
                // Persistent changes are listed, as on the desktop, but are answered there.
                case "allow_session": kind = .allowSession
                case "allow_always": kind = .allowAlways
                case "reject_always": kind = .rejectAlways
                default: kind = .other
                }
                return .init(id: id, label: label, kind: kind, scope: value["scope"]?.string)
            }
            let detail = data["content"].arrayValue.map { Self.contentText($0) }.joined(separator: "\n")
            upsert(.approval(.init(id: requestID, toolName: data["toolName"]?.string ?? "Approval request",
                                   summary: data["description"]?.string ?? data["title"]?.string ?? "Review the requested action",
                                   title: data["title"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                   detail: detail.isEmpty ? Self.inputSummary(data["rawInput"]) : detail, options: options)))
            status = .approval
        case "permission_resolved":
            guard let requestID = data["requestId"]?.string,
                  let index = items.firstIndex(where: { $0.id == "approval:\(requestID)" }), case .approval(var approval) = items[index] else { return }
            switch data["decision"]?.string { case "allow": approval.resolution = .allowed; case "cancelled": approval.resolution = .cancelled; default: approval.resolution = .denied }
            items[index] = .approval(approval)
        case "question":
            guard let requestID = data["requestId"]?.string else { return }
            let prompts = data["questions"].arrayValue.compactMap { value -> CompanionQuestion.Prompt? in
                guard let id = value["id"]?.string, let prompt = value["prompt"]?.string else { return nil }
                let options = value["options"].arrayValue.compactMap { option -> CompanionQuestion.Prompt.Option? in
                    guard let id = option["id"]?.string, let label = option["label"]?.string else { return nil }
                    return .init(id: id, label: label, detail: option["description"]?.string)
                }
                return .init(id: id, text: prompt, options: options, allowsMultiple: value["multiSelect"].boolValue, allowsFreeText: value["allowFreeText"].boolValue)
            }
            upsert(.question(.init(id: requestID, prompts: prompts))); status = .waiting
        case "question_resolved":
            guard let requestID = data["requestId"]?.string,
                  let index = items.firstIndex(where: { $0.id == "question:\(requestID)" }), case .question(var question) = items[index] else { return }
            question.resolution = data["cancelled"].boolValue ? .cancelled : .answered; items[index] = .question(question)
        case "plan":
            let plan = data["entries"].arrayValue.map { entry in
                "\(entry["status"]?.string == "completed" ? "✓" : entry["status"]?.string == "in_progress" ? "→" : "○") \(entry["content"]?.string ?? "")"
            }.joined(separator: "\n")
            upsert(.message(.init(id: "plan-\(session)", role: .system, text: plan)))
        case "plan_document":
            if let text = data["markdown"]?.string {
                upsert(.message(.init(id: "plan-document-\(data["planId"]?.string ?? session)", role: .assistant, text: text, isStreaming: data["status"]?.string == "streaming")))
            }
        case "subagent":
            let name = data["name"]?.string ?? "Subagent"
            let status = data["status"]?.string ?? "working"
            upsert(.notice(id: "subagent-\(data["subagentId"]?.string ?? String(sequence))", text: "\(name) · \(status)"))
        case "error", "notice":
            if let message = data["message"]?.string { upsert(.notice(id: "event-\(session)-\(sequence)", text: message)) }
            // Only a fatal error the runtime won't retry stops the agent; others are notices.
            if type == "error", data["fatal"].boolValue, !data["willRetry"].boolValue { status = .failed }
        case "model_changed":
            model = data["modelId"]?.string
            self.session.effort = data["effort"]?.string
            self.session.effortIsDefault = data["effortIsDefault"].boolValue
        case "mode_changed": if let level = data["level"]?.string { self.session.level = level }
        case "usage":
            if let context = data["context"], let used = context["used"]?.integer, let size = context["size"]?.integer, used >= 0, size > 0 {
                contextUsage = .init(used: Int(used), size: Int(size))
            }
        default: break // Additive protocol events are safe to ignore.
        }
    }

    /// Fields present replace earlier ones; absent ones keep them (`session_info`).
    mutating func applySessionFacts(_ data: AnnexJSON) {
        if let version = data["cliVersion"]?.string { session.cliVersion = version }
        if let level = data["level"]?.string { session.level = level }
        if case .object(let names)? = data["levelNames"] { session.levelNames = names.compactMapValues(\.string) }
        if case .array(let servers)? = data["mcpServers"] {
            session.mcpServers = servers.compactMap { server in
                server["name"]?.string.map { CompanionMCPServer(name: $0, status: server["status"]?.string.flatMap(CompanionMCPServer.Status.init(rawValue:)) ?? .unknown) }
            }
        }
    }

    /// `session_info` carries only the capabilities that changed (Claude reports them after the first prompt),
    /// so keys that are absent keep their earlier value. A new session starts from empty.
    mutating func updateCapabilities(_ value: AnnexJSON) {
        capabilities.formUnion([.chat, .approve])
        controls.applyCapabilities(value)
        func set(_ flag: CompanionCapabilities, _ key: String) {
            guard case .bool(let enabled)? = value[key] else { return }
            if enabled { capabilities.insert(flag) } else { capabilities.remove(flag) }
        }
        set(.steer, "steer")
        set(.cancel, "interrupt")
        set(.answer, "questions")
        set(.images, "images")
        if let queue = value["queue"]?.string {
            if queue != "none" { capabilities.insert(.queue) } else { capabilities.remove(.queue) }
            queueRemovalSupported = queue == "client"
            if queueRemovalSupported { capabilities.insert(.removeQueued) } else { capabilities.remove(.removeQueued) }
        }
    }

    mutating func applyQueueSnapshot(_ snapshot: AnnexJSON) {
        guard let sequence = snapshot["queueStateSeq"]?.integer, sequence >= queueStateSequence else { return }
        queueStateSequence = sequence
        queuedMessageIDs = Set(snapshot["queuedMessageIds"].arrayValue.compactMap(\.string))
        queueRemovalSupported = snapshot["queueRemovalSupported"].boolValue
        if queueRemovalSupported { capabilities.insert(.removeQueued) } else { capabilities.remove(.removeQueued) }
        applyQueueMembership()
    }

    private mutating func applyQueueMembership() {
        for index in items.indices {
            if case .message(var message) = items[index] {
                if queuedMessageIDs.contains(message.id) { message.queueState = .queued }
                else if message.queueState == .queued { message.queueState = .submitted }
                items[index] = .message(message)
            }
        }
    }
    mutating func reconcile(messageID: String, commandID: String) -> CompanionTimelineItem? {
        commandIDsByMessage[messageID] = commandID
        guard var message = message(id: messageID) else { return nil }
        message.clientCommandID = commandID
        let item = CompanionTimelineItem.message(message)
        upsert(item); return item
    }
    mutating func upsert(_ item: CompanionTimelineItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }
    private func message(id: String) -> CompanionMessage? {
        guard let item = items.first(where: { $0.id == "message:\(id)" }), case .message(let message) = item else { return nil }
        return message
    }
    private func tool(id: String) -> CompanionTool? {
        guard let item = items.first(where: { $0.id == "tool:\(id)" }), case .tool(let tool) = item else { return nil }
        return tool
    }
    private mutating func finishStreams() {
        for index in items.indices {
            if case .message(var message) = items[index], message.isStreaming { message.isStreaming = false; items[index] = .message(message) }
        }
    }
    /// The desktop reports chat agents as `running` for their whole session; what they're doing is in
    /// `detailedStatus.state` (`idle`, `working`, `needs_permission`, `tool_error`). Follows the desktop's
    /// `agentDot` (`agent-status.tsx`): an error or failed tool first, then a pending prompt, then the lifecycle.
    static func status(_ value: String?, detailed: AnnexJSON?) -> CompanionAgentStatus {
        let lifecycle = status(value)
        let state = detailed?["state"]?.string
        let message = detailed?["message"]?.string ?? ""
        if lifecycle == .failed || state == "tool_error" { return .failed }
        if state == "needs_permission" {
            let isQuestion = message.lowercased().contains("question") || detailed?["toolName"]?.string == "AskUserQuestion"
            return isQuestion ? .waiting : .approval
        }
        guard lifecycle == .working else { return lifecycle }
        switch state {
        // "Thinking" is the desktop's mid-turn idle (`isMidTurn`): still working.
        case "idle": return message == "Thinking" ? .working : .idle
        default: return .working
        }
    }
    /// A desktop agent status (`running`, `sleeping`, `waking`, `creating`, `spawning`, `error`) or a chat
    /// session state (`starting`, `idle`, `running`, `waiting_permission`, `waiting_input`, `sleeping`, `error`).
    static func status(_ value: String?) -> CompanionAgentStatus {
        switch value {
        case "running": .working
        case "starting", "creating", "spawning", "waking": .starting
        case "waiting_permission": .approval
        case "waiting_input": .waiting
        case "error", "failed": .failed
        case "completed": .completed
        case "sleeping": .sleeping
        case "cancelled": .stopped
        default: .idle
        }
    }
    /// A tool's input as a person would read it: the command, or the file and what goes in it, rather than raw JSON.
    static func inputSummary(_ value: AnnexJSON?) -> String? {
        guard let value else { return nil }
        if let command = value["command"]?.string { return "$ \(command)" }
        if let path = value["file_path"]?.string ?? value["path"]?.string {
            let name = (path as NSString).lastPathComponent
            if let content = (value["content"] ?? value["new_string"])?.string { return "\(name)\n\(content.prefix(400))" }
            return name
        }
        if let description = value["description"]?.string { return description }
        return value.displayText
    }
    /// Image blocks the desktop echoes in a user message. Older desktops send no `mediaRef`: those show as a placeholder.
    static func userImages(_ content: [AnnexJSON], messageID: String) -> [CompanionMessageImage] {
        content.filter { $0["type"]?.string == "image" }.prefix(CompanionImageLimits.maximumPerMessage).enumerated().map { index, block in
            let reference = block["mediaRef"]?.string.flatMap { CompanionContentReference.validMediaReference($0) ? $0 : nil }
            // Only ever a file name, even if a desktop sends more.
            let name = block["path"]?.string.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
            func dimension(_ key: String) -> Int? { block[key]?.integer.flatMap { $0 > 0 && $0 < 100_000 ? Int($0) : nil } }
            return .init(id: "\(messageID)-image-\(index)", mimeType: block["mimeType"]?.string, mediaRef: reference, name: name,
                         width: dimension("width"), height: dimension("height"))
        }
    }
    private static func contentText(_ value: AnnexJSON) -> String {
        switch value["type"]?.string {
        case "text": value["text"]?.string ?? ""
        case "terminal": [value["command"]?.string, value["output"]?.string].compactMap { $0 }.joined(separator: "\n")
        case "diff": value["unifiedDiff"]?.string ?? [value["path"]?.string, value["newText"]?.string].compactMap { $0 }.joined(separator: "\n")
        case "file": "File: \(value["path"]?.string ?? "Attachment")"
        case "image": "Image attachment"
        case "resource": value["text"]?.string ?? value["uri"]?.string ?? "Resource attachment"
        default: ""
        }
    }
}

extension Optional where Wrapped == AnnexJSON {
    var arrayValue: [AnnexJSON] { if case .array(let values) = self { values } else { [] } }
    var boolValue: Bool { if case .bool(let value) = self { value } else { false } }
}
extension AnnexJSON {
    var displayText: String {
        if let string { return string }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
