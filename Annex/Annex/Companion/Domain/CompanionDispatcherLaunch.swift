import Foundation
import Observation

/// A bounded, process-lifetime handoff. It owns no runtime, credentials or message text.
@MainActor @Observable final class CompanionDispatcherLaunchInbox {
    nonisolated deinit {}
    static let shared = CompanionDispatcherLaunchInbox()
    static let quickActionType = "com.Agent-Clubhouse.Go.message-dispatcher"
    enum Source: Equatable, Sendable { case quickAction, appIntent }
    struct Request: Equatable, Sendable {
        let id: UUID = UUID()
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

/// Resolution never creates authority or performs reads. Unknown restoration/catalog state keeps the handoff pending.
enum CompanionDispatcherLaunchResolution: Equatable {
    case waiting
    case unavailable
    case open(CompanionDispatcherDesktop)
    case choose([CompanionDispatcherDesktop])

    static func resolve(desktops: [CompanionDispatcherDesktop], pairedHostIDs: Set<String>?,
                        restorationComplete: Bool, hosts: [CompanionHost]) -> Self {
        guard restorationComplete, let pairedHostIDs else { return .waiting }
        let choices = desktops.filter { pairedHostIDs.contains($0.id) && $0.target != nil }
        let unresolved = pairedHostIDs.contains { id in
            guard let host = hosts.first(where: { $0.id == id }) else { return true }
            switch host.connection {
            case .connecting, .reconnecting, .synchronizing: return host.dispatcher == nil
            default: return false
            }
        }
        if unresolved { return .waiting }
        if choices.count == 1 { return .open(choices[0]) }
        if choices.count > 1 { return .choose(choices) }
        return .unavailable
    }
}
