import Foundation
import Observation

/// A bounded, process-lifetime handoff. It owns no runtime, credentials or message text.
@MainActor @Observable final class CompanionDispatcherLaunchInbox {
    nonisolated deinit {}
    static let shared = CompanionDispatcherLaunchInbox()
    static let quickActionType = "com.Agent-Clubhouse.Go.message-dispatcher"
    enum Source: Equatable, Sendable { case quickAction, appIntent }
    struct Request: Equatable, Sendable {
        let id = UUID()
        let source: Source
    }
    private(set) var pending: Request?

    func submit(_ source: Source) { pending = Request(source: source) }
    @discardableResult func handleQuickAction(_ type: String) -> Bool {
        guard type == Self.quickActionType else { return false }
        submit(.quickAction)
        return true
    }
    func consume(_ id: UUID) { if pending?.id == id { pending = nil } }
}
