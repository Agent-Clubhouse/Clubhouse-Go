import Foundation

nonisolated struct CompanionDecisionChatJump: Equatable, Sendable {
    let id: UUID
    let itemID: String

    init(itemID: String) {
        id = UUID()
        self.itemID = itemID
    }
}

/// The parent owns admission across transcript mounts. A claim consumes the UUID before any suspension,
/// while leaving the task's input identity stable until it finishes. An older finish cannot clear a newer request.
nonisolated struct CompanionDecisionChatJumps: Equatable, Sendable {
    private(set) var pending: CompanionDecisionChatJump?
    private var consumed: Set<UUID> = []

    init() {}

    mutating func request(_ request: CompanionDecisionChatJump) {
        guard !consumed.contains(request.id) else { return }
        pending = request
    }

    mutating func begin(_ id: UUID) -> Bool {
        guard pending?.id == id, !consumed.contains(id) else { return false }
        consumed.insert(id)
        return true
    }

    mutating func finish(_ id: UUID) {
        guard pending?.id == id, consumed.contains(id) else { return }
        pending = nil
    }
}
