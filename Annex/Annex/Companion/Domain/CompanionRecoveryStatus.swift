import Foundation

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
        case .connecting: "Connecting securely to your desktop. Connection recovery must finish before sending commands."
        case .reconnecting: "Trying to reconnect to your desktop. Connection recovery must finish before sending commands."
        case .synchronizing: "Synchronizing updates from your desktop. Connection recovery must finish before sending commands."
        case .refreshing: "Loading the latest conversation from your desktop. The refresh must finish before sending commands."
        case .offline: "Your desktop is offline. Retry the connection to continue."
        case .connectionFailed: "The desktop connection has a problem. Retry the connection to continue."
        case .refreshFailed: "The conversation could not be loaded. Refresh the conversation before sending commands."
        case .refreshRequired: "The conversation may be out of date. Refresh it before sending commands."
        }
        var paragraphs = [summary]
        if requiresResync && phase != .refreshRequired && phase != .refreshFailed {
            paragraphs.append("The conversation also needs a refresh before sending commands.")
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
