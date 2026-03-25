import SwiftUI

struct AllAgentsView: View {
    @Environment(AppStore.self) private var store
    @State private var expandedAgentIds: Set<String> = []
    @State private var showSettings = false
    @State private var hideSleeping = false

    private let maxActivityRows = 5

    private var filteredAgents: [AppStore.InstanceAgent] {
        store.allAgentsAcrossInstances.filter { ia in
            !hideSleeping || ia.agent.status == .running
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredAgents, id: \.agent.id) { ia in
                    Section {
                        NavigationLink(value: ia.agent) {
                            AgentRowView(agent: ia.agent)
                        }
                        .listRowBackground(store.theme.surface0Color.opacity(0.5))

                        HStack(spacing: 6) {
                            // Instance badge
                            if store.connectedInstances.count > 1 {
                                Image(systemName: "desktopcomputer")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(ia.instance.serverName)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if let project = ia.instance.project(for: ia.agent) {
                                ProjectIconView(
                                    name: project.name,
                                    displayName: project.displayName,
                                    iconData: store.projectIcons[project.id],
                                    size: 18
                                )
                                Text(project.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    if expandedAgentIds.contains(ia.agent.id) {
                                        expandedAgentIds.remove(ia.agent.id)
                                    } else {
                                        expandedAgentIds.insert(ia.agent.id)
                                    }
                                }
                            } label: {
                                Image(systemName: expandedAgentIds.contains(ia.agent.id)
                                      ? "chevron.up"
                                      : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(store.theme.surface0Color.opacity(0.3))

                        if expandedAgentIds.contains(ia.agent.id) {
                            let events = ia.instance.activity(for: ia.agent.id).suffix(maxActivityRows)
                            if events.isEmpty {
                                Text("No recent activity")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .listRowBackground(store.theme.surface0Color.opacity(0.2))
                            } else {
                                ForEach(Array(events)) { event in
                                    CompactActivityRow(
                                        event: event,
                                        accent: store.theme.accentColor
                                    )
                                    .listRowBackground(store.theme.surface0Color.opacity(0.2))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(store.theme.baseColor)
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation { hideSleeping.toggle() }
                    } label: {
                        Image(systemName: hideSleeping ? "eye.slash" : "eye")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(for: DurableAgent.self) { agent in
                AgentDetailView(agent: agent)
            }
            .navigationDestination(for: String.self) { value in
                if value.hasPrefix("live:") {
                    let id = String(value.dropFirst(5))
                    LiveTerminalView(agentId: id)
                }
            }
            .overlay {
                if filteredAgents.isEmpty {
                    if hideSleeping && !store.allAgentsAcrossInstances.isEmpty {
                        ContentUnavailableView(
                            "No Running Agents",
                            systemImage: "moon.zzz",
                            description: Text("All agents are sleeping. Tap the eye icon to show them.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Agents",
                            systemImage: "person.3",
                            description: Text("Agents will appear here once they're running.")
                        )
                    }
                }
            }
        }
    }
}

// Compact single-line activity row for the inline expansion
private struct CompactActivityRow: View {
    let event: HookEvent
    let accent: Color

    private var icon: String {
        switch event.kind {
        case .preTool: toolIcon(event.toolName)
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
            return "Needs permission"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(compactTime(event.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private func toolIcon(_ toolName: String?) -> String {
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

private func compactTime(_ unixMs: Int) -> String {
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
    return AllAgentsView()
        .environment(store)
}
