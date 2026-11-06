import Testing
@testable import CompanionDomain

struct CompanionRecoveryStatusTests {
    private let connections: [CompanionConnection] = [
        .offline, .connecting, .reconnecting, .synchronizing, .connected, .failed("TLS failed")
    ]

    @Test func allConnectionLoadingResyncAndErrorOverlaps() {
        for connection in connections {
            for loading in [false, true] {
                for resync in [false, true] {
                    for error in [nil, "History unavailable"] as [String?] {
                        let status = CompanionRecoveryStatus(connection: connection, isLoading: loading,
                                                             requiresResync: resync, error: error)
                        let phase: CompanionRecoveryStatus.Phase
                        let action: CompanionRecoveryStatus.RetryAction?
                        switch connection {
                        case .connecting: phase = .connecting; action = nil
                        case .reconnecting: phase = .reconnecting; action = nil
                        case .synchronizing: phase = .synchronizing; action = nil
                        case .offline: phase = .offline; action = .reconnect
                        case .failed: phase = .connectionFailed; action = .reconnect
                        case .connected:
                            if loading { phase = .refreshing; action = nil }
                            else if error != nil { phase = .refreshFailed; action = .refreshConversation }
                            else if resync { phase = .refreshRequired; action = .refreshConversation }
                            else { phase = .hidden; action = nil }
                        }
                        #expect(status.phase == phase)
                        #expect(status.retryAction == action)
                        #expect(status.isVisible == (phase != .hidden))
                        #expect(status.isInProgress == [.connecting, .reconnecting, .synchronizing, .refreshing].contains(phase))
                        #expect(status.conversationError == error)
                        #expect(status.requiresResync == resync)
                        if let error { #expect(status.explanation.contains(error)) }
                        if case .failed(let message) = connection {
                            #expect(status.connectionError == message)
                            #expect(status.explanation.contains(message))
                            #expect(status.hasError)
                        } else {
                            #expect(status.connectionError == nil)
                            #expect(status.hasError == (error != nil))
                        }
                    }
                }
            }
        }
    }

    @Test func recoveryHeadlinesNameOnlyProgressEstablishedBySource() {
        for (connection, title) in [
            (CompanionConnection.connecting, "Connecting…"),
            (.reconnecting, "Reconnecting…"), (.synchronizing, "Synchronizing…")
        ] {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: true,
                                                 requiresResync: true, error: "Previous history failure")
            #expect(status.title == title)
            #expect(status.explanation.contains("needs a refresh"))
            #expect(status.explanation.contains("Previous history failure"))
            #expect(status.retryAction == nil)
        }
        let loading = CompanionRecoveryStatus(connection: .connected, isLoading: true, requiresResync: true, error: nil)
        #expect(loading.title == "Refreshing conversation…")
        #expect(!loading.title.contains("Reconnecting"))
    }

    @Test func failedOrOfflineNeverClaimsActiveRecoveryFromLeftoverHistoryLoad() {
        for (connection, title) in [(CompanionConnection.offline, "Offline"), (.failed("Retrying socket"), "Connection issue")] {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: true, requiresResync: true, error: nil)
            #expect(status.title == title)
            #expect(!status.isInProgress)
            #expect(status.retryAction == .reconnect)
        }
    }

    @Test func disconnectedClientDoesNotProveDesktopIsOffline() {
        let status = CompanionRecoveryStatus(connection: .offline, isLoading: false, requiresResync: false, error: nil)
        #expect(status.explanation.hasPrefix("Not connected to your desktop."))
        #expect(!status.explanation.contains("desktop is offline"))
        #expect(status.retryAction == .reconnect)
    }

    @Test func recoveryBlockingCopyIsScopedToConversationActions() {
        for connection in connections {
            let status = CompanionRecoveryStatus(connection: connection, isLoading: true, requiresResync: true, error: nil)
            #expect(status.explanation.contains("before sending messages or taking conversation actions"))
            #expect(!status.explanation.contains("commands"))
        }
    }

    @Test func connectedErrorAloneDoesNotClaimSendingIsBlocked() {
        let status = CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: false,
                                             error: "History could not be read")
        #expect(status.phase == .refreshFailed)
        #expect(status.explanation.contains("The conversation could not be loaded."))
        #expect(status.explanation.contains("History could not be read"))
        #expect(!status.explanation.contains("before sending"))
        #expect(!status.explanation.contains("unavailable"))
        #expect(status.retryAction == .refreshConversation)
    }

    @Test func connectedHistoryFailureDoesNotClaimMissedUpdatesOrReconnect() {
        let status = CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: true,
                                             error: "Could not read history")
        #expect(status.title == "Conversation refresh failed")
        #expect(status.retryAction == .refreshConversation)
        #expect(!status.isInProgress)
        #expect(!status.explanation.contains("missed"))
        #expect(!status.explanation.contains("reconnect"))
        #expect(status.explanation.contains("before sending messages or taking conversation actions"))
    }

    @Test func staleConnectedConversationNeedsExplicitRefreshWithoutInventedFailure() {
        let status = CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: true, error: nil)
        #expect(status.title == "Conversation needs a refresh")
        #expect(!status.hasError)
        #expect(!status.isInProgress)
        #expect(status.retryAction == .refreshConversation)
    }

    @Test func fullMultilineErrorsRemainAvailableIncludingWhenBothFail() {
        let hostError = "Certificate validation failed.\n" + String(repeating: "Desktop detail. ", count: 100)
        let historyError = "History read failed.\n" + String(repeating: "Conversation detail. ", count: 100)
        let status = CompanionRecoveryStatus(connection: .failed(hostError), isLoading: false,
                                             requiresResync: true, error: historyError)
        #expect(status.connectionError == hostError)
        #expect(status.conversationError == historyError)
        #expect(status.explanation.contains("Connection error: \(hostError)"))
        #expect(status.explanation.contains("Conversation error: \(historyError)"))
    }

    @Test func emptyFailureMessagesHaveUsefulFallbackWithoutBlankErrorParagraphs() {
        let status = CompanionRecoveryStatus(connection: .failed(" \n"), isLoading: false,
                                             requiresResync: true, error: "\t")
        #expect(status.phase == .connectionFailed)
        #expect(status.hasError)
        #expect(status.connectionError == nil)
        #expect(status.conversationError == nil)
        #expect(status.explanation.contains("Retry the connection"))
        #expect(!status.explanation.contains("error:"))
    }

    @Test func cleanConnectedStatusIsHiddenAndHasNoRecoveryAction() {
        let status = CompanionRecoveryStatus(connection: .connected, isLoading: false, requiresResync: false, error: nil)
        #expect(!status.isVisible)
        #expect(!status.isInProgress)
        #expect(!status.hasError)
        #expect(status.title.isEmpty)
        #expect(status.retryAction == nil)
    }
}
