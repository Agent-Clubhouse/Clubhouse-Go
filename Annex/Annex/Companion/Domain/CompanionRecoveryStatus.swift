import Foundation

/// One notice across unavailable desktops. A Retry never targets a connected or already-recovering host.
struct CompanionConnectionNotice: Equatable, Sendable {
    let title: String
    let isInProgress: Bool
    let retryHostIDs: [String]
    let retryLabel: String

    init(hosts: [CompanionHost]) {
        let unavailable = hosts.filter { !$0.connection.canOperate }
        let recovering = unavailable.filter { Self.isRecovering($0.connection) }
        let idle = unavailable.filter { !Self.isRecovering($0.connection) }
        isInProgress = !recovering.isEmpty
        retryHostIDs = idle.map(\.id)
        retryLabel = idle.count == 1 ? "Retry \(idle[0].name)" : "Retry disconnected desktops"

        let offline: String
        if idle.count == 1 {
            offline = idle[0].connection == .offline ? "\(idle[0].name) is offline" : "\(idle[0].name) isn't connected"
        } else if !idle.isEmpty {
            offline = "\(idle.map(\.name).formatted(.list(type: .and))) aren't connected"
        } else { offline = "" }
        let progress: String
        if recovering.isEmpty { progress = "" }
        else {
            let state = recovering.contains { $0.connection == .reconnecting } ? "Reconnecting…" : "Connecting…"
            progress = "\(state) · \(recovering.map(\.name).formatted(.list(type: .and)))"
        }
        title = [offline, progress].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var isVisible: Bool { !title.isEmpty }

    private static func isRecovering(_ connection: CompanionConnection) -> Bool {
        switch connection {
        case .connecting, .reconnecting, .synchronizing: true
        default: false
        }
    }
}

/// Presentation only: a stale conversation does not establish that recovery is running.
/// The caller continues to own retry execution, command gating, and recovery scheduling.
struct CompanionRecoveryStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden, connecting, reconnecting, synchronizing, refreshing
        case offline, connectionFailed, refreshFailed, refreshRequired
    }

    enum RetryAction: Equatable, Sendable {
        case reconnect, refreshConversation

        var title: String {
            switch self {
            case .reconnect: "Retry connection"
            case .refreshConversation: "Refresh conversation"
            }
        }

        var compactTitle: String {
            switch self {
            case .reconnect: "Retry"
            case .refreshConversation: "Refresh"
            }
        }
    }

    let phase: Phase
    /// Full error text is retained independently of the headline, including during active recovery.
    let connectionError: String?
    let conversationError: String?
    let requiresResync: Bool

    init(connection: CompanionConnection, isLoading: Bool, requiresResync: Bool, error: String?) {
        self.requiresResync = requiresResync
        conversationError = Self.nonempty(error)
        if case .failed(let message) = connection { connectionError = Self.nonempty(message) }
        else { connectionError = nil }

        switch connection {
        case .connecting: phase = .connecting
        case .reconnecting: phase = .reconnecting
        case .synchronizing: phase = .synchronizing
        // A leftover history request cannot establish active connection recovery.
        case .offline: phase = .offline
        case .failed: phase = .connectionFailed
        case .connected:
            if isLoading { phase = .refreshing }
            else if conversationError != nil { phase = .refreshFailed }
            else if requiresResync { phase = .refreshRequired }
            else { phase = .hidden }
        }
    }

    var isVisible: Bool { phase != .hidden }
    var isInProgress: Bool {
        switch phase {
        case .connecting, .reconnecting, .synchronizing, .refreshing: true
        default: false
        }
    }
    var hasError: Bool { phase == .connectionFailed || connectionError != nil || conversationError != nil }
    var retryAction: RetryAction? {
        switch phase {
        case .offline, .connectionFailed: .reconnect
        case .refreshFailed, .refreshRequired: .refreshConversation
        default: nil
        }
    }
    var title: String {
        switch phase {
        case .hidden: ""
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .synchronizing: "Synchronizing…"
        case .refreshing: "Refreshing conversation…"
        case .offline: "Offline"
        case .connectionFailed: "Connection issue"
        case .refreshFailed: "Conversation refresh failed"
        case .refreshRequired: "Conversation needs a refresh"
        }
    }
    var explanation: String {
        let summary: String = switch phase {
        case .hidden: "Your desktop connection and conversation are up to date."
        case .connecting: "Connecting securely to your desktop. Conversation actions are unavailable while the connection recovers."
        case .reconnecting: "Trying to reconnect to your desktop. Conversation actions are unavailable while the connection recovers."
        case .synchronizing: "Synchronizing updates from your desktop. Conversation actions are unavailable while the connection recovers."
        case .refreshing: "Loading the latest conversation from your desktop. Conversation actions are unavailable while the refresh is in progress."
        case .offline: "Not connected to your desktop. Retry the connection to continue."
        case .connectionFailed: "The desktop connection has a problem. Retry the connection to continue."
        case .refreshFailed: "The conversation could not be loaded. Refresh to load the latest conversation."
        case .refreshRequired: "The conversation may be out of date. Refresh it before sending messages or taking conversation actions."
        }
        var paragraphs = [summary]
        if requiresResync && phase != .refreshRequired {
            paragraphs.append("The conversation needs a refresh before sending messages or taking conversation actions.")
        }
        if let connectionError { paragraphs.append("Connection error: \(connectionError)") }
        if let conversationError { paragraphs.append("Conversation error: \(conversationError)") }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func nonempty(_ message: String?) -> String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return message
    }
}
