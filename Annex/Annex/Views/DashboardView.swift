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

                    if !store.connectedInstances.isEmpty {
                        // Permission queue
                        if !store.allPendingPermissions.isEmpty {
                            PermissionReviewSection(onReviewAll: {
                                showPermissionReview = true
                            })
                        }

                        // Quick stats
                        StatsSection()

                        // Running agents
                        RunningAgentsSection()

                        // Recent Activity feed
                        RecentActivitySection()

                        // Quick actions
                        QuickActionsSection(
                            onSpawn: { showSpawnSheet = true },
                            onReviewPermissions: { showPermissionReview = true }
                        )
                    } else if !store.instances.isEmpty {
                        // Have instances but none connected
                        DisconnectedWarningView()
                    } else {
                        // No instances at all
                        NoInstancesView()
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
            StatCard(
                icon: "bolt.fill",
                label: "Running",
                value: "\(store.runningAgentCount)",
                color: .green
            )

            StatCard(
                icon: "person.3.fill",
                label: "Total Agents",
                value: "\(store.totalAgentCount)",
                color: store.theme.accentColor
            )

            StatCard(
                icon: "folder.fill",
                label: "Projects",
                value: "\(store.allProjects.count)",
                color: .blue
            )

            StatCard(
                icon: "lock.shield.fill",
                label: "Pending",
                value: "\(store.allPendingPermissions.count)",
                color: store.allPendingPermissions.isEmpty ? .secondary : .orange
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
                .fill(store.theme.surface0Color.opacity(0.5))
        )
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

// MARK: - Recent Activity Section

private struct RecentActivitySection: View {
    @Environment(AppStore.self) private var store

    private var recentEvents: [AgentHookEvent] {
        store.connectedInstances.flatMap { inst in
            inst.allActivityEvents.map { AgentHookEvent(event: $0, instance: inst) }
        }
        .sorted { $0.event.timestamp > $1.event.timestamp }
        .prefix(8)
        .map { $0 }
    }

    var body: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Activity")
                        .font(.headline)
                    Spacer()
                }

                VStack(spacing: 0) {
                    ForEach(Array(recentEvents.enumerated()), id: \.element.event.id) { index, item in
                        DashboardActivityRow(
                            event: item.event,
                            agentName: store.durableAgent(byId: item.event.agentId)?.name,
                            agentColor: store.durableAgent(byId: item.event.agentId)?.color,
                            accent: store.theme.accentColor
                        )

                        if index < recentEvents.count - 1 {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(store.theme.surface0Color.opacity(0.4))
                )
            }
        }
    }
}

/// Pairs a HookEvent with its source instance for cross-instance aggregation
private struct AgentHookEvent {
    let event: HookEvent
    let instance: ServerInstance
}

private struct DashboardActivityRow: View {
    let event: HookEvent
    let agentName: String?
    let agentColor: String?
    let accent: Color

    private var icon: String {
        switch event.kind {
        case .preTool: dashboardToolIcon(event.toolName)
        case .postTool: "checkmark.circle"
        case .toolError: "exclamationmark.triangle.fill"
        case .stop: "stop.circle.fill"
        case .notification: "bell.fill"
        case .permissionRequest: "lock.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .preTool: accent
        case .postTool: .green
        case .toolError: .red
        case .stop: .secondary
        case .notification: accent
        case .permissionRequest: .orange
        }
    }

    private var label: String {
        switch event.kind {
        case .preTool:
            return event.toolVerb ?? "Using \(event.toolName ?? "tool")"
        case .postTool:
            return "\(event.toolName ?? "Tool") done"
        case .toolError:
            return event.message ?? "Error"
        case .stop:
            return event.message ?? "Stopped"
        case .notification:
            return event.message ?? ""
        case .permissionRequest:
            return "Needs permission: \(event.toolName ?? "tool")"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let name = agentName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(dashboardCompactTime(event.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
                QuickActionButton(
                    icon: "bolt.fill",
                    label: "Spawn Agent",
                    color: store.theme.accentColor,
                    action: onSpawn
                )

                if !store.allPendingPermissions.isEmpty {
                    QuickActionButton(
                        icon: "lock.shield.fill",
                        label: "Review (\(store.allPendingPermissions.count))",
                        color: .orange,
                        action: onReviewPermissions
                    )
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
    @Environment(AppStore.self) private var store

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

// MARK: - Helpers

private func dashboardToolIcon(_ toolName: String?) -> String {
    switch toolName {
    case "Edit": "pencil"
    case "Read": "doc.text"
    case "Write": "doc.badge.plus"
    case "Bash": "terminal"
    case "Glob": "magnifyingglass"
    case "Grep": "text.magnifyingglass"
    case "WebSearch": "globe"
    case "WebFetch": "arrow.down.circle"
    case "Task": "arrow.triangle.branch"
    default: "wrench"
    }
}

private func dashboardCompactTime(_ unixMs: Int) -> String {
    let seconds = max(0, (Int(Date().timeIntervalSince1970 * 1000) - unixMs) / 1000)
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d"
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return DashboardView()
        .environment(store)
}
