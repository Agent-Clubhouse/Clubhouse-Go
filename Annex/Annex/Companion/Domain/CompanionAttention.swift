import Foundation

/// What Needs you cannot currently know. Cached requests from these desktops stay out of the action list.
struct CompanionAttentionAvailability {
    struct UnavailableHost: Identifiable, Equatable {
        var id: String
        var name: String
        var title: String
        var isConnecting: Bool
        var retryHostID: String? { isConnecting ? nil : id }
        static let detail = "Pending items are unknown until this desktop is ready."
    }

    var unavailableHosts: [UnavailableHost]
    var emptyTitle: String
    var emptyDetail: String
    var emptySystemImage: String

    init(hosts: [CompanionHost]) {
        unavailableHosts = hosts.filter { !$0.connection.canOperate }.map { host in
            let isConnecting: Bool
            switch host.connection {
            case .connecting, .reconnecting, .synchronizing: isConnecting = true
            default: isConnecting = false
            }
            return .init(id: host.id, name: host.name, title: host.connection.sentence(hostName: host.name), isConnecting: isConnecting)
        }
        if hosts.isEmpty {
            emptyTitle = "No desktops paired"
            emptyDetail = "Pair a desktop to see what needs you."
            emptySystemImage = "desktopcomputer"
        } else if !unavailableHosts.isEmpty {
            emptyTitle = "No requests to show"
            emptyDetail = "Pending items may be missing while a desktop is unavailable."
            emptySystemImage = "wifi.slash"
        } else if hosts.contains(where: { !$0.hasLoadedCatalog }) {
            emptyTitle = "No requests to show"
            emptyDetail = "Desktop information is still loading. Pending items may be missing."
            emptySystemImage = "arrow.triangle.2.circlepath"
        } else {
            emptyTitle = "All caught up"
            emptySystemImage = "checkmark.circle"
            let working = hosts.flatMap(\.allAgents).filter { $0.status == .working }.count
            emptyDetail = working == 0 ? "Nothing is waiting on you." : "\(working) agents are working. They'll show up here when they need you."
        }
    }
}

/// One entry in Needs you: something an agent is waiting on, across every paired desktop.
struct CompanionAttentionItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case approval(CompanionApproval)
        case question(CompanionQuestion)
        case failure
        /// The agent says it needs you but its conversation hasn't loaded yet.
        case unreviewed
        /// An orchestrator asked to start a helper (on the orchestrator) or dispose one (on the helper).
        case helperRequest(CompanionHelperRequest)
    }
    var agent: CompanionAgent
    var hostName: String
    /// The agent's project, or "Dispatcher" for the desktop's Dispatcher, which has none.
    var projectName: String
    var kind: Kind
    /// An agent's own wait, or one helper request: an agent can have both.
    var id: String {
        if case .helperRequest(let request) = kind { return "helper:\(request.slot)" }
        return "agent:\(agent.id.hostID):\(agent.id.projectID):\(agent.id.agentID)"
    }
    var helperRequest: CompanionHelperRequest? { if case .helperRequest(let request) = kind { request } else { nil } }

    var deadline: Date? { if case .approval(let approval) = kind { approval.deadline } else { nil } }
    /// When the agent began waiting, from the desktop's `detailedStatus.timestamp`, or when the helper request came.
    var since: Date? {
        if let helperRequest { return helperRequest.requestedAt }
        return agent.detail?.since
    }

    /// An approval this close to timing out goes to the top of Needs you and shows its countdown.
    static let urgentWindow: TimeInterval = 120
    func isUrgent(at now: Date) -> Bool {
        guard let deadline else { return false }
        return deadline > now && deadline.timeIntervalSince(now) <= Self.urgentWindow
    }

    /// One line saying why the agent needs you, in the desktop's words (`treeModel.ts` selectNeedsAttention).
    var detail: String {
        switch kind {
        case .approval(let approval): Self.permissionLine(toolName: approval.toolName)
        case .question: Self.questionLine
        case .failure: failureLine
        case .helperRequest(let request): request.summary
        case .unreviewed:
            switch agent.status {
            case .approval: Self.permissionLine(toolName: agent.detail?.toolName)
            case .waiting: Self.questionLine
            default: failureLine
            }
        }
    }

    /// What is being asked, under the line above: the request's title or description, or the question.
    var prompt: String? {
        switch kind {
        case .approval(let approval):
            if let title = approval.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
            let summary = approval.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty || summary == "Review the requested action" ? nil : summary
        case .question(let question): return question.prompts.first?.text
        case .helperRequest(let request): return request.task
        case .failure, .unreviewed: return nil
        }
    }

    static let questionLine = "Has a question for you"
    static func permissionLine(toolName: String?) -> String {
        guard let toolName, !toolName.isEmpty else { return "Needs permission" }
        return "Needs permission to use \(shortToolName(toolName))"
    }
    /// A failed tool is named as a failure, never just the tool, so it isn't read as a permission prompt.
    private var failureLine: String {
        guard agent.detail?.state == "tool_error" else { return "Stopped with an error" }
        if let tool = agent.detail?.toolName, !tool.isEmpty { return "Tool call failed (\(Self.shortToolName(tool)))" }
        return agent.detail?.message.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool call failed"
    }
    /// A tool's own name, without an MCP server prefix (`mcp__clubhouse__message_parent` → `message_parent`).
    static func shortToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"), let range = name.range(of: "__", options: .backwards) else { return name }
        let short = name[range.upperBound...]
        return short.isEmpty ? name : String(short)
    }
}

