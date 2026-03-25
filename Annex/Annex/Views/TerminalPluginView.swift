import SwiftUI

/// Terminal plugin view — shows agents grouped by status with terminal/wake actions.
struct TerminalPluginView: View {
    let projectId: String
    let instanceId: ServerInstanceID
    @Environment(AppStore.self) private var store
    @State private var wakeAgent: DurableAgent?

    private var instance: ServerInstance? {
        store.instanceByID(instanceId)
    }

    private var agents: [DurableAgent] {
        guard let instance else { return [] }
        let project = instance.projects.first { $0.id == projectId }
        guard let project else { return [] }
        return instance.agents(for: project)
    }

    private var runningAgents: [DurableAgent] {
        agents.filter { $0.status == .running }
    }

    private var sleepingAgents: [DurableAgent] {
        agents.filter { $0.status == .sleeping }
    }

    private var completedAgents: [DurableAgent] {
        agents.filter { $0.status != .running && $0.status != .sleeping }
    }

    var body: some View {
        List {
            if agents.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Agents",
                        systemImage: "terminal",
                        description: Text("No agents in this project yet.")
                    )
                    .listRowBackground(Color.clear)
                }
            }

            if !runningAgents.isEmpty {
                Section {
                    ForEach(runningAgents) { agent in
                        TerminalAgentRow(agent: agent, action: .viewTerminal)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Running")
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.5))
            }

            if !sleepingAgents.isEmpty {
                Section("Sleeping") {
                    ForEach(sleepingAgents) { agent in
                        TerminalAgentRow(agent: agent, action: .wake) {
                            wakeAgent = agent
                        }
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.4))
            }

            if !completedAgents.isEmpty {
                Section("Completed") {
                    ForEach(completedAgents) { agent in
                        TerminalAgentRow(agent: agent, action: .viewBuffer)
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.3))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
        .sheet(item: $wakeAgent) { agent in
            WakeAgentSheet(agent: agent)
        }
    }
}

// MARK: - Terminal Agent Row

private enum TerminalAction {
    case viewTerminal
    case wake
    case viewBuffer
}

private struct TerminalAgentRow: View {
    let agent: DurableAgent
    let action: TerminalAction
    var onWake: (() -> Void)? = nil
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarView(
                color: agent.color ?? "gray",
                status: agent.status,
                state: agent.detailedStatus?.state,
                name: agent.name,
                iconData: store.agentIcons[agent.id]
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name ?? agent.id)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let msg = agent.detailedStatus?.message, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let branch = agent.branch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            switch action {
            case .viewTerminal:
                NavigationLink(value: "live:\(agent.id)") {
                    Label("Terminal", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

            case .wake:
                Button {
                    onWake?()
                } label: {
                    Label("Wake", systemImage: "alarm")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

            case .viewBuffer:
                NavigationLink(value: "live:\(agent.id)") {
                    Label("Buffer", systemImage: "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
