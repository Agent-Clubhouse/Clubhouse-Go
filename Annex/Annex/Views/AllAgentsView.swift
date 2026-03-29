import SwiftUI

struct AllAgentsView: View {
    @Environment(AppStore.self) private var store
    @State private var expandedAgentIds: Set<String> = []
    @State private var showSettings = false
    @State private var hideSleeping = false
    @State private var sortOrder: AgentSortOrder = .status
    @State private var viewMode: AgentViewMode = .list

    private let maxActivityRows = 5

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

    private var filteredAgents: [AppStore.InstanceAgent] {
        let agents = store.allAgentsAcrossInstances.filter { ia in
            !hideSleeping || ia.agent.status == .running || ia.agent.status == .error || ia.agent.status == .starting
        }
        switch sortOrder {
        case .status:
            return agents.sorted { $0.agent.statusSortOrder < $1.agent.statusSortOrder }
        case .name:
            return agents.sorted { ($0.agent.name ?? "") < ($1.agent.name ?? "") }
        case .activity:
            return agents.sorted { latestTimestamp(for: $0) > latestTimestamp(for: $1) }
        }
    }

    private func latestTimestamp(for ia: AppStore.InstanceAgent) -> Int {
        ia.agent.detailedStatus?.timestamp
            ?? ia.instance.activity(for: ia.agent.id).last?.timestamp
            ?? 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    List {
                        ForEach(0..<4, id: \.self) { _ in
                            AgentCardSkeleton()
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else if hasError {
                    ErrorRetryView(
                        title: "Connection Error",
                        message: store.instances.compactMap(\.lastError).first ?? "Unable to reach server.",
                        onRetry: {
                            Task {
                                for inst in store.instances {
                                    await store.reconnect(instanceId: inst.id)
                                }
                            }
                        }
                    )
                } else if viewMode == .cards {
                    SwipeableAgentView(agents: filteredAgents)
                } else {
                    agentList
                }
            }
            .background(store.theme.baseColor)
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            withAnimation { hideSleeping.toggle() }
                        } label: {
                            Label(
                                hideSleeping ? "Show All" : "Hide Sleeping",
                                systemImage: hideSleeping ? "eye" : "eye.slash"
                            )
                        }

                        Divider()

                        Picker("Sort", selection: $sortOrder) {
                            Label("Status", systemImage: "circle.fill").tag(AgentSortOrder.status)
                            Label("Name", systemImage: "textformat").tag(AgentSortOrder.name)
                            Label("Activity", systemImage: "clock").tag(AgentSortOrder.activity)
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewMode = viewMode == .list ? .cards : .list
                        }
                    } label: {
                        Image(systemName: viewMode == .list
                              ? "rectangle.stack"
                              : "list.bullet")
                    }
                    .accessibilityLabel(viewMode == .list ? "Card View" : "List View")
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
        }
    }

    private var agentList: some View {
        List {
            ForEach(filteredAgents, id: \.agent.id) { ia in
                Section {
                    NavigationLink(value: ia.agent) {
                        AgentCardRow(
                            agent: ia.agent,
                            instance: ia.instance,
                            showInstance: store.connectedInstances.count > 1
                        )
                    }
                    .listRowBackground(store.theme.surface0Color.opacity(0.5))

                    // Expandable activity detail
                    HStack(spacing: 6) {
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
                                iconData: store.projectIconData(project.id),
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
        .refreshable {
            for inst in store.instances {
                await store.reconnect(instanceId: inst.id)
            }
        }
        .overlay {
            if filteredAgents.isEmpty {
                if hideSleeping && !store.allAgentsAcrossInstances.isEmpty {
                    ContentUnavailableView(
                        "No Running Agents",
                        systemImage: "moon.zzz",
                        description: Text("All agents are sleeping. Tap the filter icon to show them.")
                    )
                } else if store.connectedInstances.isEmpty {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect to a Clubhouse server to see your agents.")
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

// MARK: - View Mode (exposed for tests via @testable)

enum AgentViewMode: String, CaseIterable {
    case list
    case cards
}

// MARK: - Sort Order (exposed for tests via @testable)

enum AgentSortOrder: String, CaseIterable {
    case status
    case name
    case activity
}

// MARK: - Agent Card Row

private struct AgentCardRow: View {
    let agent: DurableAgent
    let instance: ServerInstance
    let showInstance: Bool
    @Environment(AppStore.self) private var store

    private var preview: String {
        if agent.status == .running, let msg = agent.detailedStatus?.message, !msg.isEmpty {
            return msg
        }
        if let mission = agent.mission {
            return mission
        }
        if let status = agent.status {
            return status.rawValue.capitalized
        }
        return ""
    }

    private var modelLabel: String? {
        guard let model = agent.model else { return nil }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    private var orchestratorLabel: String? {
        guard let orchId = agent.orchestrator,
              let info = store.orchestrators[orchId] else { return nil }
        return info.shortName
    }

    private var statusColor: Color {
        switch agent.detailedStatus?.state {
        case .working: return .green
        case .needsPermission: return .orange
        case .toolError: return .yellow
        default:
            switch agent.status {
            case .starting, .running: return .green
            case .sleeping: return .gray
            case .error, .failed: return .red
            case .completed: return .blue
            case .cancelled, .unknown: return .gray
            case nil: return .gray
            }
        }
    }

    private var projectName: String? {
        instance.project(for: agent)?.label
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status color indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 4, height: 44)
                .accessibilityHidden(true)

            AgentAvatarView(
                color: agent.color ?? "gray",
                status: agent.status,
                state: agent.detailedStatus?.state,
                name: agent.name,
                iconData: store.agentIconData(agent.id)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(agent.name ?? agent.id)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if let label = orchestratorLabel {
                        let c = OrchestratorColors.colors(for: agent.orchestrator)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                    if let label = modelLabel {
                        let c = ModelColors.colors(for: agent.model)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                    if agent.freeAgentMode == true {
                        ChipView(text: "Free", bg: .red.opacity(0.15), fg: .red)
                    }
                }

                HStack(spacing: 6) {
                    if let project = projectName {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if let ts = agent.detailedStatus?.timestamp {
                Text(compactRelativeTime(from: ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// Compact single-line activity row for the inline expansion
private struct CompactActivityRow: View {
    let event: HookEvent
    let accent: Color

    private var icon: String {
        switch event.kind {
        case .preTool: toolIcon(for: event.toolName)
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

            Text(compactRelativeTime(from: event.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return AllAgentsView()
        .environment(store)
}
