import Foundation

/// Owns derived rows, never the source item array. Streaming a hard-boundary assistant reply changes one row;
/// routine runs retain their values and expansion identities. Snapshots and structural/local edits rebuild lazily.
@MainActor final class CompanionTimelineProjection {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    private var revision: UUID?
    private var rows: [CompanionTimelineRow] = []
    private var assistantIndices: [String: (row: Int, item: Int)] = [:]
    private var toolIndices: [String: (row: Int, item: Int, part: Int)] = [:]
    private var itemCount = 0
    private(set) var regroupedItemCount = 0
    private(set) var assistantUpdateCount = 0
    private(set) var toolUpdateCount = 0
    var retainedRowCount: Int { rows.count }
    func discardIfStale(revision incoming: UUID) {
        guard revision != nil && revision != incoming else { return }
        revision = nil
        rows = []
        assistantIndices = [:]
        toolIndices = [:]
        itemCount = 0
    }

    func rows(for conversation: CompanionConversation) -> [CompanionTimelineRow] {
        guard revision != conversation.itemsRevision else { return rows }
        rows = CompanionTimelineFolding.rows(for: conversation.items)
        let indices = Dictionary(conversation.items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
        assistantIndices = [:]
        toolIndices = [:]
        for (index, row) in rows.enumerated() {
            if case .item(.message(let message)) = row, message.role == .assistant,
               let itemIndex = indices[row.id], Self.isBoundary(message) {
                assistantIndices[message.id] = (index, itemIndex)
            }
            if case .activity(let parts) = row {
                for (partIndex, part) in parts.enumerated() {
                    if case .tool(let tool) = part, let itemIndex = indices["tool:\(tool.id)"] {
                        toolIndices[tool.id] = (index, itemIndex, partIndex)
                    }
                }
            }
        }
        itemCount = conversation.items.count
        regroupedItemCount += itemCount
        revision = conversation.itemsRevision
        return rows
    }

    func updateAssistant(_ messageID: String, previousRevision: UUID?, conversation: CompanionConversation) {
        guard revision != nil, revision == previousRevision else { return }
        if let index = assistantIndices[messageID], conversation.items.count == itemCount,
           conversation.items.indices.contains(index.item), case .message(let message) = conversation.items[index.item],
           message.id == messageID, Self.isBoundary(message) {
            rows[index.row] = .item(.message(message))
        } else if conversation.items.count == itemCount + 1,
                  case .message(let message) = conversation.items.last, message.id == messageID, Self.isBoundary(message) {
            assistantIndices[messageID] = (rows.count, itemCount)
            rows.append(.item(.message(message)))
            itemCount += 1
        } else { return }
        revision = conversation.itemsRevision
        assistantUpdateCount += 1
    }

    private static func isBoundary(_ message: CompanionMessage) -> Bool { !message.text.isEmpty || message.isStreaming }

    /// Output/status chunks that keep a routine tool countable replace just its existing run. Failure, permission,
    /// image and sender changes fall back to structural folding so they can split or rejoin adjacent runs.
    func updateTool(_ toolID: String, previousRevision: UUID?, conversation: CompanionConversation) {
        guard revision != nil, revision == previousRevision, conversation.items.count == itemCount,
              let index = toolIndices[toolID], conversation.items.indices.contains(index.item),
              case .tool(let tool) = conversation.items[index.item], tool.id == toolID,
              !tool.requiresAttention, tool.images.isEmpty,
              case .activity(var parts) = rows[index.row], case .tool(let old) = parts[index.part],
              old.subagentID == tool.subagentID else { return }
        parts[index.part] = .tool(tool)
        rows[index.row] = .activity(parts)
        revision = conversation.itemsRevision
        toolUpdateCount += 1
    }
}
