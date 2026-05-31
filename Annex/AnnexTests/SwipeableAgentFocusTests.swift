import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Swipeable Agent Focus Tests
//
// Covers GH #94: tapping an agent (or dashboard tile) opens the swipe-card
// browser positioned on that agent. `SwipeableAgentView.initialIndex` resolves
// the starting page index from a focus agent id.

@MainActor
struct SwipeableAgentFocusTests {
    private func makeInstance() -> ServerInstance {
        ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "127.0.0.1", mainPort: 8443, pairingPort: 8080, fingerprint: "AA:BB")
        )
    }

    private func makeAgent(_ id: String, status: AgentStatus = .running) -> DurableAgent {
        DurableAgent(
            id: id, name: id, kind: "durable", color: nil,
            branch: nil, model: nil, orchestrator: nil, freeAgentMode: nil,
            icon: nil, executionMode: nil, status: status, mission: nil,
            detailedStatus: nil, quickAgents: nil
        )
    }

    private func makeAgents(_ ids: [String]) -> [AppStore.InstanceAgent] {
        let inst = makeInstance()
        return ids.map { AppStore.InstanceAgent(instance: inst, agent: makeAgent($0)) }
    }

    @Test func nilFocusReturnsFirstPage() {
        let agents = makeAgents(["a", "b", "c"])
        #expect(SwipeableAgentView.initialIndex(for: nil, in: agents) == 0)
    }

    @Test func unknownFocusReturnsFirstPage() {
        let agents = makeAgents(["a", "b", "c"])
        #expect(SwipeableAgentView.initialIndex(for: "zzz", in: agents) == 0)
    }

    @Test func knownFocusReturnsItsIndex() {
        let agents = makeAgents(["a", "b", "c"])
        #expect(SwipeableAgentView.initialIndex(for: "a", in: agents) == 0)
        #expect(SwipeableAgentView.initialIndex(for: "b", in: agents) == 1)
        #expect(SwipeableAgentView.initialIndex(for: "c", in: agents) == 2)
    }

    @Test func emptyListReturnsZero() {
        #expect(SwipeableAgentView.initialIndex(for: "a", in: []) == 0)
    }
}
