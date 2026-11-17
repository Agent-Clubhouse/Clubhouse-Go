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

    @Test func aCachedTurnOnADesktopThatIsNotLiveKeepsTheChips() {
        for connection in [CompanionConnection.offline, .connecting, .reconnecting, .synchronizing, .failed("Lost")] {
            #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(.working), isStreaming: true, connection: connection),
                    "\(connection) isn't live")
        }
        #expect(!CompanionDispatcherTurn.collapsesChips(agent: agent(.working), isStreaming: false, connection: nil))
    }

    @Test func onlyOverlappingAvatarsGetAGapRing() {
        #expect(!CompanionDispatcherTurn.separatesAvatars(count: 1), "A single other Dispatcher draws no ring")
        #expect(CompanionDispatcherTurn.separatesAvatars(count: 2))
        #expect(CompanionDispatcherTurn.separatesAvatars(count: 3))
    }
}
