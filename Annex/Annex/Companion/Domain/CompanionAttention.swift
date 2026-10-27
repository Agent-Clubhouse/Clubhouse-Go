import Foundation

/// One entry in Needs you: something an agent is waiting on, across every paired desktop.
struct CompanionAttentionItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case approval(CompanionApproval)
        case question(CompanionQuestion)
        case failure
        /// The agent says it needs you but its conversation hasn't loaded yet.
        case unreviewed
    }
    var agent: CompanionAgent
    var hostName: String
    var projectName: String
    var kind: Kind
    var id: CompanionTarget { agent.id }

    var deadline: Date? { if case .approval(let approval) = kind { approval.deadline } else { nil } }
}

/// A row in the conversation: either one timeline item or a run of read-only tool calls folded together.
enum CompanionTimelineRow: Identifiable, Sendable, Equatable {
    case item(CompanionTimelineItem)
    case tools([CompanionTool])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .tools(let tools): "tools:\(tools.first?.id ?? "")"
        }
    }
}

/// The desktop's folding (`buildStreamBlocks`, `exploreLabel` in `view-model.ts`).
enum CompanionTimelineFolding {
    /// Folds runs of two or more read-only tool calls, running ones included, into one "Explored" row.
    /// Failed tools, tools waiting for approval and tools that changed something stay on their own.
    static func rows(for items: [CompanionTimelineItem]) -> [CompanionTimelineRow] {
        var rows: [CompanionTimelineRow] = []
        var run: [CompanionTool] = []
        func flush() {
            if run.count >= 2 { rows.append(.tools(run)) } else { rows += run.map { .item(.tool($0)) } }
            run = []
        }
        for item in items {
            if case .tool(let tool) = item, tool.isExplore { run.append(tool); continue }
            flush()
            rows.append(.item(item))
        }
        flush()
        return rows
    }

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
    var allAgents: [CompanionAgent] { hosts.flatMap(\.projects).flatMap(\.agents) }

    /// The approval to pin above the composer: the oldest pending, unexpired one the agent can answer from here.
    func pinnedApproval(for target: CompanionTarget, now: Date = Date()) -> CompanionApproval? {
        conversation(for: target).items.lazy.compactMap { item -> CompanionApproval? in
            guard case .approval(let approval) = item, approval.resolution == .pending, !approval.isExpired(at: now),
                  approval.options.contains(where: { $0.kind == .allowOnce || $0.kind == .rejectOnce }) else { return nil }
            return approval
        }.first
    }

    /// Needs you, soonest-expiring approval first, then everything else in desktop order.
    func attentionItems(now: Date = Date()) -> [CompanionAttentionItem] {
        var items: [CompanionAttentionItem] = []
        for host in hosts where host.connection.canOperate || !host.projects.isEmpty {
            for project in host.projects {
                for agent in project.agents where agent.status.needsYou {
                    let conversation = conversation(for: agent.id)
                    let pendingQuestion = conversation.items.lazy.compactMap { item -> CompanionQuestion? in
                        if case .question(let question) = item, question.resolution == .pending { return question }; return nil
                    }.first
                    let kind: CompanionAttentionItem.Kind
                    if let approval = pinnedApproval(for: agent.id, now: now) { kind = .approval(approval) }
                    else if let pendingQuestion { kind = .question(pendingQuestion) }
                    else if agent.status == .failed { kind = .failure }
                    else { kind = .unreviewed }
                    items.append(.init(agent: agent, hostName: host.name, projectName: project.name, kind: kind))
                }
            }
        }
        return items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.deadline, rhs.element.deadline) {
            case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    var needsYouCount: Int { allAgents.filter { $0.status.needsYou }.count }

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
