import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @State private var showPermissionReview = false
    @State private var showSpawnSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection status
                    ConnectionStatusBar()

                    // Disconnected warning
                    if !store.connectedInstances.isEmpty {
                        // Permission queue
                        if !store.allPendingPermissions.isEmpty {
                            PermissionReviewSection(onReviewAll: {
                                showPermissionReview = true
                            })
                        }

                        // Running agents
                        RunningAgentsSection()

                        // Quick stats
                        StatsSection()
                    } else if !store.instances.isEmpty {
                        // Have instances but none connected
                        VStack(spacing: 16) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("All Instances Offline")
                                .font(.title3.weight(.semibold))
                            Text("Your Clubhouse servers aren't reachable. Check that they're running and on the same network.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
            .background(store.theme.baseColor)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSpawnSheet = true } label: {
                        Image(systemName: "bolt.fill")
                    }
                }
            }
            .fullScreenCover(isPresented: $showPermissionReview) {
                PermissionReviewFlow()
            }
            .sheet(isPresented: $showSpawnSheet) {
                MultiInstanceSpawnSheet()
            }
        }
    }
}

// MARK: - Connection Status Bar

private struct ConnectionStatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ForEach(store.instances) { instance in
                HStack(spacing: 6) {
                    Circle()
                        .fill(instance.connectionState.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(instance.serverName.isEmpty ? "Server" : instance.serverName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("\(instance.runningAgentCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.2)))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.theme.surface0Color.opacity(0.5))
        )
    }
}

// MARK: - Permission Review Section

private struct PermissionReviewSection: View {
    @Environment(AppStore.self) private var store
    let onReviewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("\(store.allPendingPermissions.count) Permission\(store.allPendingPermissions.count == 1 ? "" : "s") Waiting")
                    .font(.headline)
                Spacer()
                Button("Review All") { onReviewAll() }
                    .font(.subheadline.weight(.semibold))
            }

            ForEach(store.allPendingPermissions.prefix(3)) { perm in
                MiniPermissionCard(permission: perm)
            }

            if store.allPendingPermissions.count > 3 {
                Text("+ \(store.allPendingPermissions.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.08))
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct MiniPermissionCard: View {
    let permission: AppStore.InstancePermission
    @Environment(AppStore.self) private var store
    @State private var isResponding = false

    var body: some View {
        HStack(spacing: 10) {
            let agent = store.durableAgent(byId: permission.permission.agentId)
            AgentAvatarView(
                color: agent?.color ?? "gray",
                status: .running,
                state: .needsPermission,
                name: agent?.name,
                size: 28
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(agent?.name ?? "Agent")
                    .font(.subheadline.weight(.medium))
                Text(permission.permission.toolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(permission.instance.serverName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.secondary.opacity(0.15)))

            Button {
                Task { await respond(allow: true) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(isResponding)

            Button {
                Task { await respond(allow: false) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
    }

    private func respond(allow: Bool) async {
        isResponding = true
        try? await store.respondToPermission(
            agentId: permission.permission.agentId,
            requestId: permission.permission.id,
            allow: allow
        )
        isResponding = false
    }
}

// MARK: - Running Agents Section

private struct RunningAgentsSection: View {
    @Environment(AppStore.self) private var store

    private var runningAgents: [AppStore.InstanceAgent] {
        store.allAgentsAcrossInstances.filter { $0.agent.status == .running }
    }

    var body: some View {
        if !runningAgents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Running Agents")
                        .font(.headline)
                    Spacer()
                    Text("\(runningAgents.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(runningAgents, id: \.agent.id) { ia in
                            RunningAgentTile(
                                agent: ia.agent,
                                instanceName: ia.instance.serverName,
                                iconData: store.agentIcons[ia.agent.id]
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct RunningAgentTile: View {
    let agent: DurableAgent
    let instanceName: String
    let iconData: Data?

    var body: some View {
        VStack(spacing: 8) {
            AgentAvatarView(
                color: agent.color ?? "gray",
                status: agent.status,
                state: agent.detailedStatus?.state,
                name: agent.name,
                iconData: iconData,
                size: 44
            )

            Text(agent.name ?? "")
                .font(.caption2.weight(.medium))
                .lineLimit(1)

            Text(instanceName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 72)
    }
}

// MARK: - Stats Section

private struct StatsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                icon: "person.3.fill",
                label: "Total Agents",
                value: "\(store.totalAgentCount)",
                color: store.theme.accentColor
            )

            StatCard(
                icon: "bolt.fill",
                label: "Running",
                value: "\(store.runningAgentCount)",
                color: .green
            )

            StatCard(
                icon: "desktopcomputer",
                label: "Instances",
                value: "\(store.connectedInstances.count)",
                color: .blue
            )
        }
    }
}

private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.theme.surface0Color.opacity(0.5))
        )
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return DashboardView()
        .environment(store)
}
