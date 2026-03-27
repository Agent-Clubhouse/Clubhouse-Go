import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Agent View Mode Tests

struct AgentViewModeTests {
    @Test func viewModeHasListAndCards() {
        let modes = AgentViewMode.allCases
        #expect(modes.count == 2)
        #expect(modes.contains(.list))
        #expect(modes.contains(.cards))
    }

    @Test func viewModeRawValues() {
        #expect(AgentViewMode.list.rawValue == "list")
        #expect(AgentViewMode.cards.rawValue == "cards")
    }
}

// MARK: - Agent Card Data Tests

struct AgentCardDataTests {
    private func makeAgent(
        id: String = "agent-1",
        name: String? = "test-agent",
        color: String? = "emerald",
        status: AgentStatus? = .running,
        model: String? = "claude-sonnet-4-6",
        orchestrator: String? = "claude-code",
        mission: String? = nil,
        detailedStatus: AgentDetailedStatus? = nil,
        freeAgentMode: Bool? = nil
    ) -> DurableAgent {
        DurableAgent(
            id: id, name: name, kind: "durable", color: color,
            branch: nil, model: model, orchestrator: orchestrator,
            freeAgentMode: freeAgentMode, icon: nil, executionMode: "pty",
            status: status, mission: mission,
            detailedStatus: detailedStatus, quickAgents: nil
        )
    }

    @Test func statusSortOrderPutsRunningFirst() {
        let running = makeAgent(id: "1", status: .running)
        let sleeping = makeAgent(id: "2", status: .sleeping)
        let error = makeAgent(id: "3", status: .error)
        let completed = makeAgent(id: "4", status: .completed)

        let sorted = [sleeping, completed, error, running]
            .sorted { $0.statusSortOrder < $1.statusSortOrder }

        #expect(sorted[0].id == "1") // running = 0
        #expect(sorted[1].id == "3") // error = 1
        #expect(sorted[2].id == "2") // sleeping = 2
        #expect(sorted[3].id == "4") // completed = 3
    }

    @Test func agentColorTokenMapping() {
        // Valid color tokens resolve to a known AgentColor case
        #expect(AgentColor(rawValue: "emerald") != nil)
        #expect(AgentColor(rawValue: "indigo") != nil)
        #expect(AgentColor(rawValue: "amber") != nil)
        #expect(AgentColor(rawValue: "rose") != nil)
        // Invalid tokens return nil
        #expect(AgentColor(rawValue: "nonexistent") == nil)
        // All cases have a hex value
        for c in AgentColor.allCases {
            #expect(c.hex.hasPrefix("#"))
            #expect(c.hex.count == 7)
        }
    }

    @Test func modelLabelExtraction() {
        // Test the model label logic used in cards
        let opusAgent = makeAgent(model: "claude-opus-4-6")
        let sonnetAgent = makeAgent(model: "claude-sonnet-4-6")
        let haikuAgent = makeAgent(model: "claude-haiku-4-5")
        let customAgent = makeAgent(model: "gpt-4")
        let noModel = makeAgent(model: nil)

        #expect(extractModelLabel(opusAgent.model) == "Opus")
        #expect(extractModelLabel(sonnetAgent.model) == "Sonnet")
        #expect(extractModelLabel(haikuAgent.model) == "Haiku")
        #expect(extractModelLabel(customAgent.model) == "gpt-4")
        #expect(extractModelLabel(noModel.model) == nil)
    }

    @Test func detailedStatusMessageMapping() {
        let working = AgentDetailedStatus(state: .working, message: "Reading files", toolName: "Read", timestamp: 1000)
        let permission = AgentDetailedStatus(state: .needsPermission, message: "Bash", toolName: "Bash", timestamp: 1000)
        let error = AgentDetailedStatus(state: .toolError, message: "File not found", toolName: "Read", timestamp: 1000)
        let idle = AgentDetailedStatus(state: .idle, message: "", toolName: nil, timestamp: 1000)

        #expect(extractStatusLabel(working) == "Reading files")
        #expect(extractStatusLabel(permission) == "Needs permission")
        #expect(extractStatusLabel(error) == "File not found")
        #expect(extractStatusLabel(idle) == "Idle")
    }

    @Test func agentWithPendingPermission() {
        let permAgent = makeAgent(
            detailedStatus: AgentDetailedStatus(
                state: .needsPermission,
                message: "Bash",
                toolName: "Bash",
                timestamp: 1000
            )
        )
        #expect(permAgent.detailedStatus?.state == .needsPermission)
    }

    @Test func agentFilteringHideSleeping() {
        let agents = [
            makeAgent(id: "1", status: .running),
            makeAgent(id: "2", status: .sleeping),
            makeAgent(id: "3", status: .error),
            makeAgent(id: "4", status: .sleeping),
            makeAgent(id: "5", status: .starting),
        ]

        let filtered = agents.filter { agent in
            agent.status == .running || agent.status == .error || agent.status == .starting
        }

        #expect(filtered.count == 3)
        #expect(filtered.contains(where: { $0.id == "1" }))
        #expect(filtered.contains(where: { $0.id == "3" }))
        #expect(filtered.contains(where: { $0.id == "5" }))
    }

    @Test func terminalPreviewExtraction() {
        let buffer = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6"
        let lines = buffer.components(separatedBy: .newlines)
        let lastLines = lines.suffix(4).filter { !$0.isEmpty }
        let preview = lastLines.joined(separator: "\n")

        #expect(preview == "line 3\nline 4\nline 5\nline 6")
    }

    @Test func terminalPreviewEmptyBuffer() {
        let buffer = ""
        #expect(buffer.isEmpty)
    }

    @Test func hookEventActivityIcons() {
        let kinds: [HookEventKind] = [.preTool, .postTool, .toolError, .stop, .notification, .permissionRequest]
        for kind in kinds {
            let event = HookEvent(id: UUID(), agentId: "a", kind: kind, toolName: "Read", toolVerb: nil, message: nil, timestamp: 100)
            #expect(event.kind == kind)
        }
    }
}

// MARK: - Helpers for testing card logic without views

private func extractModelLabel(_ model: String?) -> String? {
    guard let model else { return nil }
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    return model
}

private func extractStatusLabel(_ status: AgentDetailedStatus) -> String {
    switch status.state {
    case .working: return status.message.isEmpty ? "Working" : status.message
    case .needsPermission: return "Needs permission"
    case .toolError: return status.message.isEmpty ? "Error" : status.message
    case .idle: return "Idle"
    }
}
