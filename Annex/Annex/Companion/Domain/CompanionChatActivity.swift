import Foundation

/// The chat header's activity line, as the desktop's `chatActivity` (`ChatHeader.tsx`) builds it.
enum CompanionChatActivity {
    /// "1:05 · Run swift test" while working, what it waits on otherwise, nil when there's nothing to say.
    static func line(status: CompanionAgentStatus, turnStartedAt: Date?, items: [CompanionTimelineItem], now: Date = Date()) -> String? {
        switch status {
        case .working:
            var parts: [String] = []
            if let turnStartedAt { parts.append(elapsed(now.timeIntervalSince(turnStartedAt))) }
            if let tool = currentTool(in: items) { parts.append(tool.name) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .approval:
            let approval = pendingApprovals(in: items, at: now).first
            return approval.map { $0.title ?? $0.toolName } ?? "Waiting for approval"
        case .waiting:
            return "Has a question"
        default:
            return nil
        }
    }

    /// The latest running tool of this turn: the search stops at your last message.
    static func currentTool(in items: [CompanionTimelineItem]) -> CompanionTool? {
        for item in items.reversed() {
            switch item {
            case .tool(let tool) where tool.state == .running: return tool
            case .message(let message) where message.role == .user: return nil
            default: continue
            }
        }
        return nil
    }

    /// Approvals still waiting on an answer, oldest first, as the desktop queues them.
    static func pendingApprovals(in items: [CompanionTimelineItem], at date: Date = Date()) -> [CompanionApproval] {
        items.compactMap { item in
            guard case .approval(let approval) = item, approval.resolution == .pending, !approval.isExpired(at: date) else { return nil }
            return approval
        }
    }

    /// "1 of 3" for an approval when several are waiting, else nil.
    static func queuePosition(of approval: CompanionApproval, in items: [CompanionTimelineItem], at date: Date = Date()) -> String? {
        let pending = pendingApprovals(in: items, at: date)
        guard pending.count > 1, let index = pending.firstIndex(where: { $0.id == approval.id }) else { return nil }
        return "\(index + 1) of \(pending.count)"
    }

    /// m:ss, as the desktop's `formatElapsed`.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
