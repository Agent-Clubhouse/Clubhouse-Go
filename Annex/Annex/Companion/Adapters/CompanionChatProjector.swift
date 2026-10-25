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
    var commandIDsByMessage: [String: String] = [:]
    var queueStateSequence: Int64 = 0
    var queuedMessageIDs: Set<String> = []
    var queueRemovalSupported = false

    mutating func apply(_ event: AnnexJSON, allowOlderPending: Bool = false) {
        guard let session = event["sessionId"]?.string,
              let sequence = event["seq"]?.integer, let type = event["type"]?.string else { return }
        if sessionID != session {
            sessionID = session; lastSequence = 0; items = []; capabilities = []; model = nil
            queueStateSequence = 0; queuedMessageIDs = []; queueRemovalSupported = false
        }
        guard allowOlderPending || sequence > lastSequence else { return }
        lastSequence = max(lastSequence, Int(sequence))
        let data = event["data"] ?? .object([:])
        let time = event["ts"]?.integer.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        switch type {
        case "session_started", "session_info":
            if let caps = data["capabilities"] { updateCapabilities(caps) }
            if let model = data["model"]?.string { self.model = model }
        case "session_state": status = Self.status(data["state"]?.string)
        case "turn_started": status = .working
        case "turn_ended":
            status = data["stopReason"]?.string == "error" ? .failed : data["stopReason"]?.string == "cancelled" ? .stopped : .idle
            finishStreams()
        case "session_ended":
            // An idle timeout puts the agent to sleep; it resumes on the next message or a wake.
            switch data["reason"]?.string { case "error": status = .failed; case "idle_timeout": status = .sleeping; default: status = .stopped }
            capabilities = []; finishStreams()
        case "user_message":
            guard let messageID = data["messageId"]?.string else { return }
            let text = data["content"].arrayValue.map { Self.contentText($0) }.joined(separator: "\n")
            upsert(.message(.init(id: messageID, role: .user, text: text, timestamp: time,
                                  clientCommandID: data["clientCommandId"]?.string ?? commandIDsByMessage[messageID],
                                  queueState: queuedMessageIDs.contains(messageID) ? .queued : data["delivery"]?.string == "queued" ? .submitted : nil)))
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
            let content = data["content"].arrayValue.map { Self.contentText($0) }.joined(separator: "\n")
            let output = content.isEmpty ? data["error"]?.string ?? data["rawOutput"]?.displayText : content
            let input = data["rawInput"]?.displayText
            let state: CompanionTool.State
            switch data["status"]?.string {
            case "completed": state = .completed
            case "failed", "cancelled": state = .failed
            case "pending", "in_progress": state = .running
            default: state = old?.state ?? .running
            }
            upsert(.tool(.init(id: toolID, name: data["title"]?.string ?? data["toolName"]?.string ?? old?.name ?? "Tool activity",
                               summary: input ?? old?.summary ?? "", output: data["contentMode"]?.string == "append" ? (old?.output ?? "") + (output ?? "") : output ?? old?.output,
                               state: state, images: data["media"] == nil ? old?.images ?? [] : data["media"].arrayValue.prefix(16).compactMap { image in
                                   guard let reference = image["mediaRef"]?.string, CompanionContentReference.validMediaReference(reference) else { return nil }
                                   return .image(reference)
                               })))
        case "permission_request":
            guard let requestID = data["requestId"]?.string else { return }
            let options = data["options"].arrayValue.compactMap { value -> CompanionApprovalOption? in
                guard let id = value["optionId"]?.string, let label = value["label"]?.string else { return nil }
                let kind: CompanionApprovalOption.Kind
                switch value["kind"]?.string {
                case "allow_once": kind = .allowOnce
                case "reject_once": kind = .rejectOnce
                case "cancel_turn": kind = .cancelTurn
                default: return nil // Persistent permission changes are not mobile actions.
                }
                return .init(id: id, label: label, kind: kind)
            }
            let detail = data["content"].arrayValue.map { Self.contentText($0) }.joined(separator: "\n")
            upsert(.approval(.init(id: requestID, toolName: data["toolName"]?.string ?? "Approval request",
                                   summary: data["description"]?.string ?? data["title"]?.string ?? "Review the requested action",
                                   detail: detail.isEmpty ? data["rawInput"]?.displayText : detail, options: options)))
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
        case "model_changed": model = data["modelId"]?.string
        default: break // Additive protocol events are safe to ignore.
        }
    }

    /// `session_info` carries only the capabilities that changed (Claude reports them after the first prompt),
    /// so keys that are absent keep their earlier value. A new session starts from empty.
    mutating func updateCapabilities(_ value: AnnexJSON) {
        capabilities.formUnion([.chat, .approve])
        func set(_ flag: CompanionCapabilities, _ key: String) {
            guard case .bool(let enabled)? = value[key] else { return }
            if enabled { capabilities.insert(flag) } else { capabilities.remove(flag) }
        }
        set(.steer, "steer")
        set(.cancel, "interrupt")
        set(.answer, "questions")
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
    /// `detailedStatus.state` (`idle`, `working`, `needs_permission`, `tool_error`).
    static func status(_ value: String?, detailed: AnnexJSON?) -> CompanionAgentStatus {
        let lifecycle = status(value)
        guard lifecycle == .working, let state = detailed?["state"]?.string else { return lifecycle }
        switch state {
        case "idle": return .idle
        case "needs_permission":
            let message = (detailed?["message"]?.string ?? "").lowercased()
            return message.contains("question") ? .waiting : .approval
        default: return .working
        }
    }
    static func status(_ value: String?) -> CompanionAgentStatus {
        switch value {
        case "running", "starting": .working
        case "waiting_permission": .approval
        case "waiting_input": .waiting
        case "error", "failed": .failed
        case "completed": .completed
        case "sleeping": .sleeping
        case "cancelled": .stopped
        default: .idle
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
