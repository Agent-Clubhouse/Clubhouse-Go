import Testing
@testable import ClubhouseGo

/// #529/#537: which Dispatcher states take the chips' reading space, and when the stack draws a gap ring.
@MainActor struct CompanionDispatcherTurnTests {
    private func agent(_ status: CompanionAgentStatus) -> CompanionAgent {
        CompanionAgent(id: .init(hostID: "studio", projectID: CompanionDispatcher.defaultProjectID, agentID: "dispatcher"),
                       name: "Navi", subtitle: "", status: status)
    }

    @Test func theWholeLiveTurnCollapsesIncludingPromptsInTheMiddle() {
        for status in [CompanionAgentStatus.working, .approval, .waiting] {
            #expect(CompanionDispatcherTurn.collapsesChips(agent: agent(status), isStreaming: false, connection: .connected),
                    "\(status) is part of the turn")
        }
        #expect(CompanionDispatcherTurn.collapsesChips(agent: agent(.idle), isStreaming: true, connection: .connected),
                "A streamed reply is in a turn")
        for status in [CompanionAgentStatus.idle, .completed, .failed, .stopped, .sleeping, .starting] {
            #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(status), isStreaming: false, connection: .connected),
                    "\(status) is between turns")
        }
        #expect(!CompanionDispatcherTurn.collapsesChips(agent: nil, isStreaming: false, connection: .connected))
    }

    @Test func aCachedTurnOnAnOfflineOrFailedDesktopKeepsTheChips() {
        for connection in [CompanionConnection.offline, .failed("Lost")] {
            #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(.working), isStreaming: true, connection: connection),
                    "\(connection) has no live turn")
        }
        #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(.working), isStreaming: false, connection: nil))
    }

    @Test func onlyOfflineOrFailedDesktopsAreNotLive() {
        for connection in [CompanionConnection.offline, .failed("Lost")] { #expect(!CompanionDispatcherTurn.isLive(connection)) }
        #expect(!CompanionDispatcherTurn.isLive(nil))
        for connection in [CompanionConnection.connecting, .reconnecting, .synchronizing, .connected] {
            #expect(CompanionDispatcherTurn.isLive(connection), "\(connection) keeps a known turn")
        }
    }

    @Test func theTurnIgnoresTheConnection() {
        #expect(CompanionDispatcherTurn.inTurn(agent: agent(.approval), isStreaming: false))
        #expect(!CompanionDispatcherTurn.inTurn(agent: agent(.idle), isStreaming: false))
    }

    @Test func aConnectionBlipKeepsTheTurn() {
        for connection in [CompanionConnection.connecting, .reconnecting, .synchronizing] {
            #expect(CompanionDispatcherTurn.collapsesChips(agent: agent(.working), isStreaming: false, connection: connection),
                    "\(connection) is a blip, not the end of the turn")
            #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(.idle), isStreaming: false, connection: connection))
        }
    }

    @Test func onlyOverlappingAvatarsGetAGapRing() {
        #expect(!CompanionDispatcherTurn.separatesAvatars(count: 1), "A single other Dispatcher draws no ring")
        #expect(CompanionDispatcherTurn.separatesAvatars(count: 2))
        #expect(CompanionDispatcherTurn.separatesAvatars(count: 3))
    }
}
