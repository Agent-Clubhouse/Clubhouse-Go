import SwiftUI

struct HomePluginView: View {
    let instanceId: ServerInstanceID
    @Environment(AppStore.self) private var store

    private var instance: ServerInstance? {
        store.instanceByID(instanceId)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let instance {
                    serverCard(instance)
                    agentSummary(instance)
                    recentActivity(instance)
                    quickActions(instance)
                } else {
                    ContentUnavailableView("Disconnected", systemImage: "wifi.slash", description: Text("This instance is not connected."))
                }
            }
            .padding()
        }
        .background(store.theme.baseColor)
    }

    // MARK: - Server Card

    private func serverCard(_ instance: ServerInstance) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(store.theme.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(instance.serverName.isEmpty ? "Clubhouse Server" : instance.serverName)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 6) {
                        Circle()
                            .fill(instance.connectionState.isConnected ? .green : .red)
                            .frame(width: 7, height: 7)
                        Text(instance.connectionState.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            Divider()

            HStack(spacing: 0) {
                statItem(value: "\(instance.projects.count)", label: "Projects")
                Spacer()
                statItem(value: "\(instance.totalAgentCount)", label: "Agents")
                Spacer()
                statItem(value: "\(instance.runningAgentCount)", label: "Running")
                Spacer()
                statItem(value: "\(instance.pendingPermissions.count)", label: "Pending")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(store.theme.surface0Color.opacity(0.6))
        )
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    // MARK: - Agent Summary

    private func agentSummary(_ instance: ServerInstance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agents", systemImage: "person.3.fill")
                .font(.headline)

            if instance.allAgents.isEmpty {
                Text("No agents on this instance.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(instance.allAgents.prefix(5)) { agent in
                    HStack(spacing: 10) {
                        AgentAvatarView(
                            color: agent.color ?? "gray",
                            status: agent.status,
                            state: agent.detailedStatus?.state,
                            name: agent.name,
                            iconData: instance.agentIcons[agent.id],
                            size: 32
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name ?? agent.id)
                                .font(.subheadline.weight(.medium))
                            if let mission = agent.mission {
                                Text(mission)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if let status = agent.status {
                            StatusDotView(status: status, size: 8)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if instance.allAgents.count > 5 {
                    Text("+ \(instance.allAgents.count - 5) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(store.theme.surface0Color.opacity(0.6))
        )
    }

    // MARK: - Recent Activity

    private func recentActivity(_ instance: ServerInstance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            let allEvents = instance.activityByAgent.values
                .flatMap { $0 }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(8)

            if allEvents.isEmpty {
                Text("No recent activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(allEvents), id: \.id) { event in
                    HStack(spacing: 8) {
                        Image(systemName: eventIcon(event.kind))
                            .font(.caption)
                            .foregroundStyle(eventColor(event.kind))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.toolVerb ?? event.toolName ?? event.kind.rawValue)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let agentName = instance.durableAgent(byId: event.agentId)?.name {
                                Text(agentName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(store.theme.surface0Color.opacity(0.6))
        )
    }

    private func eventIcon(_ kind: HookEventKind) -> String {
        switch kind {
        case .preTool: return "wrench"
        case .postTool: return "checkmark.circle"
        case .toolError: return "exclamationmark.triangle"
        case .stop: return "stop.circle"
        case .notification: return "bell"
        case .permissionRequest: return "lock.shield"
        }
    }

    private func eventColor(_ kind: HookEventKind) -> Color {
        switch kind {
        case .preTool: return .blue
        case .postTool: return .green
        case .toolError: return .red
        case .stop: return .orange
        case .notification: return .purple
        case .permissionRequest: return .yellow
        }
    }

    // MARK: - Quick Actions

    @State private var showSpawnSheet = false

    private func quickActions(_ instance: ServerInstance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Quick Actions", systemImage: "bolt.fill")
                .font(.headline)

            HStack(spacing: 12) {
                quickActionButton(icon: "plus.circle.fill", label: "Spawn Agent", color: store.theme.accentColor) {
                    showSpawnSheet = true
                }

                quickActionButton(icon: "arrow.clockwise.circle.fill", label: "Reconnect", color: .orange) {
                    Task {
                        await store.reconnect(instanceId: instanceId)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(store.theme.surface0Color.opacity(0.6))
        )
        .sheet(isPresented: $showSpawnSheet) {
            if let project = instance.projects.first {
                SpawnQuickAgentSheet(
                    projectId: project.id,
                    parentAgentId: nil,
                    orchestrators: instance.orchestrators
                )
            }
        }
    }

    private func quickActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(store.theme.surface1Color.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return NavigationStack {
        HomePluginView(instanceId: store.instances[0].id)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
    }
    .environment(store)
}
