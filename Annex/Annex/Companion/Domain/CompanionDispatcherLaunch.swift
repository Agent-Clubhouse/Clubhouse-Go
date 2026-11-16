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
            // A failed/offline catalog cannot complete; do not let its retained loading
            // record hide guidance or the other ready choices indefinitely.
            switch host.connection { case .offline, .failed: return false; default: break }
            if let dispatcher = host.dispatcher, dispatcher.isVisible && dispatcher.isLoading { return true }
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


extension CompanionNavigation {
    /// Readiness and a host report can arrive in the same SwiftUI transaction, before
    /// the owner's hosts onChange. Reconcile synchronously so opening and resolution
    /// use the same current targets, rather than consuming the request against a stale cache.
    mutating func resolveDispatcherLaunch(pairedHostIDs: Set<String>?, restorationComplete: Bool,
                                         restorationFailed: Bool = false, hosts: [CompanionHost]) -> CompanionDispatcherLaunchResolution {
        guard restorationComplete else { return .waiting }
        // Acknowledged failure is a terminal outcome, not pairing authority. Never open
        // an old cached target when the current install could not restore its identities.
        if restorationFailed { return .unavailable }
        guard let pairedHostIDs else { return .waiting }
        update(hosts: hosts)
        retainPairedDesktops(pairedHostIDs)
        return CompanionDispatcherLaunchResolution.resolve(desktops: dispatcherDesktops,
            pairedHostIDs: pairedHostIDs, restorationComplete: true, hosts: hosts)
    }
}