/// A row in the conversation: either one timeline item or a run of read-only tool calls folded together.
enum CompanionTimelineRow: Identifiable, Sendable, Equatable {
    case item(CompanionTimelineItem)
    case tools([CompanionTool])
    case activity([CompanionActivityPart])
    case routed(CompanionMessage, Int)

    var id: String {
        switch self {
        case .item(let item): item.id
        case .tools(let tools): "tools:\(tools.first?.id ?? "")"
        case .activity(let parts): "activity:\(parts.first?.id ?? "")"
        case .routed(let message, let index): "routed:\(message.id):\(index)"
        }
    }
    func contains(entryID: String) -> Bool {
        if id == entryID { return true }
        if case .item(.message(let message)) = self, message.role != .user, entryID.hasPrefix(id + "#") { return true }
        if case .activity(let parts) = self { return parts.contains { "activity:\($0.id)" == entryID } }
        return false
    }

}

/// Ordered fragments retain message/part identity even when one delivery crosses a visible notice boundary.
enum CompanionActivityPart: Identifiable, Sendable, Equatable {
    case tool(CompanionTool)
    case routed(CompanionMessage, Int)
    case empty(CompanionMessage)

    var id: String {
        switch self {
        case .tool(let tool): "tool:\(tool.id)"
        case .routed(let message, let index): "routed:\(message.id):\(index)"
        case .empty(let message): "message:\(message.id)"
        }
    }
    var subagentID: String? {
        switch self {
        case .tool(let tool): tool.subagentID
        case .routed(let message, _), .empty(let message): message.subagentID
        }
    }
    var sender: String {
        switch self {
        case .tool(let tool): return tool.subagentID.map { "Helper \($0)" } ?? "Tools"
        case .empty: return ""
        case .routed(let message, let index):
            if case .others(let parts) = message.display { return parts[index].sender?.name ?? (message.source == "group_project" ? "Group project" : "Another agent") }
            return "Another agent"
        }
    }
    var isRunning: Bool { if case .tool(let tool) = self { tool.state == .running } else { false } }
    var attachmentCount: Int {
        switch self {
        case .tool(let tool): tool.images.count
        case .empty: 0
        case .routed(let message, let index): index == 0 ? message.images.count : 0
        }
    }
    struct Avatar: Identifiable, Equatable {
        let id: String
        let identity: CompanionSenderIdentity
    }
    /// Summary identity only: never prepares routed text, Markdown or content links.
    static func avatars(_ parts: [Self], resolver: CompanionSenderResolver) -> [Avatar] {
        var seen: Set<String> = []
        return parts.compactMap { part in
            guard case .routed(let message, let index) = part, case .others(let routed) = message.display,
                  routed.indices.contains(index), let identity = resolver.avatarIdentity(for: routed[index].sender),
                  seen.insert(identity.id).inserted else { return nil }
            return Avatar(id: "companion-sender-avatar-\(message.id)-\(index)", identity: identity)
        }
    }
    static func summary(_ parts: [Self]) -> String {
        let tools = parts.filter { if case .tool = $0 { true } else { false } }.count
        let messages = parts.filter { if case .routed = $0 { true } else { false } }.count
        let images = parts.reduce(0) { $0 + $1.attachmentCount }
        var labels: [String] = []
        if tools > 0 { labels.append("\(tools) tool \(tools == 1 ? "call" : "calls")") }
        if messages > 0 { labels.append("\(messages) \(messages == 1 ? "message" : "messages")") }
        if images > 0 { labels.append("\(images) \(images == 1 ? "attachment" : "attachments")") }
        if parts.contains(where: \.isRunning) { labels.append("Running…") }
        return labels.joined(separator: " · ")
    }
}

