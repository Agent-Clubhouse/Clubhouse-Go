import SwiftUI

/// Primary project-centric navigation — mirrors the desktop's project explorer rail.
/// Shows all projects across connected instances with agents, activity, and actions.
struct ProjectsTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.connectedInstances) { instance in
                    ProjectsInstanceSection(instance: instance)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(store.theme.baseColor)
            .navigationTitle("Projects")
            .navigationDestination(for: ProjectNavItem.self) { item in
                ProjectExplorerView(project: item.project, instanceId: item.instanceId)
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
                if store.allProjects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder",
                        description: Text("Connect to a Clubhouse server to see your projects.")
                    )
                }
            }
        }
    }
}

// MARK: - Instance Section (extracted for type checker)

private struct ProjectsInstanceSection: View {
    let instance: ServerInstance
    @Environment(AppStore.self) private var store

    var body: some View {
        Section {
            ForEach(instance.projects) { project in
                ProjectRowLink(project: project, instance: instance)
            }
        } header: {
            if store.connectedInstances.count > 1 {
                Text(instance.serverName.isEmpty ? "Server" : instance.serverName)
            }
        }
    }
}

private struct ProjectRowLink: View {
    let project: Project
    let instance: ServerInstance
    @Environment(AppStore.self) private var store

    var body: some View {
        let durableAgents = instance.agents(for: project)
        let quickAgents = instance.allQuickAgents(for: project)
        let runningCount = durableAgents.filter { $0.status == .running }.count
            + quickAgents.filter { $0.status == .running }.count

        NavigationLink(value: ProjectNavItem(project: project, instanceId: instance.id)) {
            ProjectCardRow(
                project: project,
                instanceName: instance.serverName,
                durableCount: durableAgents.count,
                quickCount: quickAgents.count,
                runningCount: runningCount,
                iconData: store.projectIcons[project.id]
            )
        }
        .listRowBackground(store.theme.surface0Color.opacity(0.4))
    }
}

/// Navigation value for project detail
struct ProjectNavItem: Hashable {
    let project: Project
    let instanceId: ServerInstanceID
}

// MARK: - Project Card Row

