import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @State private var showPermissionReview = false
    @State private var showSpawnSheet = false

    private var isLoading: Bool {
        !store.instances.isEmpty
            && store.connectedInstances.isEmpty
            && store.instances.contains(where: {
                if case .connecting = $0.connectionState { return true }
                if case .discovering = $0.connectionState { return true }
                if case .reconnecting = $0.connectionState { return true }
                return false
            })
    }

    private var hasError: Bool {
        store.instances.contains { $0.lastError != nil }
            && store.connectedInstances.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionStatusBar()

                    if store.replayState != .idle {
                        ReplayStatusBanner(state: store.replayState)
                    }

                    if !store.connectedInstances.isEmpty {
                        if !store.allPendingPermissions.isEmpty {
                            PermissionReviewSection(onReviewAll: {
                                showPermissionReview = true
                            })
                        }

                        StatsSection()
                        RunningAgentsSection()
                        RecentActivitySection()

                        QuickActionsSection(
                            onSpawn: { showSpawnSheet = true },
                            onReviewPermissions: { showPermissionReview = true }
                        )
                    } else if isLoading {
                        DashboardLoadingView()
                    } else if hasError {
                        ErrorRetryView(
                            title: "Connection Error",
                            message: store.instances.compactMap(\.lastError).first ?? "Unable to connect to server.",
                            onRetry: {
                                Task {
                                    for inst in store.instances {
                                        await store.reconnect(instanceId: inst.id)
                                    }
                                }
                            }
                        )
                    } else if !store.instances.isEmpty {
                        DisconnectedWarningView()
                    } else {
                        NoInstancesView()
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.3), value: store.connectedInstances.count)
            }
            .refreshable {
                for inst in store.instances {
                    await store.reconnect(instanceId: inst.id)
                }
            }
            .background(store.theme.baseColor)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSpawnSheet = true } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .disabled(store.connectedInstances.isEmpty)
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
                    if instance.connectionState.isConnected {
                        Text("\(instance.runningAgentCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.2)))
                    } else {
                        Text(instance.connectionState.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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

// MARK: - Stats Section

private struct StatsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            StatCard(icon: "bolt.fill", label: "Running",
                     value: "\(store.runningAgentCount)", color: .green,
                     backgroundColor: store.theme.surface0Color.opacity(0.5))
            StatCard(icon: "person.3.fill", label: "Total Agents",
                     value: "\(store.totalAgentCount)", color: store.theme.accentColor,
                     backgroundColor: store.theme.surface0Color.opacity(0.5))
            StatCard(icon: "folder.fill", label: "Projects",
                     value: "\(store.allProjects.count)", color: .blue,
                     backgroundColor: store.theme.surface0Color.opacity(0.5))
            StatCard(icon: "lock.shield.fill", label: "Pending",
                     value: "\(store.allPendingPermissions.count)",
                     color: store.allPendingPermissions.isEmpty ? .secondary : .orange,
                     backgroundColor: store.theme.surface0Color.opacity(0.5))
        }
    }
}

private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let backgroundColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
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
                                iconData: store.agentIconData(ia.agent.id)
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
    @Environment(AppStore.self) private var store

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
            VStack(spacing: 2) {
                Text(agent.name ?? "")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if let msg = agent.detailedStatus?.message, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 80)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.theme.surface0Color.opacity(0.3))
        )
    }
}

// MARK: - Quick Actions Section

private struct QuickActionsSection: View {
    let onSpawn: () -> Void
    let onReviewPermissions: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
            HStack(spacing: 12) {
                QuickActionButton(icon: "bolt.fill", label: "Spawn Agent",
                                  color: store.theme.accentColor, action: onSpawn)
                    .accessibilityHint("Opens the agent spawn dialog")
                if !store.allPendingPermissions.isEmpty {
                    QuickActionButton(icon: "lock.shield.fill",
                                      label: "Review (\(store.allPendingPermissions.count))",
                                      color: .orange, action: onReviewPermissions)
                        .accessibilityHint("Opens the permission review flow")
                }
            }
        }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .strokeBorder(color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Loading State

private struct DashboardLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ], spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    StatCardSkeleton()
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ShimmerView(width: 120, height: 16, cornerRadius: 4)
                ForEach(0..<3, id: \.self) { _ in
                    AgentCardSkeleton()
                }
            }
        }
    }
}

// MARK: - Empty / Disconnected States

private struct DisconnectedWarningView: View {
    var body: some View {
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

private struct NoInstancesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Instances")
                .font(.title3.weight(.semibold))
            Text("Pair with a Clubhouse server to get started. Your agents, projects, and activity will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.top, 40)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return DashboardView()
        .environment(store)
}