extension CompanionTool {
    var isFailure: Bool { state == .failed || (exitCode.map { $0 != 0 } ?? false) }
    var requiresAttention: Bool { isFailure || awaitsApproval }
    private var nonemptyOutputLines: [Substring] {
        (output ?? "").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var outputOpenByDefault: Bool { awaitsApproval || (isFailure && nonemptyOutputLines.count <= 6) }
    var outputPreview: String { nonemptyOutputLines.last.map(String.init) ?? "" }
}

/// The desktop's folding (`buildStreamBlocks`, `exploreLabel` in `view-model.ts`).
enum CompanionTimelineFolding {
    /// Routine tools fold together; routed messages remain readable in chronological order.
    static func rows(for items: [CompanionTimelineItem]) -> [CompanionTimelineRow] {
        let waitingToolIDs = Set(items.compactMap { item -> String? in
            guard case .approval(let approval) = item,
                  [.pending, .submitting, .uncertain].contains(approval.resolution) else { return nil }
            return approval.toolCallID
        })
        var rows: [CompanionTimelineRow] = []
        var run: [CompanionActivityPart] = []
        var carried: [CompanionMessage] = []
        var runSubagentID: String?
        func flush() {
            if !run.isEmpty { rows.append(.activity(run)); run = [] }
            rows += carried.map { .item(.message($0)) }
            carried = []
            runSubagentID = nil
        }
        func begin(subagentID: String?) {
            if !run.isEmpty && runSubagentID != subagentID { flush() }
            if run.isEmpty { runSubagentID = subagentID }
        }
        func append(_ part: CompanionActivityPart) {
            if run.isEmpty { runSubagentID = part.subagentID }
            if !carried.isEmpty {
                run += carried.map { .empty($0) }
                carried = []
            }
            run.append(part)
        }
        for item in items {
            switch item {
            case .tool(var tool) where waitingToolIDs.contains(tool.id):
                flush()
                tool.awaitsApproval = true
                rows.append(.item(.tool(tool)))
            case .tool(let tool) where !tool.requiresAttention && tool.images.isEmpty:
                begin(subagentID: tool.subagentID)
                append(.tool(tool))
            case .message(let message) where message.role == .assistant && message.text.isEmpty && !message.isStreaming && !run.isEmpty:
                begin(subagentID: message.subagentID)
                if run.isEmpty { rows.append(.item(item)) } else { carried.append(message) }
            case .message(let message) where message.role == .user && message.delivery == .confirmed && (message.queueState == nil || message.queueState == .delivered || message.queueState == .removed):
                flush()
                if case .others(let parts) = message.display {
                    rows += parts.indices.map { .routed(message, $0) }
                } else { rows.append(.item(item)) }
            default: flush(); rows.append(.item(item))
            }
        }
        flush()
        return rows
    }

    /// Only explicit long-message toggles may hide routed text. Clubhouse notices and helper questions stay visible.
    static func canCollapse(_ part: CompanionRoutedMessagePart) -> Bool { !part.fromClubhouse && !part.text.hasPrefix("[QUESTION FROM HELPER:") }