private struct ProjectCardRow: View {
    let project: Project
    let instanceName: String
    let durableCount: Int
    let quickCount: Int
    let runningCount: Int
    let iconData: Data?
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ProjectIconView(
                name: project.name,
                displayName: project.displayName,
                iconData: iconData
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(project.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label("\(durableCount)", systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if quickCount > 0 {
                        Label("\(quickCount)", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if runningCount > 0 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("\(runningCount) running")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            Spacer()

            if store.connectedInstances.count > 1 {
                Text(instanceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Project Explorer (Detail)

struct ProjectExplorerView: View {
    let project: Project
    let instanceId: ServerInstanceID
    @Environment(AppStore.self) private var store
    @State private var showSpawnSheet = false

    private var instance: ServerInstance? {
        store.instanceByID(instanceId)
    }

    private var durableAgents: [DurableAgent] {
        instance?.agents(for: project) ?? []
    }

    private var quickAgents: [QuickAgent] {
        instance?.allQuickAgents(for: project) ?? []
    }

    private var recentActivity: [HookEvent] {
        // Aggregate activity across all agents in this project
        let agentIds = durableAgents.map(\.id) + quickAgents.map(\.id)
        return agentIds
            .flatMap { store.activity(for: $0) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(20)
            .map { $0 }
    }

    private var annexPlugins: [PluginSummary] {
        (instance?.plugins ?? []).filter { $0.annexEnabled && $0.scope == "project-local" }
    }

    private var nonAnnexPlugins: [PluginSummary] {
        (instance?.plugins ?? []).filter { !$0.annexEnabled && $0.scope == "project-local" }
    }

    var body: some View {
        List {
            // Project info header
            Section {
                ProjectHeaderView(
                    project: project,
                    instanceName: instance?.serverName ?? "",
                    durableCount: durableAgents.count,
                    quickCount: quickAgents.count,
                    iconData: store.projectIcons[project.id]
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Annex-enabled plugins
            if !annexPlugins.isEmpty {
                Section("Plugins") {
                    ForEach(annexPlugins) { plugin in
                        NavigationLink(value: AnnexNav.plugin(PluginItem(
                            id: "\(instanceId.value):\(project.id):\(plugin.id)",
                            name: plugin.name,
                            pluginId: plugin.id,
                            icon: pluginIcon(plugin.id),
                            instanceId: instanceId,
                            projectId: project.id,
                            enabled: true
                        ))) {
                            HStack(spacing: 10) {
                                Image(systemName: pluginIcon(plugin.id))
                                    .frame(width: 24)
                                Text(plugin.name)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.4))
            }

            // Durable Agents
            if !durableAgents.isEmpty {
                Section("Agents") {
                    ForEach(durableAgents) { agent in
                        NavigationLink(value: agent) {
                            AgentRowView(agent: agent)
                        }
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.4))
            }

            // Quick Agents
            if !quickAgents.isEmpty {
                Section("Quick Agents") {
                    ForEach(quickAgents) { agent in
                        QuickAgentRowView(agent: agent)
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.4))
            }

            // Recent Activity
            if !recentActivity.isEmpty {
                Section("Recent Activity") {
                    ForEach(recentActivity.prefix(10)) { event in
                        ActivityEventRow(event: event)
                    }
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.4))
            }

            // Non-annex plugins (greyed out)
            if !nonAnnexPlugins.isEmpty {
                Section {
                    ForEach(nonAnnexPlugins) { plugin in
                        HStack(spacing: 10) {
                            Image(systemName: pluginIcon(plugin.id))
                                .foregroundStyle(.tertiary)
                                .frame(width: 24)
                            Text(plugin.name)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("Not Annex-enabled")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                } header: {
                    Text("Other Plugins")
                }
                .listRowBackground(store.theme.surface0Color.opacity(0.2))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
        .navigationTitle(project.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSpawnSheet = true } label: {
                    Image(systemName: "bolt.fill")
                }
            }
        }
        .navigationDestination(for: AnnexNav.self) { nav in
            if case .plugin(let item) = nav {
                PluginDetailView(item: item)
            }
        }
        .sheet(isPresented: $showSpawnSheet) {
            SpawnQuickAgentSheet(
                projectId: project.id,
                parentAgentId: nil,
                orchestrators: store.orchestrators
            )
        }
    }

    private func pluginIcon(_ pluginId: String) -> String {
        switch pluginId {
        case "terminal": return "terminal"
        case "files": return "doc.text"
        case "canvas": return "rectangle.on.rectangle.angled"
        case "home": return "house"
        case "git": return "arrow.triangle.branch"
        case "search": return "magnifyingglass"
        default: return "puzzlepiece"
        }
    }
}

// MARK: - Project Header

private struct ProjectHeaderView: View {
    let project: Project
    let instanceName: String
    let durableCount: Int
    let quickCount: Int
    let iconData: Data?
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            // Large project icon
            if let iconData, let uiImage = UIImage(data: iconData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                let color = AgentColor(rawValue: project.color ?? "indigo") ?? .indigo
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: color.hex))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Text(String(project.label.prefix(1)).uppercased())
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }

            VStack(spacing: 4) {
                Text(project.label)
                    .font(.title2.weight(.bold))

                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if !instanceName.isEmpty {
                    Text(instanceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Stats row
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("\(durableCount)")
                        .font(.title3.weight(.bold))
                    Text("Agents")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if quickCount > 0 {
                    VStack(spacing: 2) {
                        Text("\(quickCount)")
                            .font(.title3.weight(.bold))
                        Text("Quick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let orch = project.orchestrator {
                    VStack(spacing: 2) {
                        let info = store.orchestrators[orch]
                        Text(info?.shortName ?? orch)
                            .font(.title3.weight(.bold))
                        Text("Orchestrator")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - Activity Event Row

private struct ActivityEventRow: View {
    let event: HookEvent

    private var icon: String {
        switch event.kind {
        case .preTool: return "hammer.fill"
        case .postTool: return "checkmark.circle"
        case .toolError: return "exclamationmark.triangle.fill"
        case .stop: return "stop.circle"
        case .notification: return "bell.fill"
        case .permissionRequest: return "lock.shield.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .preTool: return .blue
        case .postTool: return .green
        case .toolError: return .red
        case .stop: return .secondary
        case .notification: return .orange
        case .permissionRequest: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if let toolVerb = event.toolVerb {
                    Text(toolVerb)
                        .font(.subheadline)
                        .lineLimit(1)
                } else if let toolName = event.toolName {
                    Text(toolName)
                        .font(.subheadline)
                        .lineLimit(1)
                } else {
                    Text(event.kind.rawValue)
                        .font(.subheadline)
                }

                if let msg = event.message, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(relativeTime(from: event.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func relativeTime(from unixMs: Int) -> String {
        let seconds = max(0, (Int(Date().timeIntervalSince1970 * 1000) - unixMs) / 1000)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return ProjectsTabView()
        .environment(store)
}
