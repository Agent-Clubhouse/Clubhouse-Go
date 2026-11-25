import Foundation

/// Mirrors desktop `chatActivity` (`ChatHeader.tsx`), except the phone keeps "Working"
/// between tools when no turn timing exists, so its bottom-anchored footer stays stable.
/// At the minimum footer floor, presentation omits the line and the header retains status.
enum CompanionChatActivity {
    /// "1:05 · Run swift test" while working; "Working" bridges tool gaps on desktops without turn timing.
    /// `friendlyTools: false` keeps the raw tool identifier, for accessibility labels that should carry it in full.
    static func line(status: CompanionAgentStatus, turnStartedAt: Date?, items: [CompanionTimelineItem], now: Date = Date(),
                     friendlyTools: Bool = true) -> String? {
        switch status {
        case .working:
            var parts: [String] = []
            if let turnStartedAt { parts.append(elapsed(now.timeIntervalSince(turnStartedAt))) }
            if let tool = currentTool(in: items) {
                let name = friendlyTools ? toolLabel(tool.name) : tool.name
                if !name.isEmpty { parts.append(name) }
            }
            return parts.isEmpty ? "Working" : parts.joined(separator: " · ")
        case .approval:
            let approval = pendingApprovals(in: items, at: now).first
            return approval.map { $0.title ?? $0.toolName } ?? "Waiting for approval"
        case .waiting:
            return "Has a question"
        default:
            return nil
        }
    }

    /// A readable, single-line label for a tool identifier. MCP tools (`mcp__clubhouse__message_parent`) become
    /// "Clubhouse · message parent"; other names (built-in "Read file", unknown ones) pass through with
    /// control characters and runs of whitespace collapsed. Never returns a multi-line string; an empty
    /// result means the name had nothing to show.
    static func toolLabel(_ identifier: String) -> String {
        let name = singleLine(identifier)
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__").filter { !$0.isEmpty }
        // `mcp__server` alone or an odd shape: humanise what is there rather than drop it.
        guard parts.count >= 2 else { return parts.first.map(humanise) ?? name }
        var server = parts[0]
        for prefix in ["claude_ai_", "plugin_"] where server.hasPrefix(prefix) && server.count > prefix.count {
            server.removeFirst(prefix.count)
        }
        let tool = parts.dropFirst().map(humanise).joined(separator: " ")
        return "\(humanise(server).capitalizedFirst) · \(tool)"
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// snake_case, kebab-case and camelCase to lowercase words.
    private static func humanise(_ word: String) -> String {
        var out = ""
        var previousLower = false
        for ch in word {
            if ch == "_" || ch == "-" { out.append(" "); previousLower = false; continue }
            if ch.isUppercase, previousLower { out.append(" ") }
            out.append(ch)
            previousLower = ch.isLowercase || ch.isNumber
        }
        return singleLine(out)
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