    /// "Explored 3 files, 2 searches", or "Exploring…" while one of them runs.
    static func exploreLabel(_ tools: [CompanionTool]) -> String {
        var files = 0, searches = 0, other = 0
        for tool in tools {
            switch tool.kind {
            case .read: files += 1
            case .search: searches += 1
            default: other += 1
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        let parts = [count(files, "file", "files"), count(searches, "search", "searches"), count(other, "lookup", "lookups")].compactMap { $0 }
        return "\(tools.contains { $0.state == .running } ? "Exploring" : "Explored") \(parts.joined(separator: ", "))"
    }
}

extension CompanionStore {
    /// Every agent on every desktop, the Dispatchers included.
    var allAgents: [CompanionAgent] { hosts.flatMap(\.allAgents) }

    /// The approval to pin above the composer: the oldest pending, unexpired one the agent can answer from here.
    func pinnedApproval(for target: CompanionTarget, now: Date = Date()) -> CompanionApproval? {
        conversation(for: target).items.lazy.compactMap { item -> CompanionApproval? in
            guard case .approval(let approval) = item, approval.resolution == .pending, !approval.isExpired(at: now),
                  approval.options.contains(where: { $0.kind == .allowOnce || $0.kind == .rejectOnce }) else { return nil }
            return approval
        }.first
    }

    /// Needs you, as the desktop lists it: questions, permission requests, failed tools and errored agents on
    /// connected desktops, and helper start and dispose requests from desktops that send them, oldest first. An
    /// approval about to time out goes first. An offline desktop's agents are left to its reconnect card.
    func attentionItems(now: Date = Date()) -> [CompanionAttentionItem] {
        var items: [CompanionAttentionItem] = []
        for host in hosts where host.connection.canOperate {
            for request in helperRequests(on: host, now: now) {
                guard let agent = host.agent(for: request.agentTarget), let place = host.placeName(for: agent.id) else { continue }
                items.append(.init(agent: agent, hostName: host.name, projectName: place, kind: .helperRequest(request)))
            }
            // The Dispatcher is listed with its own name in place of a project's.
            let places = host.projects.map { ($0.name, $0.agents) } + (host.dispatcher?.liveAgent.map { [(CompanionDispatcher.name, [$0])] } ?? [])
            for (place, agents) in places {
                for agent in agents where agent.status.needsYou {
                    let conversation = conversation(for: agent.id)
                    let pendingQuestion = conversation.items.lazy.compactMap { item -> CompanionQuestion? in
                        if case .question(let question) = item, question.resolution == .pending { return question }; return nil
                    }.first
                    let kind: CompanionAttentionItem.Kind
                    if let approval = pinnedApproval(for: agent.id, now: now) { kind = .approval(approval) }
                    else if let pendingQuestion { kind = .question(pendingQuestion) }
                    else if agent.status == .failed { kind = .failure }
                    else { kind = .unreviewed }
                    items.append(.init(agent: agent, hostName: host.name, projectName: place, kind: kind))
                }
            }
        }
        return items.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            switch (left.isUrgent(at: now), right.isUrgent(at: now)) {
            case (true, true): if left.deadline != right.deadline { return left.deadline! < right.deadline! }
            case (true, false): return true
            case (false, true): return false
            case (false, false): break
            }
            // Oldest first; an agent with no start time sorts as the oldest, as on the desktop.
            let leftSince = left.since ?? .distantPast, rightSince = right.since ?? .distantPast
            return leftSince == rightSince ? lhs.offset < rhs.offset : leftSince < rightSince
        }.map(\.element)
    }

    /// The Needs you badge: agents waiting on you on a connected desktop, and helper requests.
    var needsYouCount: Int {
        let operable = hosts.filter(\.connection.canOperate)
        return operable.flatMap(\.allAgents).filter { $0.status.needsYou }.count
            + operable.reduce(0) { $0 + helperRequests(on: $1).count }
    }

    /// A desktop's waiting helper requests, when it can take answers: unexpired ones whose agent is listed.
    func helperRequests(on host: CompanionHost, now: Date = Date()) -> [CompanionHelperRequest] {
        guard host.canAnswerHelperRequests else { return [] }
        let listed = Set(host.allAgents.map(\.id))
        return host.helperRequests.filter { request in
            listed.contains(request.agentTarget) && (request.expiresAt.map { $0 > now } ?? true)
        }
    }

    /// An agent's latest activity: the desktop's `lastActivityAt`, or a newer message in its loaded conversation.
    func lastActivity(of agent: CompanionAgent) -> Date? {
        let seen = conversation(for: agent.id).items.compactMap { item -> Date? in if case .message(let message) = item { message.timestamp } else { nil } }.max()
        return [agent.lastActivity, seen].compactMap { $0 }.max()
    }

    /// The latest activity of any agent in the project.
    func lastActivity(for project: CompanionProjectTarget) -> Date? {
        host(for: .init(hostID: project.hostID, projectID: project.projectID, agentID: ""))?
            .projects.first { $0.id == project.projectID }?.agents.compactMap { lastActivity(of: $0) }.max()
    }

    /// Every agent, those waiting on you first, then by last activity, then in desktop order.
    func agentsNeedsYouFirst() -> [CompanionAgent] {
        let activity = Dictionary(allAgents.map { ($0.id, lastActivity(of: $0)) }, uniquingKeysWith: { first, _ in first })
        return allAgents.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.status.needsYou != right.status.needsYou { return left.status.needsYou }
            switch (activity[left.id] ?? nil, activity[right.id] ?? nil) {
            case let (a?, b?) where a != b: return a > b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
